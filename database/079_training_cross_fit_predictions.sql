\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Independent outer folds may legitimately revisit the same parameter vector.
-- Preserve de-duplication inside one optimizer run and for every non-optimizer
-- path, while removing the accidental experiment-wide Cross-fit collision.
ALTER TABLE strategy_training.training_iterations
DROP CONSTRAINT training_iterations_experiment_id_candidate_content_hash_key;
CREATE UNIQUE INDEX ux_training_iterations_candidate_scope
ON strategy_training.training_iterations (
    experiment_id,
    candidate_content_hash,
    COALESCE(resource_budget ->> 'optimizer_run_id', '')
);

ALTER TABLE strategy_training.training_tasks
DROP CONSTRAINT training_tasks_task_type_check;
ALTER TABLE strategy_training.training_tasks
ADD CONSTRAINT training_tasks_task_type_check CHECK (task_type IN (
    'DATASET_BUILD', 'MODEL_A_CANDIDATE_SCAN', 'MODEL_A_EVALUATION',
    'MODEL_A_L0_AGGREGATION', 'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION',
    'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY', 'CROSS_FIT_COORDINATE',
    'CROSS_FIT_PREDICT'
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
        WHEN 'CROSS_FIT_COORDINATE' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_PREDICT' THEN 'WORKER'
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

CREATE TABLE strategy_training.training_cross_fit_predictions (
    cross_fit_prediction_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cross_fit_execution_id uuid NOT NULL
        REFERENCES strategy_training.training_cross_fit_executions,
    outer_fold_number integer NOT NULL CHECK (outer_fold_number > 0),
    optimizer_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_runs,
    optimizer_role varchar(8) NOT NULL CHECK (optimizer_role IN ('TPE', 'RANDOM')),
    selected_trial_result_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_trial_results,
    selected_iteration_id uuid NOT NULL
        REFERENCES strategy_training.training_iterations,
    selected_train_objective numeric NOT NULL,
    prediction_start_at timestamptz NOT NULL,
    prediction_end_at timestamptz NOT NULL,
    task_id uuid UNIQUE REFERENCES strategy_training.training_tasks,
    event_count bigint CHECK (event_count >= 0),
    event_set_hash char(64) CHECK (
        event_set_hash IS NULL OR event_set_hash ~ '^[0-9a-f]{64}$'
    ),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (prediction_start_at < prediction_end_at),
    CHECK ((event_count IS NULL AND event_set_hash IS NULL AND completed_at IS NULL)
        OR (event_count IS NOT NULL AND event_set_hash IS NOT NULL
            AND completed_at IS NOT NULL)),
    UNIQUE (cross_fit_execution_id, outer_fold_number, optimizer_role)
);

CREATE OR REPLACE FUNCTION strategy_training.prepare_cross_fit_prediction_tasks(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE scope_record strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
DECLARE selected_result strategy_training.training_optimizer_trial_results%ROWTYPE;
DECLARE prediction_id uuid;
DECLARE prediction_task_id uuid;
DECLARE prepared_count integer := 0;
DECLARE complete_count integer;
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING' THEN
        RETURN 'EXECUTION_NOT_RUNNING';
    END IF;

    FOR scope_record IN
        SELECT scope.*
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        JOIN strategy_training.training_optimizer_runs run
          ON run.optimizer_run_id = scope.optimizer_run_id
        WHERE scope.cross_fit_execution_id = p_cross_fit_execution_id
          AND scope.outer_fold_number = p_outer_fold_number
          AND run.state = 'SUCCEEDED'
        ORDER BY scope.optimizer_role
    LOOP
        IF EXISTS (
            SELECT 1 FROM strategy_training.training_cross_fit_predictions prediction
            WHERE prediction.optimizer_run_id = scope_record.optimizer_run_id
        ) THEN
            CONTINUE;
        END IF;
        SELECT result.* INTO selected_result
        FROM strategy_training.training_optimizer_trial_results result
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = result.iteration_id
        WHERE result.optimizer_run_id = scope_record.optimizer_run_id
          AND result.trial_state = 'COMPLETE'
          AND iteration.state = 'SUCCEEDED'
        ORDER BY result.train_objective DESC, result.trial_number,
                 result.iteration_id
        LIMIT 1;
        IF NOT FOUND THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'NO_COMPLETE_FOLD_TRIAL',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE cross_fit_execution_id = p_cross_fit_execution_id;
            RETURN 'EXECUTION_FAILED';
        END IF;
        prediction_id := gen_random_uuid();
        INSERT INTO strategy_training.training_cross_fit_predictions (
            cross_fit_prediction_id, cross_fit_execution_id, outer_fold_number,
            optimizer_run_id, optimizer_role, selected_trial_result_id,
            selected_iteration_id, selected_train_objective,
            prediction_start_at, prediction_end_at
        ) VALUES (
            prediction_id, p_cross_fit_execution_id, p_outer_fold_number,
            scope_record.optimizer_run_id, scope_record.optimizer_role,
            selected_result.optimizer_trial_result_id,
            selected_result.iteration_id, selected_result.train_objective,
            scope_record.prediction_start_at, scope_record.prediction_end_at
        );
        prediction_task_id := strategy_training.enqueue_training_task(
            execution_record.experiment_id, selected_result.iteration_id,
            scope_record.optimizer_run_id, NULL,
            'CROSS_FIT_PREDICT', 'WORKER',
            encode(digest(concat_ws('|', prediction_id::text,
                'CROSS_FIT_PREDICT_V1'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'CROSS_FIT_PREDICT',
                'payload_version', 1), 20
        );
        UPDATE strategy_training.training_cross_fit_predictions
        SET task_id = prediction_task_id
        WHERE cross_fit_prediction_id = prediction_id;
        prepared_count := prepared_count + 1;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_predictions prediction
        JOIN strategy_training.training_tasks task ON task.task_id = prediction.task_id
        WHERE prediction.cross_fit_execution_id = p_cross_fit_execution_id
          AND prediction.outer_fold_number = p_outer_fold_number
          AND task.state IN ('FAILED', 'CANCELLED')
    ) THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'FAILED', failure_code = 'FOLD_PREDICTION_FAILED',
            completed_at = clock_timestamp(), lease_token = NULL,
            leased_by = NULL, lease_expires_at = NULL
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
        RETURN 'EXECUTION_FAILED';
    END IF;
    SELECT count(*) FILTER (
        WHERE prediction.completed_at IS NOT NULL AND task.state = 'SUCCEEDED'
    )
    INTO complete_count
    FROM strategy_training.training_cross_fit_predictions prediction
    JOIN strategy_training.training_tasks task ON task.task_id = prediction.task_id
    WHERE prediction.cross_fit_execution_id = p_cross_fit_execution_id
      AND prediction.outer_fold_number = p_outer_fold_number;
    IF complete_count = 2 THEN
        RETURN 'PREDICTION_PAIR_COMPLETED';
    ELSIF prepared_count > 0 THEN
        RETURN 'PREDICTION_TASKS_ENQUEUED';
    END IF;
    RETURN 'WAITING_PREDICTION_PAIR';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    iteration_id uuid, dataset_version_id uuid, interval_seconds integer,
    eligible_start_at timestamptz, eligible_end_at timestamptz,
    ticker_pool_rule_version_id uuid, factor_registry_version_id uuid,
    factor_registry_config jsonb, scan_parameters_version_id uuid,
    scan_parameters_config jsonb, candidate_parameters jsonb,
    dataset_root_fingerprint char(64), maximum_signal_count bigint,
    existing_batch_hash char(64)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.task_type <> 'CROSS_FIT_PREDICT'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL
       OR task_record.optimizer_run_id IS NULL
       OR task_record.task_payload <> jsonb_build_object(
            'task_type', 'CROSS_FIT_PREDICT', 'payload_version', 1
       ) THEN
        RAISE EXCEPTION 'Cross-fit prediction requires its exact active worker lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN QUERY
    SELECT iteration.iteration_id, dataset.dataset_version_id,
           dataset.interval_seconds, prediction.prediction_start_at,
           prediction.prediction_end_at, dataset.ticker_pool_rule_version_id,
           factor.config_version_id, factor.config_json,
           scan.config_version_id, scan.config_json,
           iteration.candidate_parameters, dataset.root_fingerprint,
           (limits.config_json ->> 'max_signal_count')::bigint,
           prediction.event_set_hash
    FROM strategy_training.training_cross_fit_predictions prediction
    JOIN strategy_training.training_cross_fit_executions execution
      ON execution.cross_fit_execution_id = prediction.cross_fit_execution_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = execution.dataset_version_id
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = prediction.selected_iteration_id
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = execution.experiment_id
    JOIN strategy_training.training_experiment_config_bindings factor_binding
      ON factor_binding.experiment_id = experiment.experiment_id
     AND factor_binding.config_type = 'FACTOR_REGISTRY'
    JOIN strategy_training.training_config_versions factor
      ON factor.config_version_id = factor_binding.config_version_id
     AND factor.config_type = 'FACTOR_REGISTRY' AND factor.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings scan_binding
      ON scan_binding.experiment_id = experiment.experiment_id
     AND scan_binding.config_type = 'SEARCH_SPACE'
    JOIN strategy_training.training_config_versions scan
      ON scan.config_version_id = scan_binding.config_version_id
     AND scan.config_type = 'SEARCH_SPACE' AND scan.status = 'READY'
    JOIN strategy_training.training_config_versions limits
      ON limits.config_version_id = experiment.resource_limit_config_version_id
     AND limits.config_type = 'RESOURCE_LIMITS' AND limits.status = 'READY'
    WHERE prediction.task_id = p_task_id
      AND prediction.optimizer_run_id = task_record.optimizer_run_id
      AND prediction.selected_iteration_id = task_record.iteration_id
      AND execution.state = 'RUNNING'
      AND iteration.state = 'SUCCEEDED'
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cross-fit prediction context is not READY'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_instruments(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (instrument_id bigint, symbol text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS (
        SELECT * FROM strategy_training.training_cross_fit_prediction_context(
            p_task_id, p_lease_token
        )
    )
    SELECT DISTINCT pool.instrument_id, pool.symbol::text
    FROM context
    JOIN strategy_training.training_historical_pool_evaluations pool
      ON pool.dataset_version_id = context.dataset_version_id
     AND pool.is_eligible
     AND pool.evaluation_at < context.eligible_end_at
    ORDER BY 2
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_pool(
    p_task_id uuid, p_lease_token uuid, p_instrument_id bigint
)
RETURNS TABLE (pool_evaluation_id uuid, evaluation_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS (
        SELECT * FROM strategy_training.training_cross_fit_prediction_context(
            p_task_id, p_lease_token
        )
    )
    SELECT pool.pool_evaluation_id, pool.evaluation_at
    FROM context
    JOIN strategy_training.training_historical_pool_evaluations pool
      ON pool.dataset_version_id = context.dataset_version_id
     AND pool.instrument_id = p_instrument_id AND pool.is_eligible
     AND pool.evaluation_at < context.eligible_end_at
    ORDER BY pool.evaluation_at
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_bars(
    p_task_id uuid, p_lease_token uuid, p_instrument_id bigint
)
RETURNS TABLE (
    open_time timestamptz, open_price numeric, high_price numeric,
    low_price numeric, close_price numeric, price_precision integer,
    ema20 numeric, ema240 numeric, base_volume numeric, quote_volume numeric,
    amplitude_percent numeric, open_interest_value numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $$
    WITH context AS (
        SELECT prediction.*, dataset.warmup_start_at, dataset.source_as_of_at
        FROM strategy_training.training_cross_fit_prediction_context(
            p_task_id, p_lease_token
        ) prediction
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = prediction.dataset_version_id
        WHERE EXISTS (
            SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
            WHERE pool.dataset_version_id = prediction.dataset_version_id
              AND pool.instrument_id = p_instrument_id AND pool.is_eligible
        )
    ), revisions AS (
        SELECT DISTINCT ON (bar.open_time)
               bar.open_time, bar.open_price, bar.high_price, bar.low_price,
               bar.close_price, bar.base_volume, bar.quote_volume
        FROM context
        JOIN market.klines bar ON bar.instrument_id = p_instrument_id
         AND bar.price_type = 'TRADE' AND bar.interval_seconds = 300
         AND bar.is_closed AND bar.quality_status = 'VALID'
         AND bar.open_time >= context.warmup_start_at
         AND bar.open_time < context.eligible_end_at + interval '5 minutes'
         AND bar.effective_at <= context.source_as_of_at
        ORDER BY bar.open_time, bar.revision_no DESC
    )
    SELECT revision.open_time, revision.open_price, revision.high_price,
           revision.low_price, revision.close_price, rules.price_precision,
           ema.ema20, ema.ema240, revision.base_volume, revision.quote_volume,
           ((revision.high_price - revision.low_price) / revision.open_price * 100),
           oi.open_interest_value
    FROM context
    JOIN revisions revision ON true
    JOIN market.kline_ema_indicators ema
      ON ema.instrument_id = p_instrument_id
     AND ema.price_type = 'TRADE' AND ema.interval_seconds = 300
     AND ema.open_time = revision.open_time
     AND ema.close_price = revision.close_price
     AND ema.computed_at <= context.source_as_of_at
    LEFT JOIN LATERAL (
        SELECT rule.price_precision
        FROM core.instrument_rule_versions rule
        WHERE rule.instrument_id = p_instrument_id
          AND rule.effective_from <= revision.open_time
        ORDER BY rule.effective_from DESC LIMIT 1
    ) rules ON true
    LEFT JOIN LATERAL (
        SELECT observation.open_interest_value
        FROM market.open_interest_observations observation
        WHERE observation.instrument_id = p_instrument_id
          AND observation.observed_at >= revision.open_time
          AND observation.observed_at < revision.open_time + interval '5 minutes'
          AND observation.quality_status IN ('VALID', 'PARTIAL')
          AND observation.collected_at <= context.source_as_of_at
        ORDER BY observation.observed_at DESC LIMIT 1
    ) oi ON true
    ORDER BY revision.open_time
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_cross_fit_prediction_entry_event(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64),
    p_dataset_version_id uuid, p_generating_iteration_id uuid,
    p_instrument_id bigint, p_symbol text, p_signal_time timestamptz,
    p_entry_time timestamptz, p_direction text, p_trigger_score numeric,
    p_coverage_percent numeric, p_theoretical_signal_price numeric,
    p_entry_price numeric, p_pool_evaluation_id uuid,
    p_ticker_pool_rule_version_id uuid, p_factor_registry_version_id uuid,
    p_scan_parameters_version_id uuid, p_signal_payload_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
DECLARE prediction_record strategy_training.training_cross_fit_predictions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    SELECT * INTO STRICT prediction_record
    FROM strategy_training.training_cross_fit_predictions prediction
    WHERE prediction.task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'CROSS_FIT_PREDICT'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS DISTINCT FROM p_generating_iteration_id
       OR prediction_record.completed_at IS NOT NULL
       OR p_signal_time < prediction_record.prediction_start_at
       OR p_signal_time >= prediction_record.prediction_end_at
       OR NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_historical_pool_evaluations pool
            WHERE pool.pool_evaluation_id = p_pool_evaluation_id
              AND pool.evaluation_at <= p_signal_time
              AND p_signal_time < pool.evaluation_at + interval '1 day'
       ) THEN
        RAISE EXCEPTION 'Cross-fit event is outside its active prediction lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN strategy_training.create_cross_fit_entry_event(
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, p_symbol, 'CROSS_FIT_MODEL_A_CANDIDATE', 'GO_NO_GO',
        p_signal_time, p_entry_time, p_direction, p_trigger_score,
        p_coverage_percent, p_theoretical_signal_price, p_entry_price,
        p_pool_evaluation_id, p_ticker_pool_rule_version_id,
        p_factor_registry_version_id, p_scan_parameters_version_id,
        p_signal_payload_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.complete_cross_fit_prediction(
    p_task_id uuid, p_lease_token uuid, p_event_count bigint,
    p_event_set_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
DECLARE prediction_record strategy_training.training_cross_fit_predictions%ROWTYPE;
DECLARE persisted_count bigint;
DECLARE persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    SELECT * INTO STRICT prediction_record
    FROM strategy_training.training_cross_fit_predictions prediction
    WHERE prediction.task_id = p_task_id FOR UPDATE;
    IF prediction_record.completed_at IS NOT NULL THEN
        RETURN prediction_record.event_set_hash;
    END IF;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'CROSS_FIT_PREDICT'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS DISTINCT FROM prediction_record.selected_iteration_id
       OR p_event_count < 0
       OR p_event_set_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Cross-fit prediction completion requires its active lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT count(*), encode(digest(COALESCE(string_agg(event.entry_event_id, ''
        ORDER BY event.entry_event_id), ''), 'sha256'), 'hex')
    INTO persisted_count, persisted_hash
    FROM strategy_training.training_entry_events event
    WHERE event.generating_iteration_id = prediction_record.selected_iteration_id
      AND event.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
      AND event.entry_use = 'GO_NO_GO'
      AND event.signal_time >= prediction_record.prediction_start_at
      AND event.signal_time < prediction_record.prediction_end_at
      AND event.status = 'COMPLETE';
    IF persisted_count <> p_event_count OR persisted_hash <> p_event_set_hash THEN
        RAISE EXCEPTION 'Cross-fit prediction event set does not match persisted facts'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_cross_fit_predictions
    SET event_count = persisted_count, event_set_hash = persisted_hash,
        completed_at = clock_timestamp()
    WHERE cross_fit_prediction_id = prediction_record.cross_fit_prediction_id;
    RETURN persisted_hash;
END
$$;

-- A terminal optimizer iteration may emit only its separately leased, frozen
-- outer-fold prediction. Discovery and fixed-baseline events remain RUNNING-only.
CREATE OR REPLACE FUNCTION strategy_training.guard_training_entry_event_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    iteration_state text; iteration_source text; experiment_dataset_id uuid;
    pool_record strategy_training.training_historical_pool_evaluations%ROWTYPE;
    factor_config_type text; factor_config_status text; factor_config_json jsonb;
    scan_config_type text; scan_config_status text;
BEGIN
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id FOR SHARE;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR NEW.signal_time < dataset_record.eligible_start_at
       OR NEW.signal_time >= dataset_record.eligible_end_at
       OR NEW.entry_time <> NEW.signal_time + make_interval(secs => dataset_record.interval_seconds)
       OR NEW.entry_event_id <> strategy_training.compute_training_entry_event_id(
           NEW.dataset_version_id, NEW.generating_iteration_id, NEW.symbol,
           NEW.signal_time, NEW.entry_time, NEW.direction
       ) THEN
        RAISE EXCEPTION 'entry signal/entry time is outside the governed TRAIN interval'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.state, iteration.candidate_source, experiment.dataset_version_id
    INTO STRICT iteration_state, iteration_source, experiment_dataset_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = NEW.generating_iteration_id;
    IF experiment_dataset_id <> NEW.dataset_version_id OR NOT (
        (iteration_state = 'RUNNING' AND (
            (iteration_source = 'FIXED_BASELINE' AND NEW.source = 'FIXED_BASELINE_MODEL_A')
            OR (iteration_source IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
                AND NEW.source = 'IN_SAMPLE_MODEL_A')
        )) OR (
            iteration_state = 'SUCCEEDED'
            AND iteration_source IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
            AND NEW.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
            AND EXISTS (
                SELECT 1
                FROM strategy_training.training_cross_fit_predictions prediction
                JOIN strategy_training.training_cross_fit_executions execution
                  ON execution.cross_fit_execution_id = prediction.cross_fit_execution_id
                WHERE prediction.selected_iteration_id = NEW.generating_iteration_id
                  AND execution.dataset_version_id = NEW.dataset_version_id
                  AND execution.state = 'RUNNING'
                  AND prediction.completed_at IS NULL
                  AND NEW.signal_time >= prediction.prediction_start_at
                  AND NEW.signal_time < prediction.prediction_end_at
            )
        )
    ) THEN
        RAISE EXCEPTION 'entry source does not match its governed TRAIN generator'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = NEW.pool_evaluation_id;
    IF pool_record.dataset_version_id <> NEW.dataset_version_id
       OR pool_record.instrument_id <> NEW.instrument_id
       OR pool_record.symbol <> NEW.symbol OR NOT pool_record.is_eligible
       OR pool_record.evaluation_at > NEW.signal_time THEN
        RAISE EXCEPTION 'entry lacks contemporaneous eligible-pool evidence'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.ticker_pool_rule_version_id <> dataset_record.ticker_pool_rule_version_id THEN
        RAISE EXCEPTION 'entry ticker-pool rule does not match its dataset'
            USING ERRCODE = '23514';
    END IF;
    SELECT config_type, status, config_json
    INTO STRICT factor_config_type, factor_config_status, factor_config_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.factor_registry_version_id;
    SELECT config_type, status INTO STRICT scan_config_type, scan_config_status
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.scan_parameters_version_id;
    IF factor_config_type <> 'FACTOR_REGISTRY' OR factor_config_status <> 'READY'
       OR jsonb_typeof(factor_config_json -> 'factors') IS DISTINCT FROM 'array'
       OR jsonb_array_length(factor_config_json -> 'factors') = 0
       OR scan_config_type <> 'SEARCH_SPACE' OR scan_config_status <> 'READY' THEN
        RAISE EXCEPTION 'entry requires READY factor-registry and scan configs'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'FACTOR_REGISTRY'
          AND binding.config_version_id = NEW.factor_registry_version_id
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'SEARCH_SPACE'
          AND binding.config_version_id = NEW.scan_parameters_version_id
    ) THEN
        RAISE EXCEPTION 'entry configs are not frozen on its experiment'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

-- Extend the orchestrator only after both searches are terminal. Prediction
-- completion is required before the existing fold-finalization wait state.
CREATE OR REPLACE FUNCTION strategy_training.advance_training_cross_fit_executions()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE timed_out_run strategy_training.training_optimizer_runs%ROWTYPE;
DECLARE latest_fold integer; DECLARE next_fold integer;
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
DECLARE scope_count integer; DECLARE terminal_count integer;
DECLARE prediction_action text;
BEGIN
    FOR timed_out_run IN
        SELECT run.* FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_cross_fit_optimizer_scopes scope
          ON scope.optimizer_run_id = run.optimizer_run_id
        WHERE run.state = 'RUNNING'
          AND run.started_at + make_interval(secs => scope.wall_clock_budget_seconds)
              <= clock_timestamp()
        ORDER BY run.started_at, run.optimizer_run_id
        FOR UPDATE OF run SKIP LOCKED
    LOOP
        PERFORM strategy_training.transition_training_optimizer_run(
            timed_out_run.optimizer_run_id, 'RUNNING', 'FAILED',
            'CROSS_FIT_WALL_CLOCK_EXCEEDED', NULL,
            'training-cross-fit-orchestrator',
            'frozen per-fold optimizer wall-clock budget exceeded', gen_random_uuid()
        );
    END LOOP;

    FOR execution_record IN
        SELECT execution.*
        FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.state IN ('PLANNED', 'RUNNING')
        ORDER BY execution.created_at, execution.cross_fit_execution_id
        FOR UPDATE SKIP LOCKED
    LOOP
        cross_fit_execution_id := execution_record.cross_fit_execution_id;
        IF EXISTS (
            SELECT 1 FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run
              ON run.optimizer_run_id = scope.optimizer_run_id
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND run.state IN ('FAILED', 'CANCELLED')
        ) THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'FOLD_OPTIMIZER_FAILED',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE training_cross_fit_executions.cross_fit_execution_id
                = execution_record.cross_fit_execution_id;
            action := 'EXECUTION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT COALESCE(max(scope.outer_fold_number), 0) INTO latest_fold
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id;
        next_fold := latest_fold + 1;
        IF latest_fold > 0 THEN
            SELECT count(*), count(*) FILTER (WHERE run.state = 'SUCCEEDED')
            INTO scope_count, terminal_count
            FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run
              ON run.optimizer_run_id = scope.optimizer_run_id
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND scope.outer_fold_number = latest_fold;
            IF scope_count <> 2 OR terminal_count <> 2 THEN
                action := 'WAITING_OPTIMIZER_PAIR'; RETURN NEXT; CONTINUE;
            END IF;
            prediction_action := strategy_training.prepare_cross_fit_prediction_tasks(
                execution_record.cross_fit_execution_id, latest_fold
            );
            IF prediction_action <> 'PREDICTION_PAIR_COMPLETED' THEN
                action := prediction_action; RETURN NEXT; CONTINUE;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM strategy_training.training_cross_fit_fold_executions fold_execution
                JOIN strategy_training.training_cross_fit_folds fold
                  ON fold.cross_fit_fold_id = fold_execution.cross_fit_fold_id
                WHERE fold_execution.cross_fit_execution_id
                    = execution_record.cross_fit_execution_id
                  AND fold.outer_fold_number = latest_fold
            ) THEN
                action := 'WAITING_FOLD_FINALIZATION'; RETURN NEXT; CONTINUE;
            END IF;
        END IF;
        SELECT * INTO task_record FROM strategy_training.training_tasks task
        WHERE task.experiment_id = execution_record.experiment_id
          AND task.task_type = 'CROSS_FIT_COORDINATE'
          AND task.task_payload ->> 'execution_id'
                = execution_record.cross_fit_execution_id::text
          AND (task.task_payload ->> 'fold_number')::integer = next_fold;
        IF FOUND THEN
            action := CASE task_record.state
                WHEN 'SUCCEEDED' THEN 'COORDINATION_COMPLETED'
                WHEN 'FAILED' THEN 'COORDINATION_FAILED'
                ELSE 'WAITING_COORDINATION' END;
            RETURN NEXT; CONTINUE;
        END IF;
        PERFORM strategy_training.enqueue_training_task(
            execution_record.experiment_id, NULL, NULL, NULL,
            'CROSS_FIT_COORDINATE', 'EVALUATOR',
            encode(digest(concat_ws('|', execution_record.cross_fit_execution_id::text,
                next_fold::text, 'CROSS_FIT_COORDINATE_V1'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'CROSS_FIT_COORDINATE',
                'payload_version', 1,
                'execution_id', execution_record.cross_fit_execution_id::text,
                'fold_number', next_fold), 20
        );
        action := 'COORDINATION_ENQUEUED'; RETURN NEXT;
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_cross_fit_predictions OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.prepare_cross_fit_prediction_tasks(uuid, integer)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_instruments(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_pool(uuid, uuid, bigint)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_bars(uuid, uuid, bigint)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_cross_fit_prediction_entry_event(
    uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
    text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.complete_cross_fit_prediction(
    uuid, uuid, bigint, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_predictions FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.prepare_cross_fit_prediction_tasks(uuid, integer),
    strategy_training.training_cross_fit_prediction_context(uuid, uuid),
    strategy_training.training_cross_fit_prediction_instruments(uuid, uuid),
    strategy_training.training_cross_fit_prediction_pool(uuid, uuid, bigint),
    strategy_training.training_cross_fit_prediction_bars(uuid, uuid, bigint),
    strategy_training.create_cross_fit_prediction_entry_event(
        uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
        text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
    ),
    strategy_training.complete_cross_fit_prediction(uuid, uuid, bigint, char(64))
FROM PUBLIC;
GRANT SELECT ON strategy_training.training_cross_fit_predictions
TO tb2_training_rw, tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_prediction_tasks(uuid, integer)
TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_cross_fit_prediction_context(uuid, uuid),
    strategy_training.training_cross_fit_prediction_instruments(uuid, uuid),
    strategy_training.training_cross_fit_prediction_pool(uuid, uuid, bigint),
    strategy_training.training_cross_fit_prediction_bars(uuid, uuid, bigint),
    strategy_training.create_cross_fit_prediction_entry_event(
        uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
        text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
    ),
    strategy_training.complete_cross_fit_prediction(uuid, uuid, bigint, char(64))
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '079_training_cross_fit_predictions',
    encode(digest('auto_trade_v2_079_training_cross_fit_predictions_v1',
        'sha256'), 'hex'),
    'Freeze best fold trials and generate lease-bound out-of-fold predictions'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
