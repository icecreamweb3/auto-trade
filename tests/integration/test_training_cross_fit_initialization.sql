\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE initialization_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '099_training_cross_fit_initialization'
          AND success
    ) THEN
        RAISE EXCEPTION 'migration 099 was not recorded';
    END IF;
    IF to_regclass(
        'strategy_training.training_cross_fit_initializations'
    ) IS NULL THEN
        RAISE EXCEPTION 'Cross-fit initialization audit table is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid =
          'strategy_training.training_cross_fit_initializations'::regclass
          AND tgname =
              'trg_training_cross_fit_initializations_append_only'
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'Cross-fit initialization facts are not append-only';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.initialize_training_cross_fit_from_discovery(uuid,jsonb,uuid)'
        ::regprocedure
    ) INTO initialization_source;

    IF position('assert_active_training_role' IN initialization_source) = 0
       OR position('TRAINING_ADMIN' IN initialization_source) = 0
       OR position('training_iteration_evidence_l0' IN initialization_source) = 0
       OR position('hard_gate_passed' IN initialization_source) = 0
       OR position('training_data_quality_reports' IN initialization_source) = 0
       OR position('report.status <> ''PASS''' IN initialization_source) = 0
       OR position('source_revision_watermark' IN initialization_source) = 0
       OR position('coverage_hash' IN initialization_source) = 0 THEN
        RAISE EXCEPTION 'initialization source/data evidence gates are incomplete';
    END IF;
    IF position('CROSS_FIT_PROTOCOL' IN initialization_source) = 0
       OR position('MODEL_B_SAMPLE_MIX' IN initialization_source) = 0
       OR position('MODEL_B_SEARCH_SPACE' IN initialization_source) = 0
       OR position('SCORING_MODEL_B' IN initialization_source) = 0
       OR position('p_added_config_version_ids' IN initialization_source) = 0
       OR position('jsonb_each_text' IN initialization_source) = 0
       OR position('Q-019' IN initialization_source) = 0
       OR position('Q-029' IN initialization_source) = 0
       OR position('Q-030' IN initialization_source) = 0
       OR position('Q-036' IN initialization_source) = 0
       OR position('Q-039' IN initialization_source) = 0
       OR position('bound_count <> 1' IN initialization_source) = 0 THEN
        RAISE EXCEPTION 'initialization frozen-config gates are incomplete';
    END IF;
    IF position('create_training_experiment' IN initialization_source) = 0
       OR position('transition_training_experiment' IN initialization_source) = 0
       OR position('create_cross_fit_execution' IN initialization_source) = 0
       OR position('training_cross_fit_initializations' IN initialization_source) = 0
       OR position('initialization_evidence_hash' IN initialization_source) = 0 THEN
        RAISE EXCEPTION 'initialization lifecycle or audit evidence is incomplete';
    END IF;

    IF NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.initialize_training_cross_fit_from_discovery(uuid,jsonb,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'training administrator role cannot initialize Cross-fit';
    END IF;
    IF has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.initialize_training_cross_fit_from_discovery(uuid,jsonb,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.initialize_training_cross_fit_from_discovery(uuid,jsonb,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.initialize_training_cross_fit_from_discovery(uuid,jsonb,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'runtime services can bypass administrator initialization';
    END IF;
END
$$;

ROLLBACK;
