#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.prod.yaml"
SERVICE="${1:-}"

echo "=================================================="
echo " [CORTA Deploy] Starting deployment: $(date)"
echo " [CORTA Deploy] Target: ${SERVICE:-all services}"
echo "=================================================="

# Check if production compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: $COMPOSE_FILE not found in $SCRIPT_DIR"
    exit 1
fi

# Ensure production secrets and .env exist
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
        echo "--> Configured strong production secret for $key in .env"
    fi
}

ensure_env_secret "JWT_SECRET" 32
ensure_env_secret "COLLABORATION_SERVICE_SECRET" 32
ensure_env_secret "CURSOR_SECRET" 32

# Generate missing secrets if needed
if [ -f "./generate-secrets.sh" ]; then
    ./generate-secrets.sh >/dev/null 2>&1 || true
fi

# Ensure MinIO keys are set in .env
if [ -f "secrets/minio_root_user.txt" ] && [ -f "secrets/minio_root_password.txt" ]; then
    MINIO_U="$(tr -d '\r\n' < secrets/minio_root_user.txt)"
    MINIO_P="$(tr -d '\r\n' < secrets/minio_root_password.txt)"
    export MINIO_ACCESS_KEY="$MINIO_U"
    export MINIO_SECRET_KEY="$MINIO_P"
    env_file="$SCRIPT_DIR/.env"
    if ! grep -q "^MINIO_ACCESS_KEY=" "$env_file"; then
        echo "MINIO_ACCESS_KEY=${MINIO_U}" >> "$env_file"
    else
        sed -i "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=${MINIO_U}|" "$env_file"
    fi
    if ! grep -q "^MINIO_SECRET_KEY=" "$env_file"; then
        echo "MINIO_SECRET_KEY=${MINIO_P}" >> "$env_file"
    else
        sed -i "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_P}|" "$env_file"
    fi
fi

# 1. Pull latest image(s) from ghcr.io
echo "--> Pulling latest image(s)..."
if [ -n "$SERVICE" ]; then
    docker compose -f "$COMPOSE_FILE" pull "$SERVICE"
    echo "--> Restarting $SERVICE (without touching dependencies)..."
    docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"
else
    docker compose -f "$COMPOSE_FILE" pull

    echo "--> Ensuring database and storage services are up..."
    docker compose -f "$COMPOSE_FILE" up -d postgres redis minio

    # Wait for postgres to report healthy
    echo "--> Waiting for PostgreSQL to be healthy..."
    for i in $(seq 1 30); do
        PG_CID=$(docker compose -f "$COMPOSE_FILE" ps -q postgres 2>/dev/null || true)
        if [ -n "$PG_CID" ]; then
            STATUS=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$PG_CID" 2>/dev/null || true)
            if [ "$STATUS" = "healthy" ]; then
                break
            fi
        fi
        sleep 1
    done

    # Run database initialization if script is present
    if [ -f "./init-db.sh" ]; then
        ./init-db.sh
    fi

    # Ensure MinIO bucket exists
    if [ -f "./init-minio.sh" ]; then
        ./init-minio.sh || true
    fi

    echo "--> Updating and starting all application services..."
    if ! docker compose -f "$COMPOSE_FILE" up -d --force-recreate; then
        echo "--------------------------------------------------"
        echo " [Error Diagnostics] Deployment failed! Container logs:"
        echo ">>> infra-api-1 logs:"
        docker logs infra-api-1 --tail 30 2>&1 || true
        echo "--------------------------------------------------"
        exit 1
    fi
fi

# 2. Prune dangling images to save server storage
echo "--> Cleaning up dangling images..."
docker image prune -f

# 3. Status check
echo "--> Checking container status..."
sleep 3
docker compose -f "$COMPOSE_FILE" ps

RESTARTING=$(docker compose -f "$COMPOSE_FILE" ps --filter "status=restarting" -q 2>/dev/null || true)
if [ -n "$RESTARTING" ]; then
    echo "--------------------------------------------------"
    echo " [Diagnostics] Detected restarting container(s):"
    docker compose -f "$COMPOSE_FILE" ps --filter "status=restarting"
    echo "--------------------------------------------------"
    for cid in $RESTARTING; do
        cname=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///')
        echo ">>> Last 25 log lines for $cname:"
        docker logs "$cid" --tail 25 2>&1 || true
        echo "--------------------------------------------------"
    done
fi

echo "=================================================="
echo " [CORTA Deploy] Successfully updated!"
echo "=================================================="
