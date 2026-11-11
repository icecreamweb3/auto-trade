\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE
    constraint_source text;
    guard_source text;
    legacy_guard_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '084_training_model_b_staged_exit_rules'
    ) THEN
        RAISE EXCEPTION '084 staged Model-B exit migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '085_training_model_b_search_ladder_parameters'
    ) THEN
        RAISE EXCEPTION '085 Model-B ladder search migration is missing';
    END IF;

    SELECT pg_get_constraintdef(oid)
    INTO STRICT constraint_source
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_config_versions'::regclass
      AND conname = 'training_config_versions_config_type_check';
    IF position('MODEL_B_SEARCH_SPACE' IN constraint_source) = 0 THEN
        RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE is absent from the database config contract';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.guard_training_model_b_config_ready()'::regprocedure
    ) INTO guard_source;
    IF position('RULE_BASED_EXIT_V2' IN guard_source) = 0
       OR position('hard_max_holding_seconds' IN guard_source) = 0
       OR position('shared_close_fraction' IN guard_source) = 0
       OR position('trigger_scale' IN guard_source) = 0
       OR position('REMAINING_POSITION' IN guard_source) = 0
       OR position('NEXT_BAR' IN guard_source) = 0 THEN
        RAISE EXCEPTION 'Model-B READY guard omits a governed V2 staged-exit boundary';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.guard_training_model_b_config_ready_v1()'::regprocedure
    ) INTO legacy_guard_source;
    IF position('BCA_CLUSTER_BOOTSTRAP' IN legacy_guard_source) = 0
       OR position('CROSS_FIT_MODEL_A' IN legacy_guard_source) = 0
       OR position('ORACLE_ENTRY_BENCHMARK' IN legacy_guard_source) = 0 THEN
        RAISE EXCEPTION 'legacy Model-B scoring/source guard was not preserved';
    END IF;

    IF has_function_privilege(
        'tb2_training_rw',
        'strategy_training.guard_training_model_b_config_ready()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'training worker can execute the Model-B READY trigger directly';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    '84000000-0000-0000-0000-000000000001',
    'model-b-v2@example.test', 'not-a-real-hash', 'model-b-v2', 'ADMIN'
);

DO $$
DECLARE
    config_id uuid;
    config jsonb := '{
      "model_family":"RULE_BASED_EXIT_V2",
      "interval_seconds":300,
      "hard_max_holding_seconds":86400,
      "policy_templates":{"FOUR_STAGE_SCALED_REMAINING_V1":{
        "base_partial_trigger_profit_percents":[10.0,15.0,25.0,35.0],
        "base_stop_locked_profit_percents":[1.0,5.0,15.0,25.0],
        "base_high_water_trailing_activation_percent":25.0,
        "base_high_water_max_drawdown_percent":10.0,
        "minimum_remaining_fraction":0.30
      }},
      "parameters":{
        "max_holding_seconds":{"kind":"categorical","choices":[21600,43200,64800,86400]},
        "initial_stop_loss_percent":{"kind":"numeric","minimum":2.0,"maximum":10.0,"integer":false},
        "exit_policy_template":{"kind":"categorical","choices":["FOUR_STAGE_SCALED_REMAINING_V1"]},
        "trigger_scale":{"kind":"numeric","minimum":0.8,"maximum":1.2,"integer":false},
        "shared_close_fraction":{"kind":"numeric","minimum":0.10,"maximum":0.30,"integer":false}
      }
    }'::jsonb;
BEGIN
    INSERT INTO strategy_training.training_config_versions (
        config_type, semver, schema_version, config_json, content_hash,
        created_by_user_id
    ) VALUES (
        'MODEL_B_SEARCH_SPACE', '84.1.0', 2, config,
        encode(digest(config::text, 'sha256'), 'hex'),
        '84000000-0000-0000-0000-000000000001'
    ) RETURNING config_version_id INTO config_id;
    UPDATE strategy_training.training_config_versions
    SET status = 'READY',
        ready_by_user_id = '84000000-0000-0000-0000-000000000001',
        ready_at = clock_timestamp()
    WHERE config_version_id = config_id;
END
$$;

DO $$
DECLARE
    config_id uuid;
    invalid_id uuid;
    config jsonb := '{
      "model_family":"RULE_BASED_EXIT_V2",
      "return_basis":"ENTRY_FILL_PRICE_PERCENT",
      "initial_stop_loss_percent":5.0,
      "partial_take_profit":{"fraction_basis":"REMAINING_POSITION","levels":[
        {"trigger_profit_percent":10.0,"close_fraction":0.20},
        {"trigger_profit_percent":15.0,"close_fraction":0.20},
        {"trigger_profit_percent":25.0,"close_fraction":0.20},
        {"trigger_profit_percent":35.0,"close_fraction":0.20}
      ]},
      "stop_schedule":{"levels":[
        {"trigger_profit_percent":10.0,"locked_profit_percent":1.0},
        {"trigger_profit_percent":15.0,"locked_profit_percent":5.0},
        {"trigger_profit_percent":25.0,"locked_profit_percent":15.0},
        {"trigger_profit_percent":35.0,"locked_profit_percent":25.0}
      ],"high_water_trailing_activation_percent":25.0,
         "high_water_max_drawdown_percent":10.0},
      "max_holding_seconds":86400,
      "intrabar_conflict_policy":"WORST_CASE",
      "rule_activation_timing":"NEXT_BAR"
    }'::jsonb;
BEGIN
    INSERT INTO strategy_training.training_config_versions (
        config_type, semver, schema_version, config_json, content_hash,
        created_by_user_id
    ) VALUES (
        'EXIT_RULES', '84.0.0', 2, config,
        encode(digest(config::text, 'sha256'), 'hex'),
        '84000000-0000-0000-0000-000000000001'
    ) RETURNING config_version_id INTO config_id;
    UPDATE strategy_training.training_config_versions
    SET status = 'READY',
        ready_by_user_id = '84000000-0000-0000-0000-000000000001',
        ready_at = clock_timestamp()
    WHERE config_version_id = config_id;

    BEGIN
        INSERT INTO strategy_training.training_config_versions (
            config_type, semver, schema_version, config_json, content_hash,
            created_by_user_id
        ) VALUES (
            'EXIT_RULES', '84.0.1', 1, config,
            encode(digest(config::text, 'sha256'), 'hex'),
            '84000000-0000-0000-0000-000000000001'
        ) RETURNING config_version_id INTO invalid_id;
        UPDATE strategy_training.training_config_versions
        SET status = 'READY',
            ready_by_user_id = '84000000-0000-0000-0000-000000000001',
            ready_at = clock_timestamp()
        WHERE config_version_id = invalid_id;
        RAISE EXCEPTION 'Schema 1 accepted a V2 EXIT_RULES config';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

ROLLBACK;
