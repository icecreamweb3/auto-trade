#!/bin/sh
set -eu

initial_applied=$(
    psql --set=ON_ERROR_STOP=1 --tuples-only --no-align --command \
        "SELECT EXISTS (
            SELECT 1 FROM core.schema_migrations
            WHERE version = '001_initial_schema' AND success
        )" 2>/dev/null || echo f
)
if [ "${initial_applied}" = "t" ]; then
    echo "Skipping applied migration 001_initial_schema"
else
    echo "Applying /migrations/001_initial_schema.sql"
    psql --set=ON_ERROR_STOP=1 --file=/migrations/001_initial_schema.sql
fi

for migration in /migrations/[0-9][0-9][0-9]_*.sql; do
    [ -f "${migration}" ] || continue
    version=$(basename "${migration}" .sql)
    applied=$(
        psql --set=ON_ERROR_STOP=1 --tuples-only --no-align --command \
            "SELECT EXISTS (
                SELECT 1 FROM core.schema_migrations
                WHERE version = '${version}' AND success
            )"
    )
    if [ "${applied}" = "t" ]; then
        echo "Skipping applied migration ${version}"
        continue
    fi
    echo "Applying ${migration}"
    psql --set=ON_ERROR_STOP=1 --file="${migration}"
done
