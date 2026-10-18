#!/usr/bin/env bash
# Restores a backup made by backup.sh into a running stack. DESTRUCTIVE: replaces the database.
#   ./scripts/restore.sh /backups/streamero-2026-10-18
set -euo pipefail
SRC="${1:?usage: restore.sh <backup-dir>}"
cd "$(dirname "$0")/.."
source .env
read -r -p "This replaces the current database and media bucket contents. Type RESTORE to continue: " ok
[ "$ok" = "RESTORE" ] || { echo "Aborted"; exit 1; }
(cd "$SRC" && sha256sum -c SHA256SUMS)

docker compose stop api worker
docker compose exec -T postgres dropdb -U streamero --if-exists streamero
docker compose exec -T postgres createdb -U streamero streamero
docker compose exec -T postgres pg_restore -U streamero -d streamero --no-owner < "$SRC/streamero.pgdump"

docker run --rm --network streamero_internal -v "$(realpath "$SRC")":/backup:ro \
  -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY:-streamero}" -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  amazon/aws-cli:2.27.0 --endpoint-url http://s3:8333 s3 sync /backup/media s3://streamero-media --only-show-errors

docker compose start api worker
echo "Restore complete."
