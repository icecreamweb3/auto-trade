\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_optimizer_trial_results (
    optimizer_trial_result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id                   uuid NOT NULL UNIQUE
                              REFERENCES strategy_training.training_tasks,
    optimizer_run_id          uuid NOT NULL
                              REFERENCES strategy_training.training_optimizer_runs,
    iteration_id              uuid NOT NULL REFERENCES strategy_training.training_iterations,
    trial_number              integer NOT NULL CHECK (trial_number >= 0),
    search_space_config_version_id uuid NOT NULL
                              REFERENCES strategy_training.training_config_versions,
    candidate_content_hash    char(64) NOT NULL,
    trial_state               varchar(16) NOT NULL
                              CHECK (trial_state IN ('COMPLETE', 'FAIL')),
    train_objective           numeric,
    rejection_codes           jsonb NOT NULL,
    train_evidence_hash       char(64),
    result_hash               char(64) NOT NULL,
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (candidate_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(rejection_codes) = 'array'),
    CHECK (train_evidence_hash IS NULL OR train_evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (result_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (trial_state = 'COMPLETE' AND train_objective IS NOT NULL
                                  AND train_evidence_hash IS NOT NULL
                                  AND rejection_codes = '[]'::jsonb)
        OR
        (trial_state = 'FAIL' AND train_objective IS NULL
                              AND train_evidence_hash IS NULL
                              AND jsonb_array_length(rejection_codes) > 0)
    ),
    UNIQUE (optimizer_run_id, trial_number)
);

CREATE OR REPLACE FUNCTION strategy_training.training_optimizer_trial_context(
    p_task_id uuid,
    p_lease_token uuid
)
RETURNS TABLE (
    optimizer_run_id uuid,
    iteration_id uuid,
    trial_number integer,
    candidate_parameters jsonb,
    candidate_content_hash char(64),
    search_space_config_version_id uuid,
    search_space_semver text,
    search_space_config jsonb,
    train_objective numeric,
    train_evidence_hash char(64)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    run_record strategy_training.training_optimizer_runs%ROWTYPE;
    iteration_record strategy_training.training_iterations%ROWTYPE;
    payload_trial_text text;
    expected_source text;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'OPTIMIZER'
       OR task_record.task_type <> 'OPTIMIZER_TRIAL'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'optimizer trial requires its active optimizer lease'
            USING ERRCODE = '40001';
    END IF;
    IF task_record.optimizer_run_id IS NULL OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'optimizer trial task requires optimizer_run_id and iteration_id'
            USING ERRCODE = '23514';
    END IF;
    payload_trial_text := task_record.task_payload ->> 'trial_number';
    IF jsonb_typeof(task_record.task_payload -> 'trial_number') <> 'number'
       OR payload_trial_text !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'optimizer trial_number must be a non-negative integer'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT run_record
    FROM strategy_training.training_optimizer_runs run
    WHERE run.optimizer_run_id = task_record.optimizer_run_id;
    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;
    expected_source := CASE run_record.optimizer_kind
        WHEN 'TPE' THEN 'OPTUNA_TPE'
        WHEN 'RANDOM' THEN 'RANDOM_SEARCH'
        ELSE NULL
    END;
    IF run_record.state <> 'RUNNING'
       OR run_record.experiment_id <> task_record.experiment_id
       OR iteration_record.experiment_id <> task_record.experiment_id
       OR iteration_record.candidate_source <> expected_source
       OR payload_trial_text::integer >= run_record.trial_budget THEN
        RAISE EXCEPTION 'optimizer task is outside its active run contract'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_experiment_config_bindings binding
        WHERE binding.experiment_id = task_record.experiment_id
          AND binding.config_type = 'SEARCH_SPACE'
          AND binding.config_version_id = run_record.search_space_config_version_id
    ) THEN
        RAISE EXCEPTION 'optimizer search space is not frozen on the experiment'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    SELECT run_record.optimizer_run_id,
           iteration_record.iteration_id,
           payload_trial_text::integer,
           iteration_record.candidate_parameters,
           iteration_record.candidate_content_hash,
           config.config_version_id,
           config.semver::text,
           config.config_json,
           objective.objective_value,
           objective.evidence_hash
    FROM strategy_training.training_config_versions config
    LEFT JOIN strategy_training.optimizer_train_objectives objective
      ON objective.iteration_id = iteration_record.iteration_id
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.config_type = 'SEARCH_SPACE'
      AND config.status = 'READY';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_optimizer_trial_result(
    p_task_id uuid,
    p_lease_token uuid,
    p_trial_state text,
    p_train_objective numeric,
    p_rejection_codes jsonb,
    p_train_evidence_hash char(64),
    p_result_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    context_record record;
    new_id uuid := gen_random_uuid();
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_optimizer_trial_context(p_task_id, p_lease_token);
    IF p_trial_state = 'COMPLETE' THEN
        IF context_record.train_objective IS NULL
           OR p_train_objective IS DISTINCT FROM context_record.train_objective
           OR p_train_evidence_hash IS DISTINCT FROM context_record.train_evidence_hash
           OR p_rejection_codes <> '[]'::jsonb THEN
            RAISE EXCEPTION 'complete optimizer trial must use its TRAIN-only objective'
                USING ERRCODE = '23514';
        END IF;
    ELSIF p_trial_state = 'FAIL' THEN
        IF p_train_objective IS NOT NULL OR p_train_evidence_hash IS NOT NULL
           OR jsonb_typeof(p_rejection_codes) IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_rejection_codes) = 0 THEN
            RAISE EXCEPTION 'failed optimizer trial requires rejection codes and no objective'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'optimizer trial state must be COMPLETE or FAIL'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_optimizer_trial_results (
        optimizer_trial_result_id, task_id, optimizer_run_id, iteration_id,
        trial_number, search_space_config_version_id, candidate_content_hash,
        trial_state, train_objective, rejection_codes, train_evidence_hash, result_hash
    ) VALUES (
        new_id, p_task_id, context_record.optimizer_run_id,
        context_record.iteration_id, context_record.trial_number,
        context_record.search_space_config_version_id,
        context_record.candidate_content_hash, p_trial_state,
        p_train_objective, p_rejection_codes, p_train_evidence_hash, p_result_hash
    );
    RETURN new_id;
END
$$;

CREATE TRIGGER trg_training_optimizer_trial_results_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_optimizer_trial_results
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_optimizer_trial_results OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_optimizer_trial_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_optimizer_trial_result(
    uuid, uuid, text, numeric, jsonb, char(64), char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_optimizer_trial_results FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_optimizer_trial_context(uuid, uuid)
FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_training_optimizer_trial_result(
    uuid, uuid, text, numeric, jsonb, char(64), char(64)
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.training_optimizer_trial_context(uuid, uuid)
TO tb2_training_optimizer;
GRANT EXECUTE ON FUNCTION strategy_training.record_training_optimizer_trial_result(
    uuid, uuid, text, numeric, jsonb, char(64), char(64)
) TO tb2_training_optimizer;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '044_training_optimizer_trial_context',
    encode(digest('auto_trade_v2_044_training_optimizer_trial_context_v1', 'sha256'), 'hex'),
    'Persist lease-bound optimizer tell results using TRAIN-only objective evidence'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
