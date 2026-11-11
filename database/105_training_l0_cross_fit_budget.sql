\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Cross-fit iterations store optimizer_run_id/trial_number in resource_budget;
-- the governed wall-clock limit lives in the immutable optimizer scope.  Keep
-- the legacy explicit iteration budget for non-Cross-fit L0 runs, but derive a
-- Cross-fit task's remaining time from the optimizer start and frozen scope.
CREATE OR REPLACE FUNCTION strategy_training.configure_training_l0_statement_timeout(
    p_task_id uuid,
    p_lease_token uuid
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $function$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    resource_budget_value jsonb;
    iteration_experiment_id uuid;
    optimizer_run_id_value uuid;
    budget_seconds integer;
    budget_started_at timestamptz;
    elapsed_seconds numeric;
    remaining_milliseconds integer;
BEGIN
    task_record := strategy_training.assert_training_model_a_l0_lease(
        p_task_id, p_lease_token
    );

    SELECT iteration.resource_budget, iteration.experiment_id
    INTO STRICT resource_budget_value, iteration_experiment_id
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;

    budget_seconds := (
        resource_budget_value ->> 'maximum_wall_clock_seconds'
    )::integer;
    IF budget_seconds IS NOT NULL THEN
        budget_started_at := task_record.started_at;
    ELSE
        optimizer_run_id_value := (
            resource_budget_value ->> 'optimizer_run_id'
        )::uuid;
        SELECT scope.wall_clock_budget_seconds, optimizer.started_at
        INTO budget_seconds, budget_started_at
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        JOIN strategy_training.training_optimizer_runs optimizer
          ON optimizer.optimizer_run_id = scope.optimizer_run_id
        WHERE scope.optimizer_run_id = optimizer_run_id_value
          AND optimizer.experiment_id = iteration_experiment_id
          AND optimizer.state IN ('RUNNING', 'PAUSED');
    END IF;

    IF budget_seconds IS NULL OR budget_seconds <= 0
       OR budget_started_at IS NULL THEN
        RAISE EXCEPTION 'model-A L0 wall-clock budget must be positive'
            USING ERRCODE = '22023';
    END IF;

    elapsed_seconds := extract(epoch FROM clock_timestamp() - budget_started_at);
    remaining_milliseconds := floor(
        (budget_seconds - elapsed_seconds) * 1000
    )::integer;
    IF remaining_milliseconds <= 0 THEN
        RAISE EXCEPTION 'model-A L0 wall-clock budget exhausted'
            USING ERRCODE = '57014';
    END IF;

    PERFORM set_config(
        'statement_timeout', remaining_milliseconds::text, true
    );
    RAISE LOG 'training_l0_progress task_id=% iteration_id=% stage=% budget_seconds=% budget_started_at=% elapsed_seconds=% remaining_milliseconds=%',
        task_record.task_id,
        task_record.iteration_id,
        'TIMEOUT_CONFIGURED',
        budget_seconds,
        budget_started_at,
        round(elapsed_seconds, 3),
        remaining_milliseconds;
    RETURN ceil(remaining_milliseconds::numeric / 1000)::integer;
END
$function$;

ALTER FUNCTION strategy_training.configure_training_l0_statement_timeout(
    uuid, uuid
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.configure_training_l0_statement_timeout(uuid, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.configure_training_l0_statement_timeout(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '105_training_l0_cross_fit_budget',
    encode(public.digest(
        'auto_trade_v2_105_training_l0_cross_fit_budget_v1',
        'sha256'
    ), 'hex'),
    'Use frozen optimizer scope wall clock for Cross-fit Model-A L0 tasks'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
