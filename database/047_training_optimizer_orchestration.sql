\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_optimizer_trial_iterations (
    optimizer_trial_proposal_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_optimizer_trial_proposals,
    iteration_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_iterations,
    linked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE strategy_training.training_iteration_entry_batches (
    iteration_id uuid PRIMARY KEY REFERENCES strategy_training.training_iterations,
    entry_event_ids jsonb NOT NULL,
    entry_event_count integer NOT NULL CHECK (entry_event_count > 0),
    scan_result_hash char(64) NOT NULL,
    batch_hash char(64) NOT NULL,
    frozen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(entry_event_ids) = 'array'),
    CHECK (jsonb_array_length(entry_event_ids) = entry_event_count),
    CHECK (scan_result_hash ~ '^[0-9a-f]{64}$'),
    CHECK (batch_hash ~ '^[0-9a-f]{64}$')
);

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
       OR iteration_record.candidate_source NOT IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
       OR p_scan_result_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'entry batch requires a running optimizer candidate and scan hash'
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

CREATE OR REPLACE FUNCTION strategy_training.training_optimizer_tell_context(
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
    iteration_state text,
    iteration_rejection_code text,
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
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'OPTIMIZER'
       OR task_record.task_type <> 'OPTIMIZER_TRIAL'
       OR task_record.task_payload ->> 'action' <> 'TELL'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'optimizer tell requires its active TELL lease'
            USING ERRCODE = '40001';
    END IF;
    IF task_record.optimizer_run_id IS NULL OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'optimizer TELL requires its run and iteration'
            USING ERRCODE = '23514';
    END IF;
    payload_trial_text := task_record.task_payload ->> 'trial_number';
    SELECT * INTO STRICT run_record FROM strategy_training.training_optimizer_runs run
    WHERE run.optimizer_run_id = task_record.optimizer_run_id;
    SELECT * INTO STRICT iteration_record FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;
    IF payload_trial_text !~ '^[0-9]+$'
       OR run_record.state <> 'RUNNING'
       OR iteration_record.experiment_id <> run_record.experiment_id
       OR iteration_record.state NOT IN ('SUCCEEDED', 'FAILED', 'REJECTED', 'CANCELLED')
       OR NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_optimizer_trial_proposals proposal
            JOIN strategy_training.training_optimizer_trial_iterations link
              ON link.optimizer_trial_proposal_id = proposal.optimizer_trial_proposal_id
            WHERE proposal.optimizer_run_id = run_record.optimizer_run_id
              AND proposal.trial_number = payload_trial_text::integer
              AND link.iteration_id = iteration_record.iteration_id
       ) THEN
        RAISE EXCEPTION 'optimizer TELL is outside its terminal candidate contract'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY
    SELECT run_record.optimizer_run_id, iteration_record.iteration_id,
           payload_trial_text::integer, iteration_record.candidate_parameters,
           iteration_record.candidate_content_hash, config.config_version_id,
           config.semver::text, config.config_json, iteration_record.state::text,
           iteration_record.rejection_code::text,
           objective.objective_value, objective.evidence_hash
    FROM strategy_training.training_config_versions config
    LEFT JOIN strategy_training.optimizer_train_objectives objective
      ON objective.iteration_id = iteration_record.iteration_id
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.status = 'READY' AND config.config_type = 'SEARCH_SPACE';
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
    FROM strategy_training.training_optimizer_tell_context(p_task_id, p_lease_token);
    IF p_trial_state = 'COMPLETE' THEN
        IF context_record.iteration_state <> 'SUCCEEDED'
           OR context_record.train_objective IS NULL
           OR p_train_objective IS DISTINCT FROM context_record.train_objective
           OR p_train_evidence_hash IS DISTINCT FROM context_record.train_evidence_hash
           OR p_rejection_codes <> '[]'::jsonb THEN
            RAISE EXCEPTION 'complete TELL must use its terminal TRAIN-only objective'
                USING ERRCODE = '23514';
        END IF;
    ELSIF p_trial_state = 'FAIL' THEN
        IF p_train_objective IS NOT NULL OR p_train_evidence_hash IS NOT NULL
           OR jsonb_typeof(p_rejection_codes) IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_rejection_codes) = 0
           OR context_record.iteration_state = 'SUCCEEDED' THEN
            RAISE EXCEPTION 'failed TELL requires a failed terminal iteration'
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

CREATE OR REPLACE FUNCTION strategy_training.advance_training_optimizer_run(
    p_optimizer_run_id uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    run_record strategy_training.training_optimizer_runs%ROWTYPE;
    proposal_record strategy_training.training_optimizer_trial_proposals%ROWTYPE;
    iteration_record strategy_training.training_iterations%ROWTYPE;
    task_record strategy_training.training_tasks%ROWTYPE;
    next_trial integer;
    next_candidate_version integer;
    new_iteration_id uuid;
    batch_record strategy_training.training_iteration_entry_batches%ROWTYPE;
BEGIN
    SELECT * INTO STRICT run_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_optimizer_run_id FOR UPDATE;
    IF run_record.state <> 'RUNNING' THEN
        RETURN 'RUN_NOT_ACTIVE';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiments experiment
        WHERE experiment.experiment_id = run_record.experiment_id
          AND experiment.state = 'RUNNING'
    ) THEN
        RETURN 'WAITING_EXPERIMENT';
    END IF;
    SELECT count(*) INTO next_trial
    FROM strategy_training.training_optimizer_trial_results result
    WHERE result.optimizer_run_id = p_optimizer_run_id;
    IF next_trial >= run_record.trial_budget THEN
        PERFORM strategy_training.transition_training_optimizer_run(
            p_optimizer_run_id, 'RUNNING', 'SUCCEEDED', NULL, NULL,
            'training-orchestrator', 'trial budget completed', gen_random_uuid()
        );
        RETURN 'RUN_COMPLETED';
    END IF;

    SELECT * INTO proposal_record
    FROM strategy_training.training_optimizer_trial_proposals proposal
    WHERE proposal.optimizer_run_id = p_optimizer_run_id
      AND proposal.trial_number = next_trial;
    IF NOT FOUND THEN
        SELECT * INTO task_record FROM strategy_training.training_tasks task
        WHERE task.optimizer_run_id = p_optimizer_run_id
          AND task.task_type = 'OPTIMIZER_TRIAL'
          AND task.task_payload ->> 'action' = 'ASK'
          AND (task.task_payload ->> 'trial_number')::integer = next_trial;
        IF FOUND THEN
            IF task_record.state IN ('FAILED', 'CANCELLED') THEN
                PERFORM strategy_training.transition_training_optimizer_run(
                    p_optimizer_run_id, 'RUNNING', 'FAILED', 'OPTIMIZER_ASK_FAILED',
                    NULL, 'training-orchestrator', 'ASK task failed', gen_random_uuid()
                );
                RETURN 'RUN_FAILED';
            END IF;
            RETURN 'WAITING_ASK';
        END IF;
        PERFORM strategy_training.enqueue_training_task(
            run_record.experiment_id, NULL, p_optimizer_run_id, NULL,
            'OPTIMIZER_TRIAL', 'OPTIMIZER',
            encode(public.digest(concat_ws('|', p_optimizer_run_id::text,
                next_trial::text, 'ASK'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'OPTIMIZER_TRIAL',
                'payload_version', 1, 'action', 'ASK', 'trial_number', next_trial),
            10
        );
        RETURN 'ASK_ENQUEUED';
    END IF;

    SELECT iteration.* INTO iteration_record
    FROM strategy_training.training_optimizer_trial_iterations link
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = link.iteration_id
    WHERE link.optimizer_trial_proposal_id = proposal_record.optimizer_trial_proposal_id;
    IF NOT FOUND THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(run_record.experiment_id::text, 0));
        SELECT COALESCE(max(candidate_version), 0) + 1 INTO next_candidate_version
        FROM strategy_training.training_iterations
        WHERE experiment_id = run_record.experiment_id;
        new_iteration_id := strategy_training.create_training_iteration(
            run_record.experiment_id, next_candidate_version, NULL,
            CASE run_record.optimizer_kind WHEN 'TPE' THEN 'OPTUNA_TPE'
                ELSE 'RANDOM_SEARCH' END,
            proposal_record.sampler_seed, proposal_record.candidate_parameters,
            jsonb_build_object('optimizer_run_id', p_optimizer_run_id,
                'trial_number', proposal_record.trial_number), NULL
        );
        INSERT INTO strategy_training.training_optimizer_trial_iterations (
            optimizer_trial_proposal_id, iteration_id
        ) VALUES (proposal_record.optimizer_trial_proposal_id, new_iteration_id);
        PERFORM strategy_training.transition_training_iteration(
            new_iteration_id, 'CREATED', 'VALIDATING', NULL, NULL, NULL,
            'training-orchestrator', 'candidate proposal accepted', gen_random_uuid()
        );
        PERFORM strategy_training.transition_training_iteration(
            new_iteration_id, 'VALIDATING', 'RUNNING', NULL, NULL, NULL,
            'training-orchestrator', 'candidate ready for governed scan', gen_random_uuid()
        );
        RETURN 'ITERATION_CREATED';
    END IF;

    SELECT * INTO task_record FROM strategy_training.training_tasks task
    WHERE task.optimizer_run_id = p_optimizer_run_id
      AND task.iteration_id = iteration_record.iteration_id
      AND task.task_type = 'OPTIMIZER_TRIAL'
      AND task.task_payload ->> 'action' = 'TELL';
    IF FOUND THEN
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_optimizer_run(
                p_optimizer_run_id, 'RUNNING', 'FAILED', 'OPTIMIZER_TELL_FAILED',
                NULL, 'training-orchestrator', 'TELL task failed', gen_random_uuid()
            );
            RETURN 'RUN_FAILED';
        END IF;
        RETURN 'WAITING_TELL';
    END IF;

    IF iteration_record.state IN ('SUCCEEDED', 'FAILED', 'REJECTED', 'CANCELLED') THEN
        PERFORM strategy_training.enqueue_training_task(
            run_record.experiment_id, iteration_record.iteration_id,
            p_optimizer_run_id, proposal_record.task_id,
            'OPTIMIZER_TRIAL', 'OPTIMIZER',
            encode(public.digest(concat_ws('|', p_optimizer_run_id::text,
                next_trial::text, 'TELL'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'OPTIMIZER_TRIAL',
                'payload_version', 1, 'action', 'TELL', 'trial_number', next_trial),
            10
        );
        RETURN 'TELL_ENQUEUED';
    END IF;

    SELECT * INTO batch_record
    FROM strategy_training.training_iteration_entry_batches batch
    WHERE batch.iteration_id = iteration_record.iteration_id;
    IF NOT FOUND THEN
        RETURN 'WAITING_ENTRY_BATCH';
    END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks task
    WHERE task.iteration_id = iteration_record.iteration_id
      AND task.task_type = 'MODEL_A_EVALUATION';
    IF NOT FOUND THEN
        PERFORM strategy_training.enqueue_training_task(
            run_record.experiment_id, iteration_record.iteration_id, NULL,
            proposal_record.task_id, 'MODEL_A_EVALUATION', 'EVALUATOR',
            encode(public.digest(concat_ws('|', iteration_record.iteration_id::text,
                batch_record.batch_hash::text, 'MODEL_A_EVALUATION'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'MODEL_A_EVALUATION',
                'payload_version', 1, 'entry_event_ids', batch_record.entry_event_ids),
            20
        );
        RETURN 'EVALUATION_ENQUEUED';
    END IF;
    IF task_record.state IN ('FAILED', 'CANCELLED') THEN
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id, 'RUNNING', 'FAILED',
            'MODEL_A_EVALUATION_FAILED', task_record.result_hash, NULL,
            'training-orchestrator', 'model A evaluation task failed', gen_random_uuid()
        );
        RETURN 'ITERATION_FAILED';
    END IF;
    IF task_record.state = 'SUCCEEDED' THEN
        RETURN 'WAITING_TRAIN_L0';
    END IF;
    RETURN 'WAITING_EVALUATION';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_optimizer_runs()
RETURNS TABLE (optimizer_run_id uuid, action text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE run_id uuid;
BEGIN
    FOR run_id IN
        SELECT run.optimizer_run_id
        FROM strategy_training.training_optimizer_runs run
        WHERE run.state = 'RUNNING'
        ORDER BY run.created_at, run.optimizer_run_id
    LOOP
        optimizer_run_id := run_id;
        action := strategy_training.advance_training_optimizer_run(run_id);
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE TRIGGER trg_training_optimizer_trial_iterations_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_optimizer_trial_iterations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_iteration_entry_batches_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_iteration_entry_batches
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_optimizer_trial_iterations OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iteration_entry_batches OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.freeze_training_iteration_entry_batch(uuid, char(64))
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_optimizer_tell_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_optimizer_trial_result(
    uuid, uuid, text, numeric, jsonb, char(64), char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_optimizer_run(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_optimizer_runs()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_optimizer_trial_iterations,
    strategy_training.training_iteration_entry_batches FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.freeze_training_iteration_entry_batch(uuid, char(64)),
    strategy_training.training_optimizer_tell_context(uuid, uuid),
    strategy_training.advance_training_optimizer_run(uuid),
    strategy_training.advance_training_optimizer_runs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.freeze_training_iteration_entry_batch(uuid, char(64))
TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.training_optimizer_tell_context(uuid, uuid)
TO tb2_training_optimizer;
GRANT EXECUTE ON FUNCTION strategy_training.advance_training_optimizer_runs()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '047_training_optimizer_orchestration',
    encode(digest('auto_trade_v2_047_training_optimizer_orchestration_v1', 'sha256'), 'hex'),
    'Create optimizer candidate iterations and advance ASK evaluation TELL tasks idempotently'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
