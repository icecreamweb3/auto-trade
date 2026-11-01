\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.training_kline_source_shard(
    p_dataset_version_id uuid,
    p_instrument_id bigint,
    p_member_start_at timestamptz,
    p_member_end_at timestamptz
)
RETURNS TABLE (
    source_schema text,
    source_table text,
    source_shard_identity text,
    member_start_at timestamptz,
    member_end_at timestamptz,
    source_revision_watermark jsonb,
    member_hash char(64),
    shard_fingerprint char(64),
    normalized_query_hash char(64),
    row_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $$
    WITH dataset AS (
        SELECT interval_seconds, source_as_of_at, warmup_start_at, label_window_end_at
        FROM strategy_training.training_dataset_versions
        WHERE dataset_version_id = p_dataset_version_id
          AND status = 'BUILDING'
          AND p_member_start_at >= warmup_start_at
          AND p_member_end_at <= label_window_end_at
          AND p_member_start_at < p_member_end_at
    ), ranked AS (
        SELECT kline.open_time, kline.close_time, kline.revision_no,
               kline.effective_at, kline.collected_at, kline.payload_hash,
               row_number() OVER (
                   PARTITION BY kline.open_time
                   ORDER BY kline.revision_no DESC, kline.effective_at DESC,
                            kline.collected_at DESC
               ) AS revision_rank
        FROM dataset
        JOIN market.klines kline
          ON kline.instrument_id = p_instrument_id
         AND kline.price_type = 'TRADE'
         AND kline.interval_seconds = dataset.interval_seconds
         AND kline.open_time >= p_member_start_at
         AND kline.open_time < p_member_end_at
         AND kline.effective_at <= dataset.source_as_of_at
        WHERE kline.is_closed AND kline.quality_status = 'VALID'
    ), selected AS (
        SELECT * FROM ranked WHERE revision_rank = 1
    ), aggregate_values AS (
        SELECT dataset.interval_seconds, dataset.source_as_of_at,
               count(selected.open_time)::bigint AS selected_count,
               max(selected.revision_no) AS maximum_revision_no,
               max(selected.effective_at) AS maximum_effective_at,
               max(selected.collected_at) AS maximum_collected_at,
               encode(public.digest(string_agg(
                   concat_ws(':',
                       to_char(selected.open_time AT TIME ZONE 'UTC',
                               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                       selected.revision_no::text, selected.payload_hash
                   ), '|' ORDER BY selected.open_time
               ), 'sha256'), 'hex')::char(64) AS computed_member_hash
        FROM dataset
        LEFT JOIN selected ON true
        GROUP BY dataset.interval_seconds, dataset.source_as_of_at
        HAVING count(selected.open_time) > 0
    ), canonical AS (
        SELECT 'market'::text AS computed_source_schema,
               'klines'::text AS computed_source_table,
               concat_ws(':', 'instrument', p_instrument_id::text, 'TRADE',
                   aggregate_values.interval_seconds::text,
                   to_char(p_member_start_at AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                   to_char(p_member_end_at AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
               ) AS computed_identity,
               jsonb_build_object(
                   'maximum_revision_no', aggregate_values.maximum_revision_no,
                   'maximum_effective_at', aggregate_values.maximum_effective_at,
                   'maximum_collected_at', aggregate_values.maximum_collected_at,
                   'source_as_of_at', aggregate_values.source_as_of_at
               ) AS computed_watermark,
               aggregate_values.computed_member_hash,
               encode(public.digest(
                   'training_kline_source_shard:v1:highest_revision_effective_lte_source_as_of:left_closed_right_open',
                   'sha256'
               ), 'hex')::char(64) AS computed_query_hash,
               aggregate_values.selected_count
        FROM aggregate_values
    )
    SELECT canonical.computed_source_schema,
           canonical.computed_source_table,
           canonical.computed_identity,
           p_member_start_at,
           p_member_end_at,
           canonical.computed_watermark,
           canonical.computed_member_hash,
           encode(public.digest(concat_ws('|',
               canonical.computed_source_schema,
               canonical.computed_source_table,
               canonical.computed_identity,
               to_char(p_member_start_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               to_char(p_member_end_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               canonical.selected_count::text,
               canonical.computed_member_hash,
               canonical.computed_query_hash,
               canonical.computed_watermark::text
           ), 'sha256'), 'hex')::char(64),
           canonical.computed_query_hash,
           canonical.selected_count
    FROM canonical
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_kline_dataset_member(
    p_dataset_version_id uuid,
    p_instrument_id bigint,
    p_member_start_at timestamptz,
    p_member_end_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    shard record;
BEGIN
    SELECT * INTO STRICT shard
    FROM strategy_training.training_kline_source_shard(
        p_dataset_version_id, p_instrument_id, p_member_start_at, p_member_end_at
    );

    INSERT INTO strategy_training.training_dataset_members (
        dataset_member_id, dataset_version_id, source_schema, source_table,
        source_shard_identity, member_start_at, member_end_at,
        source_revision_watermark, member_hash, shard_fingerprint,
        normalized_query_hash, row_count
    ) VALUES (
        new_id, p_dataset_version_id, shard.source_schema, shard.source_table,
        shard.source_shard_identity, shard.member_start_at, shard.member_end_at,
        shard.source_revision_watermark, shard.member_hash, shard.shard_fingerprint,
        shard.normalized_query_hash, shard.row_count
    );
    RETURN new_id;
EXCEPTION WHEN no_data_found THEN
    RAISE EXCEPTION 'no governed Kline rows exist for the requested shard'
        USING ERRCODE = '23514';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_quality_report_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    expected_rule_id uuid;
    dataset_status text;
    dataset_interval_seconds integer;
    dataset_warmup_start timestamptz;
    dataset_label_window_end timestamptz;
    governed_expected bigint;
    governed_observed bigint;
    governed_warmup_complete boolean;
    quality_config jsonb;
    dependency_rule jsonb;
    computed_pass boolean;
BEGIN
    SELECT data_quality_rule_version_id, status, interval_seconds,
           warmup_start_at, label_window_end_at
    INTO STRICT expected_rule_id, dataset_status, dataset_interval_seconds,
                dataset_warmup_start, dataset_label_window_end
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR UPDATE;
    IF NEW.data_quality_rule_version_id <> expected_rule_id THEN
        RAISE EXCEPTION 'quality report rule version must match its dataset'
            USING ERRCODE = '23514';
    END IF;
    IF dataset_status <> 'BUILDING' THEN
        RAISE EXCEPTION 'quality reports may only be added while dataset is BUILDING'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.dependency_name = 'KLINE' THEN
        SELECT sum(ceil(extract(epoch FROM member_end_at - member_start_at)
                        / dataset_interval_seconds))::bigint,
               sum(row_count)::bigint,
               min(member_start_at) <= dataset_warmup_start
                   AND max(member_end_at) >= dataset_label_window_end
        INTO governed_expected, governed_observed, governed_warmup_complete
        FROM strategy_training.training_dataset_members
        WHERE dataset_version_id = NEW.dataset_version_id
          AND source_schema = 'market' AND source_table = 'klines';

        IF governed_expected IS NULL
           OR NEW.expected_row_count <> governed_expected
           OR NEW.observed_row_count <> governed_observed
           OR NEW.missing_row_count <> governed_expected - governed_observed
           OR NEW.warmup_complete <> governed_warmup_complete THEN
            RAISE EXCEPTION 'KLINE quality counts/warmup must match trusted members'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.effective_sample_count <> governed_observed
           OR NEW.effective_fold_count <> 1 THEN
            RAISE EXCEPTION 'KLINE effective samples/folds must match governed scope'
                USING ERRCODE = '23514';
        END IF;

        SELECT config_json INTO STRICT quality_config
        FROM strategy_training.training_config_versions
        WHERE config_version_id = NEW.data_quality_rule_version_id
          AND status = 'READY';
        dependency_rule := quality_config -> 'dependency_rules' -> 'KLINE';
        computed_pass :=
            NEW.coverage_ratio >= (dependency_rule ->> 'minimum_coverage')::numeric
            AND NEW.effective_sample_count >=
                (dependency_rule ->> 'minimum_effective_samples')::bigint
            AND NEW.effective_fold_count >=
                (dependency_rule ->> 'minimum_effective_folds')::integer
            AND (
                NOT (dependency_rule ->> 'warmup_required')::boolean
                OR NEW.warmup_complete
            );
        IF computed_pass <> (NEW.status = 'PASS') THEN
            RAISE EXCEPTION 'KLINE quality status does not match READY thresholds'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

ALTER FUNCTION strategy_training.training_kline_source_shard(
    uuid, bigint, timestamptz, timestamptz
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_kline_dataset_member(
    uuid, bigint, timestamptz, timestamptz
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_quality_report_insert()
OWNER TO tb2_training_owner;

REVOKE EXECUTE ON FUNCTION strategy_training.record_training_dataset_member(
    uuid, text, text, text, timestamptz, timestamptz, jsonb,
    char(64), char(64), char(64), bigint
) FROM tb2_training_rw;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.training_kline_source_shard(
        uuid, bigint, timestamptz, timestamptz
    ),
    strategy_training.record_training_kline_dataset_member(
        uuid, bigint, timestamptz, timestamptz
    )
TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '025_training_trusted_kline_shards',
    encode(digest('auto_trade_v2_025_training_trusted_kline_shards_v1', 'sha256'), 'hex'),
    'Compute Kline source revisions and member fingerprints inside trusted SQL'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
