#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo " Initializing MinIO Bucket"
echo "=========================================="

MINIO_USER="$(cat secrets/minio_root_user.txt)"
MINIO_PASS="$(cat secrets/minio_root_password.txt)"
BUCKET_NAME="synodus-files"

if [ -f ".env" ] && grep -q "^MINIO_BUCKET_NAME=" .env; then
    BUCKET_NAME="$(grep "^MINIO_BUCKET_NAME=" .env | cut -d= -f2 | tr -d ' "' )"
fi

echo "--> Setting MinIO alias..."
docker run --rm --network synodus-network quay.io/minio/mc \
    alias set myminio http://minio:9000 "$MINIO_USER" "$MINIO_PASS"

echo "--> Creating bucket '$BUCKET_NAME' if not exists..."
docker run --rm --network synodus-network quay.io/minio/mc \
    mb --ignore-existing "myminio/$BUCKET_NAME"

echo "=========================================="
echo " MinIO initialization complete!"
echo "=========================================="
