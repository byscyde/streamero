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

# Everything is found by the Compose project label, so this works without .env and whatever
# overlay files (localhost, https/Caddy, import) were used when the stack was started.
LABEL=label=com.docker.compose.project=streamero
ids() { "$@" 2>/dev/null | sort -u | tr '\n' ' '; }

CONTAINERS=$(ids docker ps -aq --filter "$LABEL")
if [ -n "${CONTAINERS// /}" ]; then
  echo "Zaustavljam i uklanjam kontejnere…"
  # shellcheck disable=SC2086
  docker rm -f $CONTAINERS >/dev/null
fi

IMAGES=$(ids docker image ls -q --filter "$LABEL")
IMAGES+=" $(ids docker image ls -q --filter 'reference=streamero-*')"
if [ -n "${IMAGES// /}" ]; then
  echo "Uklanjam STREAMERO slike…"
  # shellcheck disable=SC2086
  docker image rm -f $IMAGES >/dev/null 2>&1 || true
fi

for n in $(ids docker network ls -q --filter "$LABEL"); do docker network rm "$n" >/dev/null 2>&1 || true; done

if [ $PURGE -eq 1 ]; then
  echo "Brišem podatke…"
  for v in $(ids docker volume ls -q --filter "$LABEL") streamero_pgdata streamero_redisdata streamero_s3data streamero_work; do
    docker volume inspect "$v" >/dev/null 2>&1 && docker volume rm "$v" >/dev/null
  done
  LEFT=$(ids docker volume ls -q --filter "$LABEL")
  if [ -n "${LEFT// /}" ]; then
    echo "Greška: ovi volumeni nisu obrisani: $LEFT" >&2
    echo "Provjeri koristi li ih još neki kontejner: docker ps -a --filter volume=<ime>" >&2
    exit 1
  fi
  rm -f "$ROOT/.env" "$ROOT/streamero-admin-credentials.txt"
fi

for vhost in /etc/nginx/sites-enabled/streamero.conf /etc/nginx/sites-available/streamero.conf /etc/nginx/conf.d/streamero.conf; do
  [ -e "$vhost" ] && rm -f "$vhost" && echo "Uklonjen $vhost"
done
if command -v nginx >/dev/null && nginx -t 2>/dev/null; then systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true; fi

echo "Gotovo."
[ $PURGE -eq 1 ] && echo "Svi STREAMERO podaci su obrisani. Instalacija od nule: sudo ./scripts/install-server.sh" \
  || echo "Podaci (baza, glazba) su sačuvani u Docker volumenima. Ponovno pokretanje: sudo ./scripts/install-server.sh"
