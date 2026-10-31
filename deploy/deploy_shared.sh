#!/usr/bin/env bash
# Pasang Gambut di VM yang sudah ada dan dipakai bersama layanan lain (idempoten).
# Syarat VM: Docker + compose >= 2.24.4, Caddy di host yang meng-import /etc/caddy/conf.d/*.caddy.
# Pakai: IP=1.2.3.4 KEY=~/.ssh/kunci ./deploy/deploy_shared.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${IP:?IP VM}" "${KEY:?kunci SSH root}"
DUMP=${DUMP:-$(ls -t ../output/gambut_*.dump | head -1)}
DOMAIN=${DOMAIN:-gambut.$(echo "$IP" | tr . -).sslip.io}
DIR=/opt/gambut
SSH="ssh -i $KEY -o ConnectTimeout=10 -o ServerAliveInterval=30 root@$IP"
DC="cd $DIR/db && docker compose"

echo "== 1. sinkron file"
$SSH "mkdir -p $DIR/api $DIR/db"
rsync -az -e "ssh -i $KEY" --delete ../api/ "root@$IP:$DIR/api/"
rsync -az -e "ssh -i $KEY" ../db/*.sql ../db/docker-compose.yml docker-compose.shared.yml "root@$IP:$DIR/db/"

echo "== 2. .env (dibuat sekali di server, password baru)"
$SSH "DIR=$DIR DOMAIN=$DOMAIN bash -s" <<'EOS'
set -euo pipefail
cd $DIR/db
if [ ! -f .env ]; then
  pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
  API_PW=$(pw)
  cat > .env <<EOF
COMPOSE_FILE=docker-compose.yml:docker-compose.shared.yml
COMPOSE_PROJECT_NAME=gambut
SITE_ADDRESS=$DOMAIN
POSTGRES_PASSWORD=$(pw)
PW_OGC_READER=$(pw)
PW_OGC_WRITER=$(pw)
PW_WEB_APP=$(pw)
PW_EDITOR_QGIS=$(pw)
API_ADMIN_USER=admin
API_ADMIN_PASSWORD=$API_PW
API_ADMIN_HASH='$(caddy hash-password --plaintext "$API_PW")'
EOF
  chmod 600 .env
fi
EOS

echo "== 3. database"
$SSH "$DC up -d db && until $DC exec -T db psql -U postgres -d gambut -qtAc 'SELECT 1' >/dev/null 2>&1; do sleep 3; done"
if [ "$($SSH "$DC exec -T db psql -U postgres -d gambut -qtAc \"SELECT to_regclass('ref.khg') IS NOT NULL\"")" != "t" ]; then
  echo "   upload $(du -h "$DUMP" | cut -f1) dump (bisa dilanjutkan bila terputus)"
  rsync -a --partial --progress -e "ssh -i $KEY" "$DUMP" "root@$IP:$DIR/awal.dump"
  echo "   restore"
  $SSH "$DC exec -T db pg_restore -U postgres -d gambut --no-owner --no-privileges < $DIR/awal.dump 2>&1 | grep -v 'already exists' || true"
  $SSH "rm -f $DIR/awal.dump"   # ponytail: dump tidak disimpan di VM (disk 40 GB); sumbernya di output/
fi

echo "== 4. role & view API"
$SSH "cd $DIR/db && set -a && . ./.env && set +a &&
  docker compose exec -T db psql -U postgres -d gambut -v ON_ERROR_STOP=1 -q \
    -v pw_reader=\"\$PW_OGC_READER\" -v pw_writer=\"\$PW_OGC_WRITER\" -v pw_web=\"\$PW_WEB_APP\" -v pw_editor=\"\$PW_EDITOR_QGIS\" \
    -f - < 09_roles.sql &&
  docker compose exec -T db psql -U postgres -d gambut -v ON_ERROR_STOP=1 -q -f - < 10_api_views.sql 2>&1 | grep -v 'NOTICE\|DETAIL\|drop cascades' || true"

echo "== 5. OGC API + Caddy host"
$SSH "$DC up -d api"
$SSH "DIR=$DIR DOMAIN=$DOMAIN bash -s" <<'EOS'
set -euo pipefail
. $DIR/db/.env
cat > /etc/caddy/conf.d/gambut.caddy <<EOF
# Gambut OGC API: GET publik, proses baca publik, operasi tulis wajib Basic Auth
$DOMAIN {
	encode zstd gzip
	route {
		@proses_baca {
			method POST
			path_regexp ^/processes/(ringkasan-dashboard|validasi-khg|saran-lokasi-pompa)/execution\$
		}
		reverse_proxy @proses_baca 127.0.0.1:5080

		@tulis not method GET HEAD OPTIONS
		basic_auth @tulis {
			$API_ADMIN_USER $API_ADMIN_HASH
		}
		reverse_proxy 127.0.0.1:5080 {
			header_up X-Forwarded-User {http.auth.user.id}
		}
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl reload caddy
EOS
until curl -sf -o /dev/null "https://$DOMAIN/"; do sleep 5; done

echo "== 6. uji asap"
$SSH "$DC exec -T db psql -U postgres -d gambut -f - < $DIR/db/tests.sql 2>&1 | tail -1"
B="https://$DOMAIN"
curl -s -o /dev/null -w "   GET  /collections/khg/items -> %{http_code} (%{time_total}s)\n" "$B/collections/khg/items?limit=1&f=json"
curl -s -o /dev/null -w "   GET  tile kanal             -> %{http_code}\n" "$B/collections/kanal/tiles/WebMercatorQuad/12/2081/3344?f=mvt"
curl -s -o /dev/null -w "   POST tanpa login            -> %{http_code} (harus 401)\n" -X POST -H 'Content-Type: application/geo+json' -d '{}' "$B/collections/pompa/items"

umask 077
$SSH "cat $DIR/db/.env" > .env.shared
{ echo "# KREDENSIAL PRODUKSI (VM bersama), RAHASIA"; echo
  echo "Server: \`$IP\` · API: $B"; echo
  echo "Tunnel DB untuk QGIS: \`ssh -i $KEY -N -L 5433:localhost:5433 root@$IP\` lalu konek ke localhost:5433 db gambut"; echo
  echo '```'; grep -v '^API_ADMIN_HASH\|^COMPOSE_' .env.shared; echo '```'; } > ../docs/KREDENSIAL_PRODUKSI.md
echo "SELESAI -> $B   (kredensial: docs/KREDENSIAL_PRODUKSI.md)"
