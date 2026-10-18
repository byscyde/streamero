#!/usr/bin/env bash
# Consistent backup of the Docker Compose stack: PostgreSQL (logical dump) + object storage (S3 mirror).
#   ./scripts/backup.sh /backups/streamero-$(date +%F)
# Media originals are the irreplaceable part; renditions can be regenerated (Admin › Reprocess).
set -euo pipefail
DEST="${1:?usage: backup.sh <destination-dir>}"
mkdir -p "$DEST"
cd "$(dirname "$0")/.."
source .env

echo "Dumping PostgreSQL…"
docker compose exec -T postgres pg_dump -U streamero -d streamero --format=custom --no-owner > "$DEST/streamero.pgdump"

echo "Copying object storage…"
docker run --rm --network streamero_internal -v "$(realpath "$DEST")":/backup \
  -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY:-streamero}" -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  amazon/aws-cli:2.27.0 --endpoint-url http://s3:8333 s3 sync s3://streamero-media /backup/media --only-show-errors

sha256sum "$DEST/streamero.pgdump" > "$DEST/SHA256SUMS"
echo "Backup written to $DEST ($(du -sh "$DEST" | cut -f1))"
