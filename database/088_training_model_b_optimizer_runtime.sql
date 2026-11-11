\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_model_b_iteration_objectives (
    model_b_iteration_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_iterations,
    portfolio_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_portfolio_runs,
    natural_event_count integer NOT NULL CHECK (natural_event_count > 0),
    accepted_trade_count integer NOT NULL CHECK (
        accepted_trade_count >= 0 AND accepted_trade_count <= natural_event_count
    ),
    net_expectancy_percentage_points numeric NOT NULL
        CHECK (net_expectancy_percentage_points <> 'NaN'::numeric),
    evidence_hash char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TRIGGER trg_training_model_b_iteration_objectives_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_model_b_iteration_objectives
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.finalize_training_model_b_candidate_objective(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        iteration_record strategy_training.training_iterations%ROWTYPE;
        portfolio_record strategy_training.training_portfolio_runs%ROWTYPE;
        natural_count integer; accepted_count integer; objective numeric;
        persisted_hash char(64); existing_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'PORTFOLIO_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'Model-B objective requires its active portfolio lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations
    WHERE iteration_id = task_record.iteration_id FOR UPDATE;
    IF iteration_record.state = 'SUCCEEDED' THEN
        SELECT evidence_hash INTO STRICT existing_hash
        FROM strategy_training.training_model_b_iteration_objectives
        WHERE model_b_iteration_id = iteration_record.iteration_id;
        RETURN existing_hash;
    END IF;
    IF iteration_record.state <> 'RUNNING'
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_model_b_compiled_candidate_policies policy
           WHERE policy.model_b_iteration_id = iteration_record.iteration_id
       ) THEN
        RAISE EXCEPTION 'portfolio task is not a compiled Model-B optimizer candidate'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT portfolio_record
    FROM strategy_training.training_portfolio_runs
    WHERE model_b_iteration_id = iteration_record.iteration_id
      AND status = 'COMPLETE';
    SELECT count(*)::integer INTO natural_count
    FROM strategy_training.training_exit_episode_inputs episode
    JOIN strategy_training.training_model_b_sample_map sample
      ON sample.model_b_sample_id = episode.model_b_sample_id
    WHERE episode.model_b_iteration_id = iteration_record.iteration_id
      AND ((sample.sample_use = 'GO_NO_GO'
            AND sample.natural_source = 'CROSS_FIT_MODEL_A_CANDIDATE')
        OR (sample.sample_use = 'MODEL_B_TRAIN'
            AND sample.natural_source = 'CROSS_FIT_MODEL_A'));
    SELECT count(*)::integer,
           COALESCE(sum(trade.net_pnl), 0)
             / (portfolio_record.notional_per_trade * natural_count) * 100
    INTO accepted_count, objective
    FROM strategy_training.training_portfolio_trades trade
    JOIN strategy_training.training_exit_episode_inputs episode
      ON episode.exit_episode_id = trade.exit_episode_id
    JOIN strategy_training.training_model_b_sample_map sample
      ON sample.model_b_sample_id = episode.model_b_sample_id
    WHERE trade.portfolio_run_id = portfolio_record.portfolio_run_id
      AND ((sample.sample_use = 'GO_NO_GO'
            AND sample.natural_source = 'CROSS_FIT_MODEL_A_CANDIDATE')
        OR (sample.sample_use = 'MODEL_B_TRAIN'
            AND sample.natural_source = 'CROSS_FIT_MODEL_A'));
    IF natural_count <= 0 OR objective IS NULL OR objective = 'NaN'::numeric
       OR EXISTS (
           SELECT 1
           FROM strategy_training.training_exit_episode_inputs episode
           JOIN strategy_training.training_exit_outcomes outcome
             ON outcome.exit_episode_id = episode.exit_episode_id
           WHERE episode.model_b_iteration_id = iteration_record.iteration_id
             AND outcome.risk_violation_codes <> '[]'::jsonb
       ) THEN
        RAISE EXCEPTION 'Model-B candidate objective violates TRAIN hard gates'
            USING ERRCODE = '23514';
    END IF;
    persisted_hash := encode(digest(jsonb_build_object(
        'accepted_trade_count', accepted_count,
        'candidate_content_hash', iteration_record.candidate_content_hash,
        'natural_event_count', natural_count,
        'net_expectancy_percentage_points', objective,
        'portfolio_result_hash', portfolio_record.result_hash
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_model_b_iteration_objectives (
        model_b_iteration_id, portfolio_run_id, natural_event_count,
        accepted_trade_count, net_expectancy_percentage_points, evidence_hash
    ) VALUES (iteration_record.iteration_id, portfolio_record.portfolio_run_id,
        natural_count, accepted_count, objective, persisted_hash);
    PERFORM strategy_training.transition_training_iteration(
        iteration_record.iteration_id, 'RUNNING', 'SUCCEEDED', NULL,
        persisted_hash, NULL, 'model-b-evaluator',
        'TRAIN-only Model-B portfolio objective complete', gen_random_uuid()
    );
    RETURN persisted_hash;
END
$$;

CREATE OR REPLACE VIEW strategy_training.optimizer_train_objectives
WITH (security_barrier = true)
AS
SELECT evidence.iteration_id, iteration.experiment_id,
       iteration.candidate_version, iteration.candidate_content_hash,
       evidence.objective_value, evidence.evidence_hash
FROM strategy_training.training_iteration_evidence_l0 evidence
JOIN strategy_training.training_iterations iteration
  ON iteration.iteration_id = evidence.iteration_id
WHERE evidence.partition = 'TRAIN'
  AND evidence.terminal_state = 'SUCCEEDED'
  AND evidence.hard_gate_passed
UNION ALL
SELECT objective.model_b_iteration_id, iteration.experiment_id,
       iteration.candidate_version, iteration.candidate_content_hash,
       objective.net_expectancy_percentage_points, objective.evidence_hash
FROM strategy_training.training_model_b_iteration_objectives objective
JOIN strategy_training.training_iterations iteration
  ON iteration.iteration_id = objective.model_b_iteration_id;

CREATE OR REPLACE FUNCTION strategy_training.training_optimizer_ask_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    optimizer_run_id uuid, trial_number integer, optimizer_kind text,
    run_random_seed bigint, search_space_config_version_id uuid,
    search_space_semver text, search_space_content_hash char(64),
    search_space_config jsonb, prior_trials jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        run_record strategy_training.training_optimizer_runs%ROWTYPE;
        experiment_mode text; expected_config_type text;
        payload_trial_text text; completed_count integer;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'OPTIMIZER'
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
    SELECT run.* INTO STRICT run_record
    FROM strategy_training.training_optimizer_runs run
    WHERE run.optimizer_run_id = task_record.optimizer_run_id;
    SELECT experiment.experiment_mode INTO STRICT experiment_mode
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = run_record.experiment_id;
    expected_config_type := CASE experiment_mode
        WHEN 'EXIT_POLICY' THEN 'MODEL_B_SEARCH_SPACE' ELSE 'SEARCH_SPACE' END;
    SELECT count(*) INTO completed_count
    FROM strategy_training.training_optimizer_trial_results result
    WHERE result.optimizer_run_id = run_record.optimizer_run_id;
    IF payload_trial_text !~ '^[0-9]+$' OR run_record.state <> 'RUNNING'
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
    RETURN QUERY SELECT run_record.optimizer_run_id,
        payload_trial_text::integer, run_record.optimizer_kind::text,
        run_record.random_seed, config.config_version_id, config.semver::text,
        config.content_hash, config.config_json,
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'trial_number', result.trial_number,
            'candidate_parameters', iteration.candidate_parameters,
            'trial_state', result.trial_state,
            'train_objective', result.train_objective
        ) ORDER BY result.trial_number)
        FROM strategy_training.training_optimizer_trial_results result
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = result.iteration_id
        WHERE result.optimizer_run_id = run_record.optimizer_run_id), '[]'::jsonb)
    FROM strategy_training.training_config_versions config
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.config_version_id = config.config_version_id
     AND binding.experiment_id = run_record.experiment_id
     AND binding.config_type = expected_config_type
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.config_type = expected_config_type AND config.status = 'READY';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_optimizer_tell_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    optimizer_run_id uuid, iteration_id uuid, trial_number integer,
    candidate_parameters jsonb, candidate_content_hash char(64),
    search_space_config_version_id uuid, search_space_semver text,
    search_space_config jsonb, iteration_state text,
    iteration_rejection_code text, train_objective numeric,
    train_evidence_hash char(64)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        run_record strategy_training.training_optimizer_runs%ROWTYPE;
        iteration_record strategy_training.training_iterations%ROWTYPE;
        experiment_mode text; expected_config_type text; payload_trial_text text;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'OPTIMIZER'
       OR task_record.task_type <> 'OPTIMIZER_TRIAL'
       OR task_record.task_payload ->> 'action' <> 'TELL'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'optimizer tell requires its active TELL lease'
            USING ERRCODE = '40001';
    END IF;
    payload_trial_text := task_record.task_payload ->> 'trial_number';
    SELECT run.* INTO STRICT run_record
    FROM strategy_training.training_optimizer_runs run
    WHERE run.optimizer_run_id = task_record.optimizer_run_id;
    SELECT experiment.experiment_mode INTO STRICT experiment_mode
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = run_record.experiment_id;
    expected_config_type := CASE experiment_mode
        WHEN 'EXIT_POLICY' THEN 'MODEL_B_SEARCH_SPACE' ELSE 'SEARCH_SPACE' END;
    SELECT iteration.* INTO STRICT iteration_record
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;
    IF payload_trial_text !~ '^[0-9]+'
       OR run_record.state <> 'RUNNING'
       OR iteration_record.experiment_id <> run_record.experiment_id
       OR iteration_record.state NOT IN ('SUCCEEDED','FAILED','REJECTED','CANCELLED')
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_optimizer_trial_proposals proposal
           JOIN strategy_training.training_optimizer_trial_iterations trial_link
             ON trial_link.optimizer_trial_proposal_id = proposal.optimizer_trial_proposal_id
           WHERE proposal.optimizer_run_id = run_record.optimizer_run_id
             AND proposal.trial_number = payload_trial_text::integer
             AND trial_link.iteration_id = iteration_record.iteration_id
       ) THEN
        RAISE EXCEPTION 'optimizer TELL is outside its terminal candidate contract'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT run_record.optimizer_run_id, iteration_record.iteration_id,
        payload_trial_text::integer, iteration_record.candidate_parameters,
        iteration_record.candidate_content_hash, config.config_version_id,
        config.semver::text, config.config_json, iteration_record.state::text,
        iteration_record.rejection_code::text, objective.objective_value,
        objective.evidence_hash
    FROM strategy_training.training_config_versions config
    LEFT JOIN strategy_training.optimizer_train_objectives objective
      ON objective.iteration_id = iteration_record.iteration_id
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.status = 'READY' AND config.config_type = expected_config_type;
END
$$;

CREATE FUNCTION strategy_training.advance_training_model_b_optimizer_run(
    p_optimizer_run_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE run_record strategy_training.training_optimizer_runs%ROWTYPE;
        proposal_record strategy_training.training_optimizer_trial_proposals%ROWTYPE;
        iteration_record strategy_training.training_iterations%ROWTYPE;
        task_record strategy_training.training_tasks%ROWTYPE;
        next_trial integer; next_candidate_version integer; new_iteration_id uuid;
BEGIN
    SELECT * INTO STRICT run_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_optimizer_run_id FOR UPDATE;
    IF run_record.state <> 'RUNNING' THEN RETURN 'RUN_NOT_ACTIVE'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_config_versions config
        WHERE config.config_version_id = run_record.search_space_config_version_id
          AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'Model-B optimizer requires a READY Model-B search space'
            USING ERRCODE = '23514';
    END IF;
    SELECT count(*) INTO next_trial
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = p_optimizer_run_id;
    IF next_trial >= run_record.trial_budget THEN
        PERFORM strategy_training.transition_training_optimizer_run(
            p_optimizer_run_id, 'RUNNING', 'SUCCEEDED', NULL, NULL,
            'training-orchestrator', 'Model-B trial budget completed', gen_random_uuid());
        RETURN 'RUN_COMPLETED';
    END IF;
    SELECT * INTO proposal_record
    FROM strategy_training.training_optimizer_trial_proposals
    WHERE optimizer_run_id = p_optimizer_run_id AND trial_number = next_trial;
    IF NOT FOUND THEN
        SELECT * INTO task_record FROM strategy_training.training_tasks
        WHERE optimizer_run_id = p_optimizer_run_id AND task_type = 'OPTIMIZER_TRIAL'
          AND task_payload ->> 'action' = 'ASK'
          AND (task_payload ->> 'trial_number')::integer = next_trial;
        IF FOUND THEN
            IF task_record.state IN ('FAILED','CANCELLED') THEN
                PERFORM strategy_training.transition_training_optimizer_run(
                    p_optimizer_run_id, 'RUNNING', 'FAILED', 'OPTIMIZER_ASK_FAILED',
                    NULL, 'training-orchestrator', 'Model-B ASK failed', gen_random_uuid());
                RETURN 'RUN_FAILED';
            END IF;
            RETURN 'WAITING_ASK';
        END IF;
        PERFORM strategy_training.enqueue_training_task(run_record.experiment_id,
            NULL, p_optimizer_run_id, NULL, 'OPTIMIZER_TRIAL', 'OPTIMIZER',
            encode(digest(concat_ws('|', p_optimizer_run_id, next_trial, 'ASK'),
                'sha256'), 'hex'),
            jsonb_build_object('task_type','OPTIMIZER_TRIAL','payload_version',1,
                'action','ASK','trial_number',next_trial), 10);
        RETURN 'ASK_ENQUEUED';
    END IF;
    SELECT iteration.* INTO iteration_record
    FROM strategy_training.training_optimizer_trial_iterations trial_link
    JOIN strategy_training.training_iterations iteration USING (iteration_id)
    WHERE trial_link.optimizer_trial_proposal_id =
          proposal_record.optimizer_trial_proposal_id;
    IF NOT FOUND THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(run_record.experiment_id::text, 0));
        SELECT COALESCE(max(candidate_version),0)+1 INTO next_candidate_version
        FROM strategy_training.training_iterations
        WHERE experiment_id = run_record.experiment_id;
        new_iteration_id := strategy_training.create_training_iteration(
            run_record.experiment_id, next_candidate_version, NULL,
            CASE run_record.optimizer_kind WHEN 'TPE' THEN 'OPTUNA_TPE'
                 ELSE 'RANDOM_SEARCH' END,
            proposal_record.sampler_seed, proposal_record.candidate_parameters,
            jsonb_build_object('optimizer_run_id',p_optimizer_run_id,
                'trial_number',proposal_record.trial_number), NULL);
        INSERT INTO strategy_training.training_optimizer_trial_iterations
            (optimizer_trial_proposal_id, iteration_id)
        VALUES (proposal_record.optimizer_trial_proposal_id, new_iteration_id);
        PERFORM strategy_training.transition_training_iteration(new_iteration_id,
            'CREATED','VALIDATING',NULL,NULL,NULL,'training-orchestrator',
            'Model-B proposal accepted',gen_random_uuid());
        PERFORM strategy_training.transition_training_iteration(new_iteration_id,
            'VALIDATING','RUNNING',NULL,NULL,NULL,'training-orchestrator',
            'Model-B candidate ready for compilation',gen_random_uuid());
        RETURN 'ITERATION_CREATED';
    END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks
    WHERE optimizer_run_id = p_optimizer_run_id
      AND iteration_id = iteration_record.iteration_id
      AND task_type = 'OPTIMIZER_TRIAL' AND task_payload ->> 'action' = 'TELL';
    IF FOUND THEN
        IF task_record.state IN ('FAILED','CANCELLED') THEN
            PERFORM strategy_training.transition_training_optimizer_run(
                p_optimizer_run_id,'RUNNING','FAILED','OPTIMIZER_TELL_FAILED',NULL,
                'training-orchestrator','Model-B TELL failed',gen_random_uuid());
            RETURN 'RUN_FAILED';
        END IF;
        RETURN 'WAITING_TELL';
    END IF;
    IF iteration_record.state IN ('SUCCEEDED','FAILED','REJECTED','CANCELLED') THEN
        PERFORM strategy_training.enqueue_training_task(run_record.experiment_id,
            iteration_record.iteration_id,p_optimizer_run_id,proposal_record.task_id,
            'OPTIMIZER_TRIAL','OPTIMIZER',encode(digest(concat_ws('|',
                p_optimizer_run_id,next_trial,'TELL'),'sha256'),'hex'),
            jsonb_build_object('task_type','OPTIMIZER_TRIAL','payload_version',1,
                'action','TELL','trial_number',next_trial),10);
        RETURN 'TELL_ENQUEUED';
    END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks
    WHERE iteration_id = iteration_record.iteration_id
      AND task_type = 'MODEL_B_PREPARE_CANDIDATE';
    IF NOT FOUND THEN
        PERFORM strategy_training.enqueue_training_task(run_record.experiment_id,
            iteration_record.iteration_id,p_optimizer_run_id,proposal_record.task_id,
            'MODEL_B_PREPARE_CANDIDATE','EVALUATOR',encode(digest(concat_ws('|',
                iteration_record.iteration_id,'PREPARE'),'sha256'),'hex'),
            jsonb_build_object('task_type','MODEL_B_PREPARE_CANDIDATE',
                'payload_version',1),20);
        RETURN 'PREPARATION_ENQUEUED';
    END IF;
    IF task_record.state IN ('FAILED','CANCELLED') THEN
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id,'RUNNING','FAILED',
            'MODEL_B_CANDIDATE_PREPARATION_FAILED',task_record.result_hash,NULL,
            'training-orchestrator','Model-B preparation failed',gen_random_uuid());
        RETURN 'ITERATION_FAILED';
    ELSIF task_record.state <> 'SUCCEEDED' THEN RETURN 'WAITING_PREPARATION'; END IF;
    IF EXISTS (SELECT 1 FROM strategy_training.training_tasks
        WHERE iteration_id = iteration_record.iteration_id
          AND task_type = 'MODEL_B_REPLAY' AND state IN ('FAILED','CANCELLED')) THEN
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id,'RUNNING','FAILED','MODEL_B_REPLAY_FAILED',
            NULL,NULL,'training-orchestrator','Model-B replay failed',gen_random_uuid());
        RETURN 'ITERATION_FAILED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_tasks
        WHERE iteration_id = iteration_record.iteration_id
          AND task_type = 'MODEL_B_REPLAY') OR EXISTS (
        SELECT 1 FROM strategy_training.training_tasks
        WHERE iteration_id = iteration_record.iteration_id
          AND task_type = 'MODEL_B_REPLAY' AND state <> 'SUCCEEDED'
    ) THEN RETURN 'WAITING_REPLAY'; END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks
    WHERE iteration_id = iteration_record.iteration_id
      AND task_type = 'PORTFOLIO_EVALUATION';
    IF NOT FOUND THEN
        PERFORM strategy_training.enqueue_training_task(run_record.experiment_id,
            iteration_record.iteration_id,p_optimizer_run_id,NULL,
            'PORTFOLIO_EVALUATION','EVALUATOR',encode(digest(concat_ws('|',
                iteration_record.iteration_id,'PORTFOLIO'),'sha256'),'hex'),
            jsonb_build_object('task_type','PORTFOLIO_EVALUATION',
                'payload_version',1),20);
        RETURN 'PORTFOLIO_ENQUEUED';
    END IF;
    IF task_record.state IN ('FAILED','CANCELLED') THEN
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id,'RUNNING','FAILED',
            'PORTFOLIO_EVALUATION_FAILED',task_record.result_hash,NULL,
            'training-orchestrator','Model-B portfolio failed',gen_random_uuid());
        RETURN 'ITERATION_FAILED';
    END IF;
    RETURN 'WAITING_PORTFOLIO';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_optimizer_runs()
RETURNS TABLE (optimizer_run_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE run_id uuid; config_type_name text;
BEGIN
    FOR run_id IN SELECT run.optimizer_run_id
        FROM strategy_training.training_optimizer_runs run
        WHERE run.state = 'RUNNING' ORDER BY run.created_at, run.optimizer_run_id
    LOOP
        SELECT config_type INTO STRICT config_type_name
        FROM strategy_training.training_config_versions config
        JOIN strategy_training.training_optimizer_runs run
          ON run.search_space_config_version_id = config.config_version_id
        WHERE run.optimizer_run_id = run_id;
        optimizer_run_id := run_id;
        action := CASE config_type_name
            WHEN 'MODEL_B_SEARCH_SPACE' THEN
                strategy_training.advance_training_model_b_optimizer_run(run_id)
            ELSE strategy_training.advance_training_optimizer_run(run_id) END;
        RETURN NEXT;
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_model_b_iteration_objectives
OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.optimizer_train_objectives OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_b_candidate_objective(uuid,uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_optimizer_ask_context(uuid,uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_optimizer_tell_context(uuid,uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_b_optimizer_run(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_optimizer_runs()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_iteration_objectives FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.finalize_training_model_b_candidate_objective(uuid,uuid),
    strategy_training.training_optimizer_ask_context(uuid,uuid),
    strategy_training.training_optimizer_tell_context(uuid,uuid),
    strategy_training.advance_training_model_b_optimizer_run(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_training_model_b_candidate_objective(uuid,uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_optimizer_ask_context(uuid,uuid),
    strategy_training.training_optimizer_tell_context(uuid,uuid)
TO tb2_training_optimizer;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('088_training_model_b_optimizer_runtime',
    encode(digest('auto_trade_v2_088_training_model_b_optimizer_runtime_v1','sha256'),'hex'),
    'Advance Model-B candidates through compile replay portfolio objective and TRAIN-only TELL')
ON CONFLICT (version) DO NOTHING;

COMMIT;
