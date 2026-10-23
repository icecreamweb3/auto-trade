\set ON_ERROR_STOP on
\pset pager off

BEGIN;

ALTER TABLE core.app_users
ADD COLUMN IF NOT EXISTS username varchar(80),
ADD COLUMN IF NOT EXISTS role varchar(16) NOT NULL DEFAULT 'NORMAL';

ALTER TABLE core.app_users
DROP CONSTRAINT IF EXISTS ck_app_users_role;
ALTER TABLE core.app_users
ADD CONSTRAINT ck_app_users_role
CHECK (role IN ('NORMAL', 'ADVANCED', 'ADMIN'));

ALTER TABLE core.app_users
DROP CONSTRAINT IF EXISTS ck_app_users_username;
ALTER TABLE core.app_users
ADD CONSTRAINT ck_app_users_username
CHECK (username IS NULL OR btrim(username) <> '');

CREATE UNIQUE INDEX IF NOT EXISTS ux_app_users_username
ON core.app_users (lower(username))
WHERE username IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_app_users_role_created
ON core.app_users (role, created_at DESC);

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '011_user_roles',
    encode(digest('auto_trade_v2_011_user_roles_v1', 'sha256'), 'hex'),
    'Add normal, advanced and administrator user levels'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
