\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_model_b_sample_map (
    model_b_sample_id      char(64) PRIMARY KEY,
    entry_event_id         char(64) NOT NULL
                           REFERENCES strategy_training.training_entry_events,
    sample_use             varchar(24) NOT NULL
                           CHECK (sample_use IN ('MODEL_B_PROTOTYPE')),
    natural_source         varchar(48) NOT NULL,
    mapping_hash           char(64) NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (model_b_sample_id ~ '^[0-9a-f]{64}$'),
    CHECK (mapping_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (entry_event_id, sample_use)
);

CREATE TABLE strategy_training.training_exit_episode_inputs (
    exit_episode_id                 char(64) PRIMARY KEY,
    model_b_sample_id               char(64) NOT NULL
                                    REFERENCES strategy_training.training_model_b_sample_map,
    model_b_iteration_id            uuid NOT NULL
                                    REFERENCES strategy_training.training_iterations,
    dataset_version_id              uuid NOT NULL
                                    REFERENCES strategy_training.training_dataset_versions,
    instrument_id                   bigint NOT NULL REFERENCES core.instruments,
    symbol                          text NOT NULL,
    direction                       varchar(8) NOT NULL CHECK (direction IN ('LONG', 'SHORT')),
    entry_time                      timestamptz NOT NULL,
    entry_reference_price           numeric NOT NULL CHECK (entry_reference_price > 0),
    maximum_end_at                  timestamptz NOT NULL,
    interval_seconds                integer NOT NULL CHECK (interval_seconds > 0),
    exit_rule_version_id            uuid NOT NULL
                                    REFERENCES strategy_training.training_config_versions,
    fee_model_version_id            uuid NOT NULL
                                    REFERENCES strategy_training.training_config_versions,
    slippage_model_version_id       uuid NOT NULL
                                    REFERENCES strategy_training.training_config_versions,
    status                          varchar(16) NOT NULL DEFAULT 'RUNNING'
                                    CHECK (status IN ('RUNNING', 'DECIDED', 'INVALID')),
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at                      timestamptz,
    invalid_reason                  text,
    CHECK (exit_episode_id ~ '^[0-9a-f]{64}$'),
    CHECK (btrim(symbol) <> '' AND symbol = upper(symbol)),
    CHECK (maximum_end_at > entry_time),
    CHECK (
        (status = 'RUNNING' AND decided_at IS NULL AND invalid_reason IS NULL)
        OR (status = 'DECIDED' AND decided_at IS NOT NULL AND invalid_reason IS NULL)
        OR (status = 'INVALID' AND decided_at IS NOT NULL
                               AND invalid_reason IS NOT NULL
                               AND btrim(invalid_reason) <> '')
    ),
    UNIQUE (model_b_sample_id, model_b_iteration_id)
);

CREATE TABLE strategy_training.training_model_b_market_access_log (
    access_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exit_episode_id       char(64) NOT NULL
                          REFERENCES strategy_training.training_exit_episode_inputs,
    model_b_sample_id     char(64) NOT NULL,
    requested_as_of_at    timestamptz NOT NULL,
    returned_close_time   timestamptz NOT NULL,
    interval_seconds      integer NOT NULL,
    snapshot_hash         char(64) NOT NULL,
    accessed_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (returned_close_time <= requested_as_of_at),
    CHECK (snapshot_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_decision_feature_snapshots (
    decision_feature_snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exit_episode_id              char(64) NOT NULL
                                 REFERENCES strategy_training.training_exit_episode_inputs,
    model_b_sample_id            char(64) NOT NULL,
    decision_time                timestamptz NOT NULL,
    last_closed_bar_at           timestamptz NOT NULL,
    interval_seconds             integer NOT NULL,
    feature_json                 jsonb NOT NULL,
    source_payload_hash          char(64) NOT NULL,
    snapshot_hash                char(64) NOT NULL,
    created_at                   timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (last_closed_bar_at <= decision_time),
    CHECK (jsonb_typeof(feature_json) = 'object' AND feature_json <> '{}'::jsonb),
    CHECK (source_payload_hash ~ '^[0-9a-f]{64}$'),
    CHECK (snapshot_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (exit_episode_id, decision_time)
);

CREATE TABLE strategy_training.training_exit_decisions (
    exit_episode_id              char(64) NOT NULL
                                 REFERENCES strategy_training.training_exit_episode_inputs,
    sequence_no                 integer NOT NULL CHECK (sequence_no > 0),
    decision_time               timestamptz NOT NULL,
    decision_feature_snapshot_id uuid NOT NULL
                                 REFERENCES strategy_training.training_decision_feature_snapshots,
    action                      varchar(16) NOT NULL
                                CHECK (action IN ('HOLD', 'REDUCE', 'MOVE_STOP', 'EXIT')),
    reason_code                 text NOT NULL,
    position_state              jsonb NOT NULL,
    reference_price             numeric,
    fill_price                  numeric,
    slippage_basis_points       numeric,
    decision_hash               char(64) NOT NULL,
    created_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (exit_episode_id, sequence_no),
    CHECK (btrim(reason_code) <> ''),
    CHECK (jsonb_typeof(position_state) = 'object' AND position_state <> '{}'::jsonb),
    CHECK ((action = 'EXIT') = (fill_price IS NOT NULL)),
    CHECK (reference_price IS NULL OR reference_price > 0),
    CHECK (fill_price IS NULL OR fill_price > 0),
    CHECK (slippage_basis_points IS NULL OR slippage_basis_points >= 0),
    CHECK (decision_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_exit_outcomes (
    exit_episode_id          char(64) PRIMARY KEY
                             REFERENCES strategy_training.training_exit_episode_inputs,
    exit_time               timestamptz NOT NULL,
    exit_price              numeric NOT NULL CHECK (exit_price > 0),
    exit_reason             text NOT NULL,
    gross_pnl               numeric NOT NULL,
    entry_fee               numeric NOT NULL CHECK (entry_fee >= 0),
    exit_fee                numeric NOT NULL CHECK (exit_fee >= 0),
    funding_total           numeric NOT NULL,
    slippage_total          numeric NOT NULL CHECK (slippage_total >= 0),
    net_pnl                 numeric NOT NULL,
    risk_violation_codes    jsonb NOT NULL,
    result_hash             char(64) NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(exit_reason) <> ''),
    CHECK (jsonb_typeof(risk_violation_codes) = 'array'),
    CHECK (result_hash ~ '^[0-9a-f]{64}$')
);

CREATE VIEW strategy_training.model_b_entry_inputs
WITH (security_barrier = true)
AS
SELECT exit_episode_id, model_b_sample_id, model_b_iteration_id,
       instrument_id, symbol, direction, entry_time, entry_reference_price,
       maximum_end_at, interval_seconds, exit_rule_version_id,
       fee_model_version_id, slippage_model_version_id, status
FROM strategy_training.training_exit_episode_inputs;

CREATE VIEW strategy_training.model_b_decision_history
WITH (security_barrier = true)
AS
SELECT decision.exit_episode_id, decision.sequence_no, decision.decision_time,
       decision.decision_feature_snapshot_id, decision.action,
       decision.reason_code, decision.position_state,
       decision.reference_price, decision.fill_price,
       decision.slippage_basis_points, decision.decision_hash
FROM strategy_training.training_exit_decisions decision;

CREATE OR REPLACE FUNCTION strategy_training.create_training_exit_episode(
    p_entry_event_id char(64),
    p_model_b_iteration_id uuid,
    p_exit_rule_version_id uuid,
    p_fee_model_version_id uuid,
    p_slippage_model_version_id uuid
)
RETURNS TABLE (created_exit_episode_id char(64), created_model_b_sample_id char(64))
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    iteration_state text;
    config_id uuid;
    config_type_name text;
    config_status text;
    exit_json jsonb;
    slippage_json jsonb;
    sample_id char(64);
    episode_id char(64);
BEGIN
    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id AND status = 'COMPLETE';
    IF entry_record.source <> 'FIXED_BASELINE_MODEL_A' THEN
        RAISE EXCEPTION 'prototype model-B episodes require FIXED_BASELINE_MODEL_A'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = entry_record.dataset_version_id AND status = 'READY';
    SELECT iteration.state INTO STRICT iteration_state
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = p_model_b_iteration_id;
    SELECT experiment.* INTO STRICT experiment_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = p_model_b_iteration_id;
    IF iteration_state <> 'RUNNING' OR experiment_record.state <> 'RUNNING'
       OR experiment_record.experiment_mode <> 'EXIT_POLICY'
       OR experiment_record.dataset_version_id <> entry_record.dataset_version_id THEN
        RAISE EXCEPTION 'model-B episode requires a running EXIT_POLICY iteration on the entry dataset'
            USING ERRCODE = '23514';
    END IF;
    FOREACH config_id IN ARRAY ARRAY[
        p_exit_rule_version_id, p_fee_model_version_id, p_slippage_model_version_id
    ]
    LOOP
        SELECT config_type, status, config_json
        INTO STRICT config_type_name, config_status, exit_json
        FROM strategy_training.training_config_versions
        WHERE config_version_id = config_id;
        IF config_status <> 'READY' OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
            WHERE binding.experiment_id = experiment_record.experiment_id
              AND binding.config_type = config_type_name
              AND binding.config_version_id = config_id
        ) THEN
            RAISE EXCEPTION 'model-B config % is not READY and frozen', config_type_name
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    IF (SELECT config_type FROM strategy_training.training_config_versions
        WHERE config_version_id = p_exit_rule_version_id) <> 'EXIT_RULES'
       OR (SELECT config_type FROM strategy_training.training_config_versions
           WHERE config_version_id = p_fee_model_version_id) <> 'FEE_MODEL'
       OR (SELECT config_type FROM strategy_training.training_config_versions
           WHERE config_version_id = p_slippage_model_version_id) <> 'SLIPPAGE_MODEL' THEN
        RAISE EXCEPTION 'model-B episode config types are invalid' USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT exit_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_exit_rule_version_id;
    SELECT config_json INTO STRICT slippage_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_slippage_model_version_id;
    IF jsonb_typeof(slippage_json -> 'base_basis_points') IS DISTINCT FROM 'number'
       OR jsonb_typeof(slippage_json -> 'reference_notional') IS DISTINCT FROM 'number'
       OR jsonb_typeof(slippage_json -> 'maximum_basis_points') IS DISTINCT FROM 'number'
       OR (slippage_json ->> 'base_basis_points')::numeric < 0
       OR (slippage_json ->> 'reference_notional')::numeric <= 0
       OR (slippage_json ->> 'maximum_basis_points')::numeric
          < (slippage_json ->> 'base_basis_points')::numeric THEN
        RAISE EXCEPTION 'model-B slippage config lacks explicit bounded cost inputs'
            USING ERRCODE = '23514';
    END IF;
    IF entry_record.entry_time
         + make_interval(secs => (exit_json ->> 'max_holding_seconds')::double precision)
       > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'model-B holding path exceeds its partition' USING ERRCODE = '23514';
    END IF;
    sample_id := encode(public.digest(
        p_entry_event_id || ':' || p_model_b_iteration_id::text || ':MODEL_B_PROTOTYPE',
        'sha256'
    ), 'hex');
    episode_id := encode(public.digest(
        sample_id || ':' || p_exit_rule_version_id::text || ':' ||
        p_fee_model_version_id::text || ':' || p_slippage_model_version_id::text,
        'sha256'
    ), 'hex');
    INSERT INTO strategy_training.training_model_b_sample_map (
        model_b_sample_id, entry_event_id, sample_use, natural_source, mapping_hash
    ) VALUES (
        sample_id, p_entry_event_id, 'MODEL_B_PROTOTYPE', entry_record.source,
        encode(public.digest(sample_id || ':' || p_entry_event_id, 'sha256'), 'hex')
    );
    INSERT INTO strategy_training.training_exit_episode_inputs (
        exit_episode_id, model_b_sample_id, model_b_iteration_id,
        dataset_version_id, instrument_id, symbol, direction, entry_time,
        entry_reference_price, maximum_end_at, interval_seconds,
        exit_rule_version_id, fee_model_version_id, slippage_model_version_id
    ) VALUES (
        episode_id, sample_id, p_model_b_iteration_id,
        entry_record.dataset_version_id, entry_record.instrument_id,
        entry_record.symbol, entry_record.direction, entry_record.entry_time,
        entry_record.entry_price,
        entry_record.entry_time
          + make_interval(secs => (exit_json ->> 'max_holding_seconds')::double precision),
        dataset_record.interval_seconds, p_exit_rule_version_id,
        p_fee_model_version_id, p_slippage_model_version_id
    );
    RETURN QUERY SELECT episode_id, sample_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.model_b_market_asof(
    p_model_b_sample_id char(64),
    p_decision_time timestamptz,
    p_interval_seconds integer
)
RETURNS TABLE (
    decision_feature_snapshot_id uuid,
    open_time timestamptz,
    close_time timestamptz,
    open_price numeric,
    high_price numeric,
    low_price numeric,
    close_price numeric,
    quote_volume numeric,
    volatility_percent numeric,
    payload_hash char(64)
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $$
DECLARE
    episode strategy_training.training_exit_episode_inputs%ROWTYPE;
    dataset strategy_training.training_dataset_versions%ROWTYPE;
    selected market.klines%ROWTYPE;
    prior_time timestamptz;
    features jsonb;
    computed_hash char(64);
    snapshot_id uuid;
BEGIN
    SELECT * INTO STRICT episode
    FROM strategy_training.training_exit_episode_inputs
    WHERE model_b_sample_id = p_model_b_sample_id AND status = 'RUNNING';
    SELECT * INTO STRICT dataset
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = episode.dataset_version_id AND status = 'READY';
    SELECT max(requested_as_of_at) INTO prior_time
    FROM strategy_training.training_model_b_market_access_log
    WHERE exit_episode_id = episode.exit_episode_id;
    IF p_interval_seconds <> episode.interval_seconds
       OR p_decision_time <= episode.entry_time
       OR p_decision_time > episode.maximum_end_at
       OR (prior_time IS NOT NULL AND p_decision_time < prior_time) THEN
        RAISE EXCEPTION 'model-B as-of request violates episode time/order bounds'
            USING ERRCODE = '23514';
    END IF;
    SELECT kline.* INTO STRICT selected
    FROM market.klines kline
    WHERE kline.instrument_id = episode.instrument_id
      AND kline.price_type = 'TRADE'
      AND kline.interval_seconds = p_interval_seconds
      AND kline.open_time >= episode.entry_time
      AND kline.close_time <= p_decision_time
      AND kline.effective_at <= dataset.source_as_of_at
      AND kline.is_closed AND kline.quality_status = 'VALID'
      AND NOT EXISTS (
          SELECT 1 FROM market.klines newer
          WHERE newer.instrument_id = kline.instrument_id
            AND newer.price_type = kline.price_type
            AND newer.interval_seconds = kline.interval_seconds
            AND newer.open_time = kline.open_time
            AND newer.revision_no > kline.revision_no
            AND newer.effective_at <= dataset.source_as_of_at
            AND newer.is_closed AND newer.quality_status = 'VALID'
      )
    ORDER BY kline.close_time DESC
    LIMIT 1;
    IF selected.close_time <> p_decision_time THEN
        RAISE EXCEPTION 'decision_time must equal an available closed-bar boundary'
            USING ERRCODE = '23514';
    END IF;
    features := jsonb_build_object(
        'close_price', selected.close_price,
        'high_price', selected.high_price,
        'low_price', selected.low_price,
        'open_price', selected.open_price,
        'quote_volume', selected.quote_volume,
        'volatility_percent',
            (selected.high_price - selected.low_price) / selected.open_price * 100
    );
    computed_hash := encode(public.digest(jsonb_build_object(
        'decision_time', p_decision_time,
        'exit_episode_id', episode.exit_episode_id,
        'features', features,
        'payload_hash', selected.payload_hash
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_decision_feature_snapshots (
        exit_episode_id, model_b_sample_id, decision_time, last_closed_bar_at,
        interval_seconds, feature_json, source_payload_hash, snapshot_hash
    ) VALUES (
        episode.exit_episode_id, p_model_b_sample_id, p_decision_time,
        selected.close_time, p_interval_seconds, features,
        selected.payload_hash, computed_hash
    ) ON CONFLICT (exit_episode_id, decision_time) DO NOTHING;
    SELECT snapshot.decision_feature_snapshot_id INTO STRICT snapshot_id
    FROM strategy_training.training_decision_feature_snapshots snapshot
    WHERE snapshot.exit_episode_id = episode.exit_episode_id
      AND snapshot.decision_time = p_decision_time;
    INSERT INTO strategy_training.training_model_b_market_access_log (
        exit_episode_id, model_b_sample_id, requested_as_of_at,
        returned_close_time, interval_seconds, snapshot_hash
    ) VALUES (
        episode.exit_episode_id, p_model_b_sample_id, p_decision_time,
        selected.close_time, p_interval_seconds, computed_hash
    );
    RETURN QUERY SELECT snapshot_id, selected.open_time, selected.close_time,
        selected.open_price, selected.high_price, selected.low_price,
        selected.close_price, selected.quote_volume,
        (selected.high_price - selected.low_price) / selected.open_price * 100,
        selected.payload_hash;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_exit_decision(
    p_exit_episode_id char(64),
    p_sequence_no integer,
    p_decision_time timestamptz,
    p_decision_feature_snapshot_id uuid,
    p_action text,
    p_reason_code text,
    p_position_state jsonb,
    p_reference_price numeric,
    p_fill_price numeric,
    p_slippage_basis_points numeric,
    p_decision_hash char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    expected_sequence integer;
    prior_decision_time timestamptz;
    episode_status text;
BEGIN
    SELECT status INTO STRICT episode_status
    FROM strategy_training.training_exit_episode_inputs
    WHERE exit_episode_id = p_exit_episode_id FOR UPDATE;
    IF episode_status <> 'RUNNING' THEN
        RAISE EXCEPTION 'exit episode is not running' USING ERRCODE = '23514';
    END IF;
    SELECT coalesce(max(sequence_no), 0) + 1, max(decision_time)
    INTO expected_sequence, prior_decision_time
    FROM strategy_training.training_exit_decisions
    WHERE exit_episode_id = p_exit_episode_id;
    IF p_sequence_no <> expected_sequence
       OR (prior_decision_time IS NOT NULL AND p_decision_time <= prior_decision_time)
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_decision_feature_snapshots snapshot
           WHERE snapshot.decision_feature_snapshot_id = p_decision_feature_snapshot_id
             AND snapshot.exit_episode_id = p_exit_episode_id
             AND snapshot.decision_time = p_decision_time
       ) THEN
        RAISE EXCEPTION 'exit decision sequence/snapshot is invalid' USING ERRCODE = '23514';
    END IF;
    IF p_action = 'MOVE_STOP' AND (
        NOT p_position_state ?& ARRAY['direction', 'stop_before', 'stop_after']
        OR (p_position_state ->> 'direction') = 'LONG'
           AND (p_position_state ->> 'stop_after')::numeric
               < (p_position_state ->> 'stop_before')::numeric
        OR (p_position_state ->> 'direction') = 'SHORT'
           AND (p_position_state ->> 'stop_after')::numeric
               > (p_position_state ->> 'stop_before')::numeric
    ) THEN
        RAISE EXCEPTION 'MOVE_STOP cannot increase risk' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_exit_decisions (
        exit_episode_id, sequence_no, decision_time,
        decision_feature_snapshot_id, action, reason_code, position_state,
        reference_price, fill_price, slippage_basis_points, decision_hash
    ) VALUES (
        p_exit_episode_id, p_sequence_no, p_decision_time,
        p_decision_feature_snapshot_id, p_action, p_reason_code, p_position_state,
        p_reference_price, p_fill_price, p_slippage_basis_points, p_decision_hash
    );
    IF p_action = 'EXIT' THEN
        UPDATE strategy_training.training_exit_episode_inputs
        SET status = 'DECIDED', decided_at = clock_timestamp()
        WHERE exit_episode_id = p_exit_episode_id;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_exit_outcome(
    p_exit_episode_id char(64), p_exit_time timestamptz, p_exit_price numeric,
    p_exit_reason text, p_gross_pnl numeric, p_entry_fee numeric,
    p_exit_fee numeric, p_funding_total numeric, p_slippage_total numeric,
    p_net_pnl numeric, p_risk_violation_codes jsonb, p_result_hash char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_exit_episode_inputs episode
        JOIN strategy_training.training_exit_decisions decision
          ON decision.exit_episode_id = episode.exit_episode_id
         AND decision.action = 'EXIT'
         AND decision.decision_time = p_exit_time
         AND decision.fill_price = p_exit_price
        WHERE episode.exit_episode_id = p_exit_episode_id
          AND episode.status = 'DECIDED'
          AND p_exit_time <= episode.maximum_end_at
    ) THEN
        RAISE EXCEPTION
            'exit outcome requires the matching terminal EXIT decision for episode %',
            p_exit_episode_id
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_exit_outcomes (
        exit_episode_id, exit_time, exit_price, exit_reason, gross_pnl,
        entry_fee, exit_fee, funding_total, slippage_total, net_pnl,
        risk_violation_codes, result_hash
    )
    VALUES (
        p_exit_episode_id, p_exit_time, p_exit_price, p_exit_reason,
        p_gross_pnl, p_entry_fee, p_exit_fee, p_funding_total,
        p_slippage_total, p_net_pnl, p_risk_violation_codes, p_result_hash
    );
END
$$;

DO $$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'training_model_b_sample_map', 'training_model_b_market_access_log',
        'training_decision_feature_snapshots', 'training_exit_decisions',
        'training_exit_outcomes'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training.%I '
            'FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()',
            table_name, table_name
        );
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_model_b_sample_map OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_exit_episode_inputs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_market_access_log OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_decision_feature_snapshots OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_exit_decisions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_exit_outcomes OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.model_b_entry_inputs OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.model_b_decision_history OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_exit_episode(char(64), uuid, uuid, uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.model_b_market_asof(char(64), timestamptz, integer)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_exit_decision(
    char(64), integer, timestamptz, uuid, text, text, jsonb,
    numeric, numeric, numeric, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_exit_outcome(
    char(64), timestamptz, numeric, text, numeric, numeric, numeric,
    numeric, numeric, numeric, jsonb, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON strategy_training.model_b_entry_inputs,
    strategy_training.model_b_decision_history
TO tb2_training_model_b;
GRANT EXECUTE ON FUNCTION
    strategy_training.model_b_market_asof(char(64), timestamptz, integer),
    strategy_training.record_training_exit_decision(
        char(64), integer, timestamptz, uuid, text, text, jsonb,
        numeric, numeric, numeric, char(64)
    )
TO tb2_training_model_b;

GRANT SELECT ON strategy_training.training_model_b_sample_map,
    strategy_training.training_exit_episode_inputs,
    strategy_training.training_model_b_market_access_log,
    strategy_training.training_decision_feature_snapshots,
    strategy_training.training_exit_decisions,
    strategy_training.training_exit_outcomes
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.create_training_exit_episode(char(64), uuid, uuid, uuid, uuid),
    strategy_training.record_training_exit_outcome(
        char(64), timestamptz, numeric, text, numeric, numeric, numeric,
        numeric, numeric, numeric, jsonb, char(64)
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '029_training_model_b_isolation',
    encode(digest('auto_trade_v2_029_training_model_b_isolation_v1', 'sha256'), 'hex'),
    'Add opaque model-B episodes, time-safe as-of access and isolated decisions/outcomes'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
