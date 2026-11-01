#!/usr/bin/env bash
# Uji asap OGC API (dipakai CI): semua koleksi dan proses baca harus menjawab 200.
#   db/ci/smoke_api.sh http://localhost:5098
#   SOLO_BACA=1 db/ci/smoke_api.sh https://...   (tanpa uji tulis; dipakai deploy/ci_deploy.sh)
set -euo pipefail
B=${1:-http://localhost:5098}
for _ in $(seq 60); do curl -sf -o /dev/null "$B/" && break; sleep 3; done
gagal=0
cek() {  # cek <label> <curl args...>
  local kode; kode=$(curl -s -o /tmp/smoke.out -w '%{http_code}' "${@:2}")
  printf '%s %s\n' "$kode" "$1"
  [ "$kode" = 200 ] || { gagal=1; head -c 400 /tmp/smoke.out; echo; }
}
for c in $(curl -sf "$B/collections?f=json" | python3 -c "import sys,json; print(' '.join(c['id'] for c in json.load(sys.stdin)['collections']))"); do
  cek "collections/$c" "$B/collections/$c/items?limit=1&f=json"
done
cek "processes" "$B/processes?f=json"
khg=$(curl -sf "$B/collections/khg/items?limit=1&f=json" | python3 -c "import sys,json; print(json.load(sys.stdin)['features'][0]['id'])")
for p in ringkasan-dashboard status-sinkron "riwayat-khg:{\"khg_id\":$khg}" "validasi-khg:{\"khg_id\":$khg}" "saran-lokasi-pompa:{\"khg_id\":$khg}"; do
  inputs=${p#*:}; [ "$inputs" = "$p" ] && inputs='{}'
  cek "processes/${p%%:*}" -X POST -H 'Content-Type: application/json' -d "{\"inputs\":$inputs}" "$B/processes/${p%%:*}/execution"
done
[ -z "${SOLO_BACA:-}" ] || exit $gagal   # SOLO_BACA=1: deploy produksi tidak boleh menulis data
# tulis (di produksi dijaga Basic Auth Caddy): role ogc_writer harus bisa INSERT + DELETE
x=$(curl -sf "$B/collections/khg/items/$khg?f=json" | python3 -c "import sys,json; from statistics import mean
g=json.load(sys.stdin)['geometry']['coordinates'][0][0]; print(mean(c[0] for c in g), mean(c[1] for c in g))")
kode=$(curl -s -D /tmp/smoke.hdr -o /tmp/smoke.out -w '%{http_code}' -X POST -H 'Content-Type: application/geo+json' \
  -d "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[${x% *},${x#* }]},\"properties\":{}}" \
  "$B/collections/pompa/items")
echo "$kode POST pompa"; [ "$kode" = 201 ] || { gagal=1; cat /tmp/smoke.out; echo; }
lok=$(grep -i '^location:' /tmp/smoke.hdr | tr -d '\r' | awk '{print $2}')
[ -z "$lok" ] || cek "DELETE pompa" -X DELETE "$lok"
exit $gagal
