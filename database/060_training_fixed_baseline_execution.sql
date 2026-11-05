\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

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
      AND iteration.candidate_source IN (
          'FIXED_BASELINE', 'OPTUNA_TPE', 'RANDOM_SEARCH'
      )
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'candidate scan context is not READY 5m TRAIN'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_entry_source(
    p_task_id uuid, p_lease_token uuid
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    candidate_source_value text;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'candidate source requires its active worker lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT iteration.candidate_source INTO STRICT candidate_source_value
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id
      AND iteration.state = 'RUNNING';
    IF candidate_source_value = 'FIXED_BASELINE' THEN
        RETURN 'FIXED_BASELINE_MODEL_A';
    ELSIF candidate_source_value IN ('OPTUNA_TPE', 'RANDOM_SEARCH') THEN
        RETURN 'IN_SAMPLE_MODEL_A';
    END IF;
    RAISE EXCEPTION 'candidate source % cannot emit model-A scan entries',
        candidate_source_value USING ERRCODE = '23514';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.freeze_training_iteration_entry_batch(
    p_iteration_id uuid,
    p_scan_result_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    iteration_record strategy_training.training_iterations%ROWTYPE;
    event_ids jsonb;
    event_count integer;
    persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations
    WHERE iteration_id = p_iteration_id FOR UPDATE;
    IF iteration_record.state <> 'RUNNING'
       OR iteration_record.candidate_source NOT IN (
           'FIXED_BASELINE', 'OPTUNA_TPE', 'RANDOM_SEARCH'
       )
       OR p_scan_result_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'entry batch requires a running governed candidate and scan hash'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_entry_events entry
        WHERE entry.generating_iteration_id = p_iteration_id
          AND entry.status <> 'COMPLETE'
    ) THEN
        RAISE EXCEPTION 'entry batch cannot freeze incomplete events'
            USING ERRCODE = '55000';
    END IF;
    SELECT jsonb_agg(to_jsonb(entry.entry_event_id::text) ORDER BY entry.entry_event_id),
           count(*)::integer
    INTO event_ids, event_count
    FROM strategy_training.training_entry_events entry
    WHERE entry.generating_iteration_id = p_iteration_id
      AND entry.status = 'COMPLETE';
    IF event_count = 0 THEN
        RAISE EXCEPTION 'entry batch requires at least one complete event'
            USING ERRCODE = '23514';
    END IF;
    persisted_hash := encode(public.digest(concat_ws('|',
        p_iteration_id::text, p_scan_result_hash::text, event_ids::text
    ), 'sha256'), 'hex');
    INSERT INTO strategy_training.training_iteration_entry_batches (
        iteration_id, entry_event_ids, entry_event_count,
        scan_result_hash, batch_hash
    ) VALUES (
        p_iteration_id, event_ids, event_count, p_scan_result_hash, persisted_hash
    );
    RETURN persisted_hash;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_fixed_baselines()
RETURNS TABLE (iteration_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE
    candidate record;
    scan_task strategy_training.training_tasks%ROWTYPE;
    evaluation_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    FOR candidate IN
        SELECT iteration.iteration_id, iteration.experiment_id,
               batch.entry_event_ids, batch.batch_hash
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiments experiment
          ON experiment.experiment_id = iteration.experiment_id
         AND experiment.state = 'RUNNING'
        LEFT JOIN strategy_training.training_iteration_entry_batches batch
          ON batch.iteration_id = iteration.iteration_id
        WHERE iteration.state = 'RUNNING'
          AND iteration.candidate_source = 'FIXED_BASELINE'
        ORDER BY iteration.created_at, iteration.iteration_id
    LOOP
        iteration_id := candidate.iteration_id;
        IF candidate.batch_hash IS NULL THEN
            SELECT * INTO scan_task
            FROM strategy_training.training_tasks task
            WHERE task.iteration_id = candidate.iteration_id
              AND task.task_type = 'MODEL_A_CANDIDATE_SCAN';
            IF NOT FOUND THEN
                PERFORM strategy_training.enqueue_training_task(
                    candidate.experiment_id, candidate.iteration_id, NULL, NULL,
                    'MODEL_A_CANDIDATE_SCAN', 'WORKER',
                    encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                        'FIXED_BASELINE_MODEL_A_CANDIDATE_SCAN'), 'sha256'), 'hex'),
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
                    'fixed baseline scan task failed', gen_random_uuid()
                );
                action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
            END IF;
            IF scan_task.state = 'SUCCEEDED' THEN
                PERFORM strategy_training.transition_training_iteration(
                    candidate.iteration_id, 'RUNNING', 'FAILED',
                    'MODEL_A_CANDIDATE_SCAN_MISSING_BATCH', scan_task.result_hash,
                    NULL, 'training-orchestrator',
                    'fixed baseline scan succeeded without frozen batch',
                    gen_random_uuid()
                );
                action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
            END IF;
            action := 'WAITING_SCAN'; RETURN NEXT; CONTINUE;
        END IF;

        SELECT * INTO evaluation_task
        FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'MODEL_A_EVALUATION';
        IF NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id, NULL, NULL,
                'MODEL_A_EVALUATION', 'EVALUATOR',
                encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                    candidate.batch_hash::text,
                    'FIXED_BASELINE_MODEL_A_EVALUATION'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_EVALUATION',
                    'payload_version', 1,
                    'entry_event_ids', candidate.entry_event_ids), 20
            );
            action := 'EVALUATION_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF evaluation_task.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                COALESCE(evaluation_task.failure_code, 'MODEL_A_EVALUATION_FAILED'),
                evaluation_task.result_hash, NULL, 'training-orchestrator',
                'fixed baseline evaluation task failed', gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        IF evaluation_task.state = 'SUCCEEDED' THEN
            action := 'WAITING_TRAIN_L0'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_EVALUATION'; RETURN NEXT;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.training_model_a_candidate_scan_entry_source(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_fixed_baselines()
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.training_model_a_candidate_scan_entry_source(uuid, uuid),
    strategy_training.advance_training_fixed_baselines()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_a_candidate_scan_entry_source(uuid, uuid)
TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.advance_training_fixed_baselines()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '060_training_fixed_baseline_execution',
    encode(digest('auto_trade_v2_060_training_fixed_baseline_execution_v1', 'sha256'), 'hex'),
    'Add governed fixed Model-A baseline scanning, evaluation orchestration, and source mapping'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
