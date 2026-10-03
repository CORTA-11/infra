#!/usr/bin/env bash
# Streamable installer: downloads configuration and pulls published images only.
set -Eeuo pipefail
umask 022

usage() {
    cat <<'EOF'
Usage: bash setup-local.sh [--dir PATH] [--ref REF]

Requires OpenSSL, curl, and a running Docker daemon with Compose v2+.
Installs configuration into ./synodus by default; no Git or build tools required.
--ref selects the infra configuration branch/tag (default: main).
EOF
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
install_dir="$PWD/synodus"
config_ref=main
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir|--ref)
            [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"
            if [[ "$1" = --dir ]]; then install_dir="$2"; else config_ref="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
for tool in docker openssl curl; do
    command -v "$tool" >/dev/null || fail "Install $tool first."
done
docker compose version >/dev/null || fail "Install Docker Compose v2 or newer."
docker info >/dev/null 2>&1 || fail "Start Docker and ensure your user can access it."
docker compose up --help | grep -q -- '--wait-timeout' || fail "Update Compose to a version supporting --wait-timeout."
mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd)"

# A checked-out script uses its sibling config files for development. A streamed
# script fetches just these seven files, rather than cloning any repository.
config_source=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    config_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$config_source/compose.local.yaml" ]] || config_source=""
fi
for file in compose.local.yaml docker-compose.yaml envoy.local.yaml \
    prometheus/prometheus.yml grafana/provisioning/datasources/prometheus.yaml \
    grafana/provisioning/dashboards/infra.yaml grafana/dashboards/infra.json; do
    mkdir -p "$(dirname "$install_dir/$file")"
    temp_config="$(mktemp "$install_dir/.download.XXXXXX")"
    if [[ -n "$config_source" ]]; then
        cp "$config_source/$file" "$temp_config"
    elif ! curl --retry 3 -fsSL "https://raw.githubusercontent.com/CORTA-11/infra/$config_ref/$file" -o "$temp_config"; then
        rm -f "$temp_config"
        fail "Could not download $file. Existing credentials and data are preserved."
    fi
    chmod 644 "$temp_config"
    mv "$temp_config" "$install_dir/$file"
done
mkdir -p "$install_dir/secrets"
chmod 700 "$install_dir/secrets"
ensure_secret_file() {
    local target="$install_dir/secrets/$1"
    if [[ ! -s "$target" ]]; then
        if [[ $# -gt 1 ]]; then
            printf '%s\n' "$2" > "$target"
        else
            openssl rand -hex 32 > "$target"
        fi
    fi
    # Compose bind-mounts secrets without remapping ownership. UID 10001 in
    # core-api must be able to read them. The parent directory is owner-only.
    chmod 644 "$target"
}

ensure_secret_file db_admin_user.txt synodus_admin
for secret in db_admin_password.txt db_runtime_password.txt db_migrator_password.txt \
    db_provisioner_password.txt redis_limit_secret.txt redis_invitation_binding_secret.txt csrf_secret.txt; do
    ensure_secret_file "$secret"
done
# MinIO and the API must start with the same storage credentials. Reuse either
# side of a partially initialized pair, and never rotate an existing password.
for pair in 'minio_root_user.txt minio_access_key' 'minio_root_password.txt minio_secret_key.txt'; do
    read -r root_key api_key <<< "$pair"
    if [[ ! -s "$install_dir/secrets/$root_key" && -s "$install_dir/secrets/$api_key" ]]; then
        ensure_secret_file "$root_key" "$(cat "$install_dir/secrets/$api_key")"
    elif [[ "$root_key" = minio_root_user.txt ]]; then
        ensure_secret_file "$root_key" "$(openssl rand -hex 10)"
    else
        ensure_secret_file "$root_key"
    fi
    ensure_secret_file "$api_key" "$(cat "$install_dir/secrets/$root_key")"
done

ensure_env_secret() {
    local env_file="$1" key="$2" value temp_env
    touch "$env_file"
    chmod 600 "$env_file"
    value="$(sed -n "s/^${key}=//p" "$env_file" | head -n 1)"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$value" in
        ''|admin|change-me|change-after-login|development*|generate-*-here)
            temp_env="$(mktemp "$env_file.XXXXXX")"
            sed "/^${key}=/d" "$env_file" > "$temp_env"
            printf '%s=%s\n' "$key" "$(openssl rand -hex 32)" >> "$temp_env"
            mv "$temp_env" "$env_file"
            ;;
    esac
}

for key in JWT_SECRET COLLABORATION_SERVICE_SECRET CURSOR_SECRET AI_SERVICE_TOKEN; do
    ensure_env_secret "$install_dir/.env" "$key"
done

# Local monitoring needs only its own password, not production environment values.
ensure_env_secret "$install_dir/.env" GRAFANA_ADMIN_PASSWORD

compose() { docker compose --project-directory "$install_dir" --env-file "$install_dir/.env" -f "$install_dir/compose.local.yaml" "$@"; }
on_error() {
    printf '\nSetup stopped. Data and containers are preserved; fix the error and rerun.\n' >&2
    compose ps >&2 || true
}
trap on_error ERR

compose --profile setup config --quiet
printf '\nPulling published images...\n'
compose --profile setup pull
printf '\nStarting database, cache, and storage...\n'
compose up --no-build -d --wait --wait-timeout 120 postgres redis minio
printf '\nApplying migrations, configuring database roles, and creating the storage bucket...\n'
compose --profile setup run --rm --no-deps --interactive=false -T local-setup
printf '\nStarting application services and monitoring...\n'
compose up --no-build -d --wait --wait-timeout 180

wait_url() {
    local url="$1" attempt
    for ((attempt=0; attempt<60; attempt++)); do
        if curl --max-time 5 -fsS -o /dev/null "$url"; then return; fi
        sleep 2
    done
    fail "Readiness check failed: $url"
}
wait_url http://localhost:9901/ready
wait_url http://localhost:10000/
wait_url http://localhost:9090/-/ready
wait_url http://localhost:3001/api/health
session_status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://localhost:10000/api/v1/auth/session)"
[[ "$session_status" = 401 ]] || fail "Expected public API session check to return 401; got $session_status."
printf '\nSynodus is ready: http://localhost:10000\nGrafana: http://localhost:3001 (password in %s/.env)\nService secrets: %s/.env and %s/secrets/\nRegister your first account in the application.\n' "$install_dir" "$install_dir" "$install_dir"
