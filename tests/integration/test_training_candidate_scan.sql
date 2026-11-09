\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '048_training_model_a_candidate_scan' AND success
    ) THEN
        RAISE EXCEPTION 'candidate scan migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '049_training_random_baseline_strata' AND success
    ) THEN
        RAISE EXCEPTION 'random-baseline strata migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '050_training_random_baseline_outcomes' AND success
    ) THEN
        RAISE EXCEPTION 'random-baseline outcome migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '051_training_model_a_discovery_l0' AND success
    ) THEN
        RAISE EXCEPTION 'model-A Discovery L0 migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '060_training_fixed_baseline_execution' AND success
    ) THEN
        RAISE EXCEPTION 'fixed-baseline execution migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '061_training_candidate_scan_static_pruning' AND success
    ) THEN
        RAISE EXCEPTION 'candidate scan static-pruning migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '062_training_candidate_scan_market_permissions' AND success
    ) THEN
        RAISE EXCEPTION 'candidate scan market-permissions migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '063_training_candidate_scan_result_types' AND success
    ) THEN
        RAISE EXCEPTION 'candidate scan result-types migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '064_training_candidate_entry_source' AND success
    ) THEN
        RAISE EXCEPTION 'candidate entry-source migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '065_training_outcome_bars_static_pruning' AND success
    ) THEN
        RAISE EXCEPTION 'outcome-bars static-pruning migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '069_training_random_baseline_reference_rebuild' AND success
    ) THEN
        RAISE EXCEPTION 'random-baseline reference-rebuild migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '071_training_random_candidate_outcome_context' AND success
    ) THEN
        RAISE EXCEPTION 'random-candidate outcome-context migration was not recorded successfully';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_context(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_bars(uuid,uuid,bigint)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.freeze_training_iteration_entry_batch(uuid,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_random_config(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_random_context(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_entry_source(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_model_a_candidate_scan_entry_source(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_training_candidate_random_baseline(uuid,uuid,uuid,uuid,bigint,timestamp with time zone,text,uuid,uuid,numeric,numeric,text,text,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,jsonb)',
        'EXECUTE'
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.klines', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.kline_ema_indicators', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.open_interest_observations', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'core.instrument_rule_versions', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_owner', 'market.klines', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_owner', 'market.kline_ema_indicators', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_owner', 'market.open_interest_observations', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_owner', 'core.instrument_rule_versions', 'SELECT'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.finalize_training_model_a_discovery_l0(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.finalize_training_model_a_discovery_l0(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.advance_training_model_a_l0_tasks()',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.advance_training_fixed_baselines()',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.advance_training_fixed_baselines()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'candidate scan least-privilege boundary is incorrect';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.training_model_a_candidate_scan_context(uuid,uuid)'::regprocedure
        ),
        '''FIXED_BASELINE'''
    ) = 0 OR strpos(
        pg_get_functiondef(
            'strategy_training.freeze_training_iteration_entry_batch(uuid,character)'::regprocedure
        ),
        '''FIXED_BASELINE'''
    ) = 0 THEN
        RAISE EXCEPTION 'fixed baseline is absent from the governed scan/batch contracts';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.training_model_a_candidate_scan_benchmark_bars(uuid,uuid)'::regprocedure
        ),
        'RETURN QUERY EXECUTE format'
    ) = 0 OR strpos(
        pg_get_functiondef(
            'strategy_training.training_model_a_candidate_scan_bars(uuid,uuid,bigint)'::regprocedure
        ),
        'RETURN QUERY EXECUTE format'
    ) = 0 THEN
        RAISE EXCEPTION 'candidate scan market reads do not use static chunk pruning';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.training_entry_outcome_bars(character)'::regprocedure
        ),
        'RETURN QUERY EXECUTE format'
    ) = 0 OR strpos(
        pg_get_functiondef(
            'strategy_training.training_random_candidate_outcome_bars(uuid,uuid,character,character)'::regprocedure
        ),
        'RETURN QUERY EXECUTE format'
    ) = 0 THEN
        RAISE EXCEPTION 'model-A outcome reads do not use static chunk pruning';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.training_model_a_candidate_scan_bars(uuid,uuid,bigint)'::regprocedure
        ),
        'rules.price_precision::integer'
    ) = 0 THEN
        RAISE EXCEPTION 'candidate scan result types do not match the function contract';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.create_training_candidate_entry_event(uuid,uuid,character,uuid,uuid,bigint,text,timestamp with time zone,timestamp with time zone,text,numeric,numeric,numeric,numeric,uuid,uuid,uuid,uuid,character)'::regprocedure
        ),
        'strategy_training.training_model_a_candidate_scan_entry_source'
    ) = 0 OR strpos(
        pg_get_functiondef(
            'strategy_training.create_training_candidate_entry_event(uuid,uuid,character,uuid,uuid,bigint,text,timestamp with time zone,timestamp with time zone,text,numeric,numeric,numeric,numeric,uuid,uuid,uuid,uuid,character)'::regprocedure
        ),
        'MODEL_B_PROTOTYPE'
    ) = 0 THEN
        RAISE EXCEPTION 'candidate entry source/use is not derived from its lease-bound iteration';
    END IF;
    IF strpos(
        pg_get_functiondef(
            'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)'::regprocedure
        ),
        'training_random_baseline_reference_support'
    ) = 0 OR strpos(
        pg_get_functiondef(
            'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)'::regprocedure
        ),
        'training_random_baseline_candidate_frame'
    ) <> 0 THEN
        RAISE EXCEPTION 'random candidate outcome context does not use direct frozen-reference membership';
    END IF;
END
$$;

ROLLBACK;
