\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_historical_pool_evaluations (
    pool_evaluation_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id       uuid NOT NULL
                             REFERENCES strategy_training.training_dataset_versions,
    instrument_id            bigint NOT NULL REFERENCES core.instruments(instrument_id),
    symbol                   varchar(32) NOT NULL,
    evaluation_at            timestamptz NOT NULL,
    onboard_at               timestamptz,
    contract_identity        varchar(64) NOT NULL,
    exchange_status          varchar(32),
    system_status            varchar(32),
    status_effective_at      timestamptz,
    status_payload_hash      char(64),
    observed_quote_notional  numeric(38, 18),
    liquidity_observed_at    timestamptz,
    liquidity_revision_hash  char(64),
    is_eligible              boolean NOT NULL,
    rejection_codes          jsonb NOT NULL,
    evidence_json            jsonb NOT NULL,
    evidence_hash            char(64) NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(symbol) <> ''),
    CHECK (btrim(contract_identity) <> ''),
    CHECK (status_effective_at IS NULL OR status_effective_at <= evaluation_at),
    CHECK (liquidity_observed_at IS NULL OR liquidity_observed_at <= evaluation_at),
    CHECK (status_payload_hash IS NULL OR status_payload_hash ~ '^[0-9a-f]{64}$'),
    CHECK (liquidity_revision_hash IS NULL OR liquidity_revision_hash ~ '^[0-9a-f]{64}$'),
    CHECK (observed_quote_notional IS NULL OR observed_quote_notional >= 0),
    CHECK (jsonb_typeof(rejection_codes) = 'array'),
    CHECK (
        (is_eligible AND jsonb_array_length(rejection_codes) = 0)
        OR (NOT is_eligible AND jsonb_array_length(rejection_codes) > 0)
    ),
    CHECK (jsonb_typeof(evidence_json) = 'object'),
    CHECK (evidence_json <> '{}'::jsonb),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (evidence_hash = encode(public.digest(evidence_json::text, 'sha256'), 'hex')),
    UNIQUE (dataset_version_id, instrument_id, evaluation_at)
);

CREATE INDEX ix_training_historical_pool_dataset_time
ON strategy_training.training_historical_pool_evaluations (
    dataset_version_id, evaluation_at, is_eligible, symbol
);

CREATE TABLE strategy_training.training_resource_preflight_reports (
    resource_preflight_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id                    uuid NOT NULL
                                          REFERENCES strategy_training.training_dataset_versions,
    resource_limit_config_version_id      uuid NOT NULL
                                          REFERENCES strategy_training.training_config_versions,
    estimated_candidate_count             bigint NOT NULL CHECK (estimated_candidate_count >= 0),
    estimated_signal_count                bigint NOT NULL CHECK (estimated_signal_count >= 0),
    estimated_decision_row_count          bigint NOT NULL CHECK (estimated_decision_row_count >= 0),
    estimated_storage_bytes               bigint NOT NULL CHECK (estimated_storage_bytes >= 0),
    estimated_db_workers                  integer NOT NULL CHECK (estimated_db_workers > 0),
    estimated_pool_connections            integer NOT NULL CHECK (estimated_pool_connections > 0),
    estimated_statement_seconds           integer NOT NULL CHECK (estimated_statement_seconds > 0),
    estimated_work_mem_bytes              bigint NOT NULL CHECK (estimated_work_mem_bytes > 0),
    estimated_cpu                         numeric(12, 4) NOT NULL CHECK (estimated_cpu > 0),
    estimated_memory_bytes                bigint NOT NULL CHECK (estimated_memory_bytes > 0),
    estimated_temp_bytes                  bigint NOT NULL CHECK (estimated_temp_bytes >= 0),
    available_temp_bytes                  bigint NOT NULL CHECK (available_temp_bytes >= 0),
    status                                varchar(16) NOT NULL CHECK (status IN ('PASS', 'BLOCKED')),
    blocking_reasons                      jsonb NOT NULL,
    evidence_json                         jsonb NOT NULL,
    evidence_hash                         char(64) NOT NULL,
    created_at                            timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(blocking_reasons) = 'array'),
    CHECK (
        (status = 'PASS' AND jsonb_array_length(blocking_reasons) = 0)
        OR (status = 'BLOCKED' AND jsonb_array_length(blocking_reasons) > 0)
    ),
    CHECK (jsonb_typeof(evidence_json) = 'object'),
    CHECK (evidence_json <> '{}'::jsonb),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (evidence_hash = encode(public.digest(evidence_json::text, 'sha256'), 'hex')),
    UNIQUE (dataset_version_id, resource_limit_config_version_id)
);

CREATE OR REPLACE FUNCTION strategy_training.historical_instrument_universe(
    p_dataset_version_id uuid,
    p_evaluation_at timestamptz
)
RETURNS TABLE (
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $$
    WITH dataset AS (
        SELECT version.dataset_version_id, version.eligible_start_at, version.eligible_end_at,
               version.source_as_of_at, config.config_json AS eligible_rules
        FROM strategy_training.training_dataset_versions version
        JOIN strategy_training.training_dataset_config_bindings binding
          ON binding.dataset_version_id = version.dataset_version_id
         AND binding.config_type = 'ELIGIBLE_POOL_RULES'
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
         AND config.config_type = 'ELIGIBLE_POOL_RULES'
         AND config.status = 'READY'
        WHERE version.dataset_version_id = p_dataset_version_id
          AND version.status = 'BUILDING'
          AND p_evaluation_at >= version.eligible_start_at
          AND p_evaluation_at < version.eligible_end_at
    ), candidates AS (
        SELECT instrument.instrument_id, instrument.symbol, instrument.onboard_at,
               instrument.quote_asset || '_' || instrument.contract_type AS contract_identity,
               dataset.source_as_of_at, dataset.eligible_rules
        FROM dataset
        CROSS JOIN core.instruments instrument
        WHERE instrument.exchange = 'BINANCE'
          AND instrument.market = 'USD_M_FUTURES'
          AND instrument.first_seen_at <= dataset.source_as_of_at
    ), observations AS (
        SELECT candidate.*,
               status.exchange_status, status.system_status,
               status.effective_at AS status_effective_at,
               status.payload_hash AS status_payload_hash,
               liquidity.quote_notional AS observed_quote_notional,
               liquidity.observed_at AS liquidity_observed_at,
               liquidity.revision_hash AS liquidity_revision_hash
        FROM candidates candidate
        LEFT JOIN LATERAL (
            SELECT history.exchange_status, history.system_status,
                   history.effective_at, history.payload_hash
            FROM core.instrument_status_history history
            WHERE history.instrument_id = candidate.instrument_id
              AND history.effective_at <= p_evaluation_at
              AND history.created_at <= candidate.source_as_of_at
            ORDER BY history.effective_at DESC, history.created_at DESC
            LIMIT 1
        ) status ON true
        LEFT JOIN LATERAL (
            SELECT sum(revision.quote_volume) AS quote_notional,
                   max(revision.close_time) AS observed_at,
                   encode(
                       public.digest(
                           string_agg(
                               revision.open_time::text || ':' || revision.revision_no::text
                               || ':' || revision.payload_hash,
                               '|' ORDER BY revision.open_time
                           ),
                           'sha256'
                       ),
                       'hex'
                   )::char(64) AS revision_hash
            FROM (
                SELECT DISTINCT ON (bar.open_time)
                       bar.open_time, bar.close_time, bar.revision_no,
                       bar.quote_volume, bar.payload_hash
                FROM market.klines bar
                WHERE bar.instrument_id = candidate.instrument_id
                  AND bar.price_type = 'TRADE'
                  AND bar.interval_seconds = 300
                  AND bar.is_closed
                  AND bar.quality_status = 'VALID'
                  AND bar.close_time <= p_evaluation_at
                  AND bar.open_time >= p_evaluation_at - make_interval(
                      secs => (candidate.eligible_rules ->> 'liquidity_lookback_seconds')::double precision
                  )
                  AND bar.effective_at <= candidate.source_as_of_at
                ORDER BY bar.open_time, bar.revision_no DESC
            ) revision
        ) liquidity ON true
    ), classified AS (
        SELECT observation.*,
               array_remove(ARRAY[
                   CASE WHEN observation.contract_identity <>
                       observation.eligible_rules ->> 'required_contract_type'
                       THEN 'CONTRACT_TYPE_NOT_ALLOWED' END,
                   CASE WHEN observation.onboard_at IS NULL
                       THEN 'MISSING_ONBOARD_TIME' END,
                   CASE WHEN observation.onboard_at IS NOT NULL AND
                       observation.onboard_at + make_interval(
                           secs => (observation.eligible_rules
                                    ->> 'minimum_listing_age_seconds')::double precision
                       ) > p_evaluation_at THEN 'LISTING_AGE_TOO_SHORT' END,
                   CASE WHEN observation.status_effective_at IS NULL
                       THEN 'MISSING_STATUS_HISTORY' END,
                   CASE WHEN observation.exchange_status IS DISTINCT FROM 'TRADING'
                       OR observation.system_status IS DISTINCT FROM 'ACTIVE'
                       THEN 'NOT_TRADING_AT_EVALUATION' END,
                   CASE WHEN observation.observed_quote_notional IS NULL
                       THEN 'MISSING_LIQUIDITY' END,
                   CASE WHEN observation.observed_quote_notional IS NOT NULL AND
                       observation.observed_quote_notional <
                           (observation.eligible_rules ->> 'minimum_notional_volume')::numeric
                       THEN 'INSUFFICIENT_LIQUIDITY' END
               ]::text[], NULL) AS reasons
        FROM observations observation
    )
    SELECT classified.instrument_id, classified.symbol, p_evaluation_at,
           classified.onboard_at, classified.contract_identity,
           classified.exchange_status, classified.system_status,
           classified.status_effective_at, classified.status_payload_hash,
           classified.observed_quote_notional, classified.liquidity_observed_at,
           classified.liquidity_revision_hash,
           cardinality(classified.reasons) = 0,
           to_jsonb(classified.reasons)
    FROM classified
    ORDER BY classified.symbol
$$;

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
    FROM core.instruments instrument WHERE instrument.instrument_id = NEW.instrument_id;

    IF NEW.symbol <> expected_symbol THEN
        RAISE EXCEPTION 'historical pool symbol does not match instrument'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.historical_instrument_universe(
            NEW.dataset_version_id, NEW.evaluation_at
        ) canonical
        WHERE canonical.instrument_id = NEW.instrument_id
          AND canonical.symbol IS NOT DISTINCT FROM NEW.symbol
          AND canonical.onboard_at IS NOT DISTINCT FROM NEW.onboard_at
          AND canonical.contract_identity IS NOT DISTINCT FROM NEW.contract_identity
          AND canonical.exchange_status IS NOT DISTINCT FROM NEW.exchange_status
          AND canonical.system_status IS NOT DISTINCT FROM NEW.system_status
          AND canonical.status_effective_at IS NOT DISTINCT FROM NEW.status_effective_at
          AND canonical.status_payload_hash IS NOT DISTINCT FROM NEW.status_payload_hash
          AND canonical.observed_quote_notional
              IS NOT DISTINCT FROM NEW.observed_quote_notional
          AND canonical.liquidity_observed_at
              IS NOT DISTINCT FROM NEW.liquidity_observed_at
          AND canonical.liquidity_revision_hash
              IS NOT DISTINCT FROM NEW.liquidity_revision_hash
          AND canonical.is_eligible = NEW.is_eligible
          AND canonical.rejection_codes = NEW.rejection_codes
    ) THEN
        RAISE EXCEPTION 'historical pool fact does not match controlled as-of query'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.is_eligible AND (
        NEW.contract_identity <> eligible_rules ->> 'required_contract_type'
        OR NEW.onboard_at IS NULL
        OR NEW.onboard_at + make_interval(
            secs => (eligible_rules ->> 'minimum_listing_age_seconds')::double precision
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

CREATE OR REPLACE FUNCTION strategy_training.guard_resource_preflight_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_status text;
    limits jsonb;
    computed_reasons text[];
BEGIN
    SELECT status INTO STRICT dataset_status
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR UPDATE;
    IF dataset_status <> 'BUILDING' THEN
        RAISE EXCEPTION 'resource preflight requires a BUILDING dataset'
            USING ERRCODE = '55000';
    END IF;
    SELECT config_json INTO STRICT limits
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.resource_limit_config_version_id
      AND config_type = 'RESOURCE_LIMITS' AND status = 'READY';
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_dataset_config_bindings
        WHERE dataset_version_id = NEW.dataset_version_id
          AND config_type = 'RESOURCE_LIMITS'
          AND config_version_id = NEW.resource_limit_config_version_id
    ) THEN
        RAISE EXCEPTION 'resource preflight config must be bound to dataset'
            USING ERRCODE = '23514';
    END IF;

    computed_reasons := array_remove(ARRAY[
        CASE WHEN NEW.estimated_candidate_count > (limits ->> 'max_candidate_count')::bigint
            THEN 'CANDIDATE_COUNT_EXCEEDED' END,
        CASE WHEN NEW.estimated_signal_count > (limits ->> 'max_signal_count')::bigint
            THEN 'SIGNAL_COUNT_EXCEEDED' END,
        CASE WHEN NEW.estimated_decision_row_count >
            (limits ->> 'max_decision_row_count')::bigint
            THEN 'DECISION_ROW_COUNT_EXCEEDED' END,
        CASE WHEN NEW.estimated_storage_bytes > (limits ->> 'max_storage_bytes')::bigint
            THEN 'STORAGE_EXCEEDED' END,
        CASE WHEN NEW.estimated_db_workers > (limits ->> 'db_workers_per_experiment')::integer
            THEN 'DB_WORKERS_EXCEEDED' END,
        CASE WHEN NEW.estimated_pool_connections > (limits ->> 'pool_connections')::integer
            THEN 'POOL_CONNECTIONS_EXCEEDED' END,
        CASE WHEN NEW.estimated_statement_seconds >
            (limits ->> 'statement_timeout_seconds')::integer
            THEN 'STATEMENT_TIMEOUT_EXCEEDED' END,
        CASE WHEN NEW.estimated_work_mem_bytes > (limits ->> 'work_mem_bytes')::bigint
            THEN 'WORK_MEM_EXCEEDED' END,
        CASE WHEN NEW.estimated_cpu > (limits ->> 'cpu_limit')::numeric
            THEN 'CPU_EXCEEDED' END,
        CASE WHEN NEW.estimated_memory_bytes > (limits ->> 'memory_bytes')::bigint
            THEN 'MEMORY_EXCEEDED' END,
        CASE WHEN NEW.available_temp_bytes - NEW.estimated_temp_bytes <
            (limits ->> 'temp_disk_min_free_bytes')::bigint
            THEN 'TEMP_DISK_WATERMARK_EXCEEDED' END
    ]::text[], NULL);

    IF (cardinality(computed_reasons) = 0) <> (NEW.status = 'PASS')
       OR to_jsonb(computed_reasons) <> NEW.blocking_reasons THEN
        RAISE EXCEPTION 'resource preflight status/reasons do not match READY limits'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_dataset_m2_readiness()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'READY' AND OLD.status <> 'READY' THEN
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
            WHERE pool.dataset_version_id = NEW.dataset_version_id AND pool.is_eligible
        ) THEN
            RAISE EXCEPTION 'READY dataset requires historical eligible-pool evidence'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.training_resource_preflight_reports report
            WHERE report.dataset_version_id = NEW.dataset_version_id
              AND report.status = 'PASS'
        ) THEN
            RAISE EXCEPTION 'READY dataset requires a passing resource preflight'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_dataset(
    p_dataset_type text,
    p_partition text,
    p_partition_start_at timestamptz,
    p_partition_end_at timestamptz,
    p_interval_seconds integer,
    p_warmup_start_at timestamptz,
    p_eligible_start_at timestamptz,
    p_eligible_end_at timestamptz,
    p_label_window_end_at timestamptz,
    p_source_as_of_at timestamptz,
    p_visibility_cutoff_at timestamptz,
    p_fingerprint_schema_version integer,
    p_purge_duration interval,
    p_embargo_duration interval,
    p_ticker_pool_rule_version_id uuid,
    p_data_quality_rule_version_id uuid,
    p_holding_rule_version_id uuid,
    p_label_horizon_duration interval,
    p_max_holding_duration interval,
    p_source_revision_watermark jsonb,
    p_supersedes_dataset_version_id uuid,
    p_created_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_created_by_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_created_by_user_id, 'TRAINING_ADMIN'
    );
    INSERT INTO strategy_training.training_dataset_versions (
        dataset_version_id, dataset_type, partition,
        partition_start_at, partition_end_at, interval_seconds,
        warmup_start_at, eligible_start_at, eligible_end_at, label_window_end_at,
        source_as_of_at, visibility_cutoff_at, fingerprint_schema_version,
        purge_duration, embargo_duration,
        ticker_pool_rule_version_id, data_quality_rule_version_id,
        holding_rule_version_id, label_horizon_duration, max_holding_duration,
        source_revision_watermark, supersedes_dataset_version_id, created_by_user_id
    ) VALUES (
        new_id, p_dataset_type, p_partition,
        p_partition_start_at, p_partition_end_at, p_interval_seconds,
        p_warmup_start_at, p_eligible_start_at, p_eligible_end_at, p_label_window_end_at,
        p_source_as_of_at, p_visibility_cutoff_at, p_fingerprint_schema_version,
        p_purge_duration, p_embargo_duration,
        p_ticker_pool_rule_version_id, p_data_quality_rule_version_id,
        p_holding_rule_version_id, p_label_horizon_duration, p_max_holding_duration,
        p_source_revision_watermark, p_supersedes_dataset_version_id, p_created_by_user_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.bind_training_dataset_config(
    p_dataset_version_id uuid,
    p_config_type text,
    p_config_version_id uuid
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    INSERT INTO strategy_training.training_dataset_config_bindings (
        dataset_version_id, config_type, config_version_id
    ) VALUES (p_dataset_version_id, p_config_type, p_config_version_id)
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_dataset_member(
    p_dataset_version_id uuid,
    p_source_schema text,
    p_source_table text,
    p_source_shard_identity text,
    p_member_start_at timestamptz,
    p_member_end_at timestamptz,
    p_source_revision_watermark jsonb,
    p_member_hash char(64),
    p_shard_fingerprint char(64),
    p_normalized_query_hash char(64),
    p_row_count bigint
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_dataset_members (
        dataset_member_id, dataset_version_id, source_schema, source_table,
        source_shard_identity, member_start_at, member_end_at,
        source_revision_watermark, member_hash, shard_fingerprint,
        normalized_query_hash, row_count
    ) VALUES (
        new_id, p_dataset_version_id, p_source_schema, p_source_table,
        p_source_shard_identity, p_member_start_at, p_member_end_at,
        p_source_revision_watermark, p_member_hash, p_shard_fingerprint,
        p_normalized_query_hash, p_row_count
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_historical_pool_evaluation(
    p_dataset_version_id uuid,
    p_instrument_id bigint,
    p_symbol text,
    p_evaluation_at timestamptz,
    p_onboard_at timestamptz,
    p_contract_identity text,
    p_exchange_status text,
    p_system_status text,
    p_status_effective_at timestamptz,
    p_status_payload_hash char(64),
    p_observed_quote_notional numeric,
    p_liquidity_observed_at timestamptz,
    p_liquidity_revision_hash char(64),
    p_is_eligible boolean,
    p_rejection_codes jsonb,
    p_evidence_json jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_historical_pool_evaluations (
        pool_evaluation_id, dataset_version_id, instrument_id, symbol, evaluation_at,
        onboard_at, contract_identity, exchange_status, system_status,
        status_effective_at, status_payload_hash, observed_quote_notional,
        liquidity_observed_at, liquidity_revision_hash, is_eligible,
        rejection_codes, evidence_json, evidence_hash
    ) VALUES (
        new_id, p_dataset_version_id, p_instrument_id, p_symbol, p_evaluation_at,
        p_onboard_at, p_contract_identity, p_exchange_status, p_system_status,
        p_status_effective_at, p_status_payload_hash, p_observed_quote_notional,
        p_liquidity_observed_at, p_liquidity_revision_hash, p_is_eligible,
        p_rejection_codes, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_quality_report(
    p_dataset_version_id uuid,
    p_data_quality_rule_version_id uuid,
    p_dependency_name text,
    p_dependency_kind text,
    p_is_required boolean,
    p_coverage_ratio numeric,
    p_missing_ratio numeric,
    p_warmup_complete boolean,
    p_effective_sample_count bigint,
    p_effective_fold_count integer,
    p_expected_row_count bigint,
    p_observed_row_count bigint,
    p_missing_row_count bigint,
    p_status text,
    p_blocking_reason text,
    p_evidence_json jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_data_quality_reports (
        quality_report_id, dataset_version_id, data_quality_rule_version_id,
        dependency_name, dependency_kind, is_required, coverage_ratio, missing_ratio,
        warmup_complete, effective_sample_count, effective_fold_count,
        expected_row_count, observed_row_count, missing_row_count,
        status, blocking_reason, evidence_json, evidence_hash
    ) VALUES (
        new_id, p_dataset_version_id, p_data_quality_rule_version_id,
        p_dependency_name, p_dependency_kind, p_is_required,
        p_coverage_ratio, p_missing_ratio, p_warmup_complete,
        p_effective_sample_count, p_effective_fold_count,
        p_expected_row_count, p_observed_row_count, p_missing_row_count,
        p_status, p_blocking_reason, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_resource_preflight(
    p_dataset_version_id uuid,
    p_resource_limit_config_version_id uuid,
    p_estimated_candidate_count bigint,
    p_estimated_signal_count bigint,
    p_estimated_decision_row_count bigint,
    p_estimated_storage_bytes bigint,
    p_estimated_db_workers integer,
    p_estimated_pool_connections integer,
    p_estimated_statement_seconds integer,
    p_estimated_work_mem_bytes bigint,
    p_estimated_cpu numeric,
    p_estimated_memory_bytes bigint,
    p_estimated_temp_bytes bigint,
    p_available_temp_bytes bigint,
    p_status text,
    p_blocking_reasons jsonb,
    p_evidence_json jsonb
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_resource_preflight_reports (
        resource_preflight_id, dataset_version_id, resource_limit_config_version_id,
        estimated_candidate_count, estimated_signal_count,
        estimated_decision_row_count, estimated_storage_bytes,
        estimated_db_workers, estimated_pool_connections,
        estimated_statement_seconds, estimated_work_mem_bytes,
        estimated_cpu, estimated_memory_bytes,
        estimated_temp_bytes, available_temp_bytes,
        status, blocking_reasons, evidence_json, evidence_hash
    ) VALUES (
        new_id, p_dataset_version_id, p_resource_limit_config_version_id,
        p_estimated_candidate_count, p_estimated_signal_count,
        p_estimated_decision_row_count, p_estimated_storage_bytes,
        p_estimated_db_workers, p_estimated_pool_connections,
        p_estimated_statement_seconds, p_estimated_work_mem_bytes,
        p_estimated_cpu, p_estimated_memory_bytes,
        p_estimated_temp_bytes, p_available_temp_bytes,
        p_status, p_blocking_reasons, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_dataset_fingerprint(
    p_dataset_version_id uuid
)
RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    canonical_fingerprint char(64);
BEGIN
    SELECT strategy_training.compute_dataset_root_fingerprint(p_dataset_version_id)
    INTO canonical_fingerprint;
    IF canonical_fingerprint IS NULL THEN
        RAISE EXCEPTION 'dataset fingerprint requires at least one member'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_dataset_versions
    SET root_fingerprint = canonical_fingerprint
    WHERE dataset_version_id = p_dataset_version_id AND status = 'BUILDING';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'dataset fingerprint can only finalize while BUILDING'
            USING ERRCODE = '55000';
    END IF;
    RETURN canonical_fingerprint;
END
$$;

CREATE TRIGGER trg_training_historical_pool_insert_guard
BEFORE INSERT ON strategy_training.training_historical_pool_evaluations
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_historical_pool_evaluation_insert();

CREATE TRIGGER trg_training_historical_pool_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_historical_pool_evaluations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_resource_preflight_insert_guard
BEFORE INSERT ON strategy_training.training_resource_preflight_reports
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_resource_preflight_insert();

CREATE TRIGGER trg_training_resource_preflight_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_resource_preflight_reports
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_dataset_m2_readiness_guard
BEFORE UPDATE ON strategy_training.training_dataset_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_dataset_m2_readiness();

ALTER TABLE strategy_training.training_historical_pool_evaluations
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_resource_preflight_reports
OWNER TO tb2_training_owner;

ALTER FUNCTION strategy_training.historical_instrument_universe(uuid, timestamptz)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_historical_pool_evaluation_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_resource_preflight_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_dataset_m2_readiness()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_dataset(
    text, text, timestamptz, timestamptz, integer,
    timestamptz, timestamptz, timestamptz, timestamptz,
    timestamptz, timestamptz, integer, interval, interval,
    uuid, uuid, uuid, interval, interval, jsonb, uuid, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.bind_training_dataset_config(uuid, text, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_dataset_member(
    uuid, text, text, text, timestamptz, timestamptz, jsonb,
    char(64), char(64), char(64), bigint
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_historical_pool_evaluation(
    uuid, bigint, text, timestamptz, timestamptz, text, text, text,
    timestamptz, char(64), numeric, timestamptz, char(64), boolean, jsonb, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_quality_report(
    uuid, uuid, text, text, boolean, numeric, numeric, boolean,
    bigint, integer, bigint, bigint, bigint, text, text, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_resource_preflight(
    uuid, uuid, bigint, bigint, bigint, bigint, integer, integer,
    integer, bigint, numeric, bigint, bigint, bigint, text, jsonb, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_dataset_fingerprint(uuid)
OWNER TO tb2_training_owner;

GRANT USAGE ON SCHEMA core, market TO tb2_training_owner;
GRANT SELECT ON core.instruments, core.instrument_status_history, market.klines
TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON
    strategy_training.training_historical_pool_evaluations,
    strategy_training.training_resource_preflight_reports
TO tb2_training_rw, tb2_training_evaluator;

GRANT SELECT ON strategy_training.training_resource_preflight_reports
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training.create_training_dataset(
        text, text, timestamptz, timestamptz, integer,
        timestamptz, timestamptz, timestamptz, timestamptz,
        timestamptz, timestamptz, integer, interval, interval,
        uuid, uuid, uuid, interval, interval, jsonb, uuid, uuid
    ),
    strategy_training.bind_training_dataset_config(uuid, text, uuid)
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training.historical_instrument_universe(uuid, timestamptz),
    strategy_training.record_training_dataset_member(
        uuid, text, text, text, timestamptz, timestamptz, jsonb,
        char(64), char(64), char(64), bigint
    ),
    strategy_training.record_historical_pool_evaluation(
        uuid, bigint, text, timestamptz, timestamptz, text, text, text,
        timestamptz, char(64), numeric, timestamptz, char(64), boolean, jsonb, jsonb
    ),
    strategy_training.record_training_quality_report(
        uuid, uuid, text, text, boolean, numeric, numeric, boolean,
        bigint, integer, bigint, bigint, bigint, text, text, jsonb
    ),
    strategy_training.record_training_resource_preflight(
        uuid, uuid, bigint, bigint, bigint, bigint, integer, integer,
        integer, bigint, numeric, bigint, bigint, bigint, text, jsonb, jsonb
    ),
    strategy_training.finalize_training_dataset_fingerprint(uuid)
TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '023_training_dataset_builder',
    encode(digest('auto_trade_v2_023_training_dataset_builder_v1', 'sha256'), 'hex'),
    'Add historical as-of eligibility, explicit resource preflight and controlled dataset writes'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
