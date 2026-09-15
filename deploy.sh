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

# 1. Pull latest image(s) from ghcr.io
echo "--> Pulling latest image(s)..."
if [ -n "$SERVICE" ]; then
    docker compose -f "$COMPOSE_FILE" pull "$SERVICE"
    echo "--> Restarting $SERVICE (without touching dependencies)..."
    docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"
else
    docker compose -f "$COMPOSE_FILE" pull
    echo "--> Updating all containers..."
    docker compose -f "$COMPOSE_FILE" up -d
fi

# 2. Prune dangling images to save server storage
echo "--> Cleaning up dangling images..."
docker image prune -f

# 3. Status check
echo "--> Checking container status..."
sleep 2
docker compose -f "$COMPOSE_FILE" ps

echo "=================================================="
echo " [CORTA Deploy] Successfully updated!"
echo "=================================================="
