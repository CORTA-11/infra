#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Mounted files must be readable by the services' non-root container users.
gen_secret() {
    local file="$1" value="${2:-}"
    if [ ! -s "$SECRETS_DIR/$file" ]; then
        if [ -n "$value" ]; then
            printf '%s\n' "$value" > "$SECRETS_DIR/$file"
        else
            openssl rand -hex 32 > "$SECRETS_DIR/$file"
        fi
        printf 'Created %s\n' "$file"
    fi
    chmod 644 "$SECRETS_DIR/$file"
}

gen_secret db_admin_user.txt synodus_admin
for file in db_admin_password.txt db_runtime_password.txt db_migrator_password.txt \
    db_provisioner_password.txt redis_limit_secret.txt redis_invitation_binding_secret.txt csrf_secret.txt; do
    gen_secret "$file"
done

# Recover a partially initialized pair, then keep API credentials aligned with MinIO.
for pair in 'minio_root_user.txt minio_access_key' 'minio_root_password.txt minio_secret_key.txt'; do
    read -r root_file api_file <<< "$pair"
    if [ ! -s "$SECRETS_DIR/$root_file" ] && [ -s "$SECRETS_DIR/$api_file" ]; then
        gen_secret "$root_file" "$(cat "$SECRETS_DIR/$api_file")"
    else
        gen_secret "$root_file"
    fi
    if ! cmp -s "$SECRETS_DIR/$root_file" "$SECRETS_DIR/$api_file"; then
        cp "$SECRETS_DIR/$root_file" "$SECRETS_DIR/$api_file"
    fi
    chmod 644 "$SECRETS_DIR/$api_file"
done

ensure_env_secret() {
    local key="$1" env_file="$SCRIPT_DIR/.env" value
    touch "$env_file"
    chmod 600 "$env_file"
    value="$(sed -n "s/^${key}=//p" "$env_file" | head -n 1)"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$value" in
      ''|admin|change-me|change-after-login|development*|generate-*-here)
        local secret
        secret=$(openssl rand -hex 32)
        if grep -q "^${key}=" "$env_file"; then
            sed -i "s|^${key}=.*|${key}=${secret}|" "$env_file"
        else
            printf '%s=%s\n' "$key" "$secret" >> "$env_file"
        fi
        ;;
    esac
}
for key in JWT_SECRET COLLABORATION_SERVICE_SECRET CURSOR_SECRET AI_SERVICE_TOKEN GRAFANA_ADMIN_PASSWORD; do
    ensure_env_secret "$key"
done
printf 'Production secrets are ready.\n'
