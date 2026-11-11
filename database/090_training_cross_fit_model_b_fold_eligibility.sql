\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_cross_fit_model_b_fold_eligibility (
    cross_fit_execution_id uuid NOT NULL
        REFERENCES strategy_training.training_cross_fit_executions,
    outer_fold_number integer NOT NULL CHECK (outer_fold_number > 0),
    eligibility varchar(16) NOT NULL CHECK (eligibility IN ('WARMUP', 'ELIGIBLE')),
    prior_training_event_count bigint NOT NULL CHECK (prior_training_event_count >= 0),
    fold_out_event_count bigint NOT NULL CHECK (fold_out_event_count >= 0),
    fold_out_effective_day_count integer NOT NULL CHECK (fold_out_effective_day_count >= 0),
    training_end_at timestamptz NOT NULL,
    prediction_start_at timestamptz NOT NULL,
    prediction_end_at timestamptz NOT NULL,
    eligibility_hash char(64) NOT NULL CHECK (eligibility_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_execution_id, outer_fold_number),
    CHECK (training_end_at <= prediction_start_at
           AND prediction_start_at < prediction_end_at),
    CHECK ((eligibility = 'WARMUP' AND prior_training_event_count = 0)
        OR (eligibility = 'ELIGIBLE' AND prior_training_event_count > 0
             AND fold_out_event_count > 0 AND fold_out_effective_day_count > 0))
);

CREATE TRIGGER trg_training_cross_fit_model_b_fold_eligibility_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_cross_fit_model_b_fold_eligibility
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.freeze_cross_fit_model_b_fold_eligibility(
    p_cross_fit_execution_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
        protocol_json jsonb; minimum_events_per_fold bigint;
        eligible_folds integer; eligible_days integer; eligible_events bigint;
        frozen_fold_count integer; expected_fold_count integer;
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state = 'INSUFFICIENT_POWER' THEN
        RETURN 'INSUFFICIENT_POWER';
    END IF;
    IF execution_record.state <> 'CANDIDATE_READY' THEN
        RAISE EXCEPTION 'Model-B fold eligibility requires CANDIDATE_READY corpus'
            USING ERRCODE = '55000';
    END IF;
    SELECT * INTO STRICT corpus_record
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND corpus_use = 'GO_NO_GO';
    SELECT config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id
      AND config_type = 'CROSS_FIT_PROTOCOL' AND status = 'READY';
    minimum_events_per_fold := (
        protocol_json #>> '{q036_go_no_go,minimum_complete_events_per_fold}'
    )::bigint;

    INSERT INTO strategy_training.training_cross_fit_model_b_fold_eligibility (
        cross_fit_execution_id, outer_fold_number, eligibility,
        prior_training_event_count, fold_out_event_count,
        fold_out_effective_day_count, training_end_at,
        prediction_start_at, prediction_end_at, eligibility_hash
    )
    SELECT p_cross_fit_execution_id, boundary.outer_fold_number,
           CASE WHEN boundary.prior_count = 0 THEN 'WARMUP' ELSE 'ELIGIBLE' END,
           boundary.prior_count, boundary.fold_count, boundary.fold_days,
           boundary.training_end_at, boundary.prediction_start_at,
           boundary.prediction_end_at,
           encode(digest(concat_ws('|', p_cross_fit_execution_id,
               boundary.outer_fold_number,
               CASE WHEN boundary.prior_count = 0 THEN 'WARMUP' ELSE 'ELIGIBLE' END,
               boundary.prior_count, boundary.fold_count, boundary.fold_days,
               boundary.training_end_at, boundary.prediction_start_at,
               boundary.prediction_end_at, corpus_record.corpus_hash),
               'sha256'), 'hex')
    FROM (
        SELECT scope.outer_fold_number,
               min(scope.effective_train_end_at) AS training_end_at,
               min(scope.prediction_start_at) AS prediction_start_at,
               min(scope.prediction_end_at) AS prediction_end_at,
               count(DISTINCT member.entry_event_id) FILTER (
                   WHERE entry.signal_time < scope.effective_train_end_at
               ) AS prior_count,
               count(DISTINCT member.entry_event_id) FILTER (
                   WHERE entry.signal_time >= scope.prediction_start_at
                     AND entry.signal_time < scope.prediction_end_at
               ) AS fold_count,
               count(DISTINCT (entry.signal_time AT TIME ZONE 'UTC')::date) FILTER (
                   WHERE entry.signal_time >= scope.prediction_start_at
                     AND entry.signal_time < scope.prediction_end_at
               )::integer AS fold_days
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        JOIN strategy_training.training_cross_fit_corpus_events member
          ON member.cross_fit_corpus_id = corpus_record.cross_fit_corpus_id
        JOIN strategy_training.training_entry_events entry
          ON entry.entry_event_id = member.entry_event_id
        WHERE scope.cross_fit_execution_id = p_cross_fit_execution_id
          AND scope.optimizer_role = 'TPE'
        GROUP BY scope.outer_fold_number
    ) boundary
    ON CONFLICT (cross_fit_execution_id, outer_fold_number) DO NOTHING;

    SELECT count(DISTINCT scope.outer_fold_number) INTO expected_fold_count
    FROM strategy_training.training_cross_fit_optimizer_scopes scope
    WHERE scope.cross_fit_execution_id = p_cross_fit_execution_id
      AND scope.optimizer_role = 'TPE';
    SELECT count(*) INTO frozen_fold_count
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
    WHERE eligibility.cross_fit_execution_id = p_cross_fit_execution_id;
    IF frozen_fold_count <> expected_fold_count OR frozen_fold_count = 0 THEN
        RAISE EXCEPTION 'Model-B eligibility snapshot does not cover every outer fold'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
        WHERE eligibility.cross_fit_execution_id = p_cross_fit_execution_id
          AND eligibility.eligibility = 'ELIGIBLE'
          AND eligibility.fold_out_event_count < minimum_events_per_fold
    ) THEN
        RAISE EXCEPTION 'eligible Model-B fold is below its frozen event minimum'
            USING ERRCODE = '23514';
    END IF;
    SELECT count(*) FILTER (WHERE eligibility = 'ELIGIBLE'),
           COALESCE(sum(fold_out_effective_day_count)
                    FILTER (WHERE eligibility = 'ELIGIBLE'), 0),
           COALESCE(sum(fold_out_event_count)
                    FILTER (WHERE eligibility = 'ELIGIBLE'), 0)
    INTO eligible_folds, eligible_days, eligible_events
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    IF eligible_folds < execution_record.minimum_effective_folds
       OR eligible_days < execution_record.minimum_effective_days
       OR eligible_events < execution_record.minimum_event_count THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'INSUFFICIENT_POWER',
            failure_code = 'MODEL_B_NESTED_INSUFFICIENT_POWER',
            completed_at = clock_timestamp(), lease_token = NULL,
            leased_by = NULL, lease_expires_at = NULL
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
        RETURN 'INSUFFICIENT_POWER';
    END IF;
    RETURN 'ELIGIBLE';
END
$$;

ALTER TABLE strategy_training.training_cross_fit_model_b_fold_eligibility
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid)
OWNER TO tb2_training_owner;
REVOKE ALL ON strategy_training.training_cross_fit_model_b_fold_eligibility FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid) FROM PUBLIC;
GRANT SELECT ON strategy_training.training_cross_fit_model_b_fold_eligibility
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid)
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('090_training_cross_fit_model_b_fold_eligibility',
    encode(digest('auto_trade_v2_090_training_cross_fit_model_b_fold_eligibility_v1',
                  'sha256'), 'hex'),
    'Freeze outcome-blind Model-B warm-up folds and stop insufficient nested power')
ON CONFLICT (version) DO NOTHING;

COMMIT;
