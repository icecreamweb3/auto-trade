\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_evaluation_context(
    p_task_id uuid,
    p_lease_token uuid,
    p_entry_event_id char(64)
)
RETURNS TABLE (
    partition text,
    partition_start_at timestamptz,
    partition_end_at timestamptz,
    entry_time timestamptz,
    entry_price numeric,
    direction text,
    label_window_end_at timestamptz,
    interval_seconds integer,
    holding_rule_version_id uuid,
    opportunity_definition_version_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    entry_record strategy_training.training_entry_events%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    opportunity_version_id uuid;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'MODEL_A evaluation requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;

    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events entry
    WHERE entry.entry_event_id = p_entry_event_id;
    IF entry_record.status <> 'COMPLETE'
       OR task_record.iteration_id IS NULL
       OR entry_record.generating_iteration_id <> task_record.iteration_id THEN
        RAISE EXCEPTION 'entry event does not belong to the leased task iteration'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = entry_record.dataset_version_id;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'MODEL_A evaluation v1 requires a READY TRAIN dataset'
            USING ERRCODE = '23514';
    END IF;

    SELECT binding.config_version_id INTO STRICT opportunity_version_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'OPPORTUNITY_DEFINITION'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'OPPORTUNITY_DEFINITION'
     AND config.status = 'READY'
    WHERE iteration.iteration_id = entry_record.generating_iteration_id;

    RETURN QUERY SELECT
        dataset_record.partition::text,
        dataset_record.partition_start_at,
        dataset_record.partition_end_at,
        entry_record.entry_time,
        entry_record.entry_price,
        entry_record.direction::text,
        entry_record.entry_time + dataset_record.label_horizon_duration,
        dataset_record.interval_seconds,
        dataset_record.holding_rule_version_id,
        opportunity_version_id;
END
$$;

ALTER FUNCTION strategy_training.training_model_a_evaluation_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.training_model_a_evaluation_context(
    uuid, uuid, char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.training_model_a_evaluation_context(
    uuid, uuid, char(64)
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '039_training_model_a_evaluation_context',
    encode(digest('auto_trade_v2_039_training_model_a_evaluation_context_v1', 'sha256'), 'hex'),
    'Bind MODEL_A evaluation reads to the active evaluator lease and iteration'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
