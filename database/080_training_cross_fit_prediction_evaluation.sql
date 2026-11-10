\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_cross_fit_predictions
ADD COLUMN evaluation_task_id uuid UNIQUE REFERENCES strategy_training.training_tasks;

CREATE TABLE strategy_training.training_cross_fit_prediction_coverage_reports (
    cross_fit_prediction_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_cross_fit_predictions,
    random_baseline_config_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    reference_set_id uuid NOT NULL
        REFERENCES strategy_training.training_random_baseline_reference_sets,
    total_signal_count integer NOT NULL CHECK (total_signal_count >= 0),
    evaluable_signal_count integer NOT NULL CHECK (evaluable_signal_count >= 0),
    excluded_signal_count integer NOT NULL CHECK (excluded_signal_count >= 0),
    coverage_ratio numeric(18,12) NOT NULL CHECK (coverage_ratio BETWEEN 0 AND 1),
    effective_day_count integer NOT NULL CHECK (effective_day_count >= 0),
    power_status varchar(24) NOT NULL CHECK (
        power_status IN ('READY', 'INSUFFICIENT_POWER')
    ),
    distribution_comparison jsonb NOT NULL CHECK (
        jsonb_typeof(distribution_comparison) = 'object'
    ),
    report_hash char(64) NOT NULL CHECK (report_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (total_signal_count = evaluable_signal_count + excluded_signal_count)
);

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_random_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    random_baseline_config_version_id uuid, config_json jsonb,
    reference_dataset_version_id uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    RETURN QUERY
    SELECT config.config_version_id, config.config_json, reference.dataset_version_id
    FROM strategy_training.training_cross_fit_prediction_context(
        p_task_id, p_lease_token
    ) context
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = context.iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'RANDOM_BASELINE'
     AND config.semver::text NOT IN ('0.1.0', '0.1.1')
     AND config.status = 'READY' AND config.config_json ? 'reference_set_id'
    JOIN strategy_training.training_random_baseline_reference_sets reference
      ON reference.reference_set_id = (config.config_json ->> 'reference_set_id')::uuid
     AND reference.status = 'READY'
    WHERE reference.dataset_version_id = context.dataset_version_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cross-fit prediction requires a same-dataset approved baseline reference'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_cross_fit_prediction_benchmark_bars(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (open_time timestamptz, close_price numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $function$
DECLARE benchmark_instrument_id bigint; benchmark_symbol_value text;
        warmup_start_value timestamptz; prediction_end_value timestamptz;
        source_as_of_value timestamptz;
BEGIN
    SELECT config.config_json -> 'stratification' ->> 'benchmark_symbol',
           dataset.warmup_start_at, prediction.eligible_end_at,
           dataset.source_as_of_at
    INTO STRICT benchmark_symbol_value, warmup_start_value,
                prediction_end_value, source_as_of_value
    FROM strategy_training.training_cross_fit_prediction_context(
        p_task_id, p_lease_token
    ) prediction
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = prediction.dataset_version_id
    JOIN strategy_training.training_cross_fit_prediction_random_context(
        p_task_id, p_lease_token
    ) config ON true;
    SELECT instrument.instrument_id INTO STRICT benchmark_instrument_id
    FROM core.instruments instrument
    WHERE instrument.exchange = 'BINANCE'
      AND instrument.market = 'USD_M_FUTURES'
      AND instrument.symbol = benchmark_symbol_value;
    RETURN QUERY EXECUTE format(
        $query$
        SELECT DISTINCT ON (bar.open_time) bar.open_time, bar.close_price
        FROM market.klines bar
        WHERE bar.instrument_id = %1$L::bigint
          AND bar.price_type = 'TRADE' AND bar.interval_seconds = 300
          AND bar.is_closed AND bar.quality_status = 'VALID'
          AND bar.open_time >= %2$L::timestamptz
          AND bar.open_time < %3$L::timestamptz
          AND bar.effective_at <= %4$L::timestamptz
        ORDER BY bar.open_time, bar.revision_no DESC
        $query$,
        benchmark_instrument_id, warmup_start_value,
        prediction_end_value, source_as_of_value
    );
END
$function$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_prediction_signal_stratum(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64),
    p_random_baseline_config_version_id uuid,
    p_volatility_bucket text, p_liquidity_bucket text, p_btc_regime text,
    p_volatility_window_start_at timestamptz,
    p_liquidity_window_start_at timestamptz,
    p_btc_regime_window_start_at timestamptz, p_evidence_json jsonb
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        prediction_record strategy_training.training_cross_fit_predictions%ROWTYPE;
        entry_record strategy_training.training_entry_events%ROWTYPE;
        config_record strategy_training.training_config_versions%ROWTYPE;
        bucket_hours integer; bucket_start integer;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    SELECT * INTO STRICT prediction_record
    FROM strategy_training.training_cross_fit_predictions
    WHERE task_id = p_task_id;
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id;
    SELECT * INTO STRICT config_record FROM strategy_training.training_config_versions
    WHERE config_version_id = p_random_baseline_config_version_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'WORKER'
       OR task_record.task_type <> 'CROSS_FIT_PREDICT'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR prediction_record.completed_at IS NOT NULL
       OR entry_record.generating_iteration_id <> prediction_record.selected_iteration_id
       OR entry_record.source <> 'CROSS_FIT_MODEL_A_CANDIDATE'
       OR entry_record.entry_use <> 'GO_NO_GO'
       OR entry_record.signal_time < prediction_record.prediction_start_at
       OR entry_record.signal_time >= prediction_record.prediction_end_at THEN
        RAISE EXCEPTION 'Cross-fit stratum requires its exact active prediction lease'
            USING ERRCODE = '40001';
    END IF;
    IF config_record.config_type <> 'RANDOM_BASELINE'
       OR config_record.status <> 'READY'
       OR config_record.semver::text IN ('0.1.0', '0.1.1')
       OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_iterations iteration
            JOIN strategy_training.training_experiment_config_bindings binding
              ON binding.experiment_id = iteration.experiment_id
             AND binding.config_type = 'RANDOM_BASELINE'
            JOIN strategy_training.training_random_baseline_reference_sets reference
              ON reference.reference_set_id =
                    (config_record.config_json ->> 'reference_set_id')::uuid
             AND reference.dataset_version_id = entry_record.dataset_version_id
             AND reference.status = 'READY'
            WHERE iteration.iteration_id = prediction_record.selected_iteration_id
              AND binding.config_version_id = config_record.config_version_id
       ) OR p_volatility_window_start_at >= entry_record.signal_time
          OR p_liquidity_window_start_at >= entry_record.signal_time
          OR p_btc_regime_window_start_at >= entry_record.signal_time
          OR jsonb_typeof(p_evidence_json) IS DISTINCT FROM 'object'
          OR p_evidence_json = '{}'::jsonb THEN
        RAISE EXCEPTION 'Cross-fit stratum does not match its frozen baseline policy'
            USING ERRCODE = '23514';
    END IF;
    bucket_hours := (config_record.config_json ->> 'time_bucket_hours')::integer;
    bucket_start := (extract(hour FROM entry_record.signal_time AT TIME ZONE 'UTC')::integer
                     / bucket_hours) * bucket_hours;
    INSERT INTO strategy_training.training_random_baseline_signal_strata (
        entry_event_id, random_baseline_config_version_id, pool_identity,
        time_bucket, volatility_bucket, liquidity_bucket, btc_regime,
        volatility_window_start_at, liquidity_window_start_at,
        btc_regime_window_start_at, evidence_json, evidence_hash
    ) VALUES (
        p_entry_event_id, p_random_baseline_config_version_id,
        entry_record.ticker_pool_rule_version_id::text,
        'UTC-' || lpad(bucket_start::text, 2, '0') || '-' ||
            lpad((bucket_start + bucket_hours - 1)::text, 2, '0'),
        p_volatility_bucket, p_liquidity_bucket, p_btc_regime,
        p_volatility_window_start_at, p_liquidity_window_start_at,
        p_btc_regime_window_start_at, p_evidence_json,
        encode(digest(p_evidence_json::text, 'sha256'), 'hex')
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.prepare_cross_fit_evaluation_tasks(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        prediction_record strategy_training.training_cross_fit_predictions%ROWTYPE;
        evaluation_id uuid; event_ids jsonb; prepared_count integer := 0;
        report_count integer; reference_record record; zero_hash char(64);
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING' THEN RETURN 'EXECUTION_NOT_RUNNING'; END IF;
    IF (SELECT count(*) FROM strategy_training.training_cross_fit_predictions
        WHERE cross_fit_execution_id = p_cross_fit_execution_id
          AND outer_fold_number = p_outer_fold_number
          AND completed_at IS NOT NULL) <> 2 THEN
        RETURN 'WAITING_PREDICTION_PAIR';
    END IF;
    FOR prediction_record IN
        SELECT * FROM strategy_training.training_cross_fit_predictions
        WHERE cross_fit_execution_id = p_cross_fit_execution_id
          AND outer_fold_number = p_outer_fold_number
        ORDER BY optimizer_role FOR UPDATE
    LOOP
        IF EXISTS (SELECT 1 FROM strategy_training.training_cross_fit_prediction_coverage_reports
                   WHERE cross_fit_prediction_id = prediction_record.cross_fit_prediction_id) THEN
            CONTINUE;
        END IF;
        IF prediction_record.event_count = 0 THEN
            SELECT config.config_version_id,
                   (config.config_json ->> 'reference_set_id')::uuid AS reference_set_id
            INTO STRICT reference_record
            FROM strategy_training.training_iterations iteration
            JOIN strategy_training.training_experiment_config_bindings binding
              ON binding.experiment_id = iteration.experiment_id
             AND binding.config_type = 'RANDOM_BASELINE'
            JOIN strategy_training.training_config_versions config
              ON config.config_version_id = binding.config_version_id
             AND config.status = 'READY'
            WHERE iteration.iteration_id = prediction_record.selected_iteration_id;
            zero_hash := encode(digest(jsonb_build_object(
                'cross_fit_prediction_id', prediction_record.cross_fit_prediction_id,
                'power_status', 'INSUFFICIENT_POWER', 'total_signal_count', 0
            )::text, 'sha256'), 'hex');
            INSERT INTO strategy_training.training_cross_fit_prediction_coverage_reports (
                cross_fit_prediction_id, random_baseline_config_version_id,
                reference_set_id, total_signal_count, evaluable_signal_count,
                excluded_signal_count, coverage_ratio, effective_day_count,
                power_status, distribution_comparison, report_hash
            ) VALUES (
                prediction_record.cross_fit_prediction_id,
                reference_record.config_version_id, reference_record.reference_set_id,
                0, 0, 0, 0, 0, 'INSUFFICIENT_POWER',
                jsonb_build_object('by_date', '[]'::jsonb, 'by_symbol', '[]'::jsonb,
                    'by_volatility_bucket', '[]'::jsonb,
                    'by_exclusion_reason', '[]'::jsonb), zero_hash
            );
            CONTINUE;
        END IF;
        IF prediction_record.evaluation_task_id IS NULL THEN
            SELECT jsonb_agg(to_jsonb(event.entry_event_id::text)
                             ORDER BY event.entry_event_id)
            INTO STRICT event_ids
            FROM strategy_training.training_entry_events event
            WHERE event.generating_iteration_id = prediction_record.selected_iteration_id
              AND event.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
              AND event.entry_use = 'GO_NO_GO'
              AND event.signal_time >= prediction_record.prediction_start_at
              AND event.signal_time < prediction_record.prediction_end_at
              AND event.status = 'COMPLETE';
            IF jsonb_array_length(event_ids) <> prediction_record.event_count THEN
                RAISE EXCEPTION 'Cross-fit evaluation event set differs from frozen prediction'
                    USING ERRCODE = '23514';
            END IF;
            evaluation_id := strategy_training.enqueue_training_task(
                execution_record.experiment_id, prediction_record.selected_iteration_id,
                prediction_record.optimizer_run_id, prediction_record.task_id,
                'MODEL_A_EVALUATION', 'EVALUATOR',
                encode(digest(concat_ws('|', prediction_record.cross_fit_prediction_id::text,
                    'CROSS_FIT_EVALUATION_V1'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_EVALUATION',
                    'payload_version', 1, 'entry_event_ids', event_ids), 20
            );
            UPDATE strategy_training.training_cross_fit_predictions
            SET evaluation_task_id = evaluation_id
            WHERE cross_fit_prediction_id = prediction_record.cross_fit_prediction_id;
            prepared_count := prepared_count + 1;
        END IF;
    END LOOP;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_predictions prediction
        JOIN strategy_training.training_tasks task
          ON task.task_id = prediction.evaluation_task_id
        WHERE prediction.cross_fit_execution_id = p_cross_fit_execution_id
          AND prediction.outer_fold_number = p_outer_fold_number
          AND task.state IN ('FAILED', 'CANCELLED')
    ) THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'FAILED', failure_code = 'FOLD_EVALUATION_FAILED',
            completed_at = clock_timestamp(), lease_token = NULL,
            leased_by = NULL, lease_expires_at = NULL
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
        RETURN 'EXECUTION_FAILED';
    END IF;
    SELECT count(*) INTO report_count
    FROM strategy_training.training_cross_fit_prediction_coverage_reports report
    JOIN strategy_training.training_cross_fit_predictions prediction USING (cross_fit_prediction_id)
    WHERE prediction.cross_fit_execution_id = p_cross_fit_execution_id
      AND prediction.outer_fold_number = p_outer_fold_number;
    IF report_count = 2 THEN RETURN 'EVALUATION_PAIR_COMPLETED';
    ELSIF prepared_count > 0 THEN RETURN 'EVALUATION_TASKS_ENQUEUED';
    END IF;
    RETURN 'WAITING_EVALUATION_PAIR';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_cross_fit_prediction_coverage(
    p_task_id uuid, p_lease_token uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        prediction_record strategy_training.training_cross_fit_predictions%ROWTYPE;
        config_record record; total_value integer; evaluable_value integer;
        excluded_value integer; days_value integer; coverage_value numeric;
        distributions_value jsonb; status_value text; hash_value char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    SELECT prediction.* INTO STRICT prediction_record
    FROM strategy_training.training_cross_fit_predictions prediction
    WHERE prediction.evaluation_task_id = p_task_id
      AND prediction.task_id = task_record.parent_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Cross-fit coverage requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT config.config_version_id, config.config_json,
           (config.config_json ->> 'reference_set_id')::uuid AS reference_set_id
    INTO STRICT config_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id AND config.status = 'READY'
    WHERE iteration.iteration_id = prediction_record.selected_iteration_id;
    WITH entries AS MATERIALIZED (
        SELECT entry.entry_event_id, entry.signal_time, entry.symbol,
               stratum.volatility_bucket,
               baseline.matched_entry_event_id IS NOT NULL AS evaluable,
               CASE WHEN baseline.matched_entry_event_id IS NOT NULL THEN NULL
                    WHEN NOT outcome.is_complete THEN 'ENTRY_OUTCOME_' || outcome.incomplete_reason
                    ELSE exclusion.reason_code::text END AS exclusion_reason
        FROM strategy_training.training_entry_events entry
        JOIN strategy_training.training_entry_outcomes outcome USING (entry_event_id)
        JOIN strategy_training.training_random_baseline_signal_strata stratum USING (entry_event_id)
        LEFT JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
        LEFT JOIN strategy_training.training_random_baseline_frame_exclusions exclusion
          ON exclusion.entry_event_id = entry.entry_event_id
        WHERE entry.generating_iteration_id = prediction_record.selected_iteration_id
          AND entry.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
          AND entry.signal_time >= prediction_record.prediction_start_at
          AND entry.signal_time < prediction_record.prediction_end_at
          AND entry.status = 'COMPLETE'
          AND (baseline.matched_entry_event_id IS NOT NULL
               OR exclusion.entry_event_id IS NOT NULL OR NOT outcome.is_complete)
    )
    SELECT count(*)::integer, count(*) FILTER (WHERE evaluable)::integer,
           count(*) FILTER (WHERE NOT evaluable)::integer,
           count(DISTINCT signal_time::date) FILTER (WHERE evaluable)::integer,
           jsonb_build_object(
             'by_date', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb)
                FROM (SELECT signal_time::date::text AS key, jsonb_build_object(
                    'date', signal_time::date, 'evaluable', count(*) FILTER (WHERE evaluable),
                    'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                    FROM entries GROUP BY signal_time::date) grouped),
             'by_symbol', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb)
                FROM (SELECT symbol AS key, jsonb_build_object('symbol', symbol,
                    'evaluable', count(*) FILTER (WHERE evaluable),
                    'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                    FROM entries GROUP BY symbol) grouped),
             'by_volatility_bucket', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb)
                FROM (SELECT volatility_bucket AS key, jsonb_build_object(
                    'volatility_bucket', volatility_bucket,
                    'evaluable', count(*) FILTER (WHERE evaluable),
                    'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                    FROM entries GROUP BY volatility_bucket) grouped),
             'by_exclusion_reason', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb)
                FROM (SELECT exclusion_reason AS key, jsonb_build_object(
                    'reason_code', exclusion_reason, 'count', count(*)) AS row_data
                    FROM entries WHERE NOT evaluable GROUP BY exclusion_reason) grouped)
           )
    INTO total_value, evaluable_value, excluded_value, days_value,
         distributions_value FROM entries;
    IF total_value <> prediction_record.event_count THEN
        RAISE EXCEPTION 'Cross-fit coverage cannot finalize before every event is classified'
            USING ERRCODE = '55000';
    END IF;
    coverage_value := evaluable_value::numeric / total_value;
    status_value := CASE
        WHEN coverage_value >= (config_record.config_json ->> 'minimum_fold_coverage_ratio')::numeric
         AND evaluable_value >= (config_record.config_json ->> 'minimum_evaluable_events_per_fold')::integer
        THEN 'READY' ELSE 'INSUFFICIENT_POWER' END;
    hash_value := encode(digest(jsonb_build_object(
        'cross_fit_prediction_id', prediction_record.cross_fit_prediction_id,
        'distribution_comparison', distributions_value,
        'effective_day_count', days_value, 'evaluable_signal_count', evaluable_value,
        'excluded_signal_count', excluded_value, 'coverage_ratio', coverage_value,
        'power_status', status_value, 'total_signal_count', total_value
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_cross_fit_prediction_coverage_reports (
        cross_fit_prediction_id, random_baseline_config_version_id,
        reference_set_id, total_signal_count, evaluable_signal_count,
        excluded_signal_count, coverage_ratio, effective_day_count,
        power_status, distribution_comparison, report_hash
    ) VALUES (
        prediction_record.cross_fit_prediction_id, config_record.config_version_id,
        config_record.reference_set_id, total_value, evaluable_value,
        excluded_value, coverage_value, days_value, status_value,
        distributions_value, hash_value
    ) ON CONFLICT (cross_fit_prediction_id) DO NOTHING;
    RETURN status_value;
END
$$;

ALTER FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
RENAME TO finalize_standard_training_random_baseline_coverage;

CREATE FUNCTION strategy_training.finalize_training_random_baseline_coverage(
    p_task_id uuid, p_lease_token uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_predictions prediction
        JOIN strategy_training.training_tasks task
          ON task.task_id = prediction.evaluation_task_id
         AND task.parent_task_id = prediction.task_id
        WHERE task.task_id = p_task_id
    ) THEN
        RETURN strategy_training.finalize_cross_fit_prediction_coverage(
            p_task_id, p_lease_token
        );
    END IF;
    RETURN strategy_training.finalize_standard_training_random_baseline_coverage(
        p_task_id, p_lease_token
    );
END
$$;

-- Prediction facts are not fold facts until both optimizer roles have complete,
-- independently classified outcome evidence.
CREATE OR REPLACE FUNCTION strategy_training.advance_training_cross_fit_executions()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        timed_out_run strategy_training.training_optimizer_runs%ROWTYPE;
        latest_fold integer; next_fold integer;
        task_record strategy_training.training_tasks%ROWTYPE;
        scope_count integer; terminal_count integer;
        prediction_action text; evaluation_action text;
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
        SELECT execution.* FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.state IN ('PLANNED', 'RUNNING')
        ORDER BY execution.created_at, execution.cross_fit_execution_id
        FOR UPDATE SKIP LOCKED
    LOOP
        cross_fit_execution_id := execution_record.cross_fit_execution_id;
        IF EXISTS (
            SELECT 1 FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run USING (optimizer_run_id)
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
            JOIN strategy_training.training_optimizer_runs run USING (optimizer_run_id)
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
            evaluation_action := strategy_training.prepare_cross_fit_evaluation_tasks(
                execution_record.cross_fit_execution_id, latest_fold
            );
            IF evaluation_action <> 'EVALUATION_PAIR_COMPLETED' THEN
                action := evaluation_action; RETURN NEXT; CONTINUE;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM strategy_training.training_cross_fit_fold_executions fold_execution
                JOIN strategy_training.training_cross_fit_folds fold USING (cross_fit_fold_id)
                WHERE fold_execution.cross_fit_execution_id =
                      execution_record.cross_fit_execution_id
                  AND fold.outer_fold_number = latest_fold
            ) THEN
                action := 'WAITING_FOLD_FINALIZATION'; RETURN NEXT; CONTINUE;
            END IF;
        END IF;
        SELECT * INTO task_record FROM strategy_training.training_tasks task
        WHERE task.experiment_id = execution_record.experiment_id
          AND task.task_type = 'CROSS_FIT_COORDINATE'
          AND task.task_payload ->> 'execution_id' =
              execution_record.cross_fit_execution_id::text
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

ALTER TABLE strategy_training.training_cross_fit_prediction_coverage_reports
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_random_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_prediction_benchmark_bars(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_prediction_signal_stratum(
    uuid, uuid, char(64), uuid, text, text, text,
    timestamptz, timestamptz, timestamptz, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.prepare_cross_fit_evaluation_tasks(uuid, integer)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_cross_fit_prediction_coverage(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_standard_training_random_baseline_coverage(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_prediction_coverage_reports FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.training_cross_fit_prediction_random_context(uuid, uuid),
    strategy_training.training_cross_fit_prediction_benchmark_bars(uuid, uuid),
    strategy_training.record_cross_fit_prediction_signal_stratum(
        uuid, uuid, char(64), uuid, text, text, text,
        timestamptz, timestamptz, timestamptz, jsonb
    ),
    strategy_training.prepare_cross_fit_evaluation_tasks(uuid, integer),
    strategy_training.finalize_cross_fit_prediction_coverage(uuid, uuid),
    strategy_training.finalize_standard_training_random_baseline_coverage(uuid, uuid),
    strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
FROM PUBLIC;
GRANT SELECT ON strategy_training.training_cross_fit_prediction_coverage_reports
TO tb2_training_rw, tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_cross_fit_prediction_random_context(uuid, uuid),
    strategy_training.training_cross_fit_prediction_benchmark_bars(uuid, uuid),
    strategy_training.record_cross_fit_prediction_signal_stratum(
        uuid, uuid, char(64), uuid, text, text, text,
        timestamptz, timestamptz, timestamptz, jsonb
    ) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_evaluation_tasks(uuid, integer)
TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_cross_fit_prediction_coverage(uuid, uuid),
    strategy_training.finalize_standard_training_random_baseline_coverage(uuid, uuid),
    strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '080_training_cross_fit_prediction_evaluation',
    encode(digest('auto_trade_v2_080_training_cross_fit_prediction_evaluation_v1',
        'sha256'), 'hex'),
    'Evaluate frozen Cross-fit predictions with isolated reference coverage evidence'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
