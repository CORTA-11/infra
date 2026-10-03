#!/usr/bin/env bash
# Also works when streamed to bash: no interactive input is read from stdin.
set -Eeuo pipefail
# Sources copied into images must remain readable by non-root container users.
# Secret directories and environment files get tighter permissions below.
umask 022

usage() {
    cat <<'EOF'
Usage: bash setup-local.sh [--dir PATH] [--ref REF]

Requires Git, OpenSSL, curl, and a running Docker daemon with Compose v2+.
Clones missing CORTA-11 repositories; existing checkouts are never updated.
Defaults to the script's sibling repositories, or ./synodus when piped to bash.
--ref selects the branch/tag for new clones (default: main).
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
install_dir=""
repo_ref=main
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir|--ref)
            [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"
            if [[ "$1" = --dir ]]; then install_dir="$2"; else repo_ref="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

if [[ -z "$install_dir" ]]; then
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        install_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    else
        install_dir="$PWD/synodus"
    fi
fi
for tool in git docker openssl curl; do
    command -v "$tool" >/dev/null || fail "Install $tool first."
done
docker compose version >/dev/null || fail "Install Docker Compose v2 or newer."
docker info >/dev/null 2>&1 || fail "Start Docker and ensure your user can access it."
docker compose up --help | grep -q -- '--wait-timeout' || fail "Update Compose to a version supporting --wait-timeout."

mkdir -p "$install_dir"
install_dir="$(cd "$install_dir" && pwd)"
for repo in infra core-api ai-service socket-server web-frontend; do
    if [[ ! -e "$install_dir/$repo" ]]; then
        git clone --branch "$repo_ref" --single-branch "https://github.com/CORTA-11/$repo.git" "$install_dir/$repo"
    else
        [[ -d "$install_dir/$repo/.git" ]] || fail "$install_dir/$repo exists but is not a Git checkout."
        printf 'Using existing checkout: %s\n' "$install_dir/$repo"
    fi
done

core="$install_dir/core-api"
infra="$install_dir/infra"
[[ -f "$infra/compose.local-setup.yaml" ]] || fail "infra checkout needs the local setup files."
[[ -f "$core/.env" ]] || cp "$core/.env.example" "$core/.env"
mkdir -p "$core/.local_secrets"
chmod 700 "$core/.local_secrets"

ensure_secret_file() {
    local target="$core/.local_secrets/$1"
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
    if [[ ! -s "$core/.local_secrets/$root_key" && -s "$core/.local_secrets/$api_key" ]]; then
        ensure_secret_file "$root_key" "$(cat "$core/.local_secrets/$api_key")"
    elif [[ "$root_key" = minio_root_user.txt ]]; then
        ensure_secret_file "$root_key" "$(openssl rand -hex 10)"
    else
        ensure_secret_file "$root_key"
    fi
    ensure_secret_file "$api_key" "$(cat "$core/.local_secrets/$root_key")"
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
    ensure_env_secret "$core/.env" "$key"
done

# Local monitoring needs only its own password, not production environment values.
ensure_env_secret "$infra/.env" GRAFANA_ADMIN_PASSWORD

core_compose() { docker compose --project-directory "$core" --env-file "$core/.env" -f "$core/docker-compose.yaml" "$@"; }
infra_compose() { docker compose --project-directory "$infra" --env-file "$infra/.env" -f "$infra/compose.yaml" "$@"; }
web_compose() { docker compose --project-directory "$install_dir/web-frontend" -f "$install_dir/web-frontend/docker-compose.yaml" "$@"; }
on_error() {
    printf '\nSetup stopped. Data and containers are preserved; fix the error and rerun.\n' >&2
    core_compose ps >&2 || true
}
trap on_error ERR

core_compose config --quiet
web_compose config --quiet
infra_compose config --quiet
docker network inspect synodus-network >/dev/null 2>&1 || docker network create synodus-network
printf '\nStarting database, cache, and storage...\n'
core_compose up -d --wait --wait-timeout 120 postgres redis minio
printf '\nApplying migrations, configuring database roles, and creating the storage bucket...\n'
docker compose --project-directory "$core" --env-file "$core/.env" -f "$core/docker-compose.yaml" \
    -f "$infra/compose.local-setup.yaml" --profile setup run --build --rm --no-deps --interactive=false -T local-setup
printf '\nBuilding and starting application services...\n'
core_compose up --build -d --wait --wait-timeout 180 api socket-server collaboration-server
web_compose up --build -d --wait --wait-timeout 180 web
infra_compose up -d --wait --wait-timeout 120

wait_url() {
    local url="$1" attempt
    for ((attempt=0; attempt<60; attempt++)); do
        if curl --max-time 5 -fsS -o /dev/null "$url"; then return; fi
        sleep 2
    done
    fail "Readiness check failed: $url"
}
wait_url http://localhost:9901/ready
wait_url http://localhost:8080/health/ready
wait_url http://localhost:10000/
wait_url http://localhost:8081/health
wait_url http://localhost:8082/health
wait_url http://localhost:9090/-/ready
wait_url http://localhost:3001/api/health
session_status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://localhost:10000/api/v1/auth/session)"
[[ "$session_status" = 401 ]] || fail "Expected public API session check to return 401; got $session_status."
printf '\nSynodus is ready: http://localhost:10000\nGrafana: http://localhost:3001 (password in %s/.env)\nService secrets: %s/.env and %s/.local_secrets/\nCheckouts: %s\nRegister your first account in the application.\n' "$infra" "$core" "$core" "$install_dir"
