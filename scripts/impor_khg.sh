#!/usr/bin/env bash
# Impor satu folder data KHG (vektor + raster) ke DB dan ubin peta.
#
#   scripts/impor_khg.sh <folder> <khg_id> [sumber]
#   scripts/impor_khg.sh "~/Karhutla/KHG Kahayan-Sebangau" 328
#
# Berkas dicari menurut pola nama (huruf besar/kecil bebas, .gpkg atau .shp):
#   batas KHG        khg.*                      cek luas terhadap ref.khg saja
#   kanal            Kanal_*                    -> peta.kanal (+ kanal terpilih dari rute pompa)
#   rute pompa       *pump_routes*              -> peta.jalur_pompa
#   pompa            *pump_stations*            -> peta.pompa
#   sekat existing   blocks*                    -> peta.sekat + peta.sekat_bangunan
#   sekat usulan     *sekat_proposed*           -> peta.sekat (rencana, final)
#   sungai (garis)   rivers*                    -> peta.sungai
#   sungai (poligon) Sungai_*                   -> peta.badan_air
#   areal terbakar   BA_within_KHG*             -> peta.areal_terbakar
#   hotspot          hotspots*                  -> peta.hotspot (kepercayaan sedang+tinggi)
#   konsesi & DMPG   Analisis_usaha*            -> peta.konsesi, analisis.dmpg (dissolve)
#   sub-KHG          unit_prioritas*            -> analisis.unit_prioritas
#   TMA              tma_stasiun*, tma_harian*  -> peta.logger_tmat, peta.tmat_bacaan
#   DEM              DTM_*.tif / DEM*.tif       -> ubin PNG lapisan/khg_<id>/dem
#   ketebalan gambut peat_depth*.tif            -> ubin PNG lapisan/khg_<id>/gambut
# Berkas yang tidak ada dilewati. Data lain di KHG tidak disentuh; impor ulang dengan sumber yang
# sama mengganti hasil impor sebelumnya. Butuh GDAL (ogr2ogr, gdalwarp, gdaldem, gdal2tiles) dan
# python3. DB: db/.env + PGHOST/PGPORT (bawaan localhost:5433); psql di host atau di container gambut_db.
set -euo pipefail

[ $# -ge 2 ] || { sed -n 2,6p "$0"; exit 1; }
DIR=$(cd "$1" && pwd)
KHG=$2
SUMBER=${3:-IMPOR_KHG}
[[ $KHG =~ ^[0-9]+$ ]] || { echo "khg_id harus angka" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
set -a; . "$ROOT/db/.env"; set +a
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres} PGDATABASE=${PGDATABASE:-gambut}
export PGPASSWORD=${PGPASSWORD:-$POSTGRES_PASSWORD}
PG="PG:host=$PGHOST port=$PGPORT dbname=$PGDATABASE user=$PGUSER password=$PGPASSWORD"
if command -v psql >/dev/null; then
  psql_() { psql -X -v ON_ERROR_STOP=1 "$@"; }
else
  psql_() { docker exec -i -e PGPASSWORD="$PGPASSWORD" gambut_db psql -X -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
fi

# cari <pola> [ekstensi...]: berkas pertama yang cocok di folder (tanpa subfolder)
cari() {
  local pola=$1; shift
  local args=() e
  for e in "${@:-gpkg shp}"; do for x in $e; do args+=(-o -iname "$pola.$x"); done; done
  find "$DIR" -maxdepth 1 -type f \( "${args[@]:1}" \) | sort | head -1
}

psql_ -qc "DROP SCHEMA IF EXISTS impor CASCADE; CREATE SCHEMA impor"

stage() {  # stage <pola> <tabel>
  local f; f=$(cari "$1")
  if [ -z "$f" ]; then echo "  -  $2: tidak ada berkas $1"; return; fi
  ogr2ogr -f PostgreSQL "$PG" "$f" -nln "impor.$2" -t_srs EPSG:4326 -dim XY -makevalid \
    -lco GEOMETRY_NAME=geom -lco FID=ogc_fid -lco SPATIAL_INDEX=NONE -lco UNLOGGED=ON \
    -nlt PROMOTE_TO_MULTI -gt 100000 --config PG_USE_COPY YES
  echo "  ok $2 <- $(basename "$f")"
}

echo "== staging dari $DIR"
stage 'khg' khg &
stage 'Kanal_*' kanal &
stage '*pump_routes*' jalur_pompa &
stage '*pump_stations*' pompa &
stage 'blocks*' sekat_existing &
stage '*sekat_proposed*' sekat_usulan &
stage 'rivers*' sungai &
wait
stage 'Sungai_*' badan_air &
stage 'BA_within_KHG*' areal_terbakar &
stage 'hotspots*' hotspot &
stage 'Analisis_usaha*' usaha &
stage 'unit_prioritas*' unit_prioritas &
stage 'tma_stasiun*' tma_stasiun &
stage 'tma_harian*' tma_harian &
wait

echo "== muat ke peta/analisis (khg $KHG, sumber $SUMBER)"
HOTSPOT=$(cari 'hotspots*')
psql_ -v khg="$KHG" -v sumber="$SUMBER" -v berkas_hotspot="$(basename "${HOTSPOT:-}")" -f - < "$ROOT/db/impor_khg.sql"

# ---------------------------------------------------------------- raster -> ubin PNG (XYZ, EPSG:3857)
OUT="$ROOT/lapisan/khg_$KHG"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

# ubin <tif> <nama> <zmin> <zmaks> <stop...>; stop "p<persen>:<warna>" = persentil nilai raster,
# "<nilai>:<warna>" = nilai tetap. Menulis $OUT/<nama>/ dan $TMP/<nama>.json (untuk meta.json).
ubin() {
  local tif=$1 nama=$2 zmin=$3 zmaks=$4; shift 4
  echo "  $nama <- $(basename "$tif")"
  gdalwarp -q -overwrite -t_srs EPSG:3857 -r bilinear -dstnodata -9999 -co COMPRESS=DEFLATE -co TILED=YES \
    "$tif" "$TMP/$nama.3857.tif"
  # sampel nilai (~200 ribu piksel) untuk persentil
  gdal_translate -q -of XYZ -outsize 400 0 -r nearest "$TMP/$nama.3857.tif" "$TMP/$nama.xyz"
  python3 - "$TMP/$nama.xyz" "$TMP/$nama.ramp" "$TMP/$nama.json" "$tif" "$zmin" "$zmaks" "$@" <<'PY'
import json, math, subprocess, sys
xyz, ramp, meta, tif, zmin, zmaks, *stops = sys.argv[1:]
v = sorted(z for z in (float(l.split()[2]) for l in open(xyz)) if math.isfinite(z) and z > -9998)
if not v:
    sys.exit(f'{tif}: raster kosong')
def nilai(s):
    return v[min(len(v) - 1, int(len(v) * float(s[1:]) / 100))] if s.startswith('p') else float(s)
legenda = [[round(nilai(s.split(':')[0]), 2), s.split(':')[1]] for s in stops]
with open(ramp, 'w') as f:
    f.write('nv 0 0 0 0\n')
    for n, w in legenda:
        f.write(f'{n} {int(w[1:3], 16)} {int(w[3:5], 16)} {int(w[5:7], 16)} 255\n')
info = json.loads(subprocess.check_output(['gdalinfo', '-json', tif]))
cs = [c for c in info['wgs84Extent']['coordinates'][0]]
batas = [min(c[0] for c in cs), min(c[1] for c in cs), max(c[0] for c in cs), max(c[1] for c in cs)]
json.dump({'berkas': tif.rsplit('/', 1)[-1], 'zmin': int(zmin), 'zmaks': int(zmaks),
           'batas': [round(b, 5) for b in batas], 'rentang': [round(v[0], 2), round(v[-1], 2)],
           'legenda': legenda, 'resolusi_m': round(abs(info['geoTransform'][1]), 1)}, open(meta, 'w'))
PY
  gdaldem color-relief -q -alpha "$TMP/$nama.3857.tif" "$TMP/$nama.ramp" "$TMP/$nama.rgba.tif" -co COMPRESS=DEFLATE
  rm -rf "${OUT:?}/$nama"
  gdal2tiles --xyz -q -z "$zmin-$zmaks" -w none -r average --processes=4 "$TMP/$nama.rgba.tif" "$OUT/$nama"
}

echo "== raster"
DEM=$(cari 'DTM_*' tif tiff); [ -n "$DEM" ] || DEM=$(cari 'DEM*' tif tiff)
GAMBUT=$(cari 'peat_depth*' tif tiff)
# elevasi: hijau (rendah) -> cokelat (tinggi), batas persentil 2-98 agar tidak didominasi pencilan
[ -n "$DEM" ] && ubin "$DEM" dem 8 14 p2:#1a9850 p25:#91cf60 p50:#d9ef8b p75:#fee08b p90:#d8a35d p98:#8c510a
# ketebalan gambut: sama dengan GAMBUT_RAMP di web (0, 1, 3, 5, 8 m)
[ -n "$GAMBUT" ] && ubin "$GAMBUT" gambut 8 12 0:#1e7b1e 1:#8dbb1c 3:#f2e318 5:#f59e1f 8:#eb4b1f
python3 - "$OUT/meta.json" "$KHG" "$TMP" <<'PY'
import json, os, sys, time
out, khg, tmp = sys.argv[1:]
meta = {'khg_id': int(khg), 'dibuat': time.strftime('%Y-%m-%d %H:%M')}
for nama in ('dem', 'gambut'):
    if os.path.exists(f'{tmp}/{nama}.json'):
        meta[nama] = json.load(open(f'{tmp}/{nama}.json'))
json.dump(meta, open(out, 'w'), indent=1)
PY
[ -z "$DEM$GAMBUT" ] && echo "  -  tidak ada raster"
echo "== selesai: $OUT/meta.json"
[ -n "$DEM" ] && echo "Simulasi (opsional): docker cp \"$DEM\" gambut_api:/simulasi/dem/khg_$KHG.tif &&" \
  "docker exec gambut_api /venv/bin/python3 /simulasi/siapkan.py --khg $KHG --dem /simulasi/dem/khg_$KHG.tif"
exit 0
