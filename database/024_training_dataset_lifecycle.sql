\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.complete_training_dataset_manifest(
    p_dataset_version_id uuid,
    p_code_commit char(40),
    p_image_digest text,
    p_python_version text,
    p_system_version text,
    p_dependency_lock_hash char(64),
    p_database_migration_version text,
    p_rule_and_scoring_versions jsonb,
    p_random_seed bigint,
    p_blas_thread_count integer,
    p_openmp_thread_count integer,
    p_cpu_count integer,
    p_worker_concurrency integer,
    p_normalized_query_hash char(64),
    p_input_hashes jsonb,
    p_output_hashes jsonb,
    p_run_command text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    manifest_id uuid := gen_random_uuid();
    dataset_status text;
    dataset_root char(64);
    config_ids jsonb;
    tolerance_config jsonb;
BEGIN
    SELECT status, root_fingerprint
    INTO STRICT dataset_status, dataset_root
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_dataset_version_id
    FOR UPDATE;

    IF dataset_status <> 'BUILDING' OR dataset_root IS NULL THEN
        RAISE EXCEPTION 'dataset manifest requires a finalized BUILDING dataset'
            USING ERRCODE = '23514';
    END IF;
    IF p_rule_and_scoring_versions IS NULL
       OR jsonb_typeof(p_rule_and_scoring_versions) <> 'object'
       OR p_rule_and_scoring_versions = '{}'::jsonb THEN
        RAISE EXCEPTION 'rule_and_scoring_versions must be a non-empty object'
            USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_agg(config_version_id::text ORDER BY config_type)
    INTO config_ids
    FROM strategy_training.training_dataset_config_bindings
    WHERE dataset_version_id = p_dataset_version_id;

    SELECT config.config_json
    INTO STRICT tolerance_config
    FROM strategy_training.training_dataset_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.dataset_version_id = p_dataset_version_id
      AND binding.config_type = 'REPRODUCIBILITY_TOLERANCE'
      AND config.status = 'READY';

    INSERT INTO strategy_training.reproducibility_manifests (
        reproducibility_manifest_id, object_type, object_id, dataset_version_id
    ) VALUES (
        manifest_id, 'DATASET', p_dataset_version_id, p_dataset_version_id
    );

    UPDATE strategy_training.reproducibility_manifests
    SET status = 'COMPLETE',
        code_commit = p_code_commit,
        image_digest = p_image_digest,
        python_version = p_python_version,
        system_version = p_system_version,
        dependency_lock_hash = p_dependency_lock_hash,
        database_migration_version = p_database_migration_version,
        config_version_ids = config_ids,
        dataset_version_ids = jsonb_build_array(p_dataset_version_id::text),
        rule_and_scoring_versions = p_rule_and_scoring_versions,
        source_root_fingerprint = dataset_root,
        random_seed = p_random_seed,
        blas_thread_count = p_blas_thread_count,
        openmp_thread_count = p_openmp_thread_count,
        cpu_count = p_cpu_count,
        worker_concurrency = p_worker_concurrency,
        float_absolute_tolerance =
            (tolerance_config ->> 'absolute_tolerance')::numeric,
        float_relative_tolerance =
            (tolerance_config ->> 'relative_tolerance')::numeric,
        normalized_query_hash = p_normalized_query_hash,
        input_hashes = p_input_hashes,
        output_hashes = p_output_hashes,
        run_command = p_run_command,
        completed_at = clock_timestamp()
    WHERE reproducibility_manifest_id = manifest_id;

    RETURN manifest_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.mark_training_dataset_stale_for_replacement(
    p_stale_dataset_version_id uuid,
    p_replacement_dataset_version_id uuid,
    p_actor_user_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    stale_dataset strategy_training.training_dataset_versions%ROWTYPE;
    replacement strategy_training.training_dataset_versions%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );

    SELECT * INTO STRICT stale_dataset
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_stale_dataset_version_id
    FOR UPDATE;
    SELECT * INTO STRICT replacement
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_replacement_dataset_version_id
    FOR UPDATE;

    IF stale_dataset.status <> 'READY' OR replacement.status <> 'BUILDING' THEN
        RAISE EXCEPTION 'source revision replacement requires READY -> BUILDING datasets'
            USING ERRCODE = '23514';
    END IF;
    IF replacement.supersedes_dataset_version_id IS DISTINCT FROM
       stale_dataset.dataset_version_id THEN
        RAISE EXCEPTION 'replacement does not reference the stale dataset'
            USING ERRCODE = '23514';
    END IF;
    IF replacement.dataset_type <> stale_dataset.dataset_type
       OR replacement.partition <> stale_dataset.partition
       OR replacement.partition_start_at <> stale_dataset.partition_start_at
       OR replacement.partition_end_at <> stale_dataset.partition_end_at THEN
        RAISE EXCEPTION 'replacement scope does not match the stale dataset'
            USING ERRCODE = '23514';
    END IF;
    IF replacement.root_fingerprint IS NULL
       OR replacement.root_fingerprint = stale_dataset.root_fingerprint THEN
        RAISE EXCEPTION 'replacement must prove a changed source/root fingerprint'
            USING ERRCODE = '23514';
    END IF;

    PERFORM strategy_training.transition_training_dataset(
        p_stale_dataset_version_id, 'READY', 'STALE', p_actor_user_id, NULL,
        p_reason, p_request_id
    );
END
$$;

ALTER FUNCTION strategy_training.complete_training_dataset_manifest(
    uuid, char(40), text, text, text, char(64), text, jsonb, bigint,
    integer, integer, integer, integer, char(64), jsonb, jsonb, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.mark_training_dataset_stale_for_replacement(
    uuid, uuid, uuid, text, uuid
) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.complete_training_dataset_manifest(
    uuid, char(40), text, text, text, char(64), text, jsonb, bigint,
    integer, integer, integer, integer, char(64), jsonb, jsonb, text
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.mark_training_dataset_stale_for_replacement(
    uuid, uuid, uuid, text, uuid
) TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '024_training_dataset_lifecycle',
    encode(digest('auto_trade_v2_024_training_dataset_lifecycle_v1', 'sha256'), 'hex'),
    'Add controlled dataset manifests and source-revision replacement lifecycle'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
