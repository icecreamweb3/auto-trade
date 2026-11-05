\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- The only training-writer entry point now computes canonical facts itself.
-- Keep row-level structural checks, but do not recompute the complete Top-N
-- universe once per inserted row.
CREATE OR REPLACE FUNCTION strategy_training.guard_historical_pool_evaluation_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    eligible_rules jsonb;
    expected_symbol text;
BEGIN
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR UPDATE;
    IF dataset_record.status <> 'BUILDING' THEN
        RAISE EXCEPTION 'historical pool facts require a BUILDING dataset'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.evaluation_at < dataset_record.eligible_start_at
       OR NEW.evaluation_at >= dataset_record.eligible_end_at THEN
        RAISE EXCEPTION 'historical pool evaluation is outside eligible range'
            USING ERRCODE = '23514';
    END IF;

    SELECT config.config_json INTO STRICT eligible_rules
    FROM strategy_training.training_dataset_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.dataset_version_id = NEW.dataset_version_id
      AND binding.config_type = 'ELIGIBLE_POOL_RULES'
      AND config.status = 'READY';
    SELECT instrument.symbol INTO STRICT expected_symbol
    FROM core.instruments instrument
    WHERE instrument.instrument_id = NEW.instrument_id;

    IF NEW.symbol <> expected_symbol THEN
        RAISE EXCEPTION 'historical pool symbol does not match instrument'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.is_eligible AND (
        NEW.contract_identity <> eligible_rules ->> 'required_contract_type'
        OR NEW.onboard_at IS NULL
        OR NEW.onboard_at + make_interval(
            secs => (eligible_rules
                     ->> 'minimum_listing_age_seconds')::double precision
        ) > NEW.evaluation_at
        OR NEW.exchange_status <> 'TRADING'
        OR NEW.system_status <> 'ACTIVE'
        OR NEW.status_effective_at IS NULL
        OR NEW.status_payload_hash IS NULL
        OR NEW.observed_quote_notional IS NULL
        OR NEW.observed_quote_notional <
            (eligible_rules ->> 'minimum_notional_volume')::numeric
        OR NEW.liquidity_revision_hash IS NULL
    ) THEN
        RAISE EXCEPTION 'eligible historical pool fact lacks contemporaneous evidence'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_historical_pool_day(
    p_dataset_version_id uuid,
    p_evaluation_at timestamptz
)
RETURNS TABLE (
    canonical_count integer,
    preexisting_count integer,
    inserted_count integer,
    final_count integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    canonical_rows jsonb;
BEGIN
    PERFORM 1
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = p_dataset_version_id
      AND dataset.status = 'BUILDING'
      AND p_evaluation_at >= dataset.eligible_start_at
      AND p_evaluation_at < dataset.eligible_end_at
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'historical pool day requires a BUILDING in-range dataset'
            USING ERRCODE = '55000';
    END IF;

    SELECT jsonb_agg(to_jsonb(canonical) ORDER BY canonical.symbol)
    INTO canonical_rows
    FROM strategy_training.historical_instrument_universe(
        p_dataset_version_id, p_evaluation_at
    ) canonical;
    IF canonical_rows IS NULL OR jsonb_array_length(canonical_rows) = 0 THEN
        RAISE EXCEPTION 'controlled historical universe returned no instruments'
            USING ERRCODE = '23514';
    END IF;
    canonical_count := jsonb_array_length(canonical_rows);

    SELECT count(*)::integer
    INTO preexisting_count
    FROM strategy_training.training_historical_pool_evaluations existing
    WHERE existing.dataset_version_id = p_dataset_version_id
      AND existing.evaluation_at = p_evaluation_at;

    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_historical_pool_evaluations existing
        WHERE existing.dataset_version_id = p_dataset_version_id
          AND existing.evaluation_at = p_evaluation_at
          AND NOT EXISTS (
              SELECT 1
              FROM jsonb_to_recordset(canonical_rows) AS canonical(
                  instrument_id bigint,
                  symbol varchar(32),
                  evaluation_at timestamptz,
                  onboard_at timestamptz,
                  contract_identity text,
                  exchange_status varchar(32),
                  system_status varchar(32),
                  status_effective_at timestamptz,
                  status_payload_hash char(64),
                  observed_quote_notional numeric,
                  liquidity_observed_at timestamptz,
                  liquidity_revision_hash char(64),
                  is_eligible boolean,
                  rejection_codes jsonb
              )
              WHERE canonical.instrument_id = existing.instrument_id
                AND canonical.symbol IS NOT DISTINCT FROM existing.symbol
                AND canonical.onboard_at IS NOT DISTINCT FROM existing.onboard_at
                AND canonical.contract_identity
                    IS NOT DISTINCT FROM existing.contract_identity
                AND canonical.exchange_status
                    IS NOT DISTINCT FROM existing.exchange_status
                AND canonical.system_status IS NOT DISTINCT FROM existing.system_status
                AND canonical.status_effective_at
                    IS NOT DISTINCT FROM existing.status_effective_at
                AND canonical.status_payload_hash
                    IS NOT DISTINCT FROM existing.status_payload_hash
                AND canonical.observed_quote_notional
                    IS NOT DISTINCT FROM existing.observed_quote_notional
                AND canonical.liquidity_observed_at
                    IS NOT DISTINCT FROM existing.liquidity_observed_at
                AND canonical.liquidity_revision_hash
                    IS NOT DISTINCT FROM existing.liquidity_revision_hash
                AND canonical.is_eligible = existing.is_eligible
                AND canonical.rejection_codes = existing.rejection_codes
          )
    ) THEN
        RAISE EXCEPTION 'existing historical pool day differs from canonical query'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO strategy_training.training_historical_pool_evaluations (
        pool_evaluation_id, dataset_version_id, instrument_id, symbol,
        evaluation_at, onboard_at, contract_identity, exchange_status,
        system_status, status_effective_at, status_payload_hash,
        observed_quote_notional, liquidity_observed_at,
        liquidity_revision_hash, is_eligible, rejection_codes,
        evidence_json, evidence_hash
    )
    SELECT gen_random_uuid(), p_dataset_version_id,
           canonical.instrument_id, canonical.symbol,
           canonical.evaluation_at, canonical.onboard_at,
           canonical.contract_identity, canonical.exchange_status,
           canonical.system_status, canonical.status_effective_at,
           canonical.status_payload_hash, canonical.observed_quote_notional,
           canonical.liquidity_observed_at,
           canonical.liquidity_revision_hash, canonical.is_eligible,
           canonical.rejection_codes,
           evidence.value,
           encode(public.digest(evidence.value::text, 'sha256'), 'hex')
    FROM jsonb_to_recordset(canonical_rows) AS canonical(
        instrument_id bigint,
        symbol varchar(32),
        evaluation_at timestamptz,
        onboard_at timestamptz,
        contract_identity text,
        exchange_status varchar(32),
        system_status varchar(32),
        status_effective_at timestamptz,
        status_payload_hash char(64),
        observed_quote_notional numeric,
        liquidity_observed_at timestamptz,
        liquidity_revision_hash char(64),
        is_eligible boolean,
        rejection_codes jsonb
    )
    CROSS JOIN LATERAL (
        SELECT jsonb_build_object(
            'policy', 'HISTORICAL_EXCHANGE_STATUS_OR_KLINE_24H_VOLUME_V1',
            'evaluation_at', canonical.evaluation_at,
            'symbol', canonical.symbol,
            'status_payload_hash', canonical.status_payload_hash,
            'liquidity_revision_hash', canonical.liquidity_revision_hash,
            'rejection_codes', canonical.rejection_codes
        ) AS value
    ) evidence
    WHERE NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_historical_pool_evaluations existing
        WHERE existing.dataset_version_id = p_dataset_version_id
          AND existing.evaluation_at = p_evaluation_at
          AND existing.instrument_id = canonical.instrument_id
    );
    GET DIAGNOSTICS inserted_count = ROW_COUNT;

    SELECT count(*)::integer
    INTO final_count
    FROM strategy_training.training_historical_pool_evaluations existing
    WHERE existing.dataset_version_id = p_dataset_version_id
      AND existing.evaluation_at = p_evaluation_at;
    IF final_count <> canonical_count THEN
        RAISE EXCEPTION 'historical pool day is incomplete after controlled insert'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEXT;
END
$$;

COMMENT ON FUNCTION strategy_training.record_historical_pool_day(uuid, timestamptz)
IS 'Compute one canonical D-1 Top-N historical pool once, verify any existing partial facts, and atomically insert only missing facts.';

ALTER FUNCTION strategy_training.guard_historical_pool_evaluation_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_historical_pool_day(uuid, timestamptz)
OWNER TO tb2_training_owner;

REVOKE EXECUTE ON FUNCTION strategy_training.record_historical_pool_evaluation(
    uuid, bigint, text, timestamptz, timestamptz, text, text, text,
    timestamptz, char(64), numeric, timestamptz, char(64), boolean, jsonb, jsonb
) FROM tb2_training_rw;
REVOKE ALL ON FUNCTION strategy_training.record_historical_pool_day(
    uuid, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.record_historical_pool_day(
    uuid, timestamptz
) TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '059_training_historical_pool_daily_batch',
    encode(digest(
        'auto_trade_v2_059_training_historical_pool_daily_batch_v1',
        'sha256'
    ), 'hex'),
    'Compute and persist each governed historical Top-N pool once per day'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
