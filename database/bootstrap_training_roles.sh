#!/bin/sh
set -eu

# Deployment-only bootstrap. Migrations create NOLOGIN group roles; this
# script creates independent LOGIN service accounts and grants one group to
# each account. Passwords are supplied by a secret manager and never echoed.

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"

psql_admin() {
    psql --set=ON_ERROR_STOP=1 --quiet "$@"
}

while IFS='|' read -r group_role login_role password_var; do
    eval "password=\${$password_var-}"
    if [ -z "$password" ]; then
        echo "missing required secret: ${password_var}" >&2
        exit 2
    fi

    # Keep the secret out of the psql argv.  It is read from the process
    # environment by psql and used only for this transaction.
    TRAINING_ROLE_PASSWORD="$password" psql_admin \
        -v group_role="$group_role" -v login_role="$login_role" <<'SQL'
\getenv role_password TRAINING_ROLE_PASSWORD
DO $do$
DECLARE
  training_group record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'login_role') THEN
    EXECUTE format(
      'CREATE ROLE %I LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
      :'login_role', :'role_password'
    );
  ELSE
    EXECUTE format(
      'ALTER ROLE %I LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
      :'login_role', :'role_password'
    );
  END IF;
  FOR training_group IN
    SELECT rolname
    FROM pg_roles
    WHERE rolname LIKE 'tb2_training\_%'
      AND NOT rolcanlogin
  LOOP
    EXECUTE format('REVOKE %I FROM %I', training_group.rolname, :'login_role');
  END LOOP;
  EXECUTE format('GRANT %I TO %I', :'group_role', :'login_role');
END
$do$;
SQL
done <<'ROLE_SPECS'
tb2_training_rw|tb2_training_rw_app|TRAINING_RW_PASSWORD
tb2_training_orchestrator|tb2_training_orchestrator_app|TRAINING_ORCHESTRATOR_PASSWORD
tb2_training_optimizer|tb2_training_optimizer_app|TRAINING_OPTIMIZER_PASSWORD
tb2_training_evaluator|tb2_training_evaluator_app|TRAINING_EVALUATOR_PASSWORD
tb2_training_model_b|tb2_training_model_b_app|TRAINING_MODEL_B_PASSWORD
tb2_training_weak_holdout_executor|tb2_training_weak_holdout_app|TRAINING_WEAK_HOLDOUT_PASSWORD
tb2_training_test_executor|tb2_training_test_executor_app|TRAINING_TEST_EXECUTOR_PASSWORD
tb2_training_test_auditor|tb2_training_test_auditor_app|TRAINING_TEST_AUDITOR_PASSWORD
tb2_training_test_backup|tb2_training_test_backup_app|TRAINING_TEST_BACKUP_PASSWORD
tb2_training_llm_gateway|tb2_training_llm_gateway_app|TRAINING_LLM_GATEWAY_PASSWORD
ROLE_SPECS

# Fail closed if an account acquired powerful or live-trading privileges.
psql_admin <<'SQL'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname LIKE 'tb2_training\_%\_app' ESCAPE '\\'
          AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)
    ) THEN
        RAISE EXCEPTION 'training account has forbidden role attributes';
    END IF;
END
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_auth_members m
        JOIN pg_roles member_role ON member_role.oid = m.member
        JOIN pg_roles granted_role ON granted_role.oid = m.roleid
        WHERE member_role.rolname LIKE 'tb2_training\_%\_app' ESCAPE '\\'
          AND granted_role.rolname IN ('tb2_trader', 'tb2_collector')
    ) THEN
        RAISE EXCEPTION 'training account has live or collector role membership';
    END IF;
END
$$;
SQL

echo "training LOGIN role bootstrap and privilege checks completed"
