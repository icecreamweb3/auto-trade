\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_config_versions
    DROP CONSTRAINT training_config_versions_config_type_check;

ALTER TABLE strategy_training.training_config_versions
    ADD CONSTRAINT training_config_versions_config_type_check CHECK (config_type IN (
        'FACTOR_REGISTRY', 'SEARCH_SPACE', 'MODEL_B_SEARCH_SPACE',
        'SCORING_MODEL_A', 'SCORING_MODEL_B', 'SCORING_END_TO_END',
        'TICKER_POOL_RULES', 'DATA_QUALITY_RULES', 'HOLDING_HORIZON_RULES',
        'ELIGIBLE_POOL_RULES', 'REPRODUCIBILITY_TOLERANCE', 'RESOURCE_LIMITS',
        'SLIPPAGE_MODEL', 'VISIBILITY_CUTOFF_POLICY', 'EXIT_RULES', 'FEE_MODEL',
        'PORTFOLIO_RULES', 'OPPORTUNITY_DEFINITION', 'RANDOM_BASELINE',
        'MODEL_B_SAMPLE_MIX', 'CROSS_FIT_PROTOCOL', 'VALIDATION_PROTOCOL',
        'RETENTION_POLICY'
    ));

CREATE OR REPLACE FUNCTION strategy_training.guard_training_model_b_config_ready()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    parameter_names text[];
    expected_parameter_names constant text[] := ARRAY[
        'max_holding_seconds', 'stop_loss_percent', 'take_profit_percent',
        'trailing_activation_percent', 'trailing_distance_percent'
    ];
BEGIN
    IF NEW.status <> 'READY'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'READY') THEN
        RETURN NEW;
    END IF;

    IF NEW.config_type = 'MODEL_B_SEARCH_SPACE' THEN
        IF NEW.config_json ->> 'model_family' <> 'RULE_BASED_EXIT_V1'
           OR jsonb_typeof(NEW.config_json -> 'interval_seconds') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'interval_seconds')::numeric <> 300
           OR jsonb_typeof(NEW.config_json -> 'hard_max_holding_seconds') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'hard_max_holding_seconds')::numeric <> 86400
           OR jsonb_typeof(NEW.config_json -> 'parameters') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE requires the governed 5m rule-based exit envelope'
                USING ERRCODE = '23514';
        END IF;
        SELECT array_agg(key ORDER BY key) INTO parameter_names
        FROM jsonb_object_keys(NEW.config_json -> 'parameters') AS parameter(key);
        IF parameter_names IS DISTINCT FROM expected_parameter_names THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE parameters do not match the governed exit parameters'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_json #>> '{parameters,max_holding_seconds,kind}' <> 'categorical'
           OR EXISTS (
                SELECT 1
                FROM unnest(ARRAY[
                    'stop_loss_percent', 'take_profit_percent',
                    'trailing_activation_percent', 'trailing_distance_percent'
                ]) AS parameter_name(name)
                WHERE NEW.config_json #>> ARRAY['parameters', parameter_name.name, 'kind']
                      <> 'numeric'
           ) THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE requires categorical holding and numeric exit rules'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_each(NEW.config_json -> 'parameters') AS parameter(name, rule)
            WHERE jsonb_typeof(rule) IS DISTINCT FROM 'object'
               OR rule ->> 'kind' NOT IN ('numeric', 'categorical')
               OR (
                    rule ->> 'kind' = 'numeric'
                    AND (
                        jsonb_typeof(rule -> 'minimum') IS DISTINCT FROM 'number'
                        OR jsonb_typeof(rule -> 'maximum') IS DISTINCT FROM 'number'
                        OR (rule ->> 'minimum')::numeric > (rule ->> 'maximum')::numeric
                        OR jsonb_typeof(rule -> 'integer') IS DISTINCT FROM 'boolean'
                    )
               )
               OR (
                    rule ->> 'kind' = 'categorical'
                    AND (
                        jsonb_typeof(rule -> 'choices') IS DISTINCT FROM 'array'
                        OR jsonb_array_length(rule -> 'choices') = 0
                    )
               )
        ) THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE contains an invalid parameter rule'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(
                NEW.config_json #> '{parameters,max_holding_seconds,choices}'
            ) AS choice(value)
            WHERE choice.value::numeric <= 0 OR choice.value::numeric > 86400
               OR choice.value::numeric % 300 <> 0
        ) THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE holding choices must be 5m aligned and at most 24h'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'EXIT_RULES' THEN
        IF jsonb_typeof(NEW.config_json -> 'max_holding_seconds') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric <= 0
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric > 86400
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric % 300 <> 0 THEN
            RAISE EXCEPTION 'EXIT_RULES max holding must be 5m aligned and at most 24h'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'SCORING_MODEL_B' THEN
        IF NEW.config_json ->> 'calculation_version' <> 'EXIT_NET_EXPECTANCY_V1'
           OR NEW.config_json ->> 'primary_metric' <> 'NET_EXPECTANCY_PERCENTAGE_POINTS'
           OR NEW.config_json ->> 'cluster_unit' <> 'UTC_DAY'
           OR NEW.config_json ->> 'bootstrap_method' <> 'BCA_CLUSTER_BOOTSTRAP'
           OR jsonb_typeof(NEW.config_json -> 'bootstrap_replicates') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'bootstrap_replicates')::numeric <= 0
           OR (NEW.config_json ->> 'bootstrap_replicates')::numeric % 1 <> 0
           OR jsonb_typeof(NEW.config_json -> 'confidence_level') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'confidence_level')::numeric <= 0
           OR (NEW.config_json ->> 'confidence_level')::numeric >= 1
           OR jsonb_typeof(NEW.config_json -> 'cost_stress_multipliers') IS DISTINCT FROM 'array'
           OR NOT (NEW.config_json -> 'cost_stress_multipliers' @> '[2.0]'::jsonb)
           OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements(
                    NEW.config_json -> 'cost_stress_multipliers'
                ) AS multiplier(value)
                WHERE jsonb_typeof(multiplier.value) IS DISTINCT FROM 'number'
                   OR (multiplier.value #>> '{}')::numeric < 1
           ) THEN
            RAISE EXCEPTION 'SCORING_MODEL_B requires governed net-expectancy and BCa cost-stress scoring'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'MODEL_B_SAMPLE_MIX' THEN
        IF NEW.config_json ->> 'natural_frequency_source' <> 'CROSS_FIT_MODEL_A'
           OR NEW.config_json ->> 'control_source' <> 'ADVERSE_OR_RANGE_CONTROL'
           OR NEW.config_json ->> 'oracle_source' <> 'ORACLE_ENTRY_BENCHMARK'
           OR jsonb_typeof(NEW.config_json -> 'natural_frequency_weight') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'natural_frequency_weight')::numeric <= 0
           OR jsonb_typeof(NEW.config_json -> 'control_weight') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'control_weight')::numeric < 0
           OR jsonb_typeof(NEW.config_json -> 'oracle_weight') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'oracle_weight')::numeric <> 0
           OR jsonb_typeof(NEW.config_json -> 'random_seed') IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'random_seed')::numeric % 1 <> 0 THEN
            RAISE EXCEPTION 'MODEL_B_SAMPLE_MIX violates the governed source and weight contract'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_model_b_config_ready_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_model_b_config_ready();

ALTER FUNCTION strategy_training.guard_training_model_b_config_ready()
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.guard_training_model_b_config_ready() FROM PUBLIC;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '083_training_model_b_config_contracts',
    encode(digest('auto_trade_v2_083_training_model_b_config_contracts_v1', 'sha256'), 'hex'),
    'Add governed Model-B search, scoring, sample-mix configuration contracts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
