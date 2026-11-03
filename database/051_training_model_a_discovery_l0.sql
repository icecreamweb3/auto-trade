\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_tasks
DROP CONSTRAINT training_tasks_task_type_check;
ALTER TABLE strategy_training.training_tasks
ADD CONSTRAINT training_tasks_task_type_check CHECK (task_type IN (
    'DATASET_BUILD', 'MODEL_A_CANDIDATE_SCAN', 'MODEL_A_EVALUATION',
    'MODEL_A_L0_AGGREGATION', 'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION',
    'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY'
));

CREATE OR REPLACE FUNCTION strategy_training.enforce_training_task_payload_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE payload_version_text text; expected_executor text;
BEGIN
    IF jsonb_typeof(NEW.task_payload -> 'task_type') <> 'string'
       OR NEW.task_payload ->> 'task_type' IS DISTINCT FROM NEW.task_type THEN
        RAISE EXCEPTION 'task payload task_type must match the task row'
            USING ERRCODE = '23514';
    END IF;
    payload_version_text := NEW.task_payload ->> 'payload_version';
    IF jsonb_typeof(NEW.task_payload -> 'payload_version') <> 'number'
       OR payload_version_text !~ '^[1-9][0-9]*$' THEN
        RAISE EXCEPTION 'task payload_version must be a positive integer'
            USING ERRCODE = '23514';
    END IF;
    expected_executor := CASE NEW.task_type
        WHEN 'DATASET_BUILD' THEN 'WORKER'
        WHEN 'MODEL_A_CANDIDATE_SCAN' THEN 'WORKER'
        WHEN 'MODEL_A_EVALUATION' THEN 'EVALUATOR'
        WHEN 'MODEL_A_L0_AGGREGATION' THEN 'EVALUATOR'
        WHEN 'MODEL_B_REPLAY' THEN 'MODEL_B'
        WHEN 'PORTFOLIO_EVALUATION' THEN 'EVALUATOR'
        WHEN 'OPTIMIZER_TRIAL' THEN 'OPTIMIZER'
        WHEN 'ARCHIVE_VERIFY' THEN 'EVALUATOR'
        ELSE NULL
    END;
    IF expected_executor IS NULL OR NEW.executor_kind <> expected_executor THEN
        RAISE EXCEPTION 'task type % requires executor %, received %',
            NEW.task_type, expected_executor, NEW.executor_kind
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_model_a_scoring_config()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE weights jsonb; expected_weight_keys constant text[] := ARRAY[
    'concentration_penalty', 'cross_period_stability', 'entry_timing',
    'excess_mfe_quality', 'false_signal_penalty', 'low_sample_penalty',
    'opportunity_recall'
]; actual_keys text[];
BEGIN
    IF NEW.config_type <> 'SCORING_MODEL_A' OR NEW.status <> 'READY'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'READY') THEN
        RETURN NEW;
    END IF;
    weights := NEW.config_json -> 'weights';
    SELECT array_agg(key ORDER BY key) INTO actual_keys FROM jsonb_object_keys(weights) key;
    IF NEW.config_json ->> 'calculation_version' <> 'DISCOVERY_V1'
       OR jsonb_typeof(weights) IS DISTINCT FROM 'object'
       OR actual_keys IS DISTINCT FROM expected_weight_keys
       OR EXISTS (
            SELECT 1 FROM jsonb_each(weights) item
            WHERE jsonb_typeof(item.value) <> 'number'
               OR (item.value #>> '{}')::numeric < 0
       )
       OR jsonb_typeof(NEW.config_json -> 'entry_timing_scale_percent') <> 'number'
       OR (NEW.config_json ->> 'entry_timing_scale_percent')::numeric <= 0
       OR jsonb_typeof(NEW.config_json -> 'excess_mfe_scale_percent') <> 'number'
       OR (NEW.config_json ->> 'excess_mfe_scale_percent')::numeric <= 0 THEN
        RAISE EXCEPTION 'READY SCORING_MODEL_A requires exact DISCOVERY_V1 weights and scales'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(ARRAY[
            'minimum_signal_count', 'minimum_opportunity_count',
            'minimum_effective_day_count', 'minimum_week_count'
        ]) field_name
        WHERE jsonb_typeof(NEW.config_json -> field_name) <> 'number'
           OR (NEW.config_json ->> field_name)::numeric <= 0
           OR (NEW.config_json ->> field_name)::numeric % 1 <> 0
    ) THEN
        RAISE EXCEPTION 'SCORING_MODEL_A minimum counts must be positive integers'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_model_a_scoring_config
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_model_a_scoring_config();

CREATE TABLE strategy_training.training_opportunity_universe_versions (
    opportunity_universe_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    opportunity_definition_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    status varchar(16) NOT NULL CHECK (status IN ('BUILDING', 'READY')),
    event_count bigint,
    opportunity_count bigint,
    universe_fingerprint char(64),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    UNIQUE (dataset_version_id, opportunity_definition_version_id),
    CHECK ((status = 'BUILDING' AND event_count IS NULL AND opportunity_count IS NULL
                                 AND universe_fingerprint IS NULL AND completed_at IS NULL)
        OR (status = 'READY' AND event_count > 0 AND opportunity_count >= 0
                             AND opportunity_count <= event_count
                             AND universe_fingerprint ~ '^[0-9a-f]{64}$'
                             AND completed_at IS NOT NULL))
);

CREATE TABLE strategy_training.training_opportunity_universe_events (
    opportunity_event_id char(64) PRIMARY KEY,
    opportunity_universe_id uuid NOT NULL
        REFERENCES strategy_training.training_opportunity_universe_versions,
    instrument_id bigint NOT NULL REFERENCES core.instruments,
    symbol text NOT NULL,
    signal_time timestamptz NOT NULL,
    entry_time timestamptz NOT NULL,
    entry_price numeric NOT NULL CHECK (entry_price > 0),
    direction varchar(8) NOT NULL CHECK (direction = 'LONG'),
    pool_evaluation_id uuid NOT NULL
        REFERENCES strategy_training.training_historical_pool_evaluations,
    mfe_percent numeric NOT NULL CHECK (mfe_percent >= 0),
    mae_percent numeric NOT NULL CHECK (mae_percent >= 0),
    return_percent numeric NOT NULL,
    is_opportunity boolean NOT NULL,
    reason_codes jsonb NOT NULL CHECK (jsonb_typeof(reason_codes) = 'array'),
    path_fingerprint char(64) NOT NULL CHECK (path_fingerprint ~ '^[0-9a-f]{64}$'),
    truth_fingerprint char(64) NOT NULL CHECK (truth_fingerprint ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (opportunity_universe_id, instrument_id, signal_time, direction),
    CHECK (entry_time > signal_time),
    CHECK ((is_opportunity AND reason_codes = '[]'::jsonb) OR NOT is_opportunity)
);

CREATE INDEX ix_training_opportunity_universe_truth
ON strategy_training.training_opportunity_universe_events (
    opportunity_universe_id, is_opportunity, instrument_id, signal_time
);

CREATE TABLE strategy_training.training_iteration_opportunity_universes (
    iteration_id uuid PRIMARY KEY REFERENCES strategy_training.training_iterations,
    opportunity_universe_id uuid NOT NULL
        REFERENCES strategy_training.training_opportunity_universe_versions,
    linked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION strategy_training.assert_training_model_a_l0_lease(
    p_task_id uuid, p_lease_token uuid
)
RETURNS strategy_training.training_tasks
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_L0_AGGREGATION'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'model-A L0 requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN task_record;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.build_training_opportunity_universe(
    p_task_id uuid, p_lease_token uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    definition_id uuid; definition_json jsonb; universe_id uuid;
    incomplete_count bigint; event_count_value bigint; opportunity_count_value bigint;
    universe_hash char(64);
BEGIN
    task_record := strategy_training.assert_training_model_a_l0_lease(
        p_task_id, p_lease_token
    );
    SELECT dataset.* INTO STRICT dataset_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = experiment.dataset_version_id
    WHERE iteration.iteration_id = task_record.iteration_id
      AND iteration.state = 'RUNNING'
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300;
    SELECT config.config_version_id, config.config_json
    INTO STRICT definition_id, definition_json
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'OPPORTUNITY_DEFINITION'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'OPPORTUNITY_DEFINITION' AND config.status = 'READY'
    WHERE iteration.iteration_id = task_record.iteration_id;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        dataset_record.dataset_version_id::text || definition_id::text, 0
    ));
    SELECT opportunity_universe_id INTO universe_id
    FROM strategy_training.training_opportunity_universe_versions
    WHERE dataset_version_id = dataset_record.dataset_version_id
      AND opportunity_definition_version_id = definition_id
      AND status = 'READY';
    IF universe_id IS NOT NULL THEN
        INSERT INTO strategy_training.training_iteration_opportunity_universes (
            iteration_id, opportunity_universe_id
        ) VALUES (task_record.iteration_id, universe_id)
        ON CONFLICT (iteration_id) DO NOTHING;
        RETURN universe_id;
    END IF;
    INSERT INTO strategy_training.training_opportunity_universe_versions (
        dataset_version_id, opportunity_definition_version_id, status
    ) VALUES (dataset_record.dataset_version_id, definition_id, 'BUILDING')
    RETURNING opportunity_universe_id INTO universe_id;

    WITH RECURSIVE revisions AS MATERIALIZED (
        SELECT DISTINCT ON (bar.instrument_id, bar.open_time)
            bar.instrument_id, bar.open_time, bar.close_time,
            bar.open_price, bar.high_price, bar.low_price, bar.close_price
        FROM market.klines bar
        WHERE bar.price_type = 'TRADE' AND bar.interval_seconds = 300
          AND bar.is_closed AND bar.quality_status = 'VALID'
          AND bar.open_time >= dataset_record.eligible_start_at
          AND bar.open_time < dataset_record.eligible_end_at
                              + dataset_record.label_horizon_duration
          AND bar.effective_at <= dataset_record.source_as_of_at
          AND EXISTS (
              SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
              WHERE pool.dataset_version_id = dataset_record.dataset_version_id
                AND pool.instrument_id = bar.instrument_id
          )
        ORDER BY bar.instrument_id, bar.open_time, bar.revision_no DESC,
                 bar.effective_at DESC, bar.collected_at DESC
    ), candidates AS MATERIALIZED (
        SELECT signal.instrument_id, instrument.symbol,
               signal.open_time AS signal_time, entry.open_time AS entry_time,
               entry.open_price AS entry_price, pool.pool_evaluation_id
        FROM revisions signal
        JOIN revisions entry ON entry.instrument_id = signal.instrument_id
         AND entry.open_time = signal.open_time + interval '5 minutes'
        JOIN core.instruments instrument
          ON instrument.instrument_id = signal.instrument_id
        JOIN LATERAL (
            SELECT evaluation.pool_evaluation_id, evaluation.is_eligible
            FROM strategy_training.training_historical_pool_evaluations evaluation
            WHERE evaluation.dataset_version_id = dataset_record.dataset_version_id
              AND evaluation.instrument_id = signal.instrument_id
              AND evaluation.evaluation_at <= signal.open_time
            ORDER BY evaluation.evaluation_at DESC LIMIT 1
        ) pool ON pool.is_eligible
        WHERE signal.open_time >= dataset_record.eligible_start_at
          AND signal.open_time < dataset_record.eligible_end_at
    ), outcomes AS MATERIALIZED (
        SELECT candidate.*,
               path.observed_count,
               GREATEST(0::numeric, path.maximum_high / candidate.entry_price * 100 - 100)
                   AS mfe_percent,
               GREATEST(0::numeric, 100 - path.minimum_low / candidate.entry_price * 100)
                   AS mae_percent,
               path.endpoint_close / candidate.entry_price * 100 - 100 AS return_percent,
               path.path_fingerprint
        FROM candidates candidate
        JOIN LATERAL (
            SELECT count(*) AS observed_count,
                   max(future.high_price) AS maximum_high,
                   min(future.low_price) AS minimum_low,
                   (array_agg(future.close_price ORDER BY future.close_time DESC))[1]
                       AS endpoint_close,
                   encode(public.digest(string_agg(
                       concat_ws('|', future.close_time::text,
                           future.high_price::text, future.low_price::text,
                           future.close_price::text), E'\n' ORDER BY future.close_time
                   ), 'sha256'), 'hex') AS path_fingerprint
            FROM revisions future
            WHERE future.instrument_id = candidate.instrument_id
              AND future.open_time >= candidate.entry_time
              AND future.close_time <= candidate.entry_time
                                     + dataset_record.label_horizon_duration
        ) path ON true
    ), classified AS (
        SELECT outcome.*,
               CASE WHEN outcome.observed_count =
                    extract(epoch FROM dataset_record.label_horizon_duration)::integer / 300
                    THEN '[]'::jsonb ELSE '["INCOMPLETE_PATH"]'::jsonb END
               || CASE WHEN outcome.mfe_percent <
                    (definition_json ->> 'minimum_mfe_percent')::numeric
                    THEN '["MFE_BELOW_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
               || CASE WHEN outcome.mae_percent >
                    (definition_json ->> 'maximum_mae_percent')::numeric
                    THEN '["MAE_ABOVE_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
               || CASE WHEN outcome.return_percent <
                    (definition_json ->> 'minimum_return_percent')::numeric
                    THEN '["RETURN_BELOW_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
                   AS reasons
        FROM outcomes outcome
    )
    INSERT INTO strategy_training.training_opportunity_universe_events (
        opportunity_event_id, opportunity_universe_id, instrument_id, symbol,
        signal_time, entry_time, entry_price, direction, pool_evaluation_id,
        mfe_percent, mae_percent, return_percent, is_opportunity,
        reason_codes, path_fingerprint, truth_fingerprint
    )
    SELECT encode(public.digest(concat_ws('|', dataset_record.dataset_version_id::text,
               definition_id::text, classified.instrument_id::text,
               classified.signal_time::text, 'LONG'), 'sha256'), 'hex'),
           universe_id, classified.instrument_id, classified.symbol,
           classified.signal_time, classified.entry_time, classified.entry_price,
           'LONG', classified.pool_evaluation_id, classified.mfe_percent,
           classified.mae_percent, classified.return_percent,
           jsonb_array_length(classified.reasons) = 0, classified.reasons,
           classified.path_fingerprint,
           encode(public.digest(jsonb_build_object(
               'definition_id', definition_id,
               'instrument_id', classified.instrument_id,
               'is_opportunity', jsonb_array_length(classified.reasons) = 0,
               'path_fingerprint', classified.path_fingerprint,
               'reason_codes', classified.reasons,
               'signal_time', classified.signal_time
           )::text, 'sha256'), 'hex')
    FROM classified;

    SELECT count(*) FILTER (WHERE reason_codes ? 'INCOMPLETE_PATH'),
           count(*), count(*) FILTER (WHERE is_opportunity)
    INTO incomplete_count, event_count_value, opportunity_count_value
    FROM strategy_training.training_opportunity_universe_events
    WHERE opportunity_universe_id = universe_id;
    IF event_count_value = 0 OR incomplete_count > 0 THEN
        RAISE EXCEPTION 'opportunity universe is empty or contains % incomplete paths',
            incomplete_count USING ERRCODE = '23514';
    END IF;
    SELECT encode(public.digest(string_agg(
        event.opportunity_event_id::text || '|' || event.truth_fingerprint::text,
        E'\n' ORDER BY event.opportunity_event_id
    ), 'sha256'), 'hex') INTO STRICT universe_hash
    FROM strategy_training.training_opportunity_universe_events event
    WHERE event.opportunity_universe_id = universe_id;
    UPDATE strategy_training.training_opportunity_universe_versions
    SET status = 'READY', event_count = event_count_value,
        opportunity_count = opportunity_count_value,
        universe_fingerprint = universe_hash, completed_at = clock_timestamp()
    WHERE opportunity_universe_id = universe_id;
    INSERT INTO strategy_training.training_iteration_opportunity_universes (
        iteration_id, opportunity_universe_id
    ) VALUES (task_record.iteration_id, universe_id);
    RETURN universe_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_model_a_discovery_l0(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    opportunity_universe_id_value uuid; scoring jsonb; metrics jsonb;
    rejection_codes jsonb := '[]'::jsonb;
    signal_count bigint; opportunity_count bigint; recalled_count bigint;
    true_signal_count bigint; independent_days bigint; week_count bigint;
    recall_score numeric; entry_score numeric; excess_score numeric;
    stability_score numeric; false_penalty numeric; low_sample_penalty numeric;
    concentration_penalty numeric; objective numeric; hard_pass boolean;
    evidence_hash_value char(64); terminal_state_value text;
BEGIN
    SELECT evidence_hash INTO evidence_hash_value
    FROM strategy_training.training_iteration_evidence_l0 evidence
    JOIN strategy_training.training_tasks task
      ON task.iteration_id = evidence.iteration_id
    WHERE task.task_id = p_task_id;
    IF evidence_hash_value IS NOT NULL THEN RETURN evidence_hash_value; END IF;
    task_record := strategy_training.assert_training_model_a_l0_lease(
        p_task_id, p_lease_token
    );
    opportunity_universe_id_value := strategy_training.build_training_opportunity_universe(
        p_task_id, p_lease_token
    );
    SELECT config.config_json INTO STRICT scoring
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'SCORING_MODEL_A'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'SCORING_MODEL_A' AND config.status = 'READY'
    WHERE iteration.iteration_id = task_record.iteration_id
      AND config.config_json ->> 'calculation_version' = 'DISCOVERY_V1';

    WITH signals AS MATERIALIZED (
        SELECT entry.entry_event_id, entry.instrument_id, entry.symbol,
               entry.signal_time, outcome.mfe_percent, outcome.mae_percent,
               opportunity.is_opportunity,
               avg(random_outcome.mfe_percent) AS random_mfe_percent
        FROM strategy_training.training_entry_events entry
        JOIN strategy_training.training_entry_outcomes outcome
          ON outcome.entry_event_id = entry.entry_event_id AND outcome.is_complete
        JOIN strategy_training.training_opportunity_events opportunity
          ON opportunity.entry_event_id = entry.entry_event_id
        JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
        JOIN strategy_training.training_random_baseline_candidate_outcomes random_outcome
          ON random_outcome.matched_entry_event_id = entry.entry_event_id
         AND random_outcome.is_complete
         AND random_outcome.candidate_id::text IN (
             SELECT jsonb_array_elements_text(baseline.selected_candidate_ids)
         )
        WHERE entry.generating_iteration_id = task_record.iteration_id
        GROUP BY entry.entry_event_id, entry.instrument_id, entry.symbol,
                 entry.signal_time, outcome.mfe_percent, outcome.mae_percent,
                 opportunity.is_opportunity
    ), weekly AS (
        SELECT date_trunc('week', signal_time) AS week_start,
               100 * count(*) FILTER (WHERE is_opportunity)::numeric / count(*) AS precision
        FROM signals GROUP BY 1
    ), scalar AS (
        SELECT count(*) AS signals,
               count(*) FILTER (WHERE is_opportunity) AS true_signals,
               count(DISTINCT signal_time::date) AS independent_days,
               count(DISTINCT date_trunc('week', signal_time)) AS weeks,
               avg(GREATEST(0, mfe_percent - mae_percent)) AS entry_raw,
               avg(mfe_percent - random_mfe_percent) AS excess_raw,
               (SELECT count(*) FROM strategy_training.training_opportunity_universe_events
                 WHERE opportunity_universe_id = opportunity_universe_id_value
                   AND is_opportunity)
                   AS opportunities,
               (SELECT count(*)
                FROM strategy_training.training_opportunity_universe_events truth
                 WHERE truth.opportunity_universe_id = opportunity_universe_id_value
                  AND truth.is_opportunity AND EXISTS (
                      SELECT 1 FROM signals signal
                      WHERE signal.instrument_id = truth.instrument_id
                        AND signal.signal_time = truth.signal_time
                  )) AS recalled,
               (SELECT COALESCE(100 - (max(precision) - min(precision)), 0)
                  FROM weekly) AS stability,
               (SELECT COALESCE(
                    max(symbol_count)::numeric / NULLIF(sum(symbol_count), 0) * 100, 0
                )
                FROM (SELECT symbol, count(*) AS symbol_count FROM signals GROUP BY symbol) grouped)
                   AS concentration
        FROM signals
    )
    SELECT scalar_row.signals, scalar_row.opportunities, scalar_row.recalled,
           scalar_row.true_signals, scalar_row.independent_days, scalar_row.weeks,
           CASE WHEN scalar_row.opportunities = 0 THEN 0
                ELSE 100 * scalar_row.recalled::numeric / scalar_row.opportunities END,
           LEAST(100, GREATEST(0, scalar_row.entry_raw /
               (scoring ->> 'entry_timing_scale_percent')::numeric * 100)),
           LEAST(100, GREATEST(0, scalar_row.excess_raw /
               (scoring ->> 'excess_mfe_scale_percent')::numeric * 100)),
           GREATEST(0, scalar_row.stability),
           CASE WHEN scalar_row.signals = 0 THEN 100
                ELSE 100 * (scalar_row.signals - scalar_row.true_signals)::numeric
                     / scalar_row.signals END,
           100 * GREATEST(0,
               (scoring ->> 'minimum_signal_count')::numeric - scalar_row.signals)
               / (scoring ->> 'minimum_signal_count')::numeric,
           scalar_row.concentration
    INTO signal_count, opportunity_count, recalled_count, true_signal_count,
         independent_days, week_count, recall_score, entry_score, excess_score,
         stability_score, false_penalty, low_sample_penalty, concentration_penalty
    FROM scalar scalar_row;

    IF signal_count < (scoring ->> 'minimum_signal_count')::bigint THEN
        rejection_codes := rejection_codes || '"LOW_SIGNAL_COUNT"'::jsonb;
    END IF;
    IF opportunity_count < (scoring ->> 'minimum_opportunity_count')::bigint THEN
        rejection_codes := rejection_codes || '"LOW_OPPORTUNITY_COUNT"'::jsonb;
    END IF;
    IF independent_days < (scoring ->> 'minimum_effective_day_count')::bigint THEN
        rejection_codes := rejection_codes || '"LOW_EFFECTIVE_DAY_COUNT"'::jsonb;
    END IF;
    IF week_count < (scoring ->> 'minimum_week_count')::bigint THEN
        rejection_codes := rejection_codes || '"LOW_WEEK_COUNT"'::jsonb;
    END IF;
    hard_pass := jsonb_array_length(rejection_codes) = 0;
    objective :=
        (scoring -> 'weights' ->> 'opportunity_recall')::numeric * recall_score
      + (scoring -> 'weights' ->> 'entry_timing')::numeric * entry_score
      + (scoring -> 'weights' ->> 'excess_mfe_quality')::numeric * excess_score
      + (scoring -> 'weights' ->> 'cross_period_stability')::numeric * stability_score
      - (scoring -> 'weights' ->> 'false_signal_penalty')::numeric * false_penalty
      - (scoring -> 'weights' ->> 'low_sample_penalty')::numeric * low_sample_penalty
      - (scoring -> 'weights' ->> 'concentration_penalty')::numeric * concentration_penalty;
    metrics := jsonb_build_object(
        'calculation_version', 'DISCOVERY_V1',
        'concentration_penalty', concentration_penalty,
        'cross_period_stability_score', stability_score,
        'effective_independent_day_count', independent_days,
        'entry_timing_score', entry_score,
        'excess_mfe_quality_score', excess_score,
        'false_signal_penalty', false_penalty,
        'low_sample_penalty', low_sample_penalty,
        'opportunity_count', opportunity_count,
        'opportunity_recall_score', recall_score,
        'recalled_opportunity_count', recalled_count,
        'signal_count', signal_count,
        'true_signal_count', true_signal_count,
        'week_count', week_count
    );
    evidence_hash_value := encode(public.digest(jsonb_build_object(
        'aggregate_metrics', metrics,
        'hard_gate_passed', hard_pass,
        'iteration_id', task_record.iteration_id,
        'objective_value', CASE WHEN hard_pass THEN objective ELSE NULL END,
        'rejection_codes', rejection_codes,
        'universe_id', opportunity_universe_id_value
    )::text, 'sha256'), 'hex');
    terminal_state_value := CASE WHEN hard_pass THEN 'SUCCEEDED' ELSE 'FAILED' END;
    PERFORM strategy_training.transition_training_iteration(
        task_record.iteration_id, 'RUNNING', terminal_state_value,
        CASE WHEN hard_pass THEN NULL ELSE 'DISCOVERY_HARD_GATE_FAILED' END,
        CASE WHEN hard_pass THEN NULL ELSE evidence_hash_value END,
        NULL, 'training-evaluator', 'authoritative model-A TRAIN L0', gen_random_uuid()
    );
    PERFORM strategy_training.record_training_iteration_l0(
        task_record.iteration_id, 'TRAIN', NULL, terminal_state_value,
        hard_pass, rejection_codes, CASE WHEN hard_pass THEN objective ELSE NULL END,
        metrics, evidence_hash_value
    );
    RETURN evidence_hash_value;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_model_a_l0_tasks()
RETURNS TABLE (iteration_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; l0_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    FOR candidate IN
        SELECT iteration.iteration_id, iteration.experiment_id,
               evaluation.task_id AS parent_task_id
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_tasks evaluation
          ON evaluation.iteration_id = iteration.iteration_id
         AND evaluation.task_type = 'MODEL_A_EVALUATION'
         AND evaluation.state = 'SUCCEEDED'
        LEFT JOIN strategy_training.training_iteration_evidence_l0 evidence
          ON evidence.iteration_id = iteration.iteration_id
        WHERE iteration.state = 'RUNNING' AND evidence.iteration_id IS NULL
        ORDER BY iteration.created_at, iteration.iteration_id
    LOOP
        iteration_id := candidate.iteration_id;
        SELECT * INTO l0_task FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'MODEL_A_L0_AGGREGATION';
        IF NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id, NULL,
                candidate.parent_task_id, 'MODEL_A_L0_AGGREGATION', 'EVALUATOR',
                encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                    'MODEL_A_L0_AGGREGATION'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_L0_AGGREGATION',
                    'payload_version', 1), 25
            );
            action := 'L0_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF l0_task.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                COALESCE(l0_task.failure_code, 'MODEL_A_L0_FAILED'),
                l0_task.result_hash, NULL, 'training-orchestrator',
                'model-A L0 task failed', gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_L0'; RETURN NEXT;
    END LOOP;
END
$$;

CREATE TRIGGER trg_training_opportunity_universe_versions_append_only
BEFORE DELETE ON strategy_training.training_opportunity_universe_versions
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_opportunity_universe_events_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_opportunity_universe_events
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_iteration_opportunity_universes_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_iteration_opportunity_universes
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_opportunity_universe_versions
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_opportunity_universe_events
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iteration_opportunity_universes
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_model_a_scoring_config()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.assert_training_model_a_l0_lease(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.build_training_opportunity_universe(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_a_discovery_l0(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_a_l0_tasks()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_opportunity_universe_versions,
    strategy_training.training_opportunity_universe_events,
    strategy_training.training_iteration_opportunity_universes FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.guard_training_model_a_scoring_config(),
    strategy_training.assert_training_model_a_l0_lease(uuid, uuid),
    strategy_training.build_training_opportunity_universe(uuid, uuid),
    strategy_training.finalize_training_model_a_discovery_l0(uuid, uuid),
    strategy_training.advance_training_model_a_l0_tasks()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_training_model_a_discovery_l0(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.advance_training_model_a_l0_tasks()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '051_training_model_a_discovery_l0',
    encode(digest('auto_trade_v2_051_training_model_a_discovery_l0_v1', 'sha256'), 'hex'),
    'Build reusable base-pool opportunity truth and authoritative config-driven Discovery L0'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
