\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE govern_source text; wrapper_source text; finalizer_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '098_training_model_b_formal_search_stopping'
          AND success
    ) THEN
        RAISE EXCEPTION 'migration 098 was not recorded';
    END IF;
    IF to_regclass(
        'strategy_training.training_model_b_formal_search_stop_facts'
    ) IS NULL THEN
        RAISE EXCEPTION 'formal stop facts are missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid =
          'strategy_training.training_model_b_formal_search_stop_facts'::regclass
          AND tgname =
              'trg_training_model_b_formal_search_stop_facts_append_only'
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'formal stop facts are not append-only';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.govern_training_model_b_formal_search_pair(uuid)'
        ::regprocedure
    ) INTO govern_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_model_b_optimizer_run(uuid)'
        ::regprocedure
    ) INTO wrapper_source;
    SELECT pg_get_functiondef(
        'strategy_training.finalize_training_model_b_formal_search(uuid,uuid)'
        ::regprocedure
    ) INTO finalizer_source;

    IF position('maximum_wall_clock_seconds' IN govern_source) = 0
       OR position('early_stopping_not_before_iteration' IN govern_source) = 0
       OR position('consecutive_train_no_improvement_rounds' IN govern_source) = 0
       OR position('WAITING_FORMAL_PEER_ROUND' IN govern_source) = 0
       OR position('tpe_count <> random_count' IN govern_source) = 0
       OR position('trial_state = ''COMPLETE''' IN govern_source) = 0
       OR position('observed_no_improvement >= no_improvement_limit'
                   IN govern_source) = 0
       OR position('training_model_b_formal_search_stop_facts'
                   IN govern_source) = 0 THEN
        RAISE EXCEPTION 'paired Q-019 stop governance is incomplete';
    END IF;
    IF position('govern_training_model_b_formal_search_pair' IN wrapper_source) = 0
       OR position('advance_training_model_b_optimizer_run_unbudgeted'
                   IN wrapper_source) = 0 THEN
        RAISE EXCEPTION 'Model-B optimizer does not pass the formal budget gate';
    END IF;
    IF position('stop_record.effective_trial_count' IN finalizer_source) = 0
       OR position('formal_stop_evidence_hash' IN finalizer_source) = 0
       OR position('effective_paired_trial_budget' IN finalizer_source) = 0
       OR position('tpe_record.trial_budget' IN finalizer_source) = 0 THEN
        RAISE EXCEPTION 'formal comparison ignores the governed effective budget';
    END IF;
    IF has_table_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_model_b_formal_search_stop_facts',
        'INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.govern_training_model_b_formal_search_pair(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'optimizer can bypass formal stopping governance';
    END IF;
END
$$;

ROLLBACK;
