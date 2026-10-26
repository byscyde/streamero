#!/usr/bin/env bash
# Removes the STREAMERO Docker stack from this server.
#   sudo ./scripts/uninstall-server.sh            # stop and remove containers, images and the nginx vhost; KEEP data
#   sudo ./scripts/uninstall-server.sh --purge    # also DELETE all data volumes (database, music, videos) and .env
# Only STREAMERO's own containers/volumes/images are touched; other Docker projects are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
[ "$(id -u)" -eq 0 ] || { echo "Pokreni sa sudo."; exit 1; }

if [ $PURGE -eq 1 ]; then
  echo "UPOZORENJE: --purge trajno briše bazu, sve pjesme, videe, korisnike i $ROOT/.env."
  read -r -p "Za potvrdu upiši OBRISI: " answer
  [ "$answer" = "OBRISI" ] || { echo "Prekinuto."; exit 1; }
fi

FILES=(-f docker-compose.yml)
for f in docker-compose.localhost.yml docker-compose.https.yml docker-compose.import.yml; do [ -f "$f" ] && FILES+=(-f "$f"); done

# Compose needs the variables from .env to parse the files; dummy values are enough for "down".
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-x}" JWT_ACCESS_SECRET="${JWT_ACCESS_SECRET:-x}" \
  MEDIA_SIGNING_SECRET="${MEDIA_SIGNING_SECRET:-x}" S3_SECRET_KEY="${S3_SECRET_KEY:-x}"
DOWN=(down --remove-orphans --rmi local)
[ $PURGE -eq 1 ] && DOWN+=(--volumes)
docker compose -p streamero "${FILES[@]}" "${DOWN[@]}" || true

if [ $PURGE -eq 1 ]; then
  for v in $(docker volume ls -q --filter label=com.docker.compose.project=streamero); do docker volume rm "$v" || true; done
  rm -f "$ROOT/.env" "$ROOT/streamero-admin-credentials.txt"
fi

for vhost in /etc/nginx/sites-enabled/streamero.conf /etc/nginx/sites-available/streamero.conf /etc/nginx/conf.d/streamero.conf; do
  [ -e "$vhost" ] && rm -f "$vhost" && echo "Uklonjen $vhost"
done
if command -v nginx >/dev/null && nginx -t 2>/dev/null; then systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true; fi

echo "Gotovo."
[ $PURGE -eq 1 ] && echo "Svi STREAMERO podaci su obrisani. Instalacija od nule: sudo ./scripts/install-server.sh" \
  || echo "Podaci (baza, glazba) su sačuvani u Docker volumenima. Ponovno pokretanje: sudo ./scripts/install-server.sh"
