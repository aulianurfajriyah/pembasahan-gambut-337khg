#!/usr/bin/env python3
"""Impor paket data beberapa KHG (vektor + raster, satu atau lebih varian DEM) menurut manifest JSON.

    python3 scripts/impor_paket.py scripts/impor_paket_okt2026.json            # semua KHG di manifest
    python3 scripts/impor_paket.py <manifest> --khg 75,624 --tanpa-raster        # sebagian, DB saja
    python3 scripts/impor_paket.py <manifest> --hanya-simulasi                   # grid simulasi saja
    python3 scripts/impor_paket.py <manifest> --hanya-pintu-air                  # pintu air varian saja

Per KHG: lapisan 'bersama' dimuat dengan sumber IMPOR_KHG dan mengganti data lama KHG itu dari sumber lain
(lihat db/impor_paket.sql, yang dihapus disalin ke schema cadangan); tiap varian DEM dimuat dengan sumber
IMPOR_KHG:<kode> dan dicatat di ref.varian_dem (varian pertama = utama). Pintu air varian (lapisan gates_required
model pompa) adalah sekat usulan yang harus berupa pintu: dimuat ke peta.pintu_air dan sekatnya dihapus
(db/impor_pintu_air.sql). Status versi KHG yang masih 'draft'
menjadi 'proses'. DB lama: jalankan dulu db/migrations/2026-10-30_varian_dem.sql + db/10_api_views.sql. Raster: DEM tiap varian -> lapisan/khg_<id>/dem_<kode>/, ketebalan gambut -> .../gambut/,
keterangan di .../meta.json. Simulasi: DEM tiap varian -> simulasi/dem/khg_<id>_<kode>.tif lalu simulasi/siapkan.py
di container gambut_api (grid varian utama = khg_<id>.npz, varian lain = khg_<id>_<kode>.npz). Butuh GDAL (ogr2ogr, gdalwarp, gdaldem, gdal2tiles) dan container gambut_db.

Format berkas di manifest: '<path>[|<layer>][?<where>]'; path relatif ke 'akar', atau 'zip:<alias>/<path>'
untuk isi zip di 'zip' (diekstrak sekali ke output/impor_cache/<alias>/, folder teratas zip dibuang).
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "output" / "impor_cache"
LAPISAN = ROOT / "lapisan"
TABEL_BERSAMA = ("khg", "kanal", "sungai", "badan_air", "areal_terbakar", "hotspot", "usaha", "konsesi", "dmpg",
                 "sekat_existing", "unit_prioritas", "tma_stasiun", "tma_harian")
TABEL_VARIAN = ("kanal_terpilih", "jalur_pompa", "rute_kanal_terpilih", "pompa", "sekat_usulan", "unit_prioritas",
                "pintu_air")
DEM_STOP = ["p2:#1a9850", "p25:#91cf60", "p50:#d9ef8b", "p75:#fee08b", "p90:#d8a35d", "p98:#8c510a"]
GAMBUT_STOP = ["0:#1e7b1e", "1:#8dbb1c", "3:#f2e318", "5:#f59e1f", "8:#eb4b1f"]   # = GAMBUT_RAMP di web


def env():
    e = {}
    for line in (ROOT / "db" / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            e[k.strip()] = v.strip().strip('"').strip("'")
    return e


ENV = env()
PG = (f"PG:host={os.environ.get('PGHOST', 'localhost')} port={os.environ.get('PGPORT', '5433')} dbname=gambut "
      f"user=postgres password={ENV['POSTGRES_PASSWORD']}")


def psql(*args, sql=None):
    cmd = ["docker", "exec", "-i", "gambut_db", "psql", "-X", "-q", "-U", "postgres", "-d", "gambut",
           "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, input=sql, text=True, capture_output=True)
    if r.returncode:
        sys.exit(f"psql gagal:\n{r.stdout}\n{r.stderr}")
    return r.stdout


class Berkas:
    def __init__(self, akar, zips):
        self.akar, self.zips = akar, zips

    def path(self, p):
        if p.startswith("zip:"):
            alias, rest = p[4:].split("/", 1)
            return self.ekstrak(alias) / rest
        return self.akar / p

    def ekstrak(self, alias):
        out = CACHE / alias
        if not out.exists():
            tmp = out.with_suffix(".tmp")
            shutil.rmtree(tmp, ignore_errors=True)
            with zipfile.ZipFile(self.akar / self.zips[alias]) as z:
                for info in z.infolist():
                    parts = [x for x in info.filename.replace("\\", "/").split("/") if x]
                    if info.filename.endswith(("/", "\\")) or not parts or ".." in parts:
                        continue
                    dst = tmp.joinpath(*(parts[1:] if len(parts) > 1 else parts))
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(z.read(info))
            tmp.rename(out)
        return out

    def spec(self, s):
        """'<path>[|<layer>][?<where>]' -> (Path, layer, where)"""
        s, _, where = s.partition("?")
        s, _, layer = s.partition("|")
        p = self.path(s.strip())
        if not p.exists():
            sys.exit(f"berkas tidak ada: {p}")
        return p, layer.strip() or None, where.strip() or None


def stage(berkas, tabel, specs):
    for i, s in enumerate(specs if isinstance(specs, list) else [specs]):
        p, layer, where = berkas.spec(s)
        cmd = ["ogr2ogr", "-f", "PostgreSQL", PG, str(p), *([layer] if layer else []), "-nln", f"impor.{tabel}",
               "-lco", "FID=ogc_fid", "-lco", "UNLOGGED=ON", "--config", "PG_USE_COPY", "YES", "-gt", "100000"]
        cmd += ["-append"] if i else ["-overwrite"]
        if where:
            cmd += ["-where", where]
        if p.suffix.lower() != ".csv":
            cmd += ["-t_srs", "EPSG:4326", "-dim", "XY", "-makevalid", "-nlt", "PROMOTE_TO_MULTI",
                    "-lco", "GEOMETRY_NAME=geom", "-lco", "SPATIAL_INDEX=NONE"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"ogr2ogr gagal ({tabel} <- {s}):\n{r.stderr}")
        print(f"   ok {tabel} <- {p.name}{'|' + layer if layer else ''}{' ?' + where if where else ''}")


def muat(berkas, khg, sumber, lapisan, ganti):
    psql("-c", "DROP SCHEMA IF EXISTS impor CASCADE; CREATE SCHEMA impor")
    for tabel, specs in lapisan.items():
        stage(berkas, tabel, specs)
    hotspot = lapisan.get("hotspot")
    nama_hotspot = berkas.spec(hotspot if isinstance(hotspot, str) else hotspot[0])[0].name if hotspot else ""
    out = psql("-v", f"khg={khg}", "-v", f"sumber={sumber}", "-v", f"ganti={'on' if ganti else 'off'}",
               "-v", f"berkas_hotspot={nama_hotspot}", "-P", "footer=off",
               sql=(ROOT / "db" / "impor_paket.sql").read_text())
    print("\n".join("   " + l for l in out.strip().splitlines()))
    if "pintu_air" in lapisan:
        pintu_air(khg, sumber)
    psql("-c", "DROP SCHEMA IF EXISTS impor CASCADE")


def pintu_air(khg, sumber):
    """impor.pintu_air (gates_required) -> peta.pintu_air; sekat usulan di titik yang sama dipindah (db/impor_pintu_air.sql)"""
    out = psql("-v", f"khg={khg}", "-v", f"sumber={sumber}", "-P", "footer=off",
               sql=(ROOT / "db" / "impor_pintu_air.sql").read_text())
    print("\n".join("   " + l for l in out.strip().splitlines()))


def impor_pintu_air(berkas, k):
    """Hanya pintu air tiap varian (memindah sekat usulan yang sudah diimpor), tanpa mengimpor ulang lapisan lain."""
    print(f"== pintu air KHG {k['id']} ({k['folder']})")
    for v in k["varian"]:
        if v.get("pintu_air"):
            print(f" - varian {v['kode']}")
            psql("-c", "DROP SCHEMA IF EXISTS impor CASCADE; CREATE SCHEMA impor")
            stage(berkas, "pintu_air", v["pintu_air"])
            pintu_air(k["id"], f"IMPOR_KHG:{v['kode']}")
            psql("-c", "DROP SCHEMA IF EXISTS impor CASCADE")


def lit(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def impor_db(berkas, k):
    khg = k["id"]
    print(f"== KHG {khg} ({k['folder']})")
    print(" - bersama (IMPOR_KHG)")
    muat(berkas, khg, "IMPOR_KHG", {t: v for t, v in k["bersama"].items() if t in TABEL_BERSAMA}, ganti=True)
    for v in k["varian"]:
        print(f" - varian {v['kode']} ({v['label']})")
        muat(berkas, khg, f"IMPOR_KHG:{v['kode']}", {t: s for t, s in v.items() if t in TABEL_VARIAN}, ganti=False)
    baris = ",\n".join(f"({khg}, {lit(v['kode'])}, {lit(v['label'])}, {str(i == 0).lower()}, {i + 1}, {lit(v.get('catatan'))})"
                       for i, v in enumerate(k["varian"]))
    psql(sql=f"""
BEGIN;
DELETE FROM ref.varian_dem WHERE khg_id = {khg};
INSERT INTO ref.varian_dem (khg_id, kode, label, utama, urutan, catatan) VALUES
{baris};
-- data proses: versi terbuka yang masih draft -> proses (tanpa versi terbuka: buat dulu)
SELECT alur.versi_terbuka({khg});
UPDATE alur.khg_versi SET status = 'proses' WHERE khg_id = {khg} AND status = 'draft';
COMMIT;""")


def ubin(tif, out, nama, zmin, zmaks, stops, tmp):
    """GeoTIFF -> ubin PNG XYZ (EPSG:3857) di out/nama/; kembalikan keterangan untuk meta.json.
    stop "p<persen>:<warna>" = persentil nilai raster, "<nilai>:<warna>" = nilai tetap."""
    print(f"   {nama} <- {tif.name}")
    w = tmp / f"{nama}.3857.tif"
    run(["gdalwarp", "-q", "-overwrite", "-t_srs", "EPSG:3857", "-r", "bilinear", "-dstnodata", "-9999",
         "-wo", "NUM_THREADS=ALL_CPUS", "-multi", "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", "-co", "BIGTIFF=IF_SAFER",
         str(tif), str(w)])
    xyz = tmp / f"{nama}.xyz"
    run(["gdal_translate", "-q", "-of", "XYZ", "-outsize", "400", "0", "-r", "nearest", str(w), str(xyz)])
    v = sorted(z for z in (float(l.split()[2]) for l in open(xyz)) if math.isfinite(z) and -9998 < z < 1e6)
    if not v:
        sys.exit(f"{tif}: raster kosong")
    nilai = lambda s: v[min(len(v) - 1, int(len(v) * float(s[1:]) / 100))] if s.startswith("p") else float(s)
    legenda = [[round(nilai(s.split(":")[0]), 2), s.split(":")[1]] for s in stops]
    ramp = tmp / f"{nama}.ramp"
    ramp.write_text("nv 0 0 0 0\n" + "".join(f"{n} {int(c[1:3], 16)} {int(c[3:5], 16)} {int(c[5:7], 16)} 255\n"
                                             for n, c in legenda))
    rgba = tmp / f"{nama}.rgba.tif"
    run(["gdaldem", "color-relief", "-q", "-alpha", str(w), str(ramp), str(rgba), "-co", "COMPRESS=DEFLATE",
         "-co", "BIGTIFF=IF_SAFER"])
    shutil.rmtree(out / nama, ignore_errors=True)
    run(["gdal2tiles", "--xyz", "-q", "-z", f"{zmin}-{zmaks}", "-w", "none", "-r", "average",
         f"--processes={os.cpu_count() or 4}", str(rgba), str(out / nama)])
    info = json.loads(subprocess.check_output(["gdalinfo", "-json", str(tif)]))
    cs = info["wgs84Extent"]["coordinates"][0]
    for f in (w, xyz, rgba):
        f.unlink()
    return {"berkas": tif.name, "folder": nama, "zmin": zmin, "zmaks": zmaks,
            "batas": [round(b, 5) for b in (min(c[0] for c in cs), min(c[1] for c in cs),
                                            max(c[0] for c in cs), max(c[1] for c in cs))],
            "rentang": [round(v[0], 2), round(v[-1], 2)], "legenda": legenda,
            "resolusi_m": round(abs(info["geoTransform"][1]), 1)}


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"gagal: {' '.join(cmd)}\n{r.stderr}")


def impor_raster(berkas, k):
    khg = k["id"]
    out = LAPISAN / f"khg_{khg}"
    out.mkdir(parents=True, exist_ok=True)
    print(f"== raster KHG {khg}")
    meta = {"khg_id": khg, "dibuat": time.strftime("%Y-%m-%d %H:%M"), "varian": []}
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        if k["bersama"].get("gambut"):
            meta["gambut"] = ubin(berkas.spec(k["bersama"]["gambut"])[0], out, "gambut", 8, 12, GAMBUT_STOP, tmp)
        else:
            shutil.rmtree(out / "gambut", ignore_errors=True)
        for i, v in enumerate(k["varian"]):
            dem = ubin(berkas.spec(v["dem"])[0], out, f"dem_{v['kode'].lower()}", 8, 14, DEM_STOP, tmp)
            meta["varian"].append({"kode": v["kode"], "label": v["label"], "utama": i == 0,
                                   "sumber": f"IMPOR_KHG:{v['kode']}", "catatan": v.get("catatan"), "dem": dem})
    # dem = DEM varian utama (pembaca lama meta.json)
    meta["dem"] = meta["varian"][0]["dem"]
    tersisa = {"gambut", "meta.json"} | {x["dem"]["folder"] for x in meta["varian"]}
    for p in out.iterdir():   # ubin varian yang tidak ada lagi di manifest, dan folder lama "dem"
        if p.name not in tersisa:
            shutil.rmtree(p) if p.is_dir() else p.unlink()
    (out / "meta.json").write_text(json.dumps(meta, indent=1))


# radius penghalusan elevasi kanal (simulasi/siapkan.py --halus): DEM rapat & bersih lebih kecil
HALUS_M = {"LIDAR": 60, "BRGM": 60}


def siapkan_simulasi(berkas, k):
    khg = k["id"]
    print(f"== simulasi KHG {khg}")
    for i, v in enumerate(k["varian"]):
        dem = ROOT / "simulasi" / "dem" / f"khg_{khg}_{v['kode'].lower()}.tif"
        src = berkas.spec(v["dem"])[0]
        res = abs(json.loads(subprocess.check_output(["gdalinfo", "-json", str(src)]))["geoTransform"][1])
        # grid simulasi 30 m: DEM lebih rapat dari 10 m dirata-ratakan dulu agar salinannya kecil
        run(["gdalwarp", "-q", "-overwrite", "-r", "average", "-tr", str(max(res, 10)), str(max(res, 10)),
             "-wo", "NUM_THREADS=ALL_CPUS", "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", str(src), str(dem)])
        halus = HALUS_M.get(v["kode"], 300)
        cmd = ["docker", "exec", "gambut_api", "/venv/bin/python3", "/simulasi/siapkan.py", "--khg", str(khg),
               "--dem", f"/simulasi/dem/{dem.name}", "--varian", v["kode"], "--halus", str(halus)]
        r = subprocess.run(cmd + (["--utama"] if i == 0 else []), capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"siapkan.py gagal (KHG {khg} {v['kode']}):\n{r.stdout}\n{r.stderr}")
        print(f"   {v['kode']} ({'utama, ' if i == 0 else ''}halus {halus} m): {r.stdout.strip().splitlines()[-1]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("manifest")
    ap.add_argument("--khg", help="id KHG dipisah koma (bawaan: semua di manifest)")
    ap.add_argument("--tanpa-raster", action="store_true")
    ap.add_argument("--hanya-raster", action="store_true")
    ap.add_argument("--hanya-simulasi", action="store_true", help="hanya siapkan grid simulasi")
    ap.add_argument("--tanpa-simulasi", action="store_true")
    ap.add_argument("--hanya-pintu-air", action="store_true",
                    help="hanya pintu air varian (DB lama yang diimpor sebelum lapisan pintu_air ada)")
    a = ap.parse_args()
    m = json.loads(Path(a.manifest).read_text())
    berkas = Berkas(Path(os.path.expanduser(m["akar"])), m.get("zip", {}))
    pilih = {int(x) for x in a.khg.split(",")} if a.khg else None
    daftar = [k for k in m["khg"] if pilih is None or k["id"] in pilih]
    if a.hanya_pintu_air:
        for k in daftar:
            impor_pintu_air(berkas, k)
        print("== statistik:", psql("-At", "-c", "SELECT api.refresh_statistik()").strip())
        return
    if not (a.hanya_raster or a.hanya_simulasi):
        for k in daftar:
            impor_db(berkas, k)
        print("== statistik:", psql("-At", "-c", "SELECT api.refresh_statistik()").strip())
    if not (a.tanpa_raster or a.hanya_simulasi):
        for k in daftar:
            impor_raster(berkas, k)
    if not (a.tanpa_simulasi or a.hanya_raster):
        for k in daftar:
            siapkan_simulasi(berkas, k)
    print("== selesai")


if __name__ == "__main__":
    main()
