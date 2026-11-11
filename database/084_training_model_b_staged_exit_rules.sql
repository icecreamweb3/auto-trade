\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER FUNCTION strategy_training.guard_training_model_b_config_ready()
RENAME TO guard_training_model_b_config_ready_v1;

DROP TRIGGER trg_training_model_b_config_ready_guard
ON strategy_training.training_config_versions;

DROP TRIGGER trg_training_model_a_config_ready_guard
ON strategy_training.training_config_versions;

CREATE TRIGGER trg_training_model_a_config_ready_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW
WHEN (NEW.config_type <> 'EXIT_RULES')
EXECUTE FUNCTION strategy_training.guard_training_model_a_config_ready();

CREATE OR REPLACE FUNCTION strategy_training.guard_training_model_b_config_ready()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    parameter_names text[];
    partial_triggers numeric[];
    partial_fractions numeric[];
    stop_triggers numeric[];
    locked_profits numeric[];
BEGIN
    IF NEW.status <> 'READY'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'READY')
       OR NEW.config_type NOT IN ('MODEL_B_SEARCH_SPACE', 'EXIT_RULES') THEN
        RETURN NEW;
    END IF;

    IF NEW.config_type = 'MODEL_B_SEARCH_SPACE' THEN
        IF NEW.schema_version <> 2
           OR NEW.config_json ->> 'model_family' <> 'RULE_BASED_EXIT_V2'
           OR NEW.config_json ->> 'interval_seconds' <> '300'
           OR NEW.config_json ->> 'hard_max_holding_seconds' <> '86400'
           OR jsonb_typeof(NEW.config_json -> 'policy_templates') IS DISTINCT FROM 'object'
           OR jsonb_typeof(NEW.config_json -> 'parameters') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE requires RULE_BASED_EXIT_V2'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_json -> 'policy_templates' IS DISTINCT FROM
           '{"FOUR_STAGE_SCALED_REMAINING_V1":{"base_partial_trigger_profit_percents":[10.0,15.0,25.0,35.0],"base_stop_locked_profit_percents":[1.0,5.0,15.0,25.0],"base_high_water_trailing_activation_percent":25.0,"base_high_water_max_drawdown_percent":10.0,"minimum_remaining_fraction":0.30}}'::jsonb THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE V2 template is not approved'
                USING ERRCODE = '23514';
        END IF;
        SELECT array_agg(key ORDER BY key) INTO parameter_names
        FROM jsonb_object_keys(NEW.config_json -> 'parameters') AS parameter(key);
        IF parameter_names IS DISTINCT FROM ARRAY[
            'exit_policy_template', 'initial_stop_loss_percent', 'max_holding_seconds',
            'shared_close_fraction', 'trigger_scale'
        ]::text[] THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE V2 parameters are not governed'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_json #>> '{parameters,max_holding_seconds,kind}' <> 'categorical'
           OR NEW.config_json #>> '{parameters,exit_policy_template,kind}' <> 'categorical'
           OR NEW.config_json #>> '{parameters,initial_stop_loss_percent,kind}' <> 'numeric'
           OR NEW.config_json #>> '{parameters,trigger_scale,kind}' <> 'numeric'
           OR NEW.config_json #>> '{parameters,shared_close_fraction,kind}' <> 'numeric'
           OR jsonb_typeof(NEW.config_json #> '{parameters,max_holding_seconds,choices}')
              IS DISTINCT FROM 'array'
           OR jsonb_typeof(NEW.config_json #> '{parameters,exit_policy_template,choices}')
              IS DISTINCT FROM 'array'
           OR jsonb_typeof(NEW.config_json #> '{parameters,initial_stop_loss_percent,minimum}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{parameters,initial_stop_loss_percent,maximum}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{parameters,trigger_scale,minimum}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{parameters,trigger_scale,maximum}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{parameters,shared_close_fraction,minimum}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{parameters,shared_close_fraction,maximum}')
              IS DISTINCT FROM 'number'
           OR NEW.config_json #> '{parameters,initial_stop_loss_percent,integer}'
              IS DISTINCT FROM 'false'::jsonb
           OR NEW.config_json #> '{parameters,trigger_scale,integer}'
              IS DISTINCT FROM 'false'::jsonb
           OR NEW.config_json #> '{parameters,shared_close_fraction,integer}'
              IS DISTINCT FROM 'false'::jsonb
           OR (NEW.config_json #>> '{parameters,initial_stop_loss_percent,minimum}')::numeric <> 2
           OR (NEW.config_json #>> '{parameters,initial_stop_loss_percent,maximum}')::numeric <> 10
           OR (NEW.config_json #>> '{parameters,trigger_scale,minimum}')::numeric <> 0.8
           OR (NEW.config_json #>> '{parameters,trigger_scale,maximum}')::numeric <> 1.2
           OR (NEW.config_json #>> '{parameters,shared_close_fraction,minimum}')::numeric <> 0.10
           OR (NEW.config_json #>> '{parameters,shared_close_fraction,maximum}')::numeric <> 0.30
           OR NEW.config_json #> '{parameters,max_holding_seconds,choices}'
              IS DISTINCT FROM '[21600,43200,64800,86400]'::jsonb
           OR NEW.config_json #> '{parameters,exit_policy_template,choices}'
              IS DISTINCT FROM '["FOUR_STAGE_SCALED_REMAINING_V1"]'::jsonb
           OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(
                    NEW.config_json #> '{parameters,max_holding_seconds,choices}'
                ) choice(value)
                WHERE choice.value::numeric <= 0 OR choice.value::numeric > 86400
                   OR choice.value::numeric % 300 <> 0
           )
           OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(
                    NEW.config_json #> '{parameters,exit_policy_template,choices}'
                ) choice(value)
                WHERE NOT (NEW.config_json -> 'policy_templates' ? choice.value)
           ) THEN
            RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE V2 search boundaries are invalid'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT array_agg(key ORDER BY key) INTO parameter_names
        FROM jsonb_object_keys(NEW.config_json) AS field(key);
        IF parameter_names IS DISTINCT FROM ARRAY[
            'initial_stop_loss_percent', 'intrabar_conflict_policy',
            'max_holding_seconds', 'model_family', 'partial_take_profit',
            'return_basis', 'rule_activation_timing', 'stop_schedule'
        ]::text[] THEN
            RAISE EXCEPTION 'EXIT_RULES V2 fields do not match the governed contract'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.schema_version <> 2
           OR NEW.config_json ->> 'model_family' <> 'RULE_BASED_EXIT_V2'
           OR NEW.config_json ->> 'return_basis' <> 'ENTRY_FILL_PRICE_PERCENT'
           OR NEW.config_json ->> 'rule_activation_timing' <> 'NEXT_BAR'
           OR NEW.config_json ->> 'intrabar_conflict_policy' <> 'WORST_CASE'
           OR jsonb_typeof(NEW.config_json -> 'initial_stop_loss_percent')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json -> 'max_holding_seconds')
              IS DISTINCT FROM 'number'
           OR (NEW.config_json ->> 'initial_stop_loss_percent')::numeric <= 0
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric <= 0
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric > 86400
           OR (NEW.config_json ->> 'max_holding_seconds')::numeric % 300 <> 0
           OR NEW.config_json #>> '{partial_take_profit,fraction_basis}'
              <> 'REMAINING_POSITION'
           OR jsonb_typeof(NEW.config_json #> '{partial_take_profit,levels}')
              IS DISTINCT FROM 'array'
           OR jsonb_typeof(NEW.config_json #> '{stop_schedule,levels}')
              IS DISTINCT FROM 'array'
           OR jsonb_array_length(NEW.config_json #> '{partial_take_profit,levels}') <> 4
           OR jsonb_array_length(NEW.config_json #> '{stop_schedule,levels}') <> 4
           OR jsonb_typeof(NEW.config_json #> '{stop_schedule,high_water_max_drawdown_percent}')
              IS DISTINCT FROM 'number'
           OR jsonb_typeof(NEW.config_json #> '{stop_schedule,high_water_trailing_activation_percent}')
              IS DISTINCT FROM 'number'
           OR (NEW.config_json #>> '{stop_schedule,high_water_max_drawdown_percent}')::numeric <= 0
           OR (NEW.config_json #>> '{stop_schedule,high_water_trailing_activation_percent}')::numeric
              <= (NEW.config_json #>> '{stop_schedule,high_water_max_drawdown_percent}')::numeric THEN
            RAISE EXCEPTION 'EXIT_RULES requires the governed staged V2 policy'
                USING ERRCODE = '23514';
        END IF;

        SELECT array_agg((level ->> 'trigger_profit_percent')::numeric ORDER BY ordinal),
               array_agg((level ->> 'close_fraction')::numeric ORDER BY ordinal)
        INTO partial_triggers, partial_fractions
        FROM jsonb_array_elements(NEW.config_json #> '{partial_take_profit,levels}')
             WITH ORDINALITY AS item(level, ordinal);
        SELECT array_agg((level ->> 'trigger_profit_percent')::numeric ORDER BY ordinal),
               array_agg((level ->> 'locked_profit_percent')::numeric ORDER BY ordinal)
        INTO stop_triggers, locked_profits
        FROM jsonb_array_elements(NEW.config_json #> '{stop_schedule,levels}')
             WITH ORDINALITY AS item(level, ordinal);
        IF EXISTS (
            SELECT 1 FROM generate_subscripts(partial_triggers, 1) index
            WHERE partial_triggers[index] <= 0
               OR partial_fractions[index] <= 0 OR partial_fractions[index] >= 1
               OR (index > 1 AND partial_triggers[index] <= partial_triggers[index - 1])
        ) OR EXISTS (
            SELECT 1 FROM generate_subscripts(stop_triggers, 1) index
            WHERE stop_triggers[index] <= 0 OR locked_profits[index] < 0
               OR locked_profits[index] >= stop_triggers[index]
               OR (index > 1 AND stop_triggers[index] <= stop_triggers[index - 1])
               OR (index > 1 AND locked_profits[index] < locked_profits[index - 1])
        ) THEN
            RAISE EXCEPTION 'EXIT_RULES V2 levels must be monotone and risk reducing'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_model_b_config_ready_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_model_b_config_ready();

CREATE TRIGGER trg_training_model_b_legacy_config_ready_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW
WHEN (NEW.config_type NOT IN ('MODEL_B_SEARCH_SPACE', 'EXIT_RULES'))
EXECUTE FUNCTION strategy_training.guard_training_model_b_config_ready_v1();

DO $$
DECLARE
    constraint_name text;
BEGIN
    SELECT conname INTO STRICT constraint_name
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_exit_decisions'::regclass
      AND contype = 'c'
      AND position('action' IN pg_get_constraintdef(oid)) > 0
      AND position('fill_price IS NOT NULL' IN pg_get_constraintdef(oid)) > 0;
    EXECUTE format(
        'ALTER TABLE strategy_training.training_exit_decisions DROP CONSTRAINT %I',
        constraint_name
    );
END
$$;

ALTER TABLE strategy_training.training_exit_decisions
ADD CONSTRAINT training_exit_decisions_fill_action_check CHECK (
    (action IN ('REDUCE', 'EXIT')) =
    (reference_price IS NOT NULL AND fill_price IS NOT NULL
     AND slippage_basis_points IS NOT NULL)
);

CREATE OR REPLACE FUNCTION strategy_training.guard_training_staged_exit_decision()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT NEW.position_state ?& ARRAY['direction', 'stop_before', 'stop_after']
       OR NEW.position_state ->> 'direction' NOT IN ('LONG', 'SHORT') THEN
        RAISE EXCEPTION 'exit decision position state is incomplete'
            USING ERRCODE = '23514';
    END IF;
    IF (NEW.position_state ->> 'direction' = 'LONG'
        AND (NEW.position_state ->> 'stop_after')::numeric
            < (NEW.position_state ->> 'stop_before')::numeric)
       OR (NEW.position_state ->> 'direction' = 'SHORT'
           AND (NEW.position_state ->> 'stop_after')::numeric
               > (NEW.position_state ->> 'stop_before')::numeric) THEN
        RAISE EXCEPTION 'exit decision cannot increase stop risk'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.action = 'REDUCE' AND (
        jsonb_typeof(NEW.position_state -> 'fills') IS DISTINCT FROM 'array'
        OR jsonb_array_length(NEW.position_state -> 'fills') = 0
        OR (NEW.position_state ->> 'remaining_quantity_after')::numeric <= 0
    ) THEN
        RAISE EXCEPTION 'REDUCE requires fills and a positive remaining quantity'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.action = 'EXIT'
       AND NEW.position_state ? 'remaining_quantity_after'
       AND (NEW.position_state ->> 'remaining_quantity_after')::numeric <> 0 THEN
        RAISE EXCEPTION 'V2 EXIT must close the remaining quantity'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_staged_exit_decision_guard
BEFORE INSERT ON strategy_training.training_exit_decisions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_staged_exit_decision();

ALTER FUNCTION strategy_training.guard_training_model_b_config_ready()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_staged_exit_decision()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.guard_training_model_b_config_ready() FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.guard_training_model_b_config_ready_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.guard_training_staged_exit_decision() FROM PUBLIC;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '084_training_model_b_staged_exit_rules',
    encode(digest('auto_trade_v2_084_training_model_b_staged_exit_rules_v1', 'sha256'), 'hex'),
    'Add governed staged partial-profit and next-bar stop rules for Model B'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
