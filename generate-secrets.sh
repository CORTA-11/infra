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

cp "$SECRETS_DIR/minio_root_user.txt" "$SECRETS_DIR/minio_access_key"
cp "$SECRETS_DIR/minio_root_password.txt" "$SECRETS_DIR/minio_secret_key.txt"

# Helper function: ensure .env has valid non-placeholder 32-byte production secrets
ensure_env_secret() {
    local key="$1"
    local length="${2:-32}"
    local env_file="$SCRIPT_DIR/.env"
    touch "$env_file"
    if ! grep -q "^${key}=" "$env_file" || grep -E "^${key}=(change-me|development|generate-.*-here|$)" "$env_file" >/dev/null 2>&1; then
        local secret
        secret=$(openssl rand -hex "$length")
        if grep -q "^${key}=" "$env_file"; then
            sed -i "s|^${key}=.*|${key}=${secret}|" "$env_file"
        else
            echo "${key}=${secret}" >> "$env_file"
        fi
        echo "Configured $key in .env"
    fi
}

ensure_env_secret "JWT_SECRET" 32
ensure_env_secret "COLLABORATION_SERVICE_SECRET" 32
ensure_env_secret "CURSOR_SECRET" 32

echo "All secrets and .env keys generated successfully!"
