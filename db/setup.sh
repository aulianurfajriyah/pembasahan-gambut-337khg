#!/usr/bin/env bash
# Bangun DB dari nol: container -> skema -> staging -> load -> dissolve -> finalisasi -> role.
# Jalankan dari mana saja:  ./db/setup.sh      (±10 menit, tergantung mesin)
set -euo pipefail
cd "$(dirname "$0")"

# kredensial: dibuat sekali di db/.env (jangan di-commit)
if [ ! -f .env ]; then
  pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
  cat > .env <<EOF
POSTGRES_PASSWORD=gambut_dev
PW_OGC_READER=$(pw)
PW_OGC_WRITER=$(pw)
PW_WEB_APP=$(pw)
PW_EDITOR_QGIS=$(pw)
API_ADMIN_USER=admin
API_ADMIN_PASSWORD=$(pw)
EOF
  chmod 600 .env
fi
set -a; . ./.env; set +a

docker compose up -d db
export PGHOST=localhost PGPORT=5433 PGUSER=postgres PGDATABASE=gambut PGPASSWORD=$POSTGRES_PASSWORD
# tunggu dari host (pg_isready di dalam container lolos saat server init sementara)
until psql -qtAc "SELECT 1" >/dev/null 2>&1; do sleep 2; done
PSQL="psql -v ON_ERROR_STOP=1 -q"

(cd .. && python3 scripts/build_gpkg.py && python3 scripts/build_hotspot.py)

$PSQL -c "DROP SCHEMA IF EXISTS alur, peta, ref, analisis, staging CASCADE"
for f in 01_schema.sql 02_trigger_fungsi.sql 03_views.sql; do $PSQL -f "$f"; done
./migrasi.sh --tandai   # build baru sudah memuat semua migrasi
./stage.sh
for f in 04_load_ref.sql 05_load_sekat.sql 06_load_bluebook.sql; do echo "== $f"; $PSQL -f "$f"; done

echo "== dissolve (paralel)"
pids=()
for f in 07_dissolve_khg.sql 07_dissolve_konsesi.sql 07_dissolve_ketebalan.sql; do $PSQL -f "$f" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done

echo "== finalisasi"
$PSQL -f 08_finalisasi.sql
$PSQL -v pw_reader="$PW_OGC_READER" -v pw_writer="$PW_OGC_WRITER" \
      -v pw_web="$PW_WEB_APP" -v pw_editor="$PW_EDITOR_QGIS" -f 09_roles.sql
$PSQL -f 10_api_views.sql

# OGC API: hash bcrypt untuk Basic Auth Caddy (tanda $ dikutip tunggal agar aman di .env)
if ! grep -q '^API_ADMIN_HASH=' .env; then
  echo "API_ADMIN_HASH='$(docker run --rm caddy:2 caddy hash-password --plaintext "$API_ADMIN_PASSWORD")'" >> .env
fi
docker compose up -d api proxy
psql -qtAc "SELECT 'Ukuran DB: ' || pg_size_pretty(pg_database_size('gambut'))"
