\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE context_source text;
DECLARE gate_source text;
DECLARE fold_guard_source text;
DECLARE fold_finalize_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '077_training_cross_fit_runtime_guards'
    ) THEN
        RAISE EXCEPTION '077 Cross-fit runtime guards migration is missing';
    END IF;
    IF to_regclass(
        'strategy_training.training_cross_fit_optimizer_scopes'
    ) IS NULL THEN
        RAISE EXCEPTION 'Cross-fit optimizer scope facts are missing';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.training_model_a_candidate_scan_context(uuid,uuid)'::regprocedure
    ) INTO context_source;
    IF position('effective_train_start_at' IN context_source) = 0
       OR position('effective_train_end_at' IN context_source) = 0
       OR position('candidate scan context is not READY or Cross-fit scoped' IN context_source) = 0 THEN
        RAISE EXCEPTION 'candidate scan does not fail closed on its fold scope';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.record_cross_fit_go_no_go(uuid,uuid,uuid,uuid,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,integer,integer)'::regprocedure
    ) INTO gate_source;
    IF position('minimum_point_estimate_percentage_points' IN gate_source) = 0
       OR position('minimum_ci_lower_bound_percentage_points' IN gate_source) = 0
       OR position('INTERSECTION_UNION_BOTH_MUST_PASS' IN gate_source) = 0
       OR position('p_model_b_stressed_ci_lower_bound > 0' IN gate_source) = 0 THEN
        RAISE EXCEPTION 'Q-036 does not enforce locked Model-A and Model-B gates';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.guard_cross_fit_fold_runtime_scope()'::regprocedure
    ) INTO fold_guard_source;
    SELECT pg_get_functiondef(
        'strategy_training.finalize_cross_fit_fold(uuid,uuid)'::regprocedure
    ) INTO fold_finalize_source;
    IF position('wall_clock_budget_seconds' IN fold_guard_source) = 0
       OR position('repeat_count' IN fold_guard_source) = 0 THEN
        RAISE EXCEPTION 'completed fold is not bound to runtime limits';
    END IF;
    IF position('minimum_fitting_samples_per_fold' IN fold_finalize_source) = 0
       OR position('fitting_sample_qualified' IN fold_finalize_source) = 0 THEN
        RAISE EXCEPTION 'fold fitting power is not recorded from the locked protocol';
    END IF;

    IF has_table_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_cross_fit_optimizer_scopes',
        'INSERT'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.register_cross_fit_optimizer_scope(uuid,uuid,integer,uuid,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,timestamp with time zone)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit scope bypasses its lease-bound procedure';
    END IF;
END
$$;

ROLLBACK;
