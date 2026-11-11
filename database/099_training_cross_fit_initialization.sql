\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_cross_fit_initializations (
    parent_experiment_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_experiments,
    cross_fit_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    cross_fit_execution_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_executions,
    actor_user_id uuid NOT NULL REFERENCES core.app_users,
    parent_l0_evidence_hash char(64) NOT NULL
        CHECK (parent_l0_evidence_hash ~ '^[0-9a-f]{64}$'),
    config_manifest_hash char(64) NOT NULL
        CHECK (config_manifest_hash ~ '^[0-9a-f]{64}$'),
    coverage_evidence_hash char(64) NOT NULL
        CHECK (coverage_evidence_hash ~ '^[0-9a-f]{64}$'),
    source_revision_watermark_hash char(64) NOT NULL
        CHECK (source_revision_watermark_hash ~ '^[0-9a-f]{64}$'),
    initialization_evidence_hash char(64) NOT NULL
        CHECK (initialization_evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TRIGGER trg_training_cross_fit_initializations_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_cross_fit_initializations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.initialize_training_cross_fit_from_discovery(
    p_parent_experiment_id uuid, p_added_config_version_ids jsonb,
    p_actor_user_id uuid
)
RETURNS TABLE (
    cross_fit_experiment_id uuid,
    cross_fit_execution_id uuid,
    initialization_evidence_hash char(64)
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE parent_record strategy_training.training_experiments%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        protocol_record strategy_training.training_config_versions%ROWTYPE;
        existing_record strategy_training.training_cross_fit_initializations%ROWTYPE;
        new_experiment_id uuid; new_execution_id uuid;
        parent_l0_hash char(64); config_manifest char(64);
        coverage_hash char(64); source_hash char(64); evidence_hash char(64);
        minimum_folds integer; minimum_days integer; minimum_events bigint;
        required_type text; ready_count integer; bound_count integer;
        selected_config_id uuid;
        required_types text[] := ARRAY[
            'CROSS_FIT_PROTOCOL', 'DATA_QUALITY_RULES', 'ELIGIBLE_POOL_RULES',
            'EXIT_RULES', 'FACTOR_REGISTRY', 'FEE_MODEL',
            'HOLDING_HORIZON_RULES', 'MODEL_B_SAMPLE_MIX',
            'MODEL_B_SEARCH_SPACE', 'OPPORTUNITY_DEFINITION',
            'PORTFOLIO_RULES', 'RANDOM_BASELINE',
            'REPRODUCIBILITY_TOLERANCE', 'RESOURCE_LIMITS',
            'SCORING_MODEL_A', 'SCORING_MODEL_B', 'SEARCH_SPACE',
            'SLIPPAGE_MODEL', 'TICKER_POOL_RULES',
            'VISIBILITY_CUTOFF_POLICY'
        ];
        added_types text[] := ARRAY[
            'CROSS_FIT_PROTOCOL', 'EXIT_RULES', 'MODEL_B_SAMPLE_MIX',
            'MODEL_B_SEARCH_SPACE', 'PORTFOLIO_RULES', 'SCORING_MODEL_B'
        ];
BEGIN
    IF p_actor_user_id IS NULL THEN
        RAISE EXCEPTION 'Cross-fit initialization requires an actor'
            USING ERRCODE = '22023';
    END IF;
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );
    IF jsonb_typeof(p_added_config_version_ids) IS DISTINCT FROM 'object'
       OR (SELECT count(*) FROM jsonb_object_keys(p_added_config_version_ids))
            <> cardinality(added_types)
       OR EXISTS (
           SELECT 1
           FROM jsonb_object_keys(p_added_config_version_ids) selected_type
           WHERE selected_type <> ALL(added_types)
       ) THEN
        RAISE EXCEPTION 'Cross-fit initialization requires exactly the six explicit config selections'
            USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_parent_experiment_id::text, 99)
    );
    SELECT * INTO existing_record
    FROM strategy_training.training_cross_fit_initializations initialization
    WHERE initialization.parent_experiment_id = p_parent_experiment_id;
    IF FOUND THEN
        RETURN QUERY SELECT existing_record.cross_fit_experiment_id,
            existing_record.cross_fit_execution_id,
            existing_record.initialization_evidence_hash;
        RETURN;
    END IF;

    SELECT * INTO STRICT parent_record
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = p_parent_experiment_id FOR SHARE;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = parent_record.dataset_version_id FOR SHARE;
    IF parent_record.experiment_mode <> 'DISCOVERY'
       OR parent_record.state <> 'STOPPED'
       OR dataset_record.partition <> 'TRAIN'
       OR dataset_record.status <> 'READY'
       OR dataset_record.root_fingerprint IS NULL THEN
        RAISE EXCEPTION 'Cross-fit initialization requires a stopped DISCOVERY on READY TRAIN data'
            USING ERRCODE = '23514';
    END IF;
    SELECT evidence.evidence_hash INTO STRICT parent_l0_hash
    FROM strategy_training.training_iteration_evidence_l0 evidence
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = evidence.iteration_id
    WHERE iteration.experiment_id = parent_record.experiment_id
      AND iteration.state = 'SUCCEEDED'
      AND evidence.partition = 'TRAIN'
      AND evidence.terminal_state = 'SUCCEEDED'
      AND evidence.hard_gate_passed
      AND evidence.objective_value IS NOT NULL;
    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.experiment_id = parent_record.experiment_id
          AND config.status <> 'READY'
    ) THEN
        RAISE EXCEPTION 'parent experiment contains a non-READY frozen config'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_data_quality_reports report
        WHERE report.dataset_version_id = dataset_record.dataset_version_id
          AND report.is_required AND report.status <> 'PASS'
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_data_quality_reports report
        WHERE report.dataset_version_id = dataset_record.dataset_version_id
          AND report.is_required AND report.status = 'PASS'
    ) THEN
        RAISE EXCEPTION 'Cross-fit initialization requires all required quality reports to PASS'
            USING ERRCODE = '23514';
    END IF;
    coverage_hash := (
        SELECT encode(digest(string_agg(report.evidence_hash, ''
            ORDER BY report.dependency_name), 'sha256'), 'hex')
        FROM strategy_training.training_data_quality_reports report
        WHERE report.dataset_version_id = dataset_record.dataset_version_id
          AND report.is_required
    );
    source_hash := encode(digest(
        dataset_record.source_revision_watermark::text, 'sha256'
    ), 'hex');

    FOREACH required_type IN ARRAY added_types LOOP
        BEGIN
            selected_config_id :=
                (p_added_config_version_ids ->> required_type)::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Cross-fit config % is not a UUID', required_type
                USING ERRCODE = '22023';
        END;
        SELECT count(*) INTO ready_count
        FROM strategy_training.training_config_versions config
        WHERE config.config_version_id = selected_config_id
          AND config.config_type = required_type
          AND config.status = 'READY';
        IF ready_count <> 1 THEN
            RAISE EXCEPTION 'selected Cross-fit config % is not a matching READY version',
                required_type USING ERRCODE = '23514';
        END IF;
    END LOOP;

    SELECT * INTO STRICT protocol_record
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id =
            (p_added_config_version_ids ->> 'CROSS_FIT_PROTOCOL')::uuid
      AND config.config_type = 'CROSS_FIT_PROTOCOL'
      AND config.status = 'READY';
    IF protocol_record.config_json #>> '{question_readiness,Q-019}'
            IS DISTINCT FROM 'READY'
       OR protocol_record.config_json #>> '{question_readiness,Q-029}'
            IS DISTINCT FROM 'READY'
       OR protocol_record.config_json #>> '{question_readiness,Q-030}'
            IS DISTINCT FROM 'READY'
       OR protocol_record.config_json #>> '{question_readiness,Q-036}'
            IS DISTINCT FROM 'READY'
       OR protocol_record.config_json #>> '{question_readiness,Q-039}'
            IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION 'Cross-fit protocol question readiness is incomplete'
            USING ERRCODE = '23514';
    END IF;
    minimum_folds := (protocol_record.config_json #>>
        '{q036_go_no_go,minimum_eligible_outer_folds}')::integer;
    minimum_days := (protocol_record.config_json #>>
        '{q036_go_no_go,minimum_effective_independent_utc_days}')::integer;
    minimum_events := (protocol_record.config_json #>>
        '{q036_go_no_go,minimum_complete_event_count}')::bigint;
    IF minimum_folds <= 0 OR minimum_days <= 0 OR minimum_events <= 0 THEN
        RAISE EXCEPTION 'Cross-fit protocol power thresholds are invalid'
            USING ERRCODE = '23514';
    END IF;

    new_experiment_id := strategy_training.create_training_experiment(
        'DISCOVERY', parent_record.experiment_id, dataset_record.dataset_version_id,
        parent_record.resource_limit_config_version_id,
        format('cross-fit-model-a-b-%s', parent_record.experiment_id),
        encode(digest(concat_ws('|', parent_record.exposure_identity_hash,
            dataset_record.root_fingerprint, protocol_record.content_hash,
            'CROSS_FIT_MODEL_A_B'), 'sha256'), 'hex'),
        p_actor_user_id
    );
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    )
    SELECT new_experiment_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = parent_record.experiment_id;
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    )
    SELECT new_experiment_id, selected.config_type,
           selected.config_version_id::uuid
    FROM jsonb_each_text(p_added_config_version_ids)
         AS selected(config_type, config_version_id)
    WHERE NOT EXISTS (
          SELECT 1
          FROM strategy_training.training_experiment_config_bindings binding
          WHERE binding.experiment_id = new_experiment_id
            AND binding.config_type = selected.config_type
      );

    FOREACH required_type IN ARRAY added_types LOOP
        selected_config_id :=
            (p_added_config_version_ids ->> required_type)::uuid;
        IF NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_experiment_config_bindings binding
            WHERE binding.experiment_id = new_experiment_id
              AND binding.config_type = required_type
              AND binding.config_version_id = selected_config_id
        ) THEN
            RAISE EXCEPTION 'Cross-fit experiment does not freeze selected % config',
                required_type USING ERRCODE = '23514';
        END IF;
    END LOOP;

    FOREACH required_type IN ARRAY required_types LOOP
        SELECT count(*) INTO bound_count
        FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.experiment_id = new_experiment_id
          AND binding.config_type = required_type
          AND config.status = 'READY';
        IF bound_count <> 1 THEN
            RAISE EXCEPTION 'Cross-fit experiment lacks one READY % binding',
                required_type USING ERRCODE = '23514';
        END IF;
    END LOOP;
    SELECT encode(digest(string_agg(concat_ws('|', binding.config_type,
               config.content_hash), '' ORDER BY binding.config_type),
               'sha256'), 'hex')
    INTO STRICT config_manifest
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.experiment_id = new_experiment_id;

    PERFORM strategy_training.transition_training_experiment(
        new_experiment_id, 'DRAFT', 'RUNNING', p_actor_user_id, NULL,
        'start governed Cross-fit Model-A/Model-B execution', gen_random_uuid()
    );
    new_execution_id := strategy_training.create_cross_fit_execution(
        new_experiment_id, protocol_record.config_version_id, 'ACCEPTED',
        coverage_hash, source_hash, protocol_record.config_json -> 'question_readiness',
        minimum_folds, minimum_days, minimum_events
    );
    evidence_hash := encode(digest(jsonb_build_object(
        'actor_user_id', p_actor_user_id,
        'config_manifest_hash', config_manifest,
        'coverage_evidence_hash', coverage_hash,
        'cross_fit_execution_id', new_execution_id,
        'cross_fit_experiment_id', new_experiment_id,
        'dataset_root_fingerprint', dataset_record.root_fingerprint,
        'parent_experiment_id', parent_record.experiment_id,
        'parent_l0_evidence_hash', parent_l0_hash,
        'protocol_content_hash', protocol_record.content_hash,
        'source_revision_watermark_hash', source_hash
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_cross_fit_initializations (
        parent_experiment_id, cross_fit_experiment_id, cross_fit_execution_id,
        actor_user_id, parent_l0_evidence_hash, config_manifest_hash,
        coverage_evidence_hash, source_revision_watermark_hash,
        initialization_evidence_hash
    ) VALUES (
        parent_record.experiment_id, new_experiment_id, new_execution_id,
        p_actor_user_id, parent_l0_hash, config_manifest, coverage_hash,
        source_hash, evidence_hash
    );
    RETURN QUERY SELECT new_experiment_id, new_execution_id, evidence_hash;
END
$$;

ALTER TABLE strategy_training.training_cross_fit_initializations
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.initialize_training_cross_fit_from_discovery(uuid, jsonb, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_initializations FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.initialize_training_cross_fit_from_discovery(uuid, jsonb, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.initialize_training_cross_fit_from_discovery(uuid, jsonb, uuid)
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '099_training_cross_fit_initialization',
    encode(digest('auto_trade_v2_099_training_cross_fit_initialization_v1',
                  'sha256'), 'hex'),
    'Create an audited Cross-fit execution from successful DISCOVERY evidence'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
