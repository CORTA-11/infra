#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo " Initializing Database and Roles"
echo "=========================================="

POSTGRES_CONTAINER=$(docker ps --format '{{.Names}}' | grep "postgres" | head -n 1 || true)
if [ -z "$POSTGRES_CONTAINER" ]; then
    echo "Error: postgres container is not running. Run ./deploy.sh first to start postgres."
    exit 1
fi

ADMIN_USER="synodus_admin"
if [ -f "secrets/db_admin_user.txt" ]; then
    ADMIN_USER="$(cat secrets/db_admin_user.txt)"
fi

DB_NAME="appdb"
if [ -f ".env" ] && grep -q "^DB_NAME=" .env; then
    DB_NAME="$(grep "^DB_NAME=" .env | cut -d= -f2 | tr -d ' "' )"
fi

TABLE_EXISTS=$(docker exec -i "$POSTGRES_CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='orgs';" 2>/dev/null || true)

if [ "$TABLE_EXISTS" != "1" ]; then
    echo "--> Applying database schema and roles to '$DB_NAME' as '$ADMIN_USER'..."
    docker exec -i "$POSTGRES_CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" < init-schema.sql
else
    echo "--> Database schema already applied (public.orgs exists)."
fi

echo "--> Setting passwords for application roles..."
DB_RUNTIME_PASS="$(cat secrets/db_runtime_password.txt)"
DB_PROVISIONER_PASS="$(cat secrets/db_provisioner_password.txt)"
DB_ADMIN_PASS="$(cat secrets/db_admin_password.txt)"

docker exec -i "$POSTGRES_CONTAINER" psql -U "$ADMIN_USER" -d "$DB_NAME" -c \
  "ALTER ROLE synodus_runtime PASSWORD '$DB_RUNTIME_PASS';
   ALTER ROLE synodus_migrator PASSWORD '$DB_ADMIN_PASS';
   ALTER ROLE synodus_provisioner PASSWORD '$DB_PROVISIONER_PASS';"

echo "=========================================="
echo " Database initialization complete!"
echo "=========================================="
