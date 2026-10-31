"""Siapkan data simulasi pembasahan untuk satu KHG (dijalankan sekali per KHG / per DEM baru).

  docker exec gambut_api /venv/bin/python3 /simulasi/siapkan.py --khg 522 --dem /simulasi/dem/khg_522.tif

Keluaran: /simulasi/data/khg_<id>.npz (grid) dan khg_<id>.alur.json (kanal berarah ke hilir).
DEM boleh diganti (mis. LiDAR 50 cm): cukup jalankan ulang dengan --dem baru; grid mengikuti DEM,
diturunkan ke --res meter bila DEM lebih rapat.

Varian DEM (ref.varian_dem): --varian <KODE> mencatat kodenya di grid; tanpa --utama keluaran diberi akhiran
(khg_<id>_<kode>.npz) agar tidak menimpa grid varian utama.
"""
import argparse
import heapq
import json
import math
import os
import shutil
import struct
import time
import zlib

import numpy as np
import rasterio
from pyproj import Transformer
from rasterio import features
from rasterio.enums import Resampling
from rasterio.transform import Affine
from rasterio.warp import reproject
from scipy import ndimage
from shapely import wkb
from sqlalchemy import create_engine, text

DIR = os.path.dirname(os.path.abspath(__file__))
NB = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def db():
    return create_engine(
        f"postgresql+psycopg2://ogc_reader:{os.environ['PW_OGC_READER']}@{os.environ['PG_HOST']}"
        f":{os.environ.get('PG_PORT', '5432')}/{os.environ['PG_DB']}")


def baca_dem(path, res):
    with rasterio.open(path) as src:
        if src.crs is None or not src.crs.is_projected:
            raise SystemExit('DEM harus berproyeksi meter (mis. UTM).')
        skala = max(1, round(res / src.res[0]))
        h, w = src.height // skala, src.width // skala
        z = src.read(1, out_shape=(h, w), resampling=Resampling.average if skala > 1 else Resampling.nearest,
                     masked=True).astype('float32').filled(np.nan)
        tr = src.transform * src.transform.scale(src.width / w, src.height / h)
        return z, tr, src.crs.to_epsg()


def isi_kosong(z):
    kosong = ~np.isfinite(z)
    if kosong.any():
        idx = ndimage.distance_transform_edt(kosong, return_distances=False, return_indices=True)
        z = z[tuple(idx)]
    return z


def banjir_prioritas(zk, tetangga, benih):
    """Priority-flood di jaringan kanal: elevasi terkondisi (tak turun ke hulu), induk (sel hilir), urutan."""
    n = len(zk)
    zc = np.full(n, np.nan, 'float32')
    induk = np.full(n, -1, 'int32')
    urut = []
    tumpuk = [(float(zk[i]), int(i)) for i in benih]
    heapq.heapify(tumpuk)
    for i in benih:
        zc[i] = zk[i]
    selesai = np.zeros(n, bool)
    while tumpuk:
        _, i = heapq.heappop(tumpuk)
        if selesai[i]:
            continue
        selesai[i] = True
        urut.append(i)
        for j in tetangga[i]:
            if j >= 0 and not selesai[j] and np.isnan(zc[j]):
                zc[j] = max(zk[j], zc[i])
                induk[j] = i
                heapq.heappush(tumpuk, (float(zc[j]), int(j)))
    return zc, induk, np.array(urut, 'int32')


def png_rgb(rgb):
    h, w, _ = rgb.shape
    baris = np.zeros((h, w * 3 + 1), 'uint8')
    baris[:, 1:] = rgb.reshape(h, w * 3)

    def potong(tipe, isi):
        return struct.pack('>I', len(isi)) + tipe + isi + struct.pack('>I', zlib.crc32(tipe + isi))

    return (b'\x89PNG\r\n\x1a\n' + potong(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + potong(b'IDAT', zlib.compress(baris.tobytes(), 6)) + potong(b'IEND', b''))


def ubin_medan(z, tr, epsg, folder, zmin=8, zmaks=12):
    """Ubin elevasi (PNG terrarium, EPSG:3857) untuk tampilan 3D MapLibre. Mengembalikan batas lon/lat."""
    H, W = z.shape
    ke_ll = Transformer.from_crs(epsg, 4326, always_xy=True)
    xs, ys = zip(*[tr * p for p in [(0, 0), (W, 0), (W, H), (0, H)]])
    lon, lat = ke_ll.transform(xs, ys)
    batas = [min(lon), min(lat), max(lon), max(lat)]
    dunia = 20037508.342789244
    shutil.rmtree(folder, ignore_errors=True)
    jumlah = 0
    for zoom in range(zmin, zmaks + 1):
        n = 2 ** zoom
        ukuran = 2 * dunia / n

        def kolom(lo):
            return int((lo + 180) / 360 * n)

        def baris(la):
            return int((1 - math.asinh(math.tan(math.radians(la))) / math.pi) / 2 * n)

        for x in range(kolom(batas[0]), kolom(batas[2]) + 1):
            for y in range(baris(batas[3]), baris(batas[1]) + 1):
                tujuan = np.full((256, 256), np.nan, 'float32')
                reproject(z, tujuan, src_transform=tr, src_crs=f'EPSG:{epsg}', src_nodata=np.nan,
                          dst_transform=Affine(ukuran / 256, 0, -dunia + x * ukuran, 0, -ukuran / 256, dunia - y * ukuran),
                          dst_crs='EPSG:3857', dst_nodata=np.nan, resampling=Resampling.bilinear)
                if not np.isfinite(tujuan).any():
                    continue
                v = np.nan_to_num(tujuan, nan=0.0).astype('float64') + 32768
                rgb = np.stack([v // 256, v % 256 // 1, (v % 1) * 256], axis=-1).astype('uint8')
                os.makedirs(f'{folder}/{zoom}/{x}', exist_ok=True)
                with open(f'{folder}/{zoom}/{x}/{y}.png', 'wb') as f:
                    f.write(png_rgb(rgb))
                jumlah += 1
    return {'zmin': zmin, 'zmaks': zmaks, 'batas': [round(b, 5) for b in batas], 'ubin': jumlah}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--khg', type=int, required=True)
    ap.add_argument('--dem', required=True)
    ap.add_argument('--res', type=float, default=30.0, help='resolusi grid simulasi (m)')
    ap.add_argument('--halus', type=float, default=300.0,
                    help='radius penghalusan elevasi kanal (m); DEMNAS 30 m: 300, LiDAR: 30-60')
    ap.add_argument('--varian', help='kode varian DEM (ref.varian_dem), mis. LIDAR')
    ap.add_argument('--utama', action='store_true', help='varian utama: keluaran tanpa akhiran kode')
    a = ap.parse_args()
    stem = f'khg_{a.khg}' if a.utama or not a.varian else f'khg_{a.khg}_{a.varian.lower()}'
    t0 = time.time()

    z, tr, epsg = baca_dem(a.dem, a.res)
    res = tr.a
    z = isi_kosong(z)
    H, W = z.shape
    print(f'grid {W}x{H} @ {res:.1f} m, EPSG:{epsg}')

    with db().connect() as con:
        def geom(sql):
            return [(r[0], wkb.loads(bytes(r[1]))) + tuple(r[2:]) for r in con.execute(text(sql), {'k': a.khg, 'e': epsg})]
        khg = geom("SELECT nama, ST_AsBinary(ST_Transform(geom, :e)) FROM ref.khg WHERE id = :k")
        if not khg:
            raise SystemExit('KHG tidak ditemukan')
        nama, poligon = khg[0]
        # salinan kanal terpilih varian DEM (sumber IMPOR_KHG:*) bukan kanal tambahan
        kanal = geom("""SELECT id, ST_AsBinary(ST_Transform(geom, :e)), jenis_kanal, kode
                          FROM peta.kanal WHERE khg_id = :k AND left(coalesce(sumber, ''), 10) <> 'IMPOR_KHG:'""")
        bakar = geom("""SELECT id, ST_AsBinary(ST_Transform(geom, :e)), cardinality(tahun_terbakar),
                               (SELECT max(t) FROM unnest(tahun_terbakar) t)
                          FROM peta.areal_terbakar WHERE khg_id = :k""")
    print(f'{nama}: {len(kanal)} kanal, {len(bakar)} poligon terbakar')

    dalam = features.rasterize([(poligon, 1)], (H, W), transform=tr, dtype='uint8').astype(bool)
    r_kanal = features.rasterize([(g, 1) for _, g, *_ in kanal], (H, W), transform=tr, dtype='uint8',
                                 all_touched=True).astype(bool)
    frek = np.zeros((H, W), 'uint8')
    for _, g, n, _t in sorted(bakar, key=lambda b: b[2]):
        features.rasterize([(g, int(n))], out=frek, transform=tr)
    frek[~dalam] = 0

    # elevasi kanal: DEM dihaluskan (Gauss) supaya yang terbaca kemiringan kubah gambut, bukan derau DEM
    zs = ndimage.gaussian_filter(z, sigma=a.halus / res, mode='nearest') if a.halus > 0 else z
    kr, kc = np.nonzero(r_kanal)
    n = len(kr)
    no = np.full((H, W), -1, 'int32')
    no[kr, kc] = np.arange(n)
    zk = zs[kr, kc]
    tetangga = np.full((n, 8), -1, 'int32')
    for t, (dr, dc) in enumerate(NB):
        rr, cc = kr + dr, kc + dc
        ok = (rr >= 0) & (rr < H) & (cc >= 0) & (cc < W)
        tetangga[ok, t] = no[rr[ok], cc[ok]]

    # muara: sel kanal di tepi/luar KHG (batas KHG = sungai), + sel terendah tiap jaringan tanpa muara
    inti = ndimage.binary_erosion(dalam, iterations=2)
    muara = ~inti[kr, kc]
    label, nlabel = ndimage.label(r_kanal, structure=np.ones((3, 3)))
    lab = label[kr, kc]
    punya = np.zeros(nlabel + 1, bool)
    punya[lab[muara]] = True
    urut_z = np.argsort(zk)
    terendah = np.full(nlabel + 1, -1, 'int64')
    terendah[lab[urut_z[::-1]]] = urut_z[::-1]
    tambahan = terendah[1:][~punya[1:]]
    benih = np.concatenate([np.nonzero(muara)[0], tambahan])
    zc, induk, urut = banjir_prioritas(zk, tetangga, benih)
    datar = float((zc[induk >= 0] == zc[induk[induk >= 0]]).mean())
    print(f'{n} sel kanal, {nlabel} jaringan, {len(benih)} muara ({len(tambahan)} jaringan buntu), '
          f'{100 * datar:.0f}% sel kanal datar setelah dikondisikan')

    jarak, (ir, ic) = ndimage.distance_transform_edt(~r_kanal, sampling=res, return_indices=True)
    dekat = no[ir, ic]

    # kanal berarah hulu -> hilir untuk animasi aliran
    ke_ll = Transformer.from_crs(epsg, 4326, always_xy=True)
    peringkat = np.empty(n, 'int32')
    peringkat[urut] = np.arange(n)
    inv = ~tr

    def sel(x, y):
        c, r = inv * (x, y)
        r, c = int(min(max(r, 0), H - 1)), int(min(max(c, 0), W - 1))
        return int(dekat[r, c])

    alur = []
    for kid, g, jenis, kode in kanal:
        for garis in getattr(g, 'geoms', [g]):
            xy = np.asarray(garis.simplify(res / 3).coords)
            if len(xy) < 2:
                continue
            awal, akhir = sel(*xy[0]), sel(*xy[-1])
            if peringkat[awal] < peringkat[akhir]:   # awal lebih hilir -> balik
                xy = xy[::-1]
                awal, akhir = akhir, awal
            tengah = sel(*garis.interpolate(0.5, normalized=True).coords[0])
            lon, lat = ke_ll.transform(xy[:, 0], xy[:, 1])
            alur.append({'id': int(kid), 'kode': kode, 'jenis': jenis, 'sel': [awal, tengah, akhir],
                         'turun_m': round(float(zc[awal] - zc[akhir]), 2),
                         'xy': [[round(float(o), 6), round(float(t), 6)] for o, t in zip(lon, lat)]})

    r0, r1 = np.nonzero(dalam.any(1))[0][[0, -1]]
    c0, c1 = np.nonzero(dalam.any(0))[0][[0, -1]]
    kiri, atas = tr * (c0, r0)
    kanan, bawah = tr * (c1 + 1, r1 + 1)
    sudut = [list(ke_ll.transform(x, y)) for x, y in [(kiri, atas), (kanan, atas), (kanan, bawah), (kiri, bawah)]]

    os.makedirs(f'{DIR}/data', exist_ok=True)
    medan = ubin_medan(ndimage.gaussian_filter(z, sigma=1, mode='nearest'), tr, epsg, f'{DIR}/data/{stem}/medan')
    print(f"{medan['ubin']} ubin medan 3D (zoom {medan['zmin']}-{medan['zmaks']})")
    np.savez_compressed(
        f'{DIR}/data/{stem}.npz',
        dalam=dalam, frek=frek, dekat=dekat, jarak=np.minimum(jarak, 60000).astype('float16'),
        elev=z.astype('float16'),
        zc=zc, induk=induk, urut=urut,
        meta=json.dumps({'khg_id': a.khg, 'nama': nama, 'epsg': epsg, 'res': res, 'transform': list(tr)[:6],
                         'jendela': [int(r0), int(r1) + 1, int(c0), int(c1) + 1], 'sudut': sudut, 'medan': medan,
                         'dem': os.path.basename(a.dem), 'halus_m': a.halus, 'varian': a.varian, 'dibuat': time.strftime('%Y-%m-%d %H:%M')}))
    with open(f'{DIR}/data/{stem}.alur.json', 'w') as f:
        json.dump(alur, f, separators=(',', ':'))
    print(f'selesai {time.time() - t0:.0f} s: {dalam.sum() * res * res / 1e4:,.0f} ha, {len(alur)} ruas alur')


if __name__ == '__main__':
    main()
