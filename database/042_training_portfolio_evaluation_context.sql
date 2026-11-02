\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.training_portfolio_evaluation_context(
    p_task_id uuid,
    p_lease_token uuid
)
RETURNS TABLE (
    model_b_iteration_id uuid,
    exit_rule_version_id uuid,
    exit_rule_config jsonb,
    fee_model_version_id uuid,
    fee_model_config jsonb,
    slippage_model_version_id uuid,
    slippage_model_config jsonb,
    portfolio_rule_version_id uuid,
    portfolio_rule_config jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    iteration_record strategy_training.training_iterations%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    exit_id uuid;
    fee_id uuid;
    slippage_id uuid;
    portfolio_id uuid;
    exit_json jsonb;
    fee_json jsonb;
    slippage_json jsonb;
    portfolio_json jsonb;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'PORTFOLIO_EVALUATION'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'portfolio evaluation requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;

    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;
    SELECT * INTO STRICT experiment_record
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = iteration_record.experiment_id;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = experiment_record.dataset_version_id;
    IF task_record.experiment_id <> experiment_record.experiment_id
       OR iteration_record.state <> 'RUNNING'
       OR experiment_record.state <> 'RUNNING'
       OR experiment_record.experiment_mode <> 'EXIT_POLICY'
       OR dataset_record.status <> 'READY'
       OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'PORTFOLIO_EVALUATION v1 requires a running TRAIN EXIT_POLICY iteration'
            USING ERRCODE = '23514';
    END IF;

    SELECT binding.config_version_id, config.config_json
    INTO STRICT exit_id, exit_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'EXIT_RULES' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'EXIT_RULES';
    SELECT binding.config_version_id, config.config_json
    INTO STRICT fee_id, fee_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'FEE_MODEL' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'FEE_MODEL';
    SELECT binding.config_version_id, config.config_json
    INTO STRICT slippage_id, slippage_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'SLIPPAGE_MODEL' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'SLIPPAGE_MODEL';
    SELECT binding.config_version_id, config.config_json
    INTO STRICT portfolio_id, portfolio_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'PORTFOLIO_RULES' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'PORTFOLIO_RULES';

    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_exit_episode_inputs episode
        WHERE episode.model_b_iteration_id = iteration_record.iteration_id
    ) OR EXISTS (
        SELECT 1
        FROM strategy_training.training_exit_episode_inputs episode
        JOIN strategy_training.training_model_b_sample_map sample
          ON sample.model_b_sample_id = episode.model_b_sample_id
        WHERE episode.model_b_iteration_id = iteration_record.iteration_id
          AND (
              episode.status <> 'DECIDED'
              OR episode.exit_rule_version_id <> exit_id
              OR episode.fee_model_version_id <> fee_id
              OR episode.slippage_model_version_id <> slippage_id
              OR sample.sample_use <> 'MODEL_B_PROTOTYPE'
              OR sample.natural_source <> 'FIXED_BASELINE_MODEL_A'
          )
    ) THEN
        RAISE EXCEPTION 'portfolio evaluation requires all frozen model-B episodes to be decided'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY SELECT
        iteration_record.iteration_id,
        exit_id, exit_json,
        fee_id, fee_json,
        slippage_id, slippage_json,
        portfolio_id, portfolio_json;
END
$$;

ALTER FUNCTION strategy_training.training_portfolio_evaluation_context(
    uuid, uuid
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.training_portfolio_evaluation_context(
    uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.training_portfolio_evaluation_context(
    uuid, uuid
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '042_training_portfolio_evaluation_context',
    encode(digest('auto_trade_v2_042_training_portfolio_evaluation_context_v1', 'sha256'), 'hex'),
    'Bind complete TRAIN model-B replay evidence to an active evaluator portfolio task'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
