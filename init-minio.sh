#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUCKET_NAME=synodus-files
if [ -f .env ] && grep -q '^MINIO_BUCKET_NAME=' .env; then
    BUCKET_NAME="$(sed -n 's/^MINIO_BUCKET_NAME=//p' .env | head -n 1 | tr -d '\r\"\047')"
fi
[[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo 'Invalid MinIO bucket name.' >&2; exit 1; }

# Use the runtime image's curl instead of downloading another MinIO client image.
docker compose -f docker-compose.prod.yaml exec -T -e MINIO_BUCKET_NAME="$BUCKET_NAME" minio sh -eu -c '
    credentials="$(cat /run/secrets/minio_root_user):$(cat /run/secrets/minio_root_password)"
    url="http://localhost:9000/$MINIO_BUCKET_NAME"
    signed_request() {
        curl --max-time 10 --silent --show-error --output /dev/null --write-out "%{http_code}" \
            --aws-sigv4 "aws:amz:us-east-1:s3" --user "$credentials" "$@" "$url"
    }
    for attempt in $(seq 1 60); do
        if curl --max-time 5 --silent --fail http://localhost:9000/minio/health/ready >/dev/null; then break; fi
        sleep 2
    done
    status="$(signed_request --head)"
    if [ "$status" = 404 ]; then
        status="$(signed_request --request PUT)"
    fi
    [ "$status" = 200 ] || { echo "Storage bucket setup failed (HTTP $status)." >&2; exit 1; }
    [ "$(signed_request --head)" = 200 ] || { echo "Storage bucket verification failed." >&2; exit 1; }
'
printf 'Storage bucket %s is ready.\n' "$BUCKET_NAME"
