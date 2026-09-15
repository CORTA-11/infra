#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/secrets"

mkdir -p "$SECRETS_DIR"

echo "Generating production secrets in $SECRETS_DIR ..."

# Helper function: generate random hex string if file doesn't exist
gen_secret() {
    local file="$1"
    local length="${2:-16}"
    if [ ! -f "$SECRETS_DIR/$file" ]; then
        openssl rand -hex "$length" > "$SECRETS_DIR/$file"
        echo "Created $file"
    else
        echo "Skipped $file (already exists)"
    fi
}

gen_secret "db_admin_password.txt" 16
gen_secret "db_runtime_password.txt" 16
gen_secret "db_provisioner_password.txt" 16
gen_secret "minio_root_password.txt" 16
gen_secret "minio_secret_key.txt" 16
gen_secret "redis_limit_secret.txt" 32
gen_secret "redis_invitation_binding_secret.txt" 32
gen_secret "csrf_secret.txt" 32

if [ ! -f "$SECRETS_DIR/db_admin_user.txt" ]; then
    echo "synodus_admin" > "$SECRETS_DIR/db_admin_user.txt"
    echo "Created db_admin_user.txt"
fi

if [ ! -f "$SECRETS_DIR/minio_root_user.txt" ]; then
    echo "minio_admin" > "$SECRETS_DIR/minio_root_user.txt"
    echo "Created minio_root_user.txt"
fi

if [ ! -f "$SECRETS_DIR/minio_access_key" ]; then
    echo "minio_key" > "$SECRETS_DIR/minio_access_key"
    echo "Created minio_access_key"
fi

echo "All secrets generated successfully!"
