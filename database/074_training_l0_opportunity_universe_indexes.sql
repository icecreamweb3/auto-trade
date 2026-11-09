\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE INDEX ix_training_historical_pool_dataset_instrument_time
ON strategy_training.training_historical_pool_evaluations (
    dataset_version_id, instrument_id, evaluation_at DESC
)
INCLUDE (pool_evaluation_id, is_eligible);

CREATE OR REPLACE FUNCTION strategy_training.build_training_opportunity_universe(
    p_task_id uuid, p_lease_token uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    definition_id uuid; definition_json jsonb; universe_id uuid;
    incomplete_count bigint; event_count_value bigint; opportunity_count_value bigint;
    universe_hash char(64);
BEGIN
    task_record := strategy_training.assert_training_model_a_l0_lease(
        p_task_id, p_lease_token
    );
    SELECT dataset.* INTO STRICT dataset_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = experiment.dataset_version_id
    WHERE iteration.iteration_id = task_record.iteration_id
      AND iteration.state = 'RUNNING'
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300;
    SELECT config.config_version_id, config.config_json
    INTO STRICT definition_id, definition_json
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'OPPORTUNITY_DEFINITION'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'OPPORTUNITY_DEFINITION' AND config.status = 'READY'
    WHERE iteration.iteration_id = task_record.iteration_id;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        dataset_record.dataset_version_id::text || definition_id::text, 0
    ));
    SELECT opportunity_universe_id INTO universe_id
    FROM strategy_training.training_opportunity_universe_versions
    WHERE dataset_version_id = dataset_record.dataset_version_id
      AND opportunity_definition_version_id = definition_id
      AND status = 'READY';
    IF universe_id IS NOT NULL THEN
        INSERT INTO strategy_training.training_iteration_opportunity_universes (
            iteration_id, opportunity_universe_id
        ) VALUES (task_record.iteration_id, universe_id)
        ON CONFLICT (iteration_id) DO NOTHING;
        RETURN universe_id;
    END IF;
    INSERT INTO strategy_training.training_opportunity_universe_versions (
        dataset_version_id, opportunity_definition_version_id, status
    ) VALUES (dataset_record.dataset_version_id, definition_id, 'BUILDING')
    RETURNING opportunity_universe_id INTO universe_id;

    CREATE TEMP TABLE training_l0_opportunity_revisions
    ON COMMIT DROP
    AS
    SELECT DISTINCT ON (bar.instrument_id, bar.open_time)
        bar.instrument_id, bar.open_time, bar.close_time,
        bar.open_price, bar.high_price, bar.low_price, bar.close_price
    FROM market.klines bar
    WHERE bar.price_type = 'TRADE' AND bar.interval_seconds = 300
      AND bar.is_closed AND bar.quality_status = 'VALID'
      AND bar.open_time >= dataset_record.eligible_start_at
      AND bar.open_time < dataset_record.eligible_end_at
                          + dataset_record.label_horizon_duration
      AND bar.effective_at <= dataset_record.source_as_of_at
      AND EXISTS (
          SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
          WHERE pool.dataset_version_id = dataset_record.dataset_version_id
            AND pool.instrument_id = bar.instrument_id
      )
    ORDER BY bar.instrument_id, bar.open_time, bar.revision_no DESC,
             bar.effective_at DESC, bar.collected_at DESC;

    CREATE UNIQUE INDEX ix_training_l0_opportunity_revisions_instrument_time
    ON training_l0_opportunity_revisions (instrument_id, open_time);

    ANALYZE training_l0_opportunity_revisions;

    WITH candidates AS MATERIALIZED (
        SELECT signal.instrument_id, instrument.symbol,
               signal.open_time AS signal_time, entry.open_time AS entry_time,
               entry.open_price AS entry_price, pool.pool_evaluation_id
        FROM training_l0_opportunity_revisions signal
        JOIN training_l0_opportunity_revisions entry
          ON entry.instrument_id = signal.instrument_id
         AND entry.open_time = signal.open_time + interval '5 minutes'
        JOIN core.instruments instrument
          ON instrument.instrument_id = signal.instrument_id
        JOIN LATERAL (
            SELECT evaluation.pool_evaluation_id, evaluation.is_eligible
            FROM strategy_training.training_historical_pool_evaluations evaluation
            WHERE evaluation.dataset_version_id = dataset_record.dataset_version_id
              AND evaluation.instrument_id = signal.instrument_id
              AND evaluation.evaluation_at <= signal.open_time
            ORDER BY evaluation.evaluation_at DESC LIMIT 1
        ) pool ON pool.is_eligible
        WHERE signal.open_time >= dataset_record.eligible_start_at
          AND signal.open_time < dataset_record.eligible_end_at
    ), outcomes AS MATERIALIZED (
        SELECT candidate.*,
               path.observed_count,
               GREATEST(0::numeric, path.maximum_high / candidate.entry_price * 100 - 100)
                   AS mfe_percent,
               GREATEST(0::numeric, 100 - path.minimum_low / candidate.entry_price * 100)
                   AS mae_percent,
               path.endpoint_close / candidate.entry_price * 100 - 100 AS return_percent,
               path.path_fingerprint
        FROM candidates candidate
        JOIN LATERAL (
            SELECT count(*) AS observed_count,
                   max(future.high_price) AS maximum_high,
                   min(future.low_price) AS minimum_low,
                   (array_agg(future.close_price ORDER BY future.close_time DESC))[1]
                       AS endpoint_close,
                   encode(public.digest(string_agg(
                       concat_ws('|', future.close_time::text,
                           future.high_price::text, future.low_price::text,
                           future.close_price::text), E'\n' ORDER BY future.close_time
                   ), 'sha256'), 'hex') AS path_fingerprint
            FROM training_l0_opportunity_revisions future
            WHERE future.instrument_id = candidate.instrument_id
              AND future.open_time >= candidate.entry_time
              AND future.close_time <= candidate.entry_time
                                     + dataset_record.label_horizon_duration
        ) path ON true
    ), classified AS (
        SELECT outcome.*,
               CASE WHEN outcome.observed_count =
                    extract(epoch FROM dataset_record.label_horizon_duration)::integer / 300
                    THEN '[]'::jsonb ELSE '["INCOMPLETE_PATH"]'::jsonb END
               || CASE WHEN outcome.mfe_percent <
                    (definition_json ->> 'minimum_mfe_percent')::numeric
                    THEN '["MFE_BELOW_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
               || CASE WHEN outcome.mae_percent >
                    (definition_json ->> 'maximum_mae_percent')::numeric
                    THEN '["MAE_ABOVE_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
               || CASE WHEN outcome.return_percent <
                    (definition_json ->> 'minimum_return_percent')::numeric
                    THEN '["RETURN_BELOW_THRESHOLD"]'::jsonb ELSE '[]'::jsonb END
                   AS reasons
        FROM outcomes outcome
    )
    INSERT INTO strategy_training.training_opportunity_universe_events (
        opportunity_event_id, opportunity_universe_id, instrument_id, symbol,
        signal_time, entry_time, entry_price, direction, pool_evaluation_id,
        mfe_percent, mae_percent, return_percent, is_opportunity,
        reason_codes, path_fingerprint, truth_fingerprint
    )
    SELECT encode(public.digest(concat_ws('|', dataset_record.dataset_version_id::text,
               definition_id::text, classified.instrument_id::text,
               classified.signal_time::text, 'LONG'), 'sha256'), 'hex'),
           universe_id, classified.instrument_id, classified.symbol,
           classified.signal_time, classified.entry_time, classified.entry_price,
           'LONG', classified.pool_evaluation_id, classified.mfe_percent,
           classified.mae_percent, classified.return_percent,
           jsonb_array_length(classified.reasons) = 0, classified.reasons,
           classified.path_fingerprint,
           encode(public.digest(jsonb_build_object(
               'definition_id', definition_id,
               'instrument_id', classified.instrument_id,
               'is_opportunity', jsonb_array_length(classified.reasons) = 0,
               'path_fingerprint', classified.path_fingerprint,
               'reason_codes', classified.reasons,
               'signal_time', classified.signal_time
           )::text, 'sha256'), 'hex')
    FROM classified;

    SELECT count(*) FILTER (WHERE reason_codes ? 'INCOMPLETE_PATH'),
           count(*), count(*) FILTER (WHERE is_opportunity)
    INTO incomplete_count, event_count_value, opportunity_count_value
    FROM strategy_training.training_opportunity_universe_events
    WHERE opportunity_universe_id = universe_id;
    IF event_count_value = 0 OR incomplete_count > 0 THEN
        RAISE EXCEPTION 'opportunity universe is empty or contains % incomplete paths',
            incomplete_count USING ERRCODE = '23514';
    END IF;
    SELECT encode(public.digest(string_agg(
        event.opportunity_event_id::text || '|' || event.truth_fingerprint::text,
        E'\n' ORDER BY event.opportunity_event_id
    ), 'sha256'), 'hex') INTO STRICT universe_hash
    FROM strategy_training.training_opportunity_universe_events event
    WHERE event.opportunity_universe_id = universe_id;
    UPDATE strategy_training.training_opportunity_universe_versions
    SET status = 'READY', event_count = event_count_value,
        opportunity_count = opportunity_count_value,
        universe_fingerprint = universe_hash, completed_at = clock_timestamp()
    WHERE opportunity_universe_id = universe_id;
    INSERT INTO strategy_training.training_iteration_opportunity_universes (
        iteration_id, opportunity_universe_id
    ) VALUES (task_record.iteration_id, universe_id);
    RETURN universe_id;
END
$$;

ALTER FUNCTION strategy_training.build_training_opportunity_universe(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.build_training_opportunity_universe(uuid, uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.build_training_opportunity_universe(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '074_training_l0_opportunity_universe_indexes',
    encode(public.digest(
        'auto_trade_v2_074_training_l0_opportunity_universe_indexes_v1', 'sha256'
    ), 'hex'),
    'Index frozen L0 K-line paths and historical pool point-in-time lookups'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
