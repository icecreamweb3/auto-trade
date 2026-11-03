\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_tasks
DROP CONSTRAINT training_tasks_task_type_check;
ALTER TABLE strategy_training.training_tasks
ADD CONSTRAINT training_tasks_task_type_check CHECK (task_type IN (
    'DATASET_BUILD', 'MODEL_A_CANDIDATE_SCAN', 'MODEL_A_EVALUATION',
    'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION', 'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY'
));

ALTER TABLE strategy_training.training_entry_events
DROP CONSTRAINT training_entry_events_source_check;
ALTER TABLE strategy_training.training_entry_events
ADD CONSTRAINT training_entry_events_source_check CHECK (source IN (
    'FIXED_BASELINE_MODEL_A', 'IN_SAMPLE_MODEL_A'
));

CREATE OR REPLACE FUNCTION strategy_training.enforce_training_task_payload_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    payload_version_text text;
    expected_executor text;
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

CREATE OR REPLACE FUNCTION strategy_training.guard_training_entry_event_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    iteration_state text;
    iteration_source text;
    experiment_dataset_id uuid;
    pool_record strategy_training.training_historical_pool_evaluations%ROWTYPE;
    factor_config_type text;
    factor_config_status text;
    factor_config_json jsonb;
    scan_config_type text;
    scan_config_status text;
BEGIN
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id FOR SHARE;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'model-A discovery entries require a READY TRAIN dataset'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.signal_time < dataset_record.eligible_start_at
       OR NEW.signal_time >= dataset_record.eligible_end_at
       OR NEW.entry_time <> NEW.signal_time
            + make_interval(secs => dataset_record.interval_seconds) THEN
        RAISE EXCEPTION 'entry signal/entry time is outside the governed interval'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.entry_event_id <> strategy_training.compute_training_entry_event_id(
        NEW.dataset_version_id, NEW.generating_iteration_id, NEW.symbol,
        NEW.signal_time, NEW.entry_time, NEW.direction
    ) THEN
        RAISE EXCEPTION 'entry_event_id does not match its deterministic identity'
            USING ERRCODE = '23514';
    END IF;

    SELECT iteration.state, iteration.candidate_source, experiment.dataset_version_id
    INTO STRICT iteration_state, iteration_source, experiment_dataset_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = NEW.generating_iteration_id;
    IF iteration_state <> 'RUNNING'
       OR experiment_dataset_id <> NEW.dataset_version_id
       OR NOT (
            (iteration_source = 'FIXED_BASELINE'
             AND NEW.source = 'FIXED_BASELINE_MODEL_A')
            OR (iteration_source IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
                AND NEW.source = 'IN_SAMPLE_MODEL_A')
       ) THEN
        RAISE EXCEPTION 'entry source does not match its running TRAIN generator'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = NEW.pool_evaluation_id;
    IF pool_record.dataset_version_id <> NEW.dataset_version_id
       OR pool_record.instrument_id <> NEW.instrument_id
       OR pool_record.symbol <> NEW.symbol
       OR NOT pool_record.is_eligible
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
    SELECT config_type, status
    INTO STRICT scan_config_type, scan_config_status
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
        SELECT 1
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'FACTOR_REGISTRY'
          AND binding.config_version_id = NEW.factor_registry_version_id
    ) OR NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_iterations iteration
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

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_context(
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
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'candidate scan requires its active worker lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN QUERY
    SELECT iteration.iteration_id, dataset.dataset_version_id,
           dataset.interval_seconds, dataset.eligible_start_at,
           dataset.eligible_end_at, dataset.ticker_pool_rule_version_id,
           factor.config_version_id, factor.config_json,
           scan.config_version_id, scan.config_json,
           iteration.candidate_parameters, dataset.root_fingerprint,
           (limits.config_json ->> 'max_signal_count')::bigint,
           batch.batch_hash
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = experiment.dataset_version_id
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
    LEFT JOIN strategy_training.training_iteration_entry_batches batch
      ON batch.iteration_id = iteration.iteration_id
    WHERE iteration.iteration_id = task_record.iteration_id
      AND iteration.state = 'RUNNING'
      AND iteration.candidate_source IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'candidate scan context is not READY 5m TRAIN'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_instruments(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (instrument_id bigint, symbol text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS (
        SELECT * FROM strategy_training.training_model_a_candidate_scan_context(
            p_task_id, p_lease_token
        )
    )
    SELECT DISTINCT pool.instrument_id, pool.symbol::text
    FROM context
    JOIN strategy_training.training_historical_pool_evaluations pool
      ON pool.dataset_version_id = context.dataset_version_id
     AND pool.is_eligible
    ORDER BY 2
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_pool(
    p_task_id uuid, p_lease_token uuid, p_instrument_id bigint
)
RETURNS TABLE (pool_evaluation_id uuid, evaluation_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS (
        SELECT * FROM strategy_training.training_model_a_candidate_scan_context(
            p_task_id, p_lease_token
        )
    )
    SELECT pool.pool_evaluation_id, pool.evaluation_at
    FROM context
    JOIN strategy_training.training_historical_pool_evaluations pool
      ON pool.dataset_version_id = context.dataset_version_id
     AND pool.instrument_id = p_instrument_id AND pool.is_eligible
    ORDER BY pool.evaluation_at
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_bars(
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
        SELECT scan.*, dataset.warmup_start_at, dataset.source_as_of_at
        FROM strategy_training.training_model_a_candidate_scan_context(
            p_task_id, p_lease_token
        ) scan
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = scan.dataset_version_id
        WHERE EXISTS (
            SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
            WHERE pool.dataset_version_id = scan.dataset_version_id
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

CREATE OR REPLACE FUNCTION strategy_training.create_training_candidate_entry_event(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64),
    p_dataset_version_id uuid, p_generating_iteration_id uuid,
    p_instrument_id bigint, p_symbol text, p_signal_time timestamptz,
    p_entry_time timestamptz, p_direction text, p_trigger_score numeric,
    p_coverage_percent numeric, p_theoretical_signal_price numeric,
    p_entry_price numeric, p_pool_evaluation_id uuid,
    p_ticker_pool_rule_version_id uuid, p_factor_registry_version_id uuid,
    p_scan_parameters_version_id uuid, p_signal_payload_hash char(64)
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS DISTINCT FROM p_generating_iteration_id THEN
        RAISE EXCEPTION 'candidate entry write requires its active scan lease'
            USING ERRCODE = '40001';
    END IF;
    INSERT INTO strategy_training.training_entry_events (
        entry_event_id, dataset_version_id, generating_iteration_id,
        instrument_id, symbol, source, signal_time, entry_time, direction,
        trigger_score, coverage_percent, theoretical_signal_price, entry_price,
        pool_evaluation_id, ticker_pool_rule_version_id,
        factor_registry_version_id, scan_parameters_version_id, signal_payload_hash
    ) VALUES (
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, upper(p_symbol), 'IN_SAMPLE_MODEL_A', p_signal_time,
        p_entry_time, p_direction, p_trigger_score, p_coverage_percent,
        p_theoretical_signal_price, p_entry_price, p_pool_evaluation_id,
        p_ticker_pool_rule_version_id, p_factor_registry_version_id,
        p_scan_parameters_version_id, p_signal_payload_hash
    );
    RETURN p_entry_event_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.complete_training_model_a_candidate_scan(
    p_task_id uuid, p_lease_token uuid, p_scan_result_hash char(64)
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'candidate scan completion requires its active lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN strategy_training.freeze_training_iteration_entry_batch(
        task_record.iteration_id, p_scan_result_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_candidate_scans()
RETURNS TABLE (iteration_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; scan_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    FOR candidate IN
        SELECT iteration.iteration_id, iteration.experiment_id,
               proposal.task_id AS parent_task_id
        FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_optimizer_trial_proposals proposal
          ON proposal.optimizer_run_id = run.optimizer_run_id
        JOIN strategy_training.training_optimizer_trial_iterations link
          ON link.optimizer_trial_proposal_id = proposal.optimizer_trial_proposal_id
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = link.iteration_id
        LEFT JOIN strategy_training.training_iteration_entry_batches batch
          ON batch.iteration_id = iteration.iteration_id
        WHERE run.state = 'RUNNING' AND iteration.state = 'RUNNING'
          AND batch.iteration_id IS NULL
        ORDER BY iteration.created_at, iteration.iteration_id
    LOOP
        iteration_id := candidate.iteration_id;
        SELECT * INTO scan_task FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'MODEL_A_CANDIDATE_SCAN';
        IF NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id, NULL,
                candidate.parent_task_id, 'MODEL_A_CANDIDATE_SCAN', 'WORKER',
                encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                    'MODEL_A_CANDIDATE_SCAN'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_CANDIDATE_SCAN',
                    'payload_version', 1), 15
            );
            action := 'SCAN_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF scan_task.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                COALESCE(scan_task.failure_code, 'MODEL_A_CANDIDATE_SCAN_FAILED'),
                scan_task.result_hash, NULL, 'training-orchestrator',
                'candidate scan task failed', gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        IF scan_task.state = 'SUCCEEDED' THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                'MODEL_A_CANDIDATE_SCAN_MISSING_BATCH', scan_task.result_hash,
                NULL, 'training-orchestrator', 'scan succeeded without frozen batch',
                gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_SCAN'; RETURN NEXT;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.training_model_a_candidate_scan_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_instruments(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_pool(uuid, uuid, bigint)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_bars(uuid, uuid, bigint)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_candidate_entry_event(
    uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
    text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.complete_training_model_a_candidate_scan(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_candidate_scans()
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.freeze_training_iteration_entry_batch(uuid, char(64))
FROM tb2_training_rw;
REVOKE ALL ON FUNCTION
    strategy_training.training_model_a_candidate_scan_context(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_instruments(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_pool(uuid, uuid, bigint),
    strategy_training.training_model_a_candidate_scan_bars(uuid, uuid, bigint),
    strategy_training.create_training_candidate_entry_event(
        uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
        text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
    ),
    strategy_training.complete_training_model_a_candidate_scan(uuid, uuid, char(64)),
    strategy_training.advance_training_candidate_scans()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_a_candidate_scan_context(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_instruments(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_pool(uuid, uuid, bigint),
    strategy_training.training_model_a_candidate_scan_bars(uuid, uuid, bigint),
    strategy_training.create_training_candidate_entry_event(
        uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz,
        text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
    ),
    strategy_training.complete_training_model_a_candidate_scan(uuid, uuid, char(64))
TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.advance_training_candidate_scans()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '048_training_model_a_candidate_scan',
    encode(digest('auto_trade_v2_048_training_model_a_candidate_scan_v1', 'sha256'), 'hex'),
    'Add lease-bound 5m optimizer candidate scanning and frozen entry batches'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
