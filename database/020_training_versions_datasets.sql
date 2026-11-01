\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_config_versions (
    config_version_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    config_type             varchar(64) NOT NULL,
    semver                  varchar(32) NOT NULL,
    schema_version          integer NOT NULL CHECK (schema_version > 0),
    config_json             jsonb NOT NULL,
    content_hash            char(64) NOT NULL,
    parent_version_id       uuid REFERENCES strategy_training.training_config_versions,
    status                  varchar(16) NOT NULL DEFAULT 'DRAFT'
                            CHECK (status IN ('DRAFT', 'READY', 'RETIRED')),
    created_by_user_id      uuid NOT NULL REFERENCES core.app_users(user_id),
    ready_by_user_id        uuid REFERENCES core.app_users(user_id),
    retired_by_user_id      uuid REFERENCES core.app_users(user_id),
    created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    ready_at                timestamptz,
    retired_at              timestamptz,
    CHECK (btrim(config_type) <> ''),
    CHECK (config_type IN (
        'FACTOR_REGISTRY', 'SEARCH_SPACE', 'SCORING_MODEL_A', 'SCORING_MODEL_B',
        'SCORING_END_TO_END', 'TICKER_POOL_RULES', 'DATA_QUALITY_RULES',
        'HOLDING_HORIZON_RULES', 'ELIGIBLE_POOL_RULES',
        'REPRODUCIBILITY_TOLERANCE', 'RESOURCE_LIMITS', 'SLIPPAGE_MODEL',
        'VISIBILITY_CUTOFF_POLICY', 'EXIT_RULES', 'FEE_MODEL', 'PORTFOLIO_RULES',
        'OPPORTUNITY_DEFINITION', 'RANDOM_BASELINE', 'MODEL_B_SAMPLE_MIX',
        'CROSS_FIT_PROTOCOL', 'VALIDATION_PROTOCOL', 'RETENTION_POLICY'
    )),
    CHECK (semver ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
    CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (content_hash = encode(digest(config_json::text, 'sha256'), 'hex')),
    CHECK (parent_version_id IS NULL OR parent_version_id <> config_version_id),
    CHECK (
        (status = 'DRAFT' AND ready_at IS NULL AND ready_by_user_id IS NULL
                          AND retired_at IS NULL AND retired_by_user_id IS NULL)
        OR (status = 'READY' AND ready_at IS NOT NULL AND ready_by_user_id IS NOT NULL
                             AND retired_at IS NULL AND retired_by_user_id IS NULL)
        OR (status = 'RETIRED' AND ready_at IS NOT NULL AND ready_by_user_id IS NOT NULL
                               AND retired_at IS NOT NULL AND retired_by_user_id IS NOT NULL)
    ),
    UNIQUE (config_type, semver)
);

CREATE INDEX ix_training_config_versions_status
ON strategy_training.training_config_versions (config_type, status, created_at DESC);

CREATE TABLE strategy_training.training_dataset_versions (
    dataset_version_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_type                varchar(32) NOT NULL,
    partition                   varchar(16) NOT NULL
                                CHECK (partition IN ('TRAIN', 'VALIDATION')),
    partition_start_at          timestamptz NOT NULL,
    partition_end_at            timestamptz NOT NULL,
    interval_seconds            integer NOT NULL CHECK (interval_seconds > 0),
    warmup_start_at             timestamptz NOT NULL,
    eligible_start_at           timestamptz NOT NULL,
    eligible_end_at             timestamptz NOT NULL,
    label_window_end_at         timestamptz NOT NULL,
    source_as_of_at             timestamptz NOT NULL,
    visibility_cutoff_at        timestamptz NOT NULL,
    fingerprint_schema_version  integer NOT NULL CHECK (fingerprint_schema_version > 0),
    purge_duration              interval NOT NULL CHECK (purge_duration >= interval '0'),
    embargo_duration            interval NOT NULL CHECK (embargo_duration >= interval '0'),
    ticker_pool_rule_version_id uuid NOT NULL,
    data_quality_rule_version_id uuid NOT NULL,
    holding_rule_version_id     uuid NOT NULL,
    label_horizon_duration      interval NOT NULL CHECK (label_horizon_duration > interval '0'),
    max_holding_duration        interval NOT NULL CHECK (max_holding_duration > interval '0'),
    root_fingerprint            char(64),
    source_revision_watermark   jsonb NOT NULL DEFAULT '{}'::jsonb,
    status                      varchar(16) NOT NULL DEFAULT 'BUILDING'
                                CHECK (status IN (
                                    'BUILDING', 'READY', 'STALE', 'SUPERSEDED',
                                    'INVALID', 'ARCHIVED'
                                )),
    stale_reason                text,
    supersedes_dataset_version_id uuid UNIQUE
                                REFERENCES strategy_training.training_dataset_versions,
    created_by_user_id          uuid NOT NULL REFERENCES core.app_users(user_id),
    created_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
    ready_at                    timestamptz,
    stale_at                    timestamptz,
    superseded_at               timestamptz,
    invalid_at                  timestamptz,
    archived_at                 timestamptz,
    FOREIGN KEY (ticker_pool_rule_version_id)
        REFERENCES strategy_training.training_config_versions (config_version_id),
    FOREIGN KEY (data_quality_rule_version_id)
        REFERENCES strategy_training.training_config_versions (config_version_id),
    FOREIGN KEY (holding_rule_version_id)
        REFERENCES strategy_training.training_config_versions (config_version_id),
    CHECK (btrim(dataset_type) <> ''),
    CHECK (partition_start_at < partition_end_at),
    CHECK (source_as_of_at >= partition_end_at),
    CHECK (visibility_cutoff_at <= partition_start_at),
    CHECK (warmup_start_at <= eligible_start_at),
    CHECK (partition_start_at <= eligible_start_at),
    CHECK (eligible_start_at < eligible_end_at),
    CHECK (eligible_end_at <= label_window_end_at),
    CHECK (label_window_end_at <= partition_end_at),
    CHECK (label_window_end_at = eligible_end_at + label_horizon_duration),
    CHECK (
        eligible_end_at + greatest(label_horizon_duration, max_holding_duration)
        <= partition_end_at
    ),
    CHECK (purge_duration >= greatest(label_horizon_duration, max_holding_duration)),
    CHECK (embargo_duration >= greatest(label_horizon_duration, max_holding_duration)),
    CHECK (interval_seconds % 60 = 0),
    CHECK (root_fingerprint IS NULL OR root_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(source_revision_watermark) = 'object'),
    CHECK (
        supersedes_dataset_version_id IS NULL
        OR supersedes_dataset_version_id <> dataset_version_id
    ),
    CHECK (
        (status = 'BUILDING' AND ready_at IS NULL AND stale_at IS NULL
                             AND superseded_at IS NULL AND invalid_at IS NULL
                             AND archived_at IS NULL)
        OR (status = 'READY' AND ready_at IS NOT NULL AND stale_at IS NULL
                          AND superseded_at IS NULL AND invalid_at IS NULL
                          AND archived_at IS NULL)
        OR (status = 'STALE' AND ready_at IS NOT NULL AND stale_at IS NOT NULL
                          AND stale_reason IS NOT NULL AND btrim(stale_reason) <> ''
                          AND superseded_at IS NULL AND invalid_at IS NULL
                          AND archived_at IS NULL)
        OR (status = 'SUPERSEDED' AND ready_at IS NOT NULL AND stale_at IS NOT NULL
                               AND superseded_at IS NOT NULL AND invalid_at IS NULL
                               AND archived_at IS NULL)
        OR (status = 'INVALID' AND ready_at IS NULL AND invalid_at IS NOT NULL
                            AND stale_at IS NULL AND superseded_at IS NULL
                            AND archived_at IS NULL)
        OR (status = 'ARCHIVED' AND archived_at IS NOT NULL AND invalid_at IS NULL)
    )
);

CREATE INDEX ix_training_dataset_versions_status_range
ON strategy_training.training_dataset_versions (status, partition_start_at, partition_end_at);
CREATE UNIQUE INDEX ux_training_dataset_versions_root_fingerprint
ON strategy_training.training_dataset_versions (root_fingerprint)
WHERE root_fingerprint IS NOT NULL;

CREATE TABLE strategy_training.training_dataset_members (
    dataset_member_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id        uuid NOT NULL
                              REFERENCES strategy_training.training_dataset_versions,
    source_schema             varchar(63) NOT NULL,
    source_table              varchar(63) NOT NULL,
    source_shard_identity     text NOT NULL,
    member_start_at           timestamptz NOT NULL,
    member_end_at             timestamptz NOT NULL,
    source_revision_watermark jsonb NOT NULL,
    member_hash               char(64) NOT NULL CHECK (member_hash ~ '^[0-9a-f]{64}$'),
    shard_fingerprint         char(64) NOT NULL CHECK (shard_fingerprint ~ '^[0-9a-f]{64}$'),
    normalized_query_hash     char(64) NOT NULL
                              CHECK (normalized_query_hash ~ '^[0-9a-f]{64}$'),
    row_count                 bigint NOT NULL CHECK (row_count > 0),
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (source_schema = 'market'),
    CHECK (btrim(source_table) <> ''),
    CHECK (btrim(source_shard_identity) <> ''),
    CHECK (jsonb_typeof(source_revision_watermark) = 'object'),
    CHECK (source_revision_watermark <> '{}'::jsonb),
    CHECK (member_start_at < member_end_at),
    UNIQUE (dataset_version_id, source_schema, source_table, source_shard_identity)
);

CREATE INDEX ix_training_dataset_members_range
ON strategy_training.training_dataset_members (
    dataset_version_id, member_start_at, member_end_at
);

CREATE TABLE strategy_training.training_dataset_config_bindings (
    dataset_version_id   uuid NOT NULL
                         REFERENCES strategy_training.training_dataset_versions,
    config_type          varchar(64) NOT NULL,
    config_version_id    uuid NOT NULL
                         REFERENCES strategy_training.training_config_versions,
    bound_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (dataset_version_id, config_type),
    UNIQUE (dataset_version_id, config_version_id)
);

CREATE TABLE strategy_training.training_data_quality_reports (
    quality_report_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id         uuid NOT NULL
                               REFERENCES strategy_training.training_dataset_versions,
    data_quality_rule_version_id uuid NOT NULL
                               REFERENCES strategy_training.training_config_versions,
    dependency_name            varchar(128) NOT NULL,
    dependency_kind            varchar(32) NOT NULL,
    is_required                boolean NOT NULL,
    coverage_ratio             numeric(12, 10) NOT NULL
                               CHECK (coverage_ratio BETWEEN 0 AND 1),
    missing_ratio              numeric(12, 10) NOT NULL
                               CHECK (missing_ratio BETWEEN 0 AND 1),
    warmup_complete            boolean NOT NULL,
    effective_sample_count     bigint NOT NULL CHECK (effective_sample_count >= 0),
    effective_fold_count       integer NOT NULL CHECK (effective_fold_count >= 0),
    expected_row_count         bigint NOT NULL CHECK (expected_row_count > 0),
    observed_row_count         bigint NOT NULL CHECK (observed_row_count >= 0),
    missing_row_count          bigint NOT NULL CHECK (missing_row_count >= 0),
    status                     varchar(16) NOT NULL
                               CHECK (status IN ('PASS', 'WARN', 'BLOCKED')),
    blocking_reason            text,
    evidence_json              jsonb NOT NULL,
    evidence_hash              char(64) NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(dependency_name) <> ''),
    CHECK (btrim(dependency_kind) <> ''),
    CHECK (coverage_ratio + missing_ratio <= 1.0000000001),
    CHECK (observed_row_count + missing_row_count = expected_row_count),
    CHECK (
        abs(coverage_ratio - observed_row_count::numeric / expected_row_count) < 0.0000000001
    ),
    CHECK (
        abs(missing_ratio - missing_row_count::numeric / expected_row_count) < 0.0000000001
    ),
    CHECK (
        (status = 'BLOCKED' AND blocking_reason IS NOT NULL
                            AND btrim(blocking_reason) <> '')
        OR (status <> 'BLOCKED' AND blocking_reason IS NULL)
    ),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(evidence_json) = 'object'),
    CHECK (evidence_json <> '{}'::jsonb),
    CHECK (evidence_hash = encode(digest(evidence_json::text, 'sha256'), 'hex')),
    UNIQUE (dataset_version_id, dependency_name, data_quality_rule_version_id)
);

CREATE INDEX ix_training_quality_reports_dataset_status
ON strategy_training.training_data_quality_reports (dataset_version_id, status, is_required);

CREATE TABLE strategy_training.training_exposure_records (
    exposure_record_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exposure_month           date NOT NULL,
    partition                varchar(16) NOT NULL
                             CHECK (partition IN ('TRAIN', 'VALIDATION', 'WEAK_HOLDOUT')),
    research_exposure_status varchar(16) NOT NULL
                             CHECK (research_exposure_status IN ('NONE', 'DECLARED', 'UNKNOWN')),
    visibility_cutoff_at     timestamptz NOT NULL,
    artifact_or_query        text NOT NULL,
    viewed_by_user_id        uuid REFERENCES core.app_users(user_id),
    impact                   text NOT NULL,
    evaluation_conclusion    text NOT NULL,
    request_id               uuid NOT NULL,
    recorded_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (exposure_month = date_trunc('month', exposure_month)::date),
    CHECK (btrim(artifact_or_query) <> ''),
    CHECK (btrim(impact) <> ''),
    CHECK (btrim(evaluation_conclusion) <> '')
);

CREATE INDEX ix_training_exposure_records_month
ON strategy_training.training_exposure_records (
    exposure_month, partition, research_exposure_status, recorded_at DESC
);

CREATE TABLE strategy_training.reproducibility_manifests (
    reproducibility_manifest_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type                varchar(32) NOT NULL,
    object_id                  uuid NOT NULL,
    dataset_version_id         uuid UNIQUE
                               REFERENCES strategy_training.training_dataset_versions,
    status                     varchar(16) NOT NULL DEFAULT 'DRAFT'
                               CHECK (status IN ('DRAFT', 'COMPLETE', 'INVALID')),
    code_commit                char(40),
    image_digest               text,
    python_version             text,
    system_version             text,
    dependency_lock_hash       char(64),
    database_migration_version varchar(128),
    config_version_ids         jsonb,
    dataset_version_ids        jsonb,
    rule_and_scoring_versions  jsonb,
    source_root_fingerprint    char(64),
    random_seed                bigint,
    blas_thread_count          integer CHECK (blas_thread_count IS NULL OR blas_thread_count > 0),
    openmp_thread_count        integer CHECK (openmp_thread_count IS NULL OR openmp_thread_count > 0),
    cpu_count                  integer CHECK (cpu_count IS NULL OR cpu_count > 0),
    worker_concurrency         integer CHECK (worker_concurrency IS NULL OR worker_concurrency > 0),
    float_absolute_tolerance   numeric CHECK (
        float_absolute_tolerance IS NULL OR float_absolute_tolerance >= 0
    ),
    float_relative_tolerance   numeric CHECK (
        float_relative_tolerance IS NULL OR float_relative_tolerance >= 0
    ),
    normalized_query_hash      char(64),
    input_hashes               jsonb,
    output_hashes              jsonb,
    run_command                text,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at               timestamptz,
    CHECK (btrim(object_type) <> ''),
    CHECK (
        (object_type = 'DATASET' AND dataset_version_id = object_id)
        OR (object_type <> 'DATASET' AND dataset_version_id IS NULL)
    ),
    CHECK (code_commit IS NULL OR code_commit ~ '^[0-9a-f]{40}$'),
    CHECK (dependency_lock_hash IS NULL OR dependency_lock_hash ~ '^[0-9a-f]{64}$'),
    CHECK (source_root_fingerprint IS NULL OR source_root_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (normalized_query_hash IS NULL OR normalized_query_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        status <> 'COMPLETE' OR (
            code_commit IS NOT NULL
            AND image_digest IS NOT NULL AND btrim(image_digest) <> ''
            AND python_version IS NOT NULL AND btrim(python_version) <> ''
            AND system_version IS NOT NULL AND btrim(system_version) <> ''
            AND dependency_lock_hash IS NOT NULL
            AND database_migration_version IS NOT NULL
            AND config_version_ids IS NOT NULL
            AND dataset_version_ids IS NOT NULL
            AND rule_and_scoring_versions IS NOT NULL
            AND source_root_fingerprint IS NOT NULL
            AND random_seed IS NOT NULL
            AND blas_thread_count IS NOT NULL
            AND openmp_thread_count IS NOT NULL
            AND cpu_count IS NOT NULL
            AND worker_concurrency IS NOT NULL
            AND float_absolute_tolerance IS NOT NULL
            AND float_relative_tolerance IS NOT NULL
            AND normalized_query_hash IS NOT NULL
            AND input_hashes IS NOT NULL
            AND output_hashes IS NOT NULL
            AND jsonb_typeof(config_version_ids) = 'array'
            AND jsonb_array_length(config_version_ids) > 0
            AND jsonb_typeof(dataset_version_ids) = 'array'
            AND jsonb_array_length(dataset_version_ids) > 0
            AND jsonb_typeof(input_hashes) = 'object' AND input_hashes <> '{}'::jsonb
            AND jsonb_typeof(output_hashes) = 'object' AND output_hashes <> '{}'::jsonb
            AND run_command IS NOT NULL AND btrim(run_command) <> ''
            AND completed_at IS NOT NULL
        )
    ),
    UNIQUE (object_type, object_id)
);

CREATE OR REPLACE FUNCTION strategy_training.guard_config_version_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    parent_type text;
    parent_status text;
    required_dependency_name text;
    dependency_rule jsonb;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'training config versions cannot be deleted' USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'new training config versions must start in DRAFT'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        IF OLD.status = 'DRAFT' AND NEW.status NOT IN ('DRAFT', 'READY') THEN
            RAISE EXCEPTION 'invalid config transition % -> %', OLD.status, NEW.status
                USING ERRCODE = '23514';
        ELSIF OLD.status = 'READY' THEN
            IF NEW.status <> 'RETIRED'
               OR (to_jsonb(NEW) - ARRAY['status', 'retired_by_user_id', 'retired_at'])
                  <> (to_jsonb(OLD) - ARRAY['status', 'retired_by_user_id', 'retired_at']) THEN
                RAISE EXCEPTION 'READY config content is immutable'
                    USING ERRCODE = '55000';
            END IF;
        ELSIF OLD.status = 'RETIRED' THEN
            RAISE EXCEPTION 'RETIRED config is immutable' USING ERRCODE = '55000';
        END IF;
    END IF;

    IF NEW.parent_version_id IS NOT NULL THEN
        SELECT config_type, status INTO STRICT parent_type, parent_status
        FROM strategy_training.training_config_versions
        WHERE config_version_id = NEW.parent_version_id;
        IF parent_type <> NEW.config_type THEN
            RAISE EXCEPTION 'parent config type must match child config type'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            WITH RECURSIVE ancestors AS (
                SELECT config_version_id, parent_version_id
                FROM strategy_training.training_config_versions
                WHERE config_version_id = NEW.parent_version_id
                UNION ALL
                SELECT parent.config_version_id, parent.parent_version_id
                FROM strategy_training.training_config_versions parent
                JOIN ancestors child ON parent.config_version_id = child.parent_version_id
            )
            SELECT 1 FROM ancestors WHERE config_version_id = NEW.config_version_id
        ) THEN
            RAISE EXCEPTION 'config parent lineage cannot contain a cycle'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF NEW.status = 'READY' AND (TG_OP = 'INSERT' OR OLD.status <> 'READY') THEN
        IF NEW.config_json = '{}'::jsonb THEN
            RAISE EXCEPTION 'READY config_json cannot be empty' USING ERRCODE = '23514';
        END IF;
        IF jsonb_strip_nulls(NEW.config_json) <> NEW.config_json THEN
            RAISE EXCEPTION 'READY config_json cannot contain null placeholders'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.parent_version_id IS NOT NULL AND parent_status = 'DRAFT' THEN
            RAISE EXCEPTION 'READY config cannot descend from a DRAFT parent'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'DATA_QUALITY_RULES' AND (
            jsonb_typeof(NEW.config_json -> 'required_dependencies') IS DISTINCT FROM 'array'
            OR jsonb_array_length(NEW.config_json -> 'required_dependencies') = 0
            OR jsonb_typeof(NEW.config_json -> 'dependency_rules') IS DISTINCT FROM 'object'
        ) THEN
            RAISE EXCEPTION 'DATA_QUALITY_RULES requires dependencies and explicit rules'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'DATA_QUALITY_RULES' THEN
            FOR required_dependency_name IN
                SELECT jsonb_array_elements_text(
                    NEW.config_json -> 'required_dependencies'
                )
            LOOP
                dependency_rule :=
                    NEW.config_json -> 'dependency_rules' -> required_dependency_name;
                IF jsonb_typeof(dependency_rule) IS DISTINCT FROM 'object'
                   OR NOT dependency_rule ?& ARRAY[
                       'minimum_coverage', 'minimum_effective_samples',
                       'minimum_effective_folds', 'warmup_required'
                   ] THEN
                    RAISE EXCEPTION 'DATA_QUALITY_RULES lacks explicit rule for %',
                        required_dependency_name USING ERRCODE = '23514';
                END IF;
                IF jsonb_typeof(dependency_rule -> 'minimum_coverage')
                       IS DISTINCT FROM 'number'
                   OR jsonb_typeof(dependency_rule -> 'minimum_effective_samples')
                       IS DISTINCT FROM 'number'
                   OR jsonb_typeof(dependency_rule -> 'minimum_effective_folds')
                       IS DISTINCT FROM 'number'
                   OR jsonb_typeof(dependency_rule -> 'warmup_required')
                       IS DISTINCT FROM 'boolean'
                   OR (dependency_rule ->> 'minimum_coverage')::numeric NOT BETWEEN 0 AND 1
                   OR (dependency_rule ->> 'minimum_effective_samples')::bigint < 0
                   OR (dependency_rule ->> 'minimum_effective_folds')::integer < 0 THEN
                    RAISE EXCEPTION 'DATA_QUALITY_RULES has invalid rule for %',
                        required_dependency_name USING ERRCODE = '23514';
                END IF;
            END LOOP;
        END IF;
        IF NEW.config_type = 'HOLDING_HORIZON_RULES' AND (
            jsonb_typeof(NEW.config_json -> 'label_horizon_seconds') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'max_holding_seconds') IS DISTINCT FROM 'number'
            OR (NEW.config_json ->> 'label_horizon_seconds')::bigint <= 0
            OR (NEW.config_json ->> 'max_holding_seconds')::bigint <= 0
        ) THEN
            RAISE EXCEPTION 'HOLDING_HORIZON_RULES requires positive horizon seconds'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'REPRODUCIBILITY_TOLERANCE' AND (
            jsonb_typeof(NEW.config_json -> 'absolute_tolerance') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'relative_tolerance') IS DISTINCT FROM 'number'
            OR (NEW.config_json ->> 'absolute_tolerance')::numeric < 0
            OR (NEW.config_json ->> 'relative_tolerance')::numeric < 0
        ) THEN
            RAISE EXCEPTION 'REPRODUCIBILITY_TOLERANCE requires non-negative values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'ELIGIBLE_POOL_RULES' AND NOT (
            NEW.config_json ?& ARRAY[
                'minimum_listing_age_seconds', 'minimum_notional_volume',
                'required_contract_type', 'liquidity_lookback_seconds'
            ]
        ) THEN
            RAISE EXCEPTION 'ELIGIBLE_POOL_RULES is missing required explicit values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'ELIGIBLE_POOL_RULES' AND (
            jsonb_typeof(NEW.config_json -> 'minimum_listing_age_seconds')
                IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'minimum_notional_volume')
                IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'required_contract_type')
                IS DISTINCT FROM 'string'
            OR jsonb_typeof(NEW.config_json -> 'liquidity_lookback_seconds')
                IS DISTINCT FROM 'number'
            OR (NEW.config_json ->> 'minimum_listing_age_seconds')::numeric < 0
            OR (NEW.config_json ->> 'minimum_notional_volume')::numeric <= 0
            OR (NEW.config_json ->> 'liquidity_lookback_seconds')::numeric <= 0
            OR btrim(NEW.config_json ->> 'required_contract_type') = ''
        ) THEN
            RAISE EXCEPTION 'ELIGIBLE_POOL_RULES values have invalid types or ranges'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'RESOURCE_LIMITS' AND NOT (
            NEW.config_json ?& ARRAY[
                'max_heavy_experiments', 'db_workers_per_experiment',
                'pool_connections', 'statement_timeout_seconds',
                'lock_timeout_seconds', 'idle_in_transaction_session_timeout_seconds',
                'work_mem_bytes', 'cpu_limit', 'memory_bytes',
                'temp_disk_min_free_bytes', 'max_candidate_count',
                'max_signal_count', 'max_decision_row_count', 'max_storage_bytes'
            ]
        ) THEN
            RAISE EXCEPTION 'RESOURCE_LIMITS is missing required explicit values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'RESOURCE_LIMITS' AND (
            jsonb_typeof(NEW.config_json -> 'max_heavy_experiments') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'db_workers_per_experiment') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'pool_connections') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'statement_timeout_seconds') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'lock_timeout_seconds') IS DISTINCT FROM 'number'
            OR jsonb_typeof(
                NEW.config_json -> 'idle_in_transaction_session_timeout_seconds'
            ) IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'work_mem_bytes') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'cpu_limit') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'memory_bytes') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'temp_disk_min_free_bytes')
                IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'max_candidate_count') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'max_signal_count') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'max_decision_row_count')
                IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'max_storage_bytes') IS DISTINCT FROM 'number'
            OR (NEW.config_json ->> 'max_heavy_experiments')::numeric <= 0
            OR (NEW.config_json ->> 'db_workers_per_experiment')::numeric <= 0
            OR (NEW.config_json ->> 'pool_connections')::numeric <= 0
            OR (NEW.config_json ->> 'statement_timeout_seconds')::numeric <= 0
            OR (NEW.config_json ->> 'lock_timeout_seconds')::numeric <= 0
            OR (NEW.config_json ->> 'idle_in_transaction_session_timeout_seconds')::numeric <= 0
            OR (NEW.config_json ->> 'work_mem_bytes')::numeric <= 0
            OR (NEW.config_json ->> 'cpu_limit')::numeric <= 0
            OR (NEW.config_json ->> 'memory_bytes')::numeric <= 0
            OR (NEW.config_json ->> 'temp_disk_min_free_bytes')::numeric <= 0
            OR (NEW.config_json ->> 'max_candidate_count')::numeric <= 0
            OR (NEW.config_json ->> 'max_signal_count')::numeric <= 0
            OR (NEW.config_json ->> 'max_decision_row_count')::numeric <= 0
            OR (NEW.config_json ->> 'max_storage_bytes')::numeric <= 0
        ) THEN
            RAISE EXCEPTION 'RESOURCE_LIMITS values must be explicit positive numbers'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'SLIPPAGE_MODEL' AND NOT (
            NEW.config_json ?& ARRAY[
                'model_name', 'notional_coefficient', 'liquidity_coefficient',
                'volatility_coefficient'
            ]
        ) THEN
            RAISE EXCEPTION 'SLIPPAGE_MODEL is missing required explicit values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'SLIPPAGE_MODEL' AND (
            jsonb_typeof(NEW.config_json -> 'model_name') IS DISTINCT FROM 'string'
            OR jsonb_typeof(NEW.config_json -> 'notional_coefficient') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'liquidity_coefficient') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'volatility_coefficient') IS DISTINCT FROM 'number'
            OR btrim(NEW.config_json ->> 'model_name') = ''
            OR (NEW.config_json ->> 'notional_coefficient')::numeric < 0
            OR (NEW.config_json ->> 'liquidity_coefficient')::numeric < 0
            OR (NEW.config_json ->> 'volatility_coefficient')::numeric < 0
        ) THEN
            RAISE EXCEPTION 'SLIPPAGE_MODEL values have invalid types or ranges'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'FEE_MODEL' AND NOT (
            NEW.config_json ?& ARRAY['maker_rate', 'taker_rate']
        ) THEN
            RAISE EXCEPTION 'FEE_MODEL is missing required explicit values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'FEE_MODEL' AND (
            jsonb_typeof(NEW.config_json -> 'maker_rate') IS DISTINCT FROM 'number'
            OR jsonb_typeof(NEW.config_json -> 'taker_rate') IS DISTINCT FROM 'number'
            OR (NEW.config_json ->> 'maker_rate')::numeric < 0
            OR (NEW.config_json ->> 'taker_rate')::numeric < 0
        ) THEN
            RAISE EXCEPTION 'FEE_MODEL rates must be explicit non-negative numbers'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'VISIBILITY_CUTOFF_POLICY' AND NOT (
            NEW.config_json ?& ARRAY['policy_name', 'required_lead_seconds']
        ) THEN
            RAISE EXCEPTION 'VISIBILITY_CUTOFF_POLICY is missing required explicit values'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.config_type = 'VISIBILITY_CUTOFF_POLICY' AND (
            jsonb_typeof(NEW.config_json -> 'policy_name') IS DISTINCT FROM 'string'
            OR jsonb_typeof(NEW.config_json -> 'required_lead_seconds') IS DISTINCT FROM 'number'
            OR btrim(NEW.config_json ->> 'policy_name') = ''
            OR (NEW.config_json ->> 'required_lead_seconds')::numeric < 0
        ) THEN
            RAISE EXCEPTION 'VISIBILITY_CUTOFF_POLICY values have invalid types or ranges'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.compute_dataset_root_fingerprint(
    requested_dataset_version_id uuid
)
RETURNS char(64)
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        public.digest(
            concat_ws(
                '|',
                dataset.dataset_type,
                dataset.partition,
                dataset.fingerprint_schema_version::text,
                to_char(dataset.partition_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.partition_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                dataset.interval_seconds::text,
                to_char(dataset.warmup_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.eligible_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.eligible_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.label_window_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.source_as_of_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                to_char(dataset.visibility_cutoff_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                dataset.label_horizon_duration::text,
                dataset.max_holding_duration::text,
                dataset.purge_duration::text,
                dataset.embargo_duration::text,
                dataset.ticker_pool_rule_version_id::text,
                dataset.data_quality_rule_version_id::text,
                dataset.holding_rule_version_id::text,
                dataset.source_revision_watermark::text,
                (SELECT string_agg(
                    binding.config_type || ':' || binding.config_version_id::text,
                    '|' ORDER BY binding.config_type
                 )
                 FROM strategy_training.training_dataset_config_bindings binding
                 WHERE binding.dataset_version_id = dataset.dataset_version_id),
                string_agg(
                    concat_ws(
                        ':', member.source_schema, member.source_table,
                        member.source_shard_identity,
                        to_char(member.member_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                        to_char(member.member_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                        member.row_count::text,
                        member.member_hash, member.shard_fingerprint,
                        member.normalized_query_hash, member.source_revision_watermark::text
                    ),
                    '|' ORDER BY member.source_schema, member.source_table,
                                 member.source_shard_identity
                )
            ),
            'sha256'
        ),
        'hex'
    )::char(64)
    FROM strategy_training.training_dataset_versions dataset
    JOIN strategy_training.training_dataset_members member
      ON member.dataset_version_id = dataset.dataset_version_id
    WHERE dataset.dataset_version_id = requested_dataset_version_id
    GROUP BY dataset.dataset_version_id;
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_dataset_version_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    ticker_rule_status text;
    ticker_rule_type text;
    quality_rule_status text;
    quality_rule_type text;
    holding_rule_status text;
    holding_rule_type text;
    holding_rule_json jsonb;
    cutoff_policy_json jsonb;
    expected_root_fingerprint char(64);
    required_dependency text;
    required_config_type text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'training dataset versions cannot be deleted' USING ERRCODE = '55000';
    END IF;

    IF TG_OP = 'INSERT' AND NEW.status <> 'BUILDING' THEN
        RAISE EXCEPTION 'new training datasets must start in BUILDING'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'BUILDING' AND EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_members
            WHERE dataset_version_id = OLD.dataset_version_id
        ) AND (
            NEW.partition_start_at <> OLD.partition_start_at
            OR NEW.partition_end_at <> OLD.partition_end_at
            OR NEW.warmup_start_at <> OLD.warmup_start_at
            OR NEW.eligible_start_at <> OLD.eligible_start_at
            OR NEW.eligible_end_at <> OLD.eligible_end_at
            OR NEW.label_window_end_at <> OLD.label_window_end_at
            OR NEW.source_as_of_at <> OLD.source_as_of_at
            OR NEW.visibility_cutoff_at <> OLD.visibility_cutoff_at
            OR NEW.fingerprint_schema_version <> OLD.fingerprint_schema_version
            OR NEW.interval_seconds <> OLD.interval_seconds
            OR NEW.dataset_type <> OLD.dataset_type
            OR NEW.partition <> OLD.partition
            OR NEW.ticker_pool_rule_version_id <> OLD.ticker_pool_rule_version_id
            OR NEW.data_quality_rule_version_id <> OLD.data_quality_rule_version_id
            OR NEW.holding_rule_version_id <> OLD.holding_rule_version_id
            OR NEW.label_horizon_duration <> OLD.label_horizon_duration
            OR NEW.max_holding_duration <> OLD.max_holding_duration
            OR NEW.purge_duration <> OLD.purge_duration
            OR NEW.embargo_duration <> OLD.embargo_duration
            OR NEW.source_revision_watermark <> OLD.source_revision_watermark
        ) THEN
            RAISE EXCEPTION 'dataset contract cannot change after members are recorded'
                USING ERRCODE = '55000';
        END IF;
        IF OLD.status = 'BUILDING' AND NEW.status NOT IN ('BUILDING', 'READY', 'INVALID') THEN
            RAISE EXCEPTION 'invalid dataset transition % -> %', OLD.status, NEW.status
                USING ERRCODE = '23514';
        ELSIF OLD.status = 'READY' AND NEW.status <> 'STALE' THEN
            RAISE EXCEPTION 'READY dataset may only transition to STALE'
                USING ERRCODE = '23514';
        ELSIF OLD.status = 'STALE' AND NEW.status NOT IN ('SUPERSEDED', 'ARCHIVED') THEN
            RAISE EXCEPTION 'STALE dataset may only be superseded or archived'
                USING ERRCODE = '23514';
        ELSIF OLD.status IN ('SUPERSEDED', 'INVALID', 'ARCHIVED') THEN
            RAISE EXCEPTION '% dataset is immutable', OLD.status USING ERRCODE = '55000';
        END IF;
        IF NEW.status = 'SUPERSEDED' AND NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_versions replacement
            WHERE replacement.supersedes_dataset_version_id = OLD.dataset_version_id
              AND replacement.status = 'READY'
        ) THEN
            RAISE EXCEPTION 'STALE dataset requires a READY replacement before SUPERSEDED'
                USING ERRCODE = '23514';
        END IF;

        IF OLD.status <> 'BUILDING'
           AND (to_jsonb(NEW) - ARRAY[
                'status', 'stale_reason', 'stale_at',
                'superseded_at', 'archived_at'
           ]) <> (to_jsonb(OLD) - ARRAY[
                'status', 'stale_reason', 'stale_at',
                'superseded_at', 'archived_at'
           ]) THEN
            RAISE EXCEPTION 'non-BUILDING dataset content is immutable'
                USING ERRCODE = '55000';
        END IF;
    END IF;

    IF NEW.status = 'READY' AND (TG_OP = 'INSERT' OR OLD.status <> 'READY') THEN
        IF NEW.root_fingerprint IS NULL OR NEW.source_revision_watermark = '{}'::jsonb THEN
            RAISE EXCEPTION 'READY dataset requires root_fingerprint'
                USING ERRCODE = '23514';
        END IF;
        FOREACH required_config_type IN ARRAY ARRAY[
            'TICKER_POOL_RULES', 'DATA_QUALITY_RULES', 'HOLDING_HORIZON_RULES',
            'ELIGIBLE_POOL_RULES', 'REPRODUCIBILITY_TOLERANCE', 'RESOURCE_LIMITS',
            'FEE_MODEL', 'SLIPPAGE_MODEL', 'VISIBILITY_CUTOFF_POLICY'
        ]
        LOOP
            IF NOT EXISTS (
                SELECT 1
                FROM strategy_training.training_dataset_config_bindings binding
                JOIN strategy_training.training_config_versions config
                  ON config.config_version_id = binding.config_version_id
                WHERE binding.dataset_version_id = NEW.dataset_version_id
                  AND binding.config_type = required_config_type
                  AND config.config_type = required_config_type
                  AND config.status = 'READY'
            ) THEN
                RAISE EXCEPTION 'dataset lacks READY required config %', required_config_type
                    USING ERRCODE = '23514';
            END IF;
        END LOOP;
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_config_bindings
            WHERE dataset_version_id = NEW.dataset_version_id
              AND config_type = 'TICKER_POOL_RULES'
              AND config_version_id = NEW.ticker_pool_rule_version_id
        ) OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_config_bindings
            WHERE dataset_version_id = NEW.dataset_version_id
              AND config_type = 'DATA_QUALITY_RULES'
              AND config_version_id = NEW.data_quality_rule_version_id
        ) OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_config_bindings
            WHERE dataset_version_id = NEW.dataset_version_id
              AND config_type = 'HOLDING_HORIZON_RULES'
              AND config_version_id = NEW.holding_rule_version_id
        ) THEN
            RAISE EXCEPTION 'dataset explicit rule references must match config bindings'
                USING ERRCODE = '23514';
        END IF;

        SELECT status, config_type INTO STRICT ticker_rule_status, ticker_rule_type
        FROM strategy_training.training_config_versions
        WHERE config_version_id = NEW.ticker_pool_rule_version_id;
        SELECT status, config_type INTO STRICT quality_rule_status, quality_rule_type
        FROM strategy_training.training_config_versions
        WHERE config_version_id = NEW.data_quality_rule_version_id;
        SELECT status, config_type, config_json
        INTO STRICT holding_rule_status, holding_rule_type, holding_rule_json
        FROM strategy_training.training_config_versions
        WHERE config_version_id = NEW.holding_rule_version_id;

        IF ticker_rule_status <> 'READY' OR ticker_rule_type <> 'TICKER_POOL_RULES'
           OR quality_rule_status <> 'READY' OR quality_rule_type <> 'DATA_QUALITY_RULES'
           OR holding_rule_status <> 'READY' OR holding_rule_type <> 'HOLDING_HORIZON_RULES' THEN
            RAISE EXCEPTION 'READY dataset requires all bound rule configs to be READY'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.label_horizon_duration
              <> make_interval(secs => (holding_rule_json ->> 'label_horizon_seconds')::double precision)
           OR NEW.max_holding_duration
              <> make_interval(secs => (holding_rule_json ->> 'max_holding_seconds')::double precision) THEN
            RAISE EXCEPTION 'dataset horizons must match HOLDING_HORIZON_RULES'
                USING ERRCODE = '23514';
        END IF;
        SELECT config.config_json INTO STRICT cutoff_policy_json
        FROM strategy_training.training_dataset_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.dataset_version_id = NEW.dataset_version_id
          AND binding.config_type = 'VISIBILITY_CUTOFF_POLICY';
        IF NEW.visibility_cutoff_at
              + make_interval(
                    secs => (cutoff_policy_json ->> 'required_lead_seconds')::double precision
                )
           > NEW.partition_start_at THEN
            RAISE EXCEPTION 'visibility cutoff does not meet configured lead time'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_members
            WHERE dataset_version_id = NEW.dataset_version_id
        ) THEN
            RAISE EXCEPTION 'READY dataset requires at least one member'
                USING ERRCODE = '23514';
        END IF;
        IF (
            SELECT min(member_start_at) > NEW.warmup_start_at
                   OR max(member_end_at) < NEW.label_window_end_at
            FROM strategy_training.training_dataset_members
            WHERE dataset_version_id = NEW.dataset_version_id
        ) THEN
            RAISE EXCEPTION 'dataset members do not cover warmup through label window'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.training_data_quality_reports
            WHERE dataset_version_id = NEW.dataset_version_id
        ) OR EXISTS (
            SELECT 1 FROM strategy_training.training_data_quality_reports
            WHERE dataset_version_id = NEW.dataset_version_id
              AND is_required
              AND (status <> 'PASS' OR NOT warmup_complete)
        ) THEN
            RAISE EXCEPTION 'READY dataset requires passing required quality reports'
                USING ERRCODE = '23514';
        END IF;
        FOR required_dependency IN
            SELECT jsonb_array_elements_text(
                (SELECT config_json -> 'required_dependencies'
                 FROM strategy_training.training_config_versions
                 WHERE config_version_id = NEW.data_quality_rule_version_id)
            )
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM strategy_training.training_data_quality_reports
                WHERE dataset_version_id = NEW.dataset_version_id
                  AND dependency_name = required_dependency
                  AND is_required AND status = 'PASS' AND warmup_complete
            ) THEN
                RAISE EXCEPTION 'missing passing quality report for required dependency %',
                    required_dependency USING ERRCODE = '23514';
            END IF;
        END LOOP;
        SELECT strategy_training.compute_dataset_root_fingerprint(NEW.dataset_version_id)
        INTO expected_root_fingerprint;
        IF expected_root_fingerprint IS NULL OR NEW.root_fingerprint <> expected_root_fingerprint THEN
            RAISE EXCEPTION 'dataset root_fingerprint does not match canonical members'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM strategy_training.reproducibility_manifests manifest
            WHERE manifest.dataset_version_id = NEW.dataset_version_id
              AND manifest.object_type = 'DATASET'
              AND manifest.status = 'COMPLETE'
              AND manifest.source_root_fingerprint = NEW.root_fingerprint
        ) THEN
            RAISE EXCEPTION 'READY dataset requires a matching COMPLETE reproducibility manifest'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.supersedes_dataset_version_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_versions previous
            WHERE previous.dataset_version_id = NEW.supersedes_dataset_version_id
              AND previous.status = 'STALE'
              AND previous.dataset_type = NEW.dataset_type
              AND previous.partition = NEW.partition
              AND previous.partition_start_at = NEW.partition_start_at
              AND previous.partition_end_at = NEW.partition_end_at
        ) THEN
            RAISE EXCEPTION 'replacement dataset must supersede a matching STALE dataset'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_dataset_member_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_status text;
    dataset_warmup_start timestamptz;
    dataset_partition_end timestamptz;
BEGIN
    SELECT status, warmup_start_at, partition_end_at
    INTO STRICT dataset_status, dataset_warmup_start, dataset_partition_end
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR UPDATE;
    IF dataset_status <> 'BUILDING' THEN
        RAISE EXCEPTION 'dataset members may only be added while BUILDING'
            USING ERRCODE = '55000';
    END IF;
    IF NEW.member_start_at < dataset_warmup_start
       OR NEW.member_end_at > dataset_partition_end THEN
        RAISE EXCEPTION 'dataset member range exceeds dataset reproducibility range'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_quality_report_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    expected_rule_id uuid;
    dataset_status text;
BEGIN
    SELECT data_quality_rule_version_id, status INTO STRICT expected_rule_id, dataset_status
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
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_dataset_config_binding_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_status text;
    actual_config_type text;
BEGIN
    SELECT status INTO STRICT dataset_status
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR UPDATE;
    SELECT config_type INTO STRICT actual_config_type
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.config_version_id;
    IF dataset_status <> 'BUILDING' THEN
        RAISE EXCEPTION 'config bindings may only be added while dataset is BUILDING'
            USING ERRCODE = '55000';
    END IF;
    IF actual_config_type <> NEW.config_type THEN
        RAISE EXCEPTION 'binding config_type does not match config version'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_exposure_record_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(NEW.exposure_month::text || ':' || NEW.partition, 0)
    );
    IF NEW.research_exposure_status = 'NONE'
       AND NEW.visibility_cutoff_at > NEW.exposure_month::timestamp AT TIME ZONE 'UTC' THEN
        RAISE EXCEPTION 'NONE exposure requires cutoff effective by the start of the month'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.research_exposure_status = 'NONE' AND EXISTS (
        SELECT 1 FROM strategy_training.training_exposure_records existing
        WHERE existing.exposure_month = NEW.exposure_month
          AND existing.partition = NEW.partition
          AND existing.research_exposure_status IN ('DECLARED', 'UNKNOWN')
    ) THEN
        RAISE EXCEPTION 'DECLARED or UNKNOWN exposure cannot be reset to NONE'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_reproducibility_manifest_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_status text;
    dataset_root char(64);
    expected_config_ids jsonb;
    tolerance_config jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'new reproducibility manifests must start in DRAFT'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.object_type = 'DATASET' THEN
            SELECT status INTO STRICT dataset_status
            FROM strategy_training.training_dataset_versions
            WHERE dataset_version_id = NEW.dataset_version_id
            FOR UPDATE;
            IF dataset_status <> 'BUILDING' THEN
                RAISE EXCEPTION 'dataset manifest must be created while dataset is BUILDING'
                    USING ERRCODE = '55000';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'reproducibility manifests cannot be deleted' USING ERRCODE = '55000';
    END IF;
    IF OLD.status <> 'DRAFT' THEN
        RAISE EXCEPTION '% reproducibility manifest is immutable', OLD.status
            USING ERRCODE = '55000';
    END IF;
    IF NEW.status NOT IN ('COMPLETE', 'INVALID') THEN
        RAISE EXCEPTION 'DRAFT manifest may only become COMPLETE or INVALID'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'COMPLETE' AND NEW.object_type = 'DATASET' THEN
        IF EXISTS (
            SELECT 1 FROM jsonb_each_text(NEW.input_hashes)
            WHERE value !~ '^[0-9a-f]{64}$'
        ) OR EXISTS (
            SELECT 1 FROM jsonb_each_text(NEW.output_hashes)
            WHERE value !~ '^[0-9a-f]{64}$'
        ) THEN
            RAISE EXCEPTION 'manifest input/output hashes must be lowercase SHA-256'
                USING ERRCODE = '23514';
        END IF;
        SELECT status, root_fingerprint INTO STRICT dataset_status, dataset_root
        FROM strategy_training.training_dataset_versions
        WHERE dataset_version_id = NEW.dataset_version_id
        FOR UPDATE;
        IF dataset_status <> 'BUILDING' OR dataset_root IS NULL
           OR NEW.source_root_fingerprint <> dataset_root THEN
            RAISE EXCEPTION 'COMPLETE manifest must match a BUILDING dataset root'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM strategy_training.training_dataset_config_bindings binding
            JOIN strategy_training.training_config_versions config
              ON config.config_version_id = binding.config_version_id
            WHERE binding.dataset_version_id = NEW.dataset_version_id
              AND config.status <> 'READY'
        ) OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_dataset_config_bindings
            WHERE dataset_version_id = NEW.dataset_version_id
        ) THEN
            RAISE EXCEPTION 'COMPLETE dataset manifest requires READY bound configs'
                USING ERRCODE = '23514';
        END IF;
        SELECT jsonb_agg(config_version_id::text ORDER BY config_type)
        INTO expected_config_ids
        FROM strategy_training.training_dataset_config_bindings
        WHERE dataset_version_id = NEW.dataset_version_id;
        IF NEW.config_version_ids <> expected_config_ids
           OR NEW.dataset_version_ids <> jsonb_build_array(NEW.dataset_version_id::text) THEN
            RAISE EXCEPTION 'manifest version identities do not match dataset bindings'
                USING ERRCODE = '23514';
        END IF;
        SELECT config.config_json INTO STRICT tolerance_config
        FROM strategy_training.training_dataset_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.dataset_version_id = NEW.dataset_version_id
          AND binding.config_type = 'REPRODUCIBILITY_TOLERANCE';
        IF NEW.float_absolute_tolerance
              <> (tolerance_config ->> 'absolute_tolerance')::numeric
           OR NEW.float_relative_tolerance
              <> (tolerance_config ->> 'relative_tolerance')::numeric THEN
            RAISE EXCEPTION 'manifest tolerances must match the bound READY config'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_config_version_guard
BEFORE INSERT OR UPDATE OR DELETE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_config_version_mutation();

CREATE TRIGGER trg_training_dataset_version_guard
BEFORE INSERT OR UPDATE OR DELETE ON strategy_training.training_dataset_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_dataset_version_mutation();

CREATE TRIGGER trg_training_dataset_member_insert_guard
BEFORE INSERT ON strategy_training.training_dataset_members
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_dataset_member_insert();

CREATE TRIGGER trg_training_quality_report_insert_guard
BEFORE INSERT ON strategy_training.training_data_quality_reports
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_quality_report_insert();

CREATE TRIGGER trg_training_dataset_config_binding_insert_guard
BEFORE INSERT ON strategy_training.training_dataset_config_bindings
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_dataset_config_binding_insert();

CREATE TRIGGER trg_training_dataset_config_binding_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_dataset_config_bindings
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_dataset_member_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_dataset_members
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_quality_report_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_data_quality_reports
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_exposure_record_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_exposure_records
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_exposure_record_insert_guard
BEFORE INSERT ON strategy_training.training_exposure_records
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_exposure_record_insert();

CREATE TRIGGER trg_reproducibility_manifest_guard
BEFORE INSERT OR UPDATE OR DELETE ON strategy_training.reproducibility_manifests
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_reproducibility_manifest_mutation();

ALTER TABLE strategy_training.training_config_versions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_dataset_versions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_dataset_members OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_dataset_config_bindings OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_data_quality_reports OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_exposure_records OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.reproducibility_manifests OWNER TO tb2_training_owner;

ALTER FUNCTION strategy_training.guard_config_version_mutation() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.compute_dataset_root_fingerprint(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_dataset_version_mutation() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_dataset_member_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_quality_report_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_dataset_config_binding_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_exposure_record_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_reproducibility_manifest_mutation()
OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON strategy_training.training_config_versions,
    strategy_training.training_dataset_versions,
    strategy_training.training_dataset_members,
    strategy_training.training_dataset_config_bindings,
    strategy_training.training_data_quality_reports,
    strategy_training.reproducibility_manifests
TO tb2_training_rw, tb2_training_evaluator;

GRANT SELECT ON strategy_training.training_config_versions,
    strategy_training.training_dataset_versions,
    strategy_training.reproducibility_manifests
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '020_training_versions_datasets',
    encode(digest('auto_trade_v2_020_training_versions_datasets_v1', 'sha256'), 'hex'),
    'Add governed training config versions, datasets, quality, exposure and reproducibility facts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
