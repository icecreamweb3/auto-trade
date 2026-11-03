\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_optimizer_trial_proposals (
    optimizer_trial_proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id                    uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_tasks,
    optimizer_run_id           uuid NOT NULL
                               REFERENCES strategy_training.training_optimizer_runs,
    trial_number               integer NOT NULL CHECK (trial_number >= 0),
    sampler_kind               varchar(16) NOT NULL
                               CHECK (sampler_kind IN ('TPE', 'RANDOM')),
    sampler_seed               bigint NOT NULL CHECK (sampler_seed >= 0),
    search_space_config_version_id uuid NOT NULL
                               REFERENCES strategy_training.training_config_versions,
    search_space_content_hash  char(64) NOT NULL,
    candidate_parameters       jsonb NOT NULL,
    candidate_content_hash     char(64) NOT NULL,
    proposal_hash              char(64) NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (search_space_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(candidate_parameters) = 'object'
           AND candidate_parameters <> '{}'::jsonb),
    CHECK (candidate_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (candidate_content_hash = encode(digest(candidate_parameters::text, 'sha256'), 'hex')),
    CHECK (proposal_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (optimizer_run_id, trial_number)
);

CREATE OR REPLACE FUNCTION strategy_training.training_optimizer_ask_context(
    p_task_id uuid,
    p_lease_token uuid
)
RETURNS TABLE (
    optimizer_run_id uuid,
    trial_number integer,
    optimizer_kind text,
    run_random_seed bigint,
    search_space_config_version_id uuid,
    search_space_semver text,
    search_space_content_hash char(64),
    search_space_config jsonb,
    prior_trials jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    run_record strategy_training.training_optimizer_runs%ROWTYPE;
    payload_trial_text text;
    completed_count integer;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'OPTIMIZER'
       OR task_record.task_type <> 'OPTIMIZER_TRIAL'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.task_payload ->> 'action' <> 'ASK' THEN
        RAISE EXCEPTION 'optimizer ask requires its active ASK lease'
            USING ERRCODE = '40001';
    END IF;
    IF task_record.optimizer_run_id IS NULL OR task_record.iteration_id IS NOT NULL THEN
        RAISE EXCEPTION 'optimizer ASK requires a run and no iteration'
            USING ERRCODE = '23514';
    END IF;
    payload_trial_text := task_record.task_payload ->> 'trial_number';
    IF jsonb_typeof(task_record.task_payload -> 'trial_number') <> 'number'
       OR payload_trial_text !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'optimizer ASK trial_number must be a non-negative integer'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT run_record
    FROM strategy_training.training_optimizer_runs run
    WHERE run.optimizer_run_id = task_record.optimizer_run_id;
    SELECT count(*) INTO completed_count
    FROM strategy_training.training_optimizer_trial_results result
    WHERE result.optimizer_run_id = run_record.optimizer_run_id;
    IF run_record.state <> 'RUNNING'
       OR run_record.experiment_id <> task_record.experiment_id
       OR payload_trial_text::integer <> completed_count
       OR completed_count >= run_record.trial_budget
       OR EXISTS (
            SELECT 1 FROM strategy_training.training_optimizer_trial_proposals proposal
            WHERE proposal.optimizer_run_id = run_record.optimizer_run_id
              AND proposal.trial_number = payload_trial_text::integer
       ) THEN
        RAISE EXCEPTION 'optimizer ASK is not the next sequential trial'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    SELECT run_record.optimizer_run_id,
           payload_trial_text::integer,
           run_record.optimizer_kind::text,
           run_record.random_seed,
           config.config_version_id,
           config.semver::text,
           config.content_hash,
           config.config_json,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                   'trial_number', result.trial_number,
                   'candidate_parameters', iteration.candidate_parameters,
                   'trial_state', result.trial_state,
                   'train_objective', result.train_objective
               ) ORDER BY result.trial_number)
               FROM strategy_training.training_optimizer_trial_results result
               JOIN strategy_training.training_iterations iteration
                 ON iteration.iteration_id = result.iteration_id
               WHERE result.optimizer_run_id = run_record.optimizer_run_id
           ), '[]'::jsonb)
    FROM strategy_training.training_config_versions config
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.config_version_id = config.config_version_id
     AND binding.experiment_id = run_record.experiment_id
     AND binding.config_type = 'SEARCH_SPACE'
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.config_type = 'SEARCH_SPACE'
      AND config.status = 'READY';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_optimizer_trial_proposal(
    p_task_id uuid,
    p_lease_token uuid,
    p_sampler_seed bigint,
    p_search_space_content_hash char(64),
    p_candidate_parameters jsonb
)
RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    context_record record;
    new_id uuid := gen_random_uuid();
    candidate_hash char(64);
    persisted_proposal_hash char(64);
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_optimizer_ask_context(p_task_id, p_lease_token);
    IF p_sampler_seed < 0
       OR jsonb_typeof(p_candidate_parameters) IS DISTINCT FROM 'object'
       OR p_candidate_parameters = '{}'::jsonb
       OR p_search_space_content_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'optimizer proposal hashes or seed are invalid'
            USING ERRCODE = '23514';
    END IF;
    IF p_search_space_content_hash IS DISTINCT FROM
       context_record.search_space_content_hash THEN
        RAISE EXCEPTION 'optimizer proposal must reference its frozen search space hash'
            USING ERRCODE = '23514';
    END IF;
    candidate_hash := encode(public.digest(p_candidate_parameters::text, 'sha256'), 'hex');
    persisted_proposal_hash := encode(public.digest(concat_ws('|',
        context_record.optimizer_run_id::text, context_record.trial_number::text,
        context_record.optimizer_kind, p_sampler_seed::text,
        context_record.search_space_config_version_id::text,
        p_search_space_content_hash::text, candidate_hash::text
    ), 'sha256'), 'hex');
    INSERT INTO strategy_training.training_optimizer_trial_proposals (
        optimizer_trial_proposal_id, task_id, optimizer_run_id, trial_number,
        sampler_kind, sampler_seed, search_space_config_version_id,
        search_space_content_hash, candidate_parameters,
        candidate_content_hash, proposal_hash
    ) VALUES (
        new_id, p_task_id, context_record.optimizer_run_id,
        context_record.trial_number, context_record.optimizer_kind,
        p_sampler_seed, context_record.search_space_config_version_id,
        p_search_space_content_hash, p_candidate_parameters,
        candidate_hash, persisted_proposal_hash
    );
    RETURN persisted_proposal_hash;
END
$$;

CREATE TRIGGER trg_training_optimizer_trial_proposals_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_optimizer_trial_proposals
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_optimizer_trial_proposals OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_optimizer_ask_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_optimizer_trial_proposal(
    uuid, uuid, bigint, char(64), jsonb
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_optimizer_trial_proposals FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_optimizer_ask_context(uuid, uuid)
FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_training_optimizer_trial_proposal(
    uuid, uuid, bigint, char(64), jsonb
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.training_optimizer_ask_context(uuid, uuid)
TO tb2_training_optimizer;
GRANT EXECUTE ON FUNCTION strategy_training.record_training_optimizer_trial_proposal(
    uuid, uuid, bigint, char(64), jsonb
) TO tb2_training_optimizer;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '046_training_optimizer_ask',
    encode(digest('auto_trade_v2_046_training_optimizer_ask_v1', 'sha256'), 'hex'),
    'Persist sequential Optuna ASK proposals without exposing metrics or validation data'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
