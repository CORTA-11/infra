#!/bin/sh
set -eu

# Percent-encode credentials so later password changes can include URL characters.
urlencode() { printf '%s' "$1" | od -An -v -tx1 | tr -d '\n' | sed 's/ *\([0-9a-f][0-9a-f]\)/%\1/g'; }
admin_user="$(cat /run/secrets/db_admin_user.txt)"
admin_password="$(cat /run/secrets/db_admin_password.txt)"
BOOTSTRAP_DATABASE_URL="postgres://$(urlencode "$admin_user"):$(urlencode "$admin_password")@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
MIGRATION_DATABASE_URL="$BOOTSTRAP_DATABASE_URL"
DB_RUNTIME_PASSWORD="$(cat /run/secrets/db_runtime_password.txt)"
DB_MIGRATOR_PASSWORD="$(cat /run/secrets/db_migrator_password.txt)"
DB_PROVISIONER_PASSWORD="$(cat /run/secrets/db_provisioner_password.txt)"
export BOOTSTRAP_DATABASE_URL MIGRATION_DATABASE_URL
export DB_RUNTIME_PASSWORD DB_MIGRATOR_PASSWORD DB_PROVISIONER_PASSWORD
migrate up-all
dbroles
unset BOOTSTRAP_DATABASE_URL MIGRATION_DATABASE_URL DB_MIGRATOR_PASSWORD DB_PROVISIONER_PASSWORD
exec bootstrap
