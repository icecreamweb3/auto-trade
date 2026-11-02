\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_portfolio_runs (
    portfolio_run_id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type                        varchar(24) NOT NULL
                                    CHECK (run_type IN ('TRAIN_PORTFOLIO', 'VALIDATION_PORTFOLIO')),
    experiment_id                   uuid NOT NULL REFERENCES strategy_training.training_experiments,
    model_b_iteration_id            uuid NOT NULL REFERENCES strategy_training.training_iterations,
    dataset_version_id              uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    portfolio_rule_version_id       uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    fee_model_version_id            uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    slippage_model_version_id       uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    initial_capital                 numeric NOT NULL CHECK (initial_capital > 0),
    notional_per_trade              numeric NOT NULL CHECK (notional_per_trade > 0),
    maximum_concurrent_positions    integer NOT NULL CHECK (maximum_concurrent_positions > 0),
    status                          varchar(16) NOT NULL DEFAULT 'BUILDING'
                                    CHECK (status IN ('BUILDING', 'COMPLETE', 'INVALID')),
    final_balance                   numeric,
    maximum_drawdown_percent        numeric CHECK (maximum_drawdown_percent IS NULL
                                                    OR maximum_drawdown_percent >= 0),
    peak_occupied_capital           numeric CHECK (peak_occupied_capital IS NULL
                                                    OR peak_occupied_capital >= 0),
    result_hash                     char(64),
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at                    timestamptz,
    invalid_reason                  text,
    CHECK (result_hash IS NULL OR result_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (status = 'BUILDING' AND final_balance IS NULL
                              AND maximum_drawdown_percent IS NULL
                              AND peak_occupied_capital IS NULL
                              AND result_hash IS NULL AND completed_at IS NULL
                              AND invalid_reason IS NULL)
        OR (status = 'COMPLETE' AND final_balance IS NOT NULL
                              AND maximum_drawdown_percent IS NOT NULL
                              AND peak_occupied_capital IS NOT NULL
                              AND result_hash IS NOT NULL AND completed_at IS NOT NULL
                              AND invalid_reason IS NULL)
        OR (status = 'INVALID' AND completed_at IS NOT NULL
                             AND invalid_reason IS NOT NULL
                             AND btrim(invalid_reason) <> '')
    ),
    UNIQUE (model_b_iteration_id, portfolio_rule_version_id)
);

CREATE TABLE strategy_training.training_portfolio_signal_dispositions (
    portfolio_run_id          uuid NOT NULL REFERENCES strategy_training.training_portfolio_runs,
    entry_event_id            char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    exit_episode_id           char(64) NOT NULL REFERENCES strategy_training.training_exit_episode_inputs,
    entry_time                timestamptz NOT NULL,
    disposition               varchar(40) NOT NULL CHECK (disposition IN (
                                  'ACCEPTED', 'REJECTED_CAPITAL',
                                  'REJECTED_CONCURRENCY', 'REJECTED_EXISTING_POSITION'
                              )),
    capital_before            numeric NOT NULL,
    occupied_before           numeric NOT NULL CHECK (occupied_before >= 0),
    open_positions_before     integer NOT NULL CHECK (open_positions_before >= 0),
    disposition_hash          char(64) NOT NULL,
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (portfolio_run_id, entry_event_id),
    CHECK (disposition_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_portfolio_trades (
    portfolio_trade_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_run_id          uuid NOT NULL REFERENCES strategy_training.training_portfolio_runs,
    entry_event_id            char(64) NOT NULL,
    exit_episode_id           char(64) NOT NULL REFERENCES strategy_training.training_exit_outcomes,
    instrument_id             bigint NOT NULL REFERENCES core.instruments,
    symbol                    text NOT NULL,
    direction                 varchar(8) NOT NULL CHECK (direction IN ('LONG', 'SHORT')),
    entry_time                timestamptz NOT NULL,
    exit_time                 timestamptz NOT NULL,
    quantity                  numeric NOT NULL CHECK (quantity > 0),
    notional                  numeric NOT NULL CHECK (notional > 0),
    gross_pnl                 numeric NOT NULL,
    fee_total                 numeric NOT NULL CHECK (fee_total >= 0),
    funding_total             numeric NOT NULL,
    slippage_total            numeric NOT NULL CHECK (slippage_total >= 0),
    net_pnl                   numeric NOT NULL,
    exit_reason               text NOT NULL,
    trade_hash                char(64) NOT NULL,
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (exit_time >= entry_time),
    CHECK (btrim(symbol) <> '' AND symbol = upper(symbol)),
    CHECK (btrim(exit_reason) <> ''),
    CHECK (trade_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (portfolio_run_id, entry_event_id),
    FOREIGN KEY (portfolio_run_id, entry_event_id)
        REFERENCES strategy_training.training_portfolio_signal_dispositions
        (portfolio_run_id, entry_event_id)
);

CREATE TABLE strategy_training.training_portfolio_trade_fills (
    portfolio_trade_id       uuid NOT NULL REFERENCES strategy_training.training_portfolio_trades,
    fill_sequence_no         integer NOT NULL CHECK (fill_sequence_no > 0),
    fill_side                varchar(8) NOT NULL CHECK (fill_side IN ('ENTRY', 'EXIT')),
    fill_time                timestamptz NOT NULL,
    price                    numeric NOT NULL CHECK (price > 0),
    quantity                 numeric NOT NULL CHECK (quantity > 0),
    fee                      numeric NOT NULL CHECK (fee >= 0),
    slippage_cost            numeric NOT NULL CHECK (slippage_cost >= 0),
    fill_hash                char(64) NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (portfolio_trade_id, fill_sequence_no),
    CHECK (fill_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_portfolio_equity_points (
    portfolio_run_id       uuid NOT NULL REFERENCES strategy_training.training_portfolio_runs,
    point_sequence_no      integer NOT NULL CHECK (point_sequence_no > 0),
    observed_at            timestamptz NOT NULL,
    balance                numeric NOT NULL,
    occupied_capital       numeric NOT NULL CHECK (occupied_capital >= 0),
    available_capital      numeric NOT NULL,
    open_position_count    integer NOT NULL CHECK (open_position_count >= 0),
    peak_balance           numeric NOT NULL,
    drawdown_percent       numeric NOT NULL CHECK (drawdown_percent >= 0),
    event_type             varchar(16) NOT NULL CHECK (event_type IN ('ENTRY', 'EXIT')),
    entry_event_id         char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    point_hash             char(64) NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (portfolio_run_id, point_sequence_no),
    CHECK (available_capital = balance - occupied_capital),
    CHECK (point_hash ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION strategy_training.create_training_portfolio_run(
    p_model_b_iteration_id uuid,
    p_portfolio_rule_version_id uuid,
    p_fee_model_version_id uuid,
    p_slippage_model_version_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    iteration_record strategy_training.training_iterations%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    portfolio_config strategy_training.training_config_versions%ROWTYPE;
    created_id uuid := gen_random_uuid();
BEGIN
    SELECT * INTO STRICT iteration_record FROM strategy_training.training_iterations
    WHERE iteration_id = p_model_b_iteration_id;
    SELECT * INTO STRICT experiment_record FROM strategy_training.training_experiments
    WHERE experiment_id = iteration_record.experiment_id;
    SELECT * INTO STRICT dataset_record FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = experiment_record.dataset_version_id;
    SELECT * INTO STRICT portfolio_config FROM strategy_training.training_config_versions
    WHERE config_version_id = p_portfolio_rule_version_id;
    IF iteration_record.state <> 'RUNNING' OR experiment_record.state <> 'RUNNING'
       OR experiment_record.experiment_mode <> 'EXIT_POLICY'
       OR dataset_record.status <> 'READY'
       OR portfolio_config.status <> 'READY'
       OR portfolio_config.config_type <> 'PORTFOLIO_RULES'
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
           WHERE binding.experiment_id = experiment_record.experiment_id
             AND binding.config_type = 'PORTFOLIO_RULES'
             AND binding.config_version_id = p_portfolio_rule_version_id
       ) OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
           WHERE binding.experiment_id = experiment_record.experiment_id
             AND binding.config_type = 'FEE_MODEL'
             AND binding.config_version_id = p_fee_model_version_id
       ) OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
           WHERE binding.experiment_id = experiment_record.experiment_id
             AND binding.config_type = 'SLIPPAGE_MODEL'
             AND binding.config_version_id = p_slippage_model_version_id
       ) THEN
        RAISE EXCEPTION 'portfolio run requires frozen READY EXIT_POLICY configs'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_portfolio_runs (
        portfolio_run_id, run_type, experiment_id, model_b_iteration_id,
        dataset_version_id, portfolio_rule_version_id,
        fee_model_version_id, slippage_model_version_id,
        initial_capital, notional_per_trade, maximum_concurrent_positions
    ) VALUES (
        created_id,
        CASE dataset_record.partition WHEN 'TRAIN' THEN 'TRAIN_PORTFOLIO'
                                      ELSE 'VALIDATION_PORTFOLIO' END,
        experiment_record.experiment_id, p_model_b_iteration_id,
        dataset_record.dataset_version_id, p_portfolio_rule_version_id,
        p_fee_model_version_id, p_slippage_model_version_id,
        (portfolio_config.config_json ->> 'initial_capital')::numeric,
        (portfolio_config.config_json ->> 'notional_per_trade')::numeric,
        (portfolio_config.config_json ->> 'maximum_concurrent_positions')::integer
    );
    RETURN created_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_portfolio_disposition(
    p_portfolio_run_id uuid, p_entry_event_id char(64), p_exit_episode_id char(64),
    p_entry_time timestamptz, p_disposition text, p_capital_before numeric,
    p_occupied_before numeric, p_open_positions_before integer,
    p_disposition_hash char(64)
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
        FROM strategy_training.training_portfolio_runs run
        JOIN strategy_training.training_exit_episode_inputs episode
          ON episode.model_b_iteration_id = run.model_b_iteration_id
        JOIN strategy_training.training_model_b_sample_map sample
          ON sample.model_b_sample_id = episode.model_b_sample_id
        WHERE run.portfolio_run_id = p_portfolio_run_id AND run.status = 'BUILDING'
          AND episode.exit_episode_id = p_exit_episode_id
          AND sample.entry_event_id = p_entry_event_id
          AND episode.entry_time = p_entry_time
    ) THEN
        RAISE EXCEPTION 'portfolio disposition is outside its frozen run inputs'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_portfolio_signal_dispositions (
        portfolio_run_id, entry_event_id, exit_episode_id, entry_time,
        disposition, capital_before, occupied_before,
        open_positions_before, disposition_hash
    ) VALUES (
        p_portfolio_run_id, p_entry_event_id, p_exit_episode_id, p_entry_time,
        p_disposition, p_capital_before, p_occupied_before,
        p_open_positions_before, p_disposition_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_portfolio_trade(
    p_portfolio_run_id uuid, p_entry_event_id char(64),
    p_exit_episode_id char(64), p_quantity numeric, p_notional numeric,
    p_trade_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    created_id uuid := gen_random_uuid();
    entry_record strategy_training.training_entry_events%ROWTYPE;
    outcome strategy_training.training_exit_outcomes%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_portfolio_signal_dispositions disposition
        JOIN strategy_training.training_portfolio_runs run
          ON run.portfolio_run_id = disposition.portfolio_run_id
        WHERE disposition.portfolio_run_id = p_portfolio_run_id
          AND disposition.entry_event_id = p_entry_event_id
          AND disposition.exit_episode_id = p_exit_episode_id
          AND disposition.disposition = 'ACCEPTED' AND run.status = 'BUILDING'
    ) THEN
        RAISE EXCEPTION 'portfolio trade requires an accepted BUILDING disposition'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id;
    SELECT * INTO STRICT outcome FROM strategy_training.training_exit_outcomes
    WHERE exit_episode_id = p_exit_episode_id;
    INSERT INTO strategy_training.training_portfolio_trades (
        portfolio_trade_id, portfolio_run_id, entry_event_id, exit_episode_id,
        instrument_id, symbol, direction, entry_time, exit_time,
        quantity, notional, gross_pnl, fee_total, funding_total,
        slippage_total, net_pnl, exit_reason, trade_hash
    ) VALUES (
        created_id, p_portfolio_run_id, p_entry_event_id, p_exit_episode_id,
        entry_record.instrument_id, entry_record.symbol, entry_record.direction,
        entry_record.entry_time, outcome.exit_time, p_quantity, p_notional,
        outcome.gross_pnl, outcome.entry_fee + outcome.exit_fee,
        outcome.funding_total, outcome.slippage_total, outcome.net_pnl,
        outcome.exit_reason, p_trade_hash
    );
    RETURN created_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_portfolio_fill(
    p_portfolio_trade_id uuid, p_fill_sequence_no integer, p_fill_side text,
    p_fill_time timestamptz, p_price numeric, p_quantity numeric,
    p_fee numeric, p_slippage_cost numeric, p_fill_hash char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    run_status text;
BEGIN
    SELECT run.status INTO STRICT run_status
        FROM strategy_training.training_portfolio_trades trade
        JOIN strategy_training.training_portfolio_runs run
          ON run.portfolio_run_id = trade.portfolio_run_id
        WHERE trade.portfolio_trade_id = p_portfolio_trade_id
        FOR UPDATE OF run;
    IF run_status <> 'BUILDING' THEN
        RAISE EXCEPTION
            'portfolio fill requires a BUILDING run for trade %',
            p_portfolio_trade_id
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_portfolio_trade_fills (
        portfolio_trade_id, fill_sequence_no, fill_side, fill_time,
        price, quantity, fee, slippage_cost, fill_hash
    ) VALUES (
        p_portfolio_trade_id, p_fill_sequence_no, p_fill_side, p_fill_time,
        p_price, p_quantity, p_fee, p_slippage_cost, p_fill_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_portfolio_equity_point(
    p_portfolio_run_id uuid, p_point_sequence_no integer, p_observed_at timestamptz,
    p_balance numeric, p_occupied_capital numeric, p_available_capital numeric,
    p_open_position_count integer, p_peak_balance numeric,
    p_drawdown_percent numeric, p_event_type text,
    p_entry_event_id char(64), p_point_hash char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    run_status text;
BEGIN
    SELECT run.status INTO STRICT run_status
        FROM strategy_training.training_portfolio_runs run
        WHERE run.portfolio_run_id = p_portfolio_run_id
        FOR UPDATE;
    IF run_status <> 'BUILDING' THEN
        RAISE EXCEPTION
            'portfolio equity point requires BUILDING run %',
            p_portfolio_run_id
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_portfolio_equity_points (
        portfolio_run_id, point_sequence_no, observed_at, balance,
        occupied_capital, available_capital, open_position_count,
        peak_balance, drawdown_percent, event_type, entry_event_id, point_hash
    ) VALUES (
        p_portfolio_run_id, p_point_sequence_no, p_observed_at, p_balance,
        p_occupied_capital, p_available_capital, p_open_position_count,
        p_peak_balance, p_drawdown_percent, p_event_type, p_entry_event_id, p_point_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_portfolio_run(
    p_portfolio_run_id uuid, p_final_balance numeric,
    p_maximum_drawdown_percent numeric, p_peak_occupied_capital numeric,
    p_result_hash char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    run_record strategy_training.training_portfolio_runs%ROWTYPE;
    last_equity strategy_training.training_portfolio_equity_points%ROWTYPE;
BEGIN
    SELECT * INTO STRICT run_record FROM strategy_training.training_portfolio_runs
    WHERE portfolio_run_id = p_portfolio_run_id FOR UPDATE;
    IF run_record.status <> 'BUILDING'
       OR EXISTS (
           SELECT 1 FROM strategy_training.training_exit_episode_inputs episode
           WHERE episode.model_b_iteration_id = run_record.model_b_iteration_id
             AND NOT EXISTS (
                 SELECT 1 FROM strategy_training.training_portfolio_signal_dispositions disposition
                 WHERE disposition.portfolio_run_id = p_portfolio_run_id
                   AND disposition.exit_episode_id = episode.exit_episode_id
             )
       ) OR EXISTS (
           SELECT 1 FROM strategy_training.training_portfolio_signal_dispositions disposition
           WHERE disposition.portfolio_run_id = p_portfolio_run_id
             AND disposition.disposition = 'ACCEPTED'
             AND NOT EXISTS (
                 SELECT 1 FROM strategy_training.training_portfolio_trades trade
                 WHERE trade.portfolio_run_id = p_portfolio_run_id
                   AND trade.entry_event_id = disposition.entry_event_id
             )
       ) THEN
        RAISE EXCEPTION 'portfolio run is incomplete' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_portfolio_trades trade
        WHERE trade.portfolio_run_id = p_portfolio_run_id
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_portfolio_trade_fills fill
              WHERE fill.portfolio_trade_id = trade.portfolio_trade_id
              GROUP BY fill.portfolio_trade_id
              HAVING count(*) >= 2
                 AND sum(fill.quantity) FILTER (WHERE fill.fill_side = 'ENTRY')
                     = sum(fill.quantity) FILTER (WHERE fill.fill_side = 'EXIT')
                 AND sum(fill.fee) = trade.fee_total
                 AND sum(fill.slippage_cost) = trade.slippage_total
          )
    ) THEN
        RAISE EXCEPTION 'portfolio trade fills do not reconstruct their trade'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT last_equity
    FROM strategy_training.training_portfolio_equity_points
    WHERE portfolio_run_id = p_portfolio_run_id
    ORDER BY point_sequence_no DESC LIMIT 1;
    IF last_equity.balance <> p_final_balance
       OR last_equity.open_position_count <> 0
       OR (SELECT max(drawdown_percent)
           FROM strategy_training.training_portfolio_equity_points
           WHERE portfolio_run_id = p_portfolio_run_id) <> p_maximum_drawdown_percent
       OR (SELECT max(occupied_capital)
           FROM strategy_training.training_portfolio_equity_points
           WHERE portfolio_run_id = p_portfolio_run_id) <> p_peak_occupied_capital THEN
        RAISE EXCEPTION 'portfolio summary does not match its equity curve'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_portfolio_runs
    SET status = 'COMPLETE', final_balance = p_final_balance,
        maximum_drawdown_percent = p_maximum_drawdown_percent,
        peak_occupied_capital = p_peak_occupied_capital,
        result_hash = p_result_hash, completed_at = clock_timestamp()
    WHERE portfolio_run_id = p_portfolio_run_id;
END
$$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'training_portfolio_signal_dispositions', 'training_portfolio_trades',
        'training_portfolio_trade_fills', 'training_portfolio_equity_points'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training.%I '
            'FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()',
            table_name, table_name
        );
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_portfolio_runs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_portfolio_signal_dispositions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_portfolio_trades OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_portfolio_trade_fills OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_portfolio_equity_points OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_portfolio_run(uuid, uuid, uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_portfolio_disposition(
    uuid, char(64), char(64), timestamptz, text, numeric, numeric, integer, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_portfolio_trade(
    uuid, char(64), char(64), numeric, numeric, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_portfolio_fill(
    uuid, integer, text, timestamptz, numeric, numeric, numeric, numeric, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_portfolio_equity_point(
    uuid, integer, timestamptz, numeric, numeric, numeric, integer,
    numeric, numeric, text, char(64), char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_portfolio_run(
    uuid, numeric, numeric, numeric, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON strategy_training.training_portfolio_runs,
    strategy_training.training_portfolio_signal_dispositions,
    strategy_training.training_portfolio_trades,
    strategy_training.training_portfolio_trade_fills,
    strategy_training.training_portfolio_equity_points
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.create_training_portfolio_run(uuid, uuid, uuid, uuid),
    strategy_training.record_training_portfolio_disposition(
        uuid, char(64), char(64), timestamptz, text,
        numeric, numeric, integer, char(64)
    ),
    strategy_training.record_training_portfolio_trade(
        uuid, char(64), char(64), numeric, numeric, char(64)
    ),
    strategy_training.record_training_portfolio_fill(
        uuid, integer, text, timestamptz, numeric, numeric,
        numeric, numeric, char(64)
    ),
    strategy_training.record_training_portfolio_equity_point(
        uuid, integer, timestamptz, numeric, numeric, numeric, integer,
        numeric, numeric, text, char(64), char(64)
    ),
    strategy_training.finalize_training_portfolio_run(
        uuid, numeric, numeric, numeric, char(64)
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '030_training_portfolio_simulation',
    encode(digest('auto_trade_v2_030_training_portfolio_simulation_v1', 'sha256'), 'hex'),
    'Add governed portfolio capacity, dispositions, fills and replayable equity curves'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
