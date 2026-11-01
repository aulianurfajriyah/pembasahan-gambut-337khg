#!/usr/bin/env bash
# Pasang migrasi db/migrations/*.sql yang belum tercatat di ref.migrasi (urut nama = urut tanggal).
#   db/migrasi.sh             migrasi yang belum terpasang
#   db/migrasi.sh --tandai    catat semua sebagai terpasang tanpa menjalankan (build baru: sudah ada di 01-03/10)
#   db/migrasi.sh --semua     DB lama tanpa ref.migrasi (mis. dump 2026-09-30): jalankan semua dari awal
# Target DB lewat $PSQL (bawaan: container lokal gambut_db), mis. untuk VM:
#   PSQL="ssh -i ~/.ssh/gambut_vps gambut@1.2.3.4 docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1" db/migrasi.sh
# Aturan migrasi baru: tulis juga perubahannya di 01-03 / 10_api_views.sql agar build baru tidak butuh migrasi.
set -euo pipefail
cd "$(dirname "$0")/migrations"
PSQL=${PSQL:-docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1}
mode=${1:-}

ada=$($PSQL -tA <<< "SELECT to_regclass('ref.migrasi') IS NOT NULL")
if [ "$ada" != t ]; then
  [ -n "$mode" ] || { echo "ref.migrasi belum ada. DB sudah terbaru: $0 --tandai;  DB lama (dump sebelum migrasi): $0 --semua" >&2; exit 1; }
  $PSQL <<< "CREATE TABLE ref.migrasi (nama text PRIMARY KEY, dipasang_at timestamptz NOT NULL DEFAULT now())"
fi
sudah=$($PSQL -tA <<< "SELECT nama FROM ref.migrasi")

n=0
for f in *.sql; do
  grep -qxF "$f" <<< "$sudah" && continue
  if [ "$mode" = --tandai ]; then
    $PSQL <<< "INSERT INTO ref.migrasi (nama) VALUES ('$f')"
  else
    echo "== migrasi $f"
    { cat "$f"; echo; echo "INSERT INTO ref.migrasi (nama) VALUES ('$f');"; } | $PSQL
  fi
  n=$((n + 1))
done
echo "migrasi: $n $([ "$mode" = --tandai ] && echo ditandai || echo dipasang)"
