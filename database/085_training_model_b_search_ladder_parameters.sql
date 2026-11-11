\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_config_versions
    DROP CONSTRAINT training_config_versions_config_type_check1;

ALTER TABLE strategy_training.training_config_versions
    ADD CONSTRAINT training_config_versions_config_type_nonblank_check
    CHECK (btrim(config_type) <> '');

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '085_training_model_b_search_ladder_parameters',
    encode(digest(
        'auto_trade_v2_085_training_model_b_search_ladder_parameters_v1',
        'sha256'
    ), 'hex'),
    'Remove the legacy config-type whitelist before governed Model-B ladder search'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
