#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo " Initializing MinIO Bucket & Secrets"
echo "=========================================="

MINIO_USER="$(tr -d '\r\n' < secrets/minio_root_user.txt)"
MINIO_PASS="$(tr -d '\r\n' < secrets/minio_root_password.txt)"
BUCKET_NAME="synodus-files"

if [ -f ".env" ] && grep -q "^MINIO_BUCKET_NAME=" .env; then
    BUCKET_NAME="$(grep "^MINIO_BUCKET_NAME=" .env | cut -d= -f2 | tr -d ' "' )"
fi

# Sync secret files so any component reading either file gets identical credentials
cp secrets/minio_root_user.txt secrets/minio_access_key
cp secrets/minio_root_password.txt secrets/minio_secret_key.txt

echo "--> Configuring MinIO and ensuring bucket '$BUCKET_NAME' exists..."
docker run --rm --network synodus-network --entrypoint /bin/sh quay.io/minio/mc -c \
    "mc alias set myminio http://minio:9000 '$MINIO_USER' '$MINIO_PASS' && \
     mc mb --ignore-existing 'myminio/$BUCKET_NAME' && \
     mc stat 'myminio/$BUCKET_NAME'"

echo "=========================================="
echo " MinIO initialization complete!"
echo "=========================================="
