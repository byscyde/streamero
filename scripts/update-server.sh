#!/usr/bin/env bash
# Updates a STREAMERO server: backup → pull latest code → rebuild → migrations run automatically on start.
#   sudo ./scripts/update-server.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env — run scripts/install-server.sh first"; exit 1; }
set -a; . ./.env; set +a

COMPOSE=(docker compose -f docker-compose.yml)
if [ -f docker-compose.import.yml ]; then COMPOSE+=(-f docker-compose.import.yml); fi
case "${STREAMERO_PROXY:-}" in
  host-nginx) COMPOSE+=(-f docker-compose.localhost.yml) ;;
  caddy) COMPOSE+=(-f docker-compose.https.yml) ;;
  *) if [ -n "${STREAMERO_DOMAIN:-}" ]; then COMPOSE+=(-f docker-compose.https.yml); fi ;;
esac

BACKUP_DIR="${BACKUP_DIR:-/var/backups/streamero}/$(date +%F-%H%M)"
echo "Backup → $BACKUP_DIR"
./scripts/backup.sh "$BACKUP_DIR"

if git symbolic-ref -q HEAD >/dev/null; then
  git pull --ff-only
else
  # Installed from a release tag: move to the newest release.
  git fetch --tags --quiet
  LATEST=$(git tag -l 'v*' --sort=-v:refname | head -1)
  echo "Updating to release $LATEST"
  git checkout --quiet "$LATEST"
fi
"${COMPOSE[@]}" up -d --build
"${COMPOSE[@]}" ps
