\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE source_constraint text; sample_constraint text; view_columns text[];
        corpus_view_definition text; create_run_definition text;
BEGIN
    IF to_regclass('strategy_training.training_model_b_formal_search_runs') IS NULL
       OR to_regclass('strategy_training.training_model_b_search_qualifications') IS NULL
       OR to_regclass('strategy_training.training_go_no_go_round_zero_baselines') IS NULL
       OR to_regclass('strategy_training.training_model_b_formal_search_selections') IS NULL
       OR to_regclass('strategy_training.training_non_reusable_iterations') IS NULL THEN
        RAISE EXCEPTION 'formal Model-B governed facts are missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO source_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_check';
    IF source_constraint IS NULL
       OR position('CROSS_FIT_MODEL_A_CANDIDATE' IN source_constraint) = 0 THEN
        RAISE EXCEPTION 'post-048 candidate Cross-fit source is not available';
    END IF;
    SELECT pg_get_viewdef('strategy_training.formal_model_b_cross_fit_entries'::regclass, true)
    INTO corpus_view_definition;
    IF position('underlying_source' IN corpus_view_definition) = 0
       OR position('promoted_source' IN corpus_view_definition) = 0
       OR position('CROSS_FIT_MODEL_A' IN corpus_view_definition) = 0 THEN
        RAISE EXCEPTION 'formal corpus view does not preserve candidate-to-formal lineage';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.create_model_b_formal_search_run(uuid,uuid,uuid,uuid,uuid)'::regprocedure
    ) INTO create_run_definition;
    IF position('formal_model_b_cross_fit_entries' IN create_run_definition) = 0
       OR position('promoted_source' IN create_run_definition) = 0
       OR position('underlying_source' IN create_run_definition) = 0 THEN
        RAISE EXCEPTION 'formal search does not consume the promoted corpus membership';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO sample_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_model_b_sample_map'::regclass
      AND conname = 'training_model_b_sample_map_sample_use_check';
    IF sample_constraint IS NULL OR position('MODEL_B_TRAIN' IN sample_constraint) = 0 THEN
        RAISE EXCEPTION 'formal Model-B sample use was not enabled';
    END IF;
    SELECT array_agg(column_name::text ORDER BY ordinal_position) INTO view_columns
    FROM information_schema.columns
    WHERE table_schema = 'strategy_training' AND table_name = 'model_b_formal_safe_inputs';
    IF view_columns && ARRAY['source', 'input_kind', 'label', 'outcome', 'future']::text[] THEN
        RAISE EXCEPTION 'formal safe input view exposes forbidden fields';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.create_model_b_formal_search_run(uuid,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) OR has_table_privilege(
        'tb2_training_model_b',
        'strategy_training.training_entry_events',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'formal Model-B privilege boundary is incorrect';
    END IF;
END
$$;

ROLLBACK;
