\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.training_model_b_replay_context(
    p_task_id uuid,
    p_lease_token uuid,
    p_model_b_sample_id char(64)
)
RETURNS TABLE (
    model_b_sample_id char(64),
    entry_event_id char(64),
    exit_episode_id char(64),
    episode_status text,
    exit_rule_version_id uuid,
    exit_rule_config jsonb,
    fee_model_version_id uuid,
    fee_model_config jsonb,
    slippage_model_version_id uuid,
    slippage_model_config jsonb,
    notional numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    episode_record strategy_training.training_exit_episode_inputs%ROWTYPE;
    sample_record strategy_training.training_model_b_sample_map%ROWTYPE;
    exit_config jsonb;
    fee_config jsonb;
    slippage_config jsonb;
    portfolio_config jsonb;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'MODEL_B'
       OR task_record.task_type <> 'MODEL_B_REPLAY'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'MODEL_B replay requires its active model-B lease'
            USING ERRCODE = '40001';
    END IF;

    SELECT * INTO STRICT episode_record
    FROM strategy_training.training_exit_episode_inputs episode
    WHERE episode.model_b_sample_id = p_model_b_sample_id;
    SELECT * INTO STRICT sample_record
    FROM strategy_training.training_model_b_sample_map sample
    WHERE sample.model_b_sample_id = p_model_b_sample_id;
    IF task_record.iteration_id IS NULL
       OR episode_record.model_b_iteration_id <> task_record.iteration_id
       OR episode_record.status NOT IN ('RUNNING', 'DECIDED')
       OR sample_record.sample_use <> 'MODEL_B_PROTOTYPE'
       OR sample_record.natural_source <> 'FIXED_BASELINE_MODEL_A' THEN
        RAISE EXCEPTION 'model-B sample does not belong to the leased task iteration'
            USING ERRCODE = '23514';
    END IF;

    SELECT config.config_json INTO STRICT exit_config
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = episode_record.exit_rule_version_id
      AND config.config_type = 'EXIT_RULES' AND config.status = 'READY';
    SELECT config.config_json INTO STRICT fee_config
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = episode_record.fee_model_version_id
      AND config.config_type = 'FEE_MODEL' AND config.status = 'READY';
    SELECT config.config_json INTO STRICT slippage_config
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = episode_record.slippage_model_version_id
      AND config.config_type = 'SLIPPAGE_MODEL' AND config.status = 'READY';
    SELECT config.config_json INTO STRICT portfolio_config
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'PORTFOLIO_RULES'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'PORTFOLIO_RULES' AND config.status = 'READY'
    WHERE iteration.iteration_id = episode_record.model_b_iteration_id;

    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings exit_binding
          ON exit_binding.experiment_id = iteration.experiment_id
         AND exit_binding.config_type = 'EXIT_RULES'
         AND exit_binding.config_version_id = episode_record.exit_rule_version_id
        JOIN strategy_training.training_experiment_config_bindings fee_binding
          ON fee_binding.experiment_id = iteration.experiment_id
         AND fee_binding.config_type = 'FEE_MODEL'
         AND fee_binding.config_version_id = episode_record.fee_model_version_id
        JOIN strategy_training.training_experiment_config_bindings slip_binding
          ON slip_binding.experiment_id = iteration.experiment_id
         AND slip_binding.config_type = 'SLIPPAGE_MODEL'
         AND slip_binding.config_version_id = episode_record.slippage_model_version_id
        WHERE iteration.iteration_id = episode_record.model_b_iteration_id
          AND iteration.state = 'RUNNING'
    ) THEN
        RAISE EXCEPTION 'model-B replay configs are not frozen on the running iteration'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY SELECT
        episode_record.model_b_sample_id,
        sample_record.entry_event_id,
        episode_record.exit_episode_id,
        episode_record.status::text,
        episode_record.exit_rule_version_id,
        exit_config,
        episode_record.fee_model_version_id,
        fee_config,
        episode_record.slippage_model_version_id,
        slippage_config,
        (portfolio_config ->> 'notional_per_trade')::numeric;
END
$$;

ALTER FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) TO tb2_training_model_b;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '041_training_model_b_replay_context',
    encode(digest('auto_trade_v2_041_training_model_b_replay_context_v1', 'sha256'), 'hex'),
    'Bind MODEL_B replay inputs and frozen configs to the active model-B lease'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
