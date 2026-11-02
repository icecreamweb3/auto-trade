\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.guard_training_model_a_config_ready()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    expected_matching_fields constant text[] := ARRAY[
        'btc_regime', 'instrument_id', 'liquidity_bucket',
        'pool_identity', 'time_bucket', 'volatility_bucket'
    ];
    actual_matching_fields text[];
    factor_count integer;
    distinct_factor_count integer;
BEGIN
    IF NEW.status <> 'READY'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'READY') THEN
        RETURN NEW;
    END IF;

    IF NEW.config_type = 'FACTOR_REGISTRY' THEN
        IF jsonb_typeof(NEW.config_json -> 'adapter_version') IS DISTINCT FROM 'string'
           OR btrim(NEW.config_json ->> 'adapter_version') = ''
           OR jsonb_typeof(NEW.config_json -> 'factors') IS DISTINCT FROM 'array'
           OR jsonb_array_length(NEW.config_json -> 'factors') = 0 THEN
            RAISE EXCEPTION 'FACTOR_REGISTRY requires adapter_version and non-empty factors'
                USING ERRCODE = '23514';
        END IF;
        SELECT count(*), count(DISTINCT factor_name)
        INTO factor_count, distinct_factor_count
        FROM jsonb_array_elements(NEW.config_json -> 'factors') AS factor(value)
        CROSS JOIN LATERAL (
            SELECT CASE WHEN jsonb_typeof(factor.value) = 'string'
                        THEN btrim(factor.value #>> '{}') END AS factor_name
        ) normalized;
        IF factor_count <> distinct_factor_count OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(NEW.config_json -> 'factors') AS factor(value)
            WHERE jsonb_typeof(factor.value) IS DISTINCT FROM 'string'
               OR btrim(factor.value #>> '{}') = ''
        ) THEN
            RAISE EXCEPTION 'FACTOR_REGISTRY factors must be unique non-empty strings'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'SEARCH_SPACE' THEN
        IF jsonb_typeof(NEW.config_json -> 'interval_seconds') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'strategy_parameters') IS DISTINCT FROM 'object'
           OR NEW.config_json -> 'strategy_parameters' = '{}'::jsonb THEN
            RAISE EXCEPTION 'SEARCH_SPACE requires interval_seconds and strategy_parameters'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.config_json ->> 'interval_seconds')::numeric NOT IN (300, 900) THEN
            RAISE EXCEPTION 'model-A SEARCH_SPACE interval must be 300 or 900 seconds'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'OPPORTUNITY_DEFINITION' THEN
        IF jsonb_typeof(NEW.config_json -> 'minimum_mfe_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'maximum_mae_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'minimum_return_percent') IS DISTINCT FROM 'number' THEN
            RAISE EXCEPTION 'OPPORTUNITY_DEFINITION thresholds must be explicit numbers'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.config_json ->> 'minimum_mfe_percent')::numeric <= 0
           OR (NEW.config_json ->> 'maximum_mae_percent')::numeric < 0 THEN
            RAISE EXCEPTION 'OPPORTUNITY_DEFINITION threshold ranges are invalid'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'RANDOM_BASELINE' THEN
        IF jsonb_typeof(NEW.config_json -> 'sample_count') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'minimum_frame_size') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'exclusion_window_seconds') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'matching_fields') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'RANDOM_BASELINE requires explicit numeric limits and matching_fields'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.config_json ->> 'sample_count')::numeric <= 0
           OR (NEW.config_json ->> 'sample_count')::numeric % 1 <> 0
           OR (NEW.config_json ->> 'minimum_frame_size')::numeric <= 0
           OR (NEW.config_json ->> 'minimum_frame_size')::numeric % 1 <> 0
           OR (NEW.config_json ->> 'exclusion_window_seconds')::numeric < 0
           OR (NEW.config_json ->> 'exclusion_window_seconds')::numeric % 1 <> 0 THEN
            RAISE EXCEPTION 'RANDOM_BASELINE limits must be non-negative integer seconds/counts'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(NEW.config_json -> 'matching_fields') field(value)
            WHERE jsonb_typeof(field.value) IS DISTINCT FROM 'string'
        ) THEN
            RAISE EXCEPTION 'RANDOM_BASELINE matching_fields must be strings'
                USING ERRCODE = '23514';
        END IF;
        SELECT array_agg(field_name ORDER BY field_name)
        INTO actual_matching_fields
        FROM jsonb_array_elements_text(NEW.config_json -> 'matching_fields') field(field_name);
        IF actual_matching_fields IS DISTINCT FROM expected_matching_fields
           OR cardinality(actual_matching_fields) <> cardinality(
               ARRAY(SELECT DISTINCT unnest(actual_matching_fields))
           ) THEN
            RAISE EXCEPTION 'RANDOM_BASELINE matching_fields must equal the governed strata'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'EXIT_RULES' THEN
        IF jsonb_typeof(NEW.config_json -> 'stop_loss_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'take_profit_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'trailing_activation_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'trailing_distance_percent') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'max_holding_seconds') IS DISTINCT FROM 'number'
           OR NEW.config_json ->> 'intrabar_conflict_policy' <> 'WORST_CASE' THEN
            RAISE EXCEPTION 'EXIT_RULES requires explicit prototype boundaries'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.config_json ->> 'stop_loss_percent')::numeric <= 0
           OR (NEW.config_json ->> 'take_profit_percent')::numeric <= 0
           OR (NEW.config_json ->> 'trailing_activation_percent')::numeric < 0
           OR (NEW.config_json ->> 'trailing_distance_percent')::numeric < 0
           OR ((NEW.config_json ->> 'trailing_activation_percent')::numeric = 0)
              <> ((NEW.config_json ->> 'trailing_distance_percent')::numeric = 0)
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric <= 0
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric % 60 <> 0 THEN
            RAISE EXCEPTION 'EXIT_RULES values violate fixed-exit risk boundaries'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.config_type = 'PORTFOLIO_RULES' THEN
        IF jsonb_typeof(NEW.config_json -> 'initial_capital') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'notional_per_trade') IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'maximum_concurrent_positions') IS DISTINCT FROM 'number'
           OR NEW.config_json ->> 'same_ticker_position_policy' <> 'ONE_OPEN_POSITION' THEN
            RAISE EXCEPTION 'PORTFOLIO_RULES requires explicit capital and concurrency limits'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.config_json ->> 'initial_capital')::numeric <= 0
           OR (NEW.config_json ->> 'notional_per_trade')::numeric <= 0
           OR (NEW.config_json ->> 'maximum_concurrent_positions')::numeric <= 0
           OR (NEW.config_json ->> 'maximum_concurrent_positions')::numeric % 1 <> 0 THEN
            RAISE EXCEPTION 'PORTFOLIO_RULES values are invalid'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_model_a_config_ready_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_model_a_config_ready();

ALTER FUNCTION strategy_training.guard_training_model_a_config_ready()
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.guard_training_model_a_config_ready() FROM PUBLIC;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '028_training_model_a_config_contracts',
    encode(digest('auto_trade_v2_028_training_model_a_config_contracts_v1', 'sha256'), 'hex'),
    'Validate frozen model-A feature, scan, opportunity, and random-baseline config contracts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
