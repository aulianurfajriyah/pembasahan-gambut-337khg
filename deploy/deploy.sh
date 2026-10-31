#!/usr/bin/env bash
# Pasang / perbarui Gambut di VM hasil provision.sh (idempoten).
#  1. tunggu cloud-init  2. sinkron file  3. .env produksi (password baru)  4. DB + restore dump
#  5. role & view API  6. pygeoapi + Caddy (HTTPS otomatis)  7. cron backup  8. uji asap
#  6b. web Next.js (repo LH-KHG) di app.<DOMAIN> bila foldernya ada
# Pakai: ./deploy/deploy.sh            DOMAIN=api.contoh.id WEB_DOMAIN=contoh.id ./deploy/deploy.sh (setelah DNS diarahkan)
#        WEB_DIR= ./deploy/deploy.sh   (tanpa web)
#        KOSONG=1 ./deploy/deploy.sh   (DB kosong: skema saja, tanpa dump; data diimpor belakangan)
set -euo pipefail
cd "$(dirname "$0")"
. ./.state
DUMP=${DUMP:-$(ls -t ../output/gambut_*.dump 2>/dev/null | head -1)}
KOSONG=${KOSONG:-0}
[ "$KOSONG" = 1 ] || [ -n "$DUMP" ] || { echo "dump tidak ada: docker exec gambut_db pg_dump -U postgres -Fc -Z 6 gambut > output/gambut_\$(date +%F).dump"; exit 1; }
DOMAIN=${DOMAIN:-$(echo "$IP" | tr . -).sslip.io}     # tanpa domain: HTTPS lewat sslip.io
WEB_DIR=${WEB_DIR-../../LH-KHG}
[ -n "$WEB_DIR" ] && [ ! -f "$WEB_DIR/package.json" ] && WEB_DIR=
WEB_DOMAIN=${WEB_DOMAIN:-app.$DOMAIN}                 # sslip.io juga melayani subdomain
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 gambut@$IP"
R="rsync -az -e \"ssh -i $KEY -o StrictHostKeyChecking=accept-new\""

echo "== 1. menunggu VM siap ($IP)"
until $SSH true 2>/dev/null; do sleep 5; done
$SSH 'cloud-init status --wait >/dev/null; docker compose version --short' | {
  read -r v; echo "docker compose $v"
  [ "$(printf '%s\n2.24.4\n' "$v" | sort -V | head -1)" = "2.24.4" ] || { echo "compose < 2.24.4 (butuh !override)"; exit 1; }; }

echo "== 2. sinkron file"
eval "$R --delete ../api/ gambut@$IP:/srv/gambut/api/"
eval "$R ../db/*.sql ../db/docker-compose.yml docker-compose.prod.yml docker-compose.web.yml Caddyfile.web web.Dockerfile backup.sh gambut@$IP:/srv/gambut/db/"
$SSH 'mkdir -p /srv/gambut/simulasi /srv/gambut/lapisan'
mkdir -p ../simulasi/data ../lapisan   # boleh kosong (DB baru): rsync gagal bila sumbernya tidak ada
eval "$R --delete ../simulasi/data/ gambut@$IP:/srv/gambut/simulasi/data/"   # ubin medan simulasi
eval "$R --delete ../lapisan/ gambut@$IP:/srv/gambut/lapisan/"               # raster DEM/gambut per KHG
if [ -n "$WEB_DIR" ]; then
  eval "$R --delete --exclude node_modules --exclude .next --exclude '.env*' --exclude .git --exclude .claude \
    --exclude '*.tsbuildinfo' --exclude public/maplibre \"$WEB_DIR/\" gambut@$IP:/srv/gambut/web/"
fi

echo "== 3. .env produksi (dibuat sekali di server, password baru)"
$SSH "DOMAIN=$DOMAIN bash -s" <<'EOS'
set -euo pipefail
cd /srv/gambut/db
if [ ! -f .env ]; then
  pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
  API_PW=$(pw)
  cat > .env <<EOF
COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml
SITE_ADDRESS=$DOMAIN
POSTGRES_PASSWORD=$(pw)
PW_OGC_READER=$(pw)
PW_OGC_WRITER=$(pw)
PW_WEB_APP=$(pw)
PW_EDITOR_QGIS=$(pw)
API_ADMIN_USER=admin
API_ADMIN_PASSWORD=$API_PW
API_ADMIN_HASH='$(docker run --rm caddy:2 caddy hash-password --plaintext "$API_PW")'
EOF
  chmod 600 .env
fi
sed -i "s/^SITE_ADDRESS=.*/SITE_ADDRESS=$DOMAIN/" .env
# setelan memori mengikuti RAM server (4 GB demo vs 8+ GB produksi)
MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
sed -i '/^PG_\|^WSGI_WORKERS=/d' .env
cat >> .env <<EOF
PG_SHARED_BUFFERS=$((MB / 4))MB
PG_CACHE=$((MB * 3 / 4))MB
PG_WORK_MEM=$([ "$MB" -lt 6000 ] && echo 16MB || echo 32MB)
PG_MAINT_MEM=$([ "$MB" -lt 6000 ] && echo 256MB || echo 512MB)
WSGI_WORKERS=$([ "$MB" -lt 6000 ] && echo 2 || echo 4)
EOF
EOS
if [ -n "$WEB_DIR" ]; then   # web: compose tambahan + alamat; BASEMAP_STYLE_URL/ESTIMASI_BIAYA_PER_SEKAT boleh diubah manual di .env
  $SSH "WEB_DOMAIN=$WEB_DOMAIN bash -s" <<'EOS'
set -euo pipefail
cd /srv/gambut/db
sed -i 's/^COMPOSE_FILE=.*/COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml:docker-compose.web.yml/' .env
sed -i '/^WEB_ADDRESS=/d' .env && echo "WEB_ADDRESS=$WEB_DOMAIN" >> .env
grep -q '^BASEMAP_STYLE_URL=' .env || echo 'BASEMAP_STYLE_URL=https://tiles.openfreemap.org/styles/positron' >> .env
grep -q '^ESTIMASI_BIAYA_PER_SEKAT=' .env || echo 'ESTIMASI_BIAYA_PER_SEKAT=' >> .env
EOS
fi

echo "== 4. database"
$SSH 'cd /srv/gambut/db && docker compose up -d db && until docker compose exec -T db pg_isready -U postgres -d gambut -q && docker compose exec -T db psql -h 127.0.0.1 -U postgres -d gambut -qtAc "SELECT 1" >/dev/null 2>&1; do sleep 3; done'
if [ "$($SSH "cd /srv/gambut/db && docker compose exec -T db psql -U postgres -d gambut -qtAc \"SELECT to_regclass('ref.khg') IS NOT NULL\"")" != "t" ]; then
  if [ "$KOSONG" = 1 ]; then
  echo "   skema kosong (01-03, tanpa data)"
  $SSH 'cd /srv/gambut/db && for f in 01_schema.sql 02_trigger_fungsi.sql 03_views.sql; do
    docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -U postgres -d gambut -v ON_ERROR_STOP=1 -q -f - < $f || exit 1; done'
  else
  echo "   upload $(du -h "$DUMP" | cut -f1) dump (bisa dilanjutkan bila terputus)"
  eval "$R --partial --progress \"$DUMP\" gambut@$IP:/srv/backup/awal.dump"
  echo "   restore (±5-10 menit)"
  $SSH 'cd /srv/gambut/db && docker compose exec -T db pg_restore -U postgres -d gambut --no-owner --no-privileges < /srv/backup/awal.dump 2>&1 | grep -v "already exists" || true'
  fi
fi

echo "== 5. role & view API"
$SSH 'cd /srv/gambut/db && set -a && . ./.env && set +a &&
  docker compose exec -T db psql -U postgres -d gambut -v ON_ERROR_STOP=1 -q \
    -v pw_reader="$PW_OGC_READER" -v pw_writer="$PW_OGC_WRITER" -v pw_web="$PW_WEB_APP" -v pw_editor="$PW_EDITOR_QGIS" \
    -f - < 09_roles.sql &&
  docker compose exec -T db psql -U postgres -d gambut -v ON_ERROR_STOP=1 -q -f - < 10_api_views.sql 2>&1 | grep -v "NOTICE\|DETAIL\|drop cascades" || true'

echo "== 6. OGC API + HTTPS"
$SSH 'cd /srv/gambut/db && docker compose up -d --remove-orphans api proxy >/dev/null'
until curl -sf -o /dev/null "https://$DOMAIN/"; do sleep 5; done

if [ -n "$WEB_DIR" ]; then
  echo "== 6b. web (build ±3-5 menit, butuh API di atas sudah jalan)"
  $SSH 'cd /srv/gambut/db && docker compose up -d --build web && docker image prune -f >/dev/null'
  until curl -sf -o /dev/null "https://$WEB_DOMAIN/"; do sleep 5; done
fi

if [ "${BACKUP:-0}" = 1 ]; then
  echo "== 7. cron (02:00 backup + refresh statistik)"
  $SSH '(crontab -l 2>/dev/null | grep -v backup.sh; echo "0 2 * * * /srv/gambut/db/backup.sh >> /srv/backup/backup.log 2>&1") | crontab -'
else
  echo "== 7. backup dilewati (mode demo; BACKUP=1 untuk produksi)"
fi

echo "== 8. uji asap"
[ "$KOSONG" = 1 ] || $SSH 'cd /srv/gambut/db && docker compose exec -T db psql -U postgres -d gambut -f - < tests.sql 2>&1 | tail -1'
B="https://$DOMAIN"
curl -s -o /dev/null -w "   GET  /collections/khg/items   -> %{http_code} (%{time_total}s)\n" "$B/collections/khg/items?limit=1&f=json"
curl -s -o /dev/null -w "   GET  tile kanal               -> %{http_code}\n" "$B/collections/kanal/tiles/WebMercatorQuad/12/2081/3344?f=mvt"
curl -s -o /dev/null -w "   POST tanpa login              -> %{http_code} (harus 401)\n" -X POST -H 'Content-Type: application/geo+json' -d '{}' "$B/collections/pompa/items"

# kredensial produksi -> lokal (rahasia)
umask 077
$SSH 'cat /srv/gambut/db/.env' > .env.prod
{ echo "# KREDENSIAL PRODUKSI — RAHASIA"; echo; echo "Server: \`$IP\` · SSH: \`ssh -i $KEY gambut@$IP\` · API: $B"; echo
  echo "Tunnel DB untuk QGIS: \`ssh -i $KEY -N -L 5433:localhost:5432 gambut@$IP\` lalu konek ke localhost:5433 db gambut"; echo
  echo '```'; grep -v '^API_ADMIN_HASH\|^COMPOSE_FILE' .env.prod; echo '```'; } > ../docs/KREDENSIAL_PRODUKSI.md
[ -n "$WEB_DIR" ] && curl -s -o /dev/null -w "   GET  web                      -> %{http_code}\n" "https://$WEB_DOMAIN/"
echo "SELESAI -> $B$([ -n "$WEB_DIR" ] && echo "  web: https://$WEB_DOMAIN")   (kredensial: docs/KREDENSIAL_PRODUKSI.md)"
