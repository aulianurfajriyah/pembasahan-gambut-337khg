#!/usr/bin/env bash
# Kirim seluruh isi DB lokal (container gambut_db) + raster lapisan/ + grid simulasi/data/ ke VM produksi.
# ISI DB VM DIGANTI SEMUA (suntingan di VM sejak kiriman terakhir hilang; dump VM lama disimpan dulu).
#   IP=1.2.3.4 KEY=~/.ssh/gambut_vps scripts/kirim_db_vm.sh       (tanpa IP/KEY: dibaca dari deploy/.state)
#   LEWATI_DUMP=1 ...   pakai output/kirim.dump yang sudah ada (mis. setelah unggahan terputus)
# Syarat: VM sudah dipasang deploy.sh, kunci SSH pengguna 'gambut' di VM, Docker lokal jalan.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f deploy/.state ] && . deploy/.state
: "${IP:?IP VM}" "${KEY:=$HOME/.ssh/gambut_vps}"
SSH="ssh -i $KEY -o ServerAliveInterval=30 gambut@$IP"
VPSQL="docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1"
DUMP=output/kirim.dump

echo "== 1. dump DB lokal"
mkdir -p output
docker exec gambut_db psql -X -q -U postgres -d gambut -tAc "SELECT 'KHG: ' || count(*) || ', DB ' || pg_size_pretty(pg_database_size('gambut')) FROM ref.khg"
[ "${LEWATI_DUMP:-0}" = 1 ] || docker exec gambut_db pg_dump -U postgres -Fc -Z 6 gambut > $DUMP
echo "   $(du -h $DUMP | cut -f1)"

echo "== 2. unggah (bisa dilanjutkan bila terputus: ulangi dengan LEWATI_DUMP=1)"
rsync -a --partial --progress -e "ssh -i $KEY" $DUMP "gambut@$IP:/srv/backup/kirim.dump"

echo "== 3. cadangkan DB VM lama, restore"
$SSH 'set -euo pipefail
  df -h / | tail -1
  docker exec gambut_db pg_dump -U postgres -Fc -Z 6 gambut > /srv/backup/sebelum_kirim.dump
  cd /srv/gambut/db && docker compose stop api >/dev/null
  docker exec gambut_db psql -X -q -U postgres -d gambut -c "DROP SCHEMA IF EXISTS api, alur, peta, analisis, ref, impor, cadangan, staging CASCADE"
  docker exec -i gambut_db pg_restore -U postgres -d gambut --no-owner --no-privileges < /srv/backup/kirim.dump 2>&1 | grep -v "already exists" || true
  rm /srv/backup/kirim.dump'

echo "== 4. migrasi, role, view API"
# DB lokal sudah memuat semua migrasi -> cukup ditandai; berikutnya db/migrasi.sh memasang migrasi baru saja
PSQL="$SSH $VPSQL" db/migrasi.sh --tandai
$SSH 'cd /srv/gambut/db && set -a && . ./.env && set +a &&
  docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1 \
    -v pw_reader="$PW_OGC_READER" -v pw_writer="$PW_OGC_WRITER" -v pw_web="$PW_WEB_APP" -v pw_editor="$PW_EDITOR_QGIS"' < db/09_roles.sql
$SSH "$VPSQL" < db/10_api_views.sql 2>&1 | grep -v "NOTICE\|DETAIL\|drop cascades" || true

echo "== 5. raster & grid simulasi"
for d in lapisan simulasi/data; do   # folder kosong di laptop dilewati: --delete akan menghapus isi di VM
  if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then rsync -az --delete -e "ssh -i $KEY" "$d/" "gambut@$IP:/srv/gambut/$d/"
  else echo "   $d kosong di laptop: dilewati"; fi
done

echo "== 6. statistik planner, nyalakan API, cek"
# pg_restore tidak membawa statistik planner: tanpa ANALYZE query bisa memakai rencana buruk (CPU tinggi)
$SSH "$VPSQL" <<< "VACUUM (ANALYZE)"
$SSH "$VPSQL -tA" <<'SQL'
SELECT api.refresh_statistik() \g /dev/null
SELECT 'VM -> KHG: ' || count(*) || ', DB ' || pg_size_pretty(pg_database_size('gambut')) FROM ref.khg;
SQL
$SSH 'cd /srv/gambut/db && docker compose start api >/dev/null && docker compose restart martin >/dev/null'   # martin membaca daftar view saat start
B="https://${DOMAIN:-$(echo "$IP" | tr . -).sslip.io}"
for _ in $(seq 30); do curl -sf -o /dev/null "$B/collections/khg/items?limit=1&f=json" && break; sleep 2; done
curl -s -o /dev/null -w "   GET $B/collections/khg/items -> %{http_code}\n" "$B/collections/khg/items?limit=1&f=json"
rm -f $DUMP
echo "SELESAI. Cadangan DB VM sebelum kiriman: /srv/backup/sebelum_kirim.dump (hapus bila disk sempit)"
