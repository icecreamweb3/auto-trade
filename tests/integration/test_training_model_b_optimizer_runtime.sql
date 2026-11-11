\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE task_constraint text; replay_source text; portfolio_source text;
        ask_source text; tell_source text; advance_source text; objective_view text;
BEGIN
    IF to_regclass(
        'strategy_training.training_model_b_compiled_candidate_policies'
    ) IS NULL OR to_regclass(
        'strategy_training.training_model_b_iteration_objectives'
    ) IS NULL THEN
        RAISE EXCEPTION 'Model-B candidate runtime tables are missing';
    END IF;
    IF to_regprocedure(
        'strategy_training.training_model_b_candidate_preparation_context(uuid,uuid)'
    ) IS NULL OR to_regprocedure(
        'strategy_training.finalize_training_model_b_candidate_objective(uuid,uuid)'
    ) IS NULL OR to_regprocedure(
        'strategy_training.advance_training_model_b_optimizer_run(uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Model-B candidate runtime functions are missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO task_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_tasks'::regclass
      AND conname = 'training_tasks_task_type_check';
    IF position('MODEL_B_PREPARE_CANDIDATE' IN task_constraint) = 0 THEN
        RAISE EXCEPTION 'candidate preparation task is not governed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'strategy_training.training_model_b_sample_map'::regclass
          AND conname = 'training_model_b_sample_map_entry_event_id_sample_use_key'
    ) THEN
        RAISE EXCEPTION 'one entry must be replayable by multiple candidate iterations';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid =
              'strategy_training.training_model_b_compiled_candidate_policies'::regclass
          AND tgname = 'trg_training_model_b_compiled_candidate_policies_append_only'
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'compiled candidate policies are not append-only';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.training_model_b_replay_context(uuid,uuid,character)'::regprocedure
    ) INTO replay_source;
    SELECT pg_get_functiondef(
        'strategy_training.training_portfolio_evaluation_context(uuid,uuid)'::regprocedure
    ) INTO portfolio_source;
    IF position('training_effective_model_b_exit_config' IN replay_source) = 0
       OR position('training_effective_model_b_exit_config' IN portfolio_source) = 0
       OR position('GO_NO_GO' IN replay_source) = 0
       OR position('GO_NO_GO' IN portfolio_source) = 0 THEN
        RAISE EXCEPTION 'replay and portfolio do not share the candidate policy overlay';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.training_optimizer_ask_context(uuid,uuid)'::regprocedure
    ) INTO ask_source;
    SELECT pg_get_functiondef(
        'strategy_training.training_optimizer_tell_context(uuid,uuid)'::regprocedure
    ) INTO tell_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_model_b_optimizer_run(uuid)'::regprocedure
    ) INTO advance_source;
    IF position('MODEL_B_SEARCH_SPACE' IN ask_source) = 0
       OR position('MODEL_B_SEARCH_SPACE' IN tell_source) = 0
       OR position('MODEL_B_PREPARE_CANDIDATE' IN advance_source) = 0
       OR position('PORTFOLIO_EVALUATION' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'Model-B ASK/replay/portfolio/TELL chain is incomplete';
    END IF;
    SELECT pg_get_viewdef(
        'strategy_training.optimizer_train_objectives'::regclass, true
    ) INTO objective_view;
    IF position('training_model_b_iteration_objectives' IN objective_view) = 0 THEN
        RAISE EXCEPTION 'optimizer cannot read TRAIN-only Model-B objectives';
    END IF;
    IF has_table_privilege(
        'tb2_training_model_b',
        'strategy_training.training_model_b_compiled_candidate_policies',
        'SELECT'
    ) OR has_table_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_model_b_iteration_objectives',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'worker or optimizer can bypass controlled Model-B contexts';
    END IF;
END
$$;

ROLLBACK;
