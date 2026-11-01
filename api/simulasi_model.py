"""Model simulasi pembasahan (tier 1, penapisan cepat) - dipakai proses simulasi-pembasahan.

Ringkas:
  1. Muka air kanal tanpa sekat = permukaan terkondisi - kedalaman_kanal.
  2. Sekat menahan air setinggi mercu (permukaan - jagaan, dikali efektivitas); genangan merambat ke hulu
     sampai permukaan naik melebihi mercu.
  3. Kedalaman muka air tanah di lahan = alami + (kedalaman air kanal terdekat - alami) * exp(-jarak / L).
  4. Lahan "kering" bila muka air tanah lebih dalam dari ambang (PP 57/2016: 0,4 m).
  5. Kondisi awal 'tmat' (opsional): selisih bacaan stasiun TMAT terhadap model kondisi saat ini diinterpolasi
     (IDW) dan diredam menurut jarak ke stasiun terdekat (exp(-jarak / radius_tmat_m)), lalu ditambahkan ke semua
     kondisi. Kenaikan akibat sekat tetap dari model; yang dikoreksi adalah titik awalnya.
Hasil bersifat indikatif.
"""
import base64
import glob
import json
import os
import struct
import zlib
from functools import lru_cache

import numpy as np

DATA = os.environ.get('SIMULASI_DATA', '/simulasi/data')

PARAM = {  # nama: (bawaan, min, maks, keterangan)
    'kedalaman_kanal_m': (1.0, 0.2, 3.0, 'Kedalaman muka air kanal tanpa sekat, dari permukaan gambut'),
    'jagaan_sekat_m': (0.2, 0.0, 1.0, 'Mercu sekat di bawah permukaan gambut'),
    'efektivitas': (0.8, 0.1, 1.0, 'Bagian tinggi tahan yang tercapai (kebocoran/rembesan)'),
    'jarak_pengaruh_m': (200.0, 20.0, 2000.0, 'Jarak pengaruh kanal ke muka air tanah di lahan'),
    'muka_air_alami_m': (0.2, 0.0, 1.5, 'Kedalaman muka air tanah jauh dari kanal pada puncak kemarau'),
    'ambang_tmat_m': (0.4, 0.1, 1.0, 'Ambang tinggi muka air tanah (PP 57/2016: 0,4 m)'),
    'radius_tmat_m': (3000.0, 200.0, 20000.0, 'Jarak pengaruh koreksi stasiun TMAT (hanya kondisi awal TMAT)'),
}
SKENARIO = {'final': 'Sekat existing + sekat final', 'rencana': 'Sekat existing + semua sekat rencana'}
KONDISI_AWAL = {'model': 'Model (muka air alami seragam)', 'tmat': 'Data stasiun TMAT'}
STATISTIK_TMAT = {'akhir': 'Bacaan terakhir', 'rata': 'Rata-rata', 'maks': 'Terdalam (terkering)'}

BATAS_DALAM = [0.1, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0]
WARNA_DALAM = ['#08519c', '#3182bd', '#6baed6', '#bdd7e7', '#fee08b', '#fdae61', '#f46d43', '#d73027']
BATAS_NAIK = [0.05, 0.1, 0.2, 0.4, 0.6]
WARNA_NAIK = ['#d9f0a3', '#addd8e', '#78c679', '#31a354', '#006837']
WARNA_ELEV = ['#1a6b52', '#4f9b63', '#8cc47a', '#cfe3a0', '#f5efb8', '#e8c98a', '#d19c63', '#b5713f', '#7d4426']


def berkas(khg_id, varian=None):
    """Nama dasar grid: khg_<id>_<kode> untuk varian DEM non-utama, khg_<id> untuk varian utama / tanpa varian."""
    if varian:
        stem = f'khg_{khg_id}_{varian.lower()}'
        if os.path.exists(f'{DATA}/{stem}.npz'):
            return stem
        if os.path.exists(f'{DATA}/khg_{khg_id}.npz') and \
                json.loads(str(np.load(f'{DATA}/khg_{khg_id}.npz')['meta'])).get('varian') == varian:
            return f'khg_{khg_id}'
        raise ValueError(f'KHG {khg_id} varian DEM {varian} belum disiapkan untuk simulasi (jalankan simulasi/siapkan.py).')
    return f'khg_{khg_id}'


def muat(khg_id, varian=None):
    stem = berkas(khg_id, varian)
    try:
        versi = os.path.getmtime(f'{DATA}/{stem}.npz')   # grid yang disiapkan ulang tidak tertahan di cache
    except FileNotFoundError:
        versi = None
    return _muat(stem, versi)


@lru_cache(maxsize=4)
def _muat(stem, versi):
    try:
        d = np.load(f'{DATA}/{stem}.npz')
    except FileNotFoundError:
        raise ValueError(f'{stem.replace("khg_", "KHG ")} belum disiapkan untuk simulasi (jalankan simulasi/siapkan.py).')
    g = {k: d[k] for k in ('dalam', 'frek', 'dekat', 'jarak', 'zc', 'induk', 'urut')}
    g['meta'] = json.loads(str(d['meta']))
    g['stem'] = stem
    with open(f'{DATA}/{stem}.alur.json') as f:
        g['alur'] = json.load(f)
    g['dekat_d'] = g['dekat'][g['dalam']]
    g['jarak_d'] = g['jarak'][g['dalam']].astype('float32')
    g['frek_d'] = g['frek'][g['dalam']]
    g['urut_l'], g['induk_l'] = g['urut'].tolist(), g['induk'].tolist()
    g['nomor_d'] = np.full(g['dalam'].shape, -1, 'int32')
    g['nomor_d'][g['dalam']] = np.arange(len(g['dekat_d']))
    elev = d['elev'][g['dalam']].astype('float32')
    batas = sorted({round(float(v), 1) for v in np.percentile(elev, np.linspace(4, 96, len(WARNA_ELEV) - 1))})
    g['elevasi'] = {'gambar': gambar(g, elev, batas, WARNA_ELEV),
                    'legenda': {'batas': batas, 'warna': WARNA_ELEV[:len(batas) + 1]},
                    'min_m': round(float(elev.min()), 1), 'maks_m': round(float(elev.max()), 1)}
    return g


def daftar():
    out = []
    for p in sorted(glob.glob(f'{DATA}/khg_*.npz')):
        m = json.loads(str(np.load(p)['meta']))
        out.append({**{k: m[k] for k in ('khg_id', 'nama', 'res', 'dem', 'dibuat')}, 'varian': m.get('varian')})
    return out


def parameter(masukan):
    p = {}
    for nama, (bawaan, lo, hi, _) in PARAM.items():
        v = masukan.get(nama, bawaan)
        if not isinstance(v, (int, float)) or isinstance(v, bool) or not lo <= v <= hi:
            raise ValueError(f'{nama} harus angka antara {lo} dan {hi}.')
        p[nama] = float(v)
    return p


def sel_sekat(g, xy, toleransi_m=90.0):
    """Tempelkan titik sekat (koordinat grid) ke sel kanal terdekat; -1 bila tidak di kanal terpetakan."""
    a, b, c, d, e, f = g['meta']['transform']
    x, y = np.asarray(xy, 'float64').reshape(-1, 2).T
    col = np.floor((x - c) / a).astype('int64')
    row = np.floor((y - f) / e).astype('int64')
    H, W = g['dalam'].shape
    ok = (row >= 0) & (row < H) & (col >= 0) & (col < W)
    sel = np.full(len(x), -1, 'int64')
    r, k = row[ok], col[ok]
    dekat = g['dekat'][r, k].astype('int64')
    dekat[g['jarak'][r, k] > toleransi_m] = -1
    sel[ok] = dekat
    return sel


def muka_air_kanal(g, p, sel, nomor):
    """Kedalaman air kanal dari permukaan (m) dan sekat pengendali tiap sel kanal."""
    zc = g['zc']
    n = len(zc)
    d0 = p['kedalaman_kanal_m']
    tahan = max(0.0, p['efektivitas'] * (d0 - p['jagaan_sekat_m']))
    dasar = (zc - d0).tolist()
    mercu = [None] * n
    milik = [-1] * n
    for s, no in zip(sel.tolist(), nomor):
        if s >= 0 and mercu[s] is None:
            mercu[s] = dasar[s] + tahan
            milik[s] = no
    muka = dasar[:]
    kendali = [-1] * n
    induk = g['induk_l']
    for i in g['urut_l']:
        h = induk[i]
        if h >= 0 and muka[h] > muka[i]:
            muka[i] = muka[h]
            kendali[i] = kendali[h]
        m = mercu[i]
        if m is not None and m > muka[i]:
            muka[i] = m
            kendali[i] = milik[i]
    return zc - np.asarray(muka, 'float32'), np.asarray(kendali, 'int64')


def muka_air_tanah(g, p, dalam_kanal):
    alami = p['muka_air_alami_m']
    return alami + (dalam_kanal[g['dekat_d']] - alami) * redaman(g, p['jarak_pengaruh_m'])


def redaman(g, jarak_pengaruh_m):
    """exp(-jarak / L) tiap sel lahan; satu simulasi memakai 3 nilai L untuk 11 panggilan, jadi disimpan per grid."""
    simpan = g.setdefault('redaman', {})
    if jarak_pengaruh_m not in simpan:
        if len(simpan) >= 6:   # ponytail: batas kasar memori (13 MB per L untuk 3 juta sel)
            simpan.clear()
        simpan[jarak_pengaruh_m] = np.exp(-g['jarak_d'] / jarak_pengaruh_m)
    return simpan[jarak_pengaruh_m]


def png(indeks, palet):
    """PNG berpalet; indeks 0 transparan."""
    h, w = indeks.shape
    baris = np.zeros((h, w + 1), 'uint8')
    baris[:, 1:] = indeks

    def potong(tipe, isi):
        return struct.pack('>I', len(isi)) + tipe + isi + struct.pack('>I', zlib.crc32(tipe + isi))

    plte = b'\x00\x00\x00' + b''.join(bytes.fromhex(c[1:]) for c in palet)
    data = (b'\x89PNG\r\n\x1a\n' + potong(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0))
            + potong(b'PLTE', plte) + potong(b'tRNS', b'\x00')
            + potong(b'IDAT', zlib.compress(baris.tobytes(), 6)) + potong(b'IEND', b''))
    return 'data:image/png;base64,' + base64.b64encode(data).decode()


def digitize1(nilai, batas):
    """= (np.digitize(nilai, batas) + 1) sebagai uint8, ±3x lebih cepat untuk batas sedikit (tanpa NaN)."""
    kelas = np.ones(nilai.shape, 'uint8')
    for b in np.asarray(batas, 'float64').reshape(-1, 1):   # batas float64 seperti digitize
        kelas += nilai >= b
    return kelas


def gambar(g, nilai, batas, palet, kosongkan_di_bawah=None):
    r0, r1, c0, c1 = g['meta']['jendela']
    kelas = digitize1(nilai, batas)
    if kosongkan_di_bawah is not None:
        kelas[nilai < kosongkan_di_bawah] = 0
        kelas[kelas > 0] -= 1
    penuh = np.zeros(g['dalam'].shape, 'uint8')
    penuh[g['dalam']] = kelas
    return png(penuh[r0:r1, c0:c1], palet)


def sel_lahan(g, xy):
    """Nomor sel lahan (di dalam KHG) untuk tiap titik; -1 bila di luar."""
    a, _, c, _, e, f = g['meta']['transform']
    x, y = np.asarray(xy, 'float64').reshape(-1, 2).T
    col, row = np.floor((x - c) / a).astype('int64'), np.floor((y - f) / e).astype('int64')
    H, W = g['dalam'].shape
    ok = (row >= 0) & (row < H) & (col >= 0) & (col < W)
    out = np.full(len(x), -1, 'int64')
    out[ok] = g['nomor_d'][row[ok], col[ok]]
    return out


def koreksi_tmat(g, p, tanah_kini, stasiun):
    """Koreksi muka air tanah (m) tiap sel lahan dari selisih bacaan TMAT terhadap model kondisi saat ini."""
    nomor = sel_lahan(g, [(s['x'], s['y']) for s in stasiun]) if stasiun else np.zeros(0, 'int64')
    pakai = [(s, i) for s, i in zip(stasiun, nomor.tolist()) if i >= 0 and s['tmat_m'] is not None]
    info = [{'kode': s['kode'], 'lokasi': [round(s['lon'], 6), round(s['lat'], 6)], 'tanggal': s['tanggal'],
             'n_bacaan': s['n_bacaan'], 'tmat_m': round(float(s['tmat_m']), 2),
             'model_m': round(float(tanah_kini[i]), 2), 'selisih_m': round(float(s['tmat_m'] - tanah_kini[i]), 2)}
            for s, i in pakai]
    if not pakai:
        return None, info, len(stasiun)
    a, _, c, _, e, f = g['meta']['transform']
    row, col = np.nonzero(g['dalam'])
    x, y = c + (col + 0.5) * a, f + (row + 0.5) * e
    jumlah = np.zeros(len(x), 'float64')
    bobot = np.zeros(len(x), 'float64')
    terdekat = np.full(len(x), np.inf)
    for s, i in pakai:
        d = np.hypot(x - s['x'], y - s['y'])
        w = 1.0 / np.maximum(d, g['meta']['res']) ** 2
        jumlah += w * float(s['tmat_m'] - tanah_kini[i])
        bobot += w
        np.minimum(terdekat, d, out=terdekat)
    return (jumlah / bobot * np.exp(-terdekat / p['radius_tmat_m'])).astype('float32'), info, len(stasiun) - len(pakai)


def jalankan(khg_id, sekat, skenario='final', masukan=None, biaya_per_sekat=None, hotspot=(),
             kondisi_awal='model', statistik_tmat='akhir', stasiun=(), varian=None):
    """sekat: list dict {id, kode, status, final, x, y, lon, lat} (x, y pada CRS grid).
    stasiun (kondisi_awal='tmat'): list dict {kode, x, y, lon, lat, tmat_m, tanggal, n_bacaan}."""
    if skenario not in SKENARIO:
        raise ValueError(f"skenario harus salah satu dari: {', '.join(SKENARIO)}.")
    if kondisi_awal not in KONDISI_AWAL:
        raise ValueError(f"kondisi_awal harus salah satu dari: {', '.join(KONDISI_AWAL)}.")
    if statistik_tmat not in STATISTIK_TMAT:
        raise ValueError(f"statistik_tmat harus salah satu dari: {', '.join(STATISTIK_TMAT)}.")
    g = muat(khg_id, varian)
    p = parameter(masukan or {})
    ha = g['meta']['res'] ** 2 / 1e4
    ambang = p['ambang_tmat_m']

    sel = sel_sekat(g, [(s['x'], s['y']) for s in sekat]) if sekat else np.zeros(0, 'int64')
    existing = np.array([s['status'] == 'existing' for s in sekat], bool)
    tambahan = np.array([s['status'] == 'rencana' and (skenario == 'rencana' or s['final']) for s in sekat], bool)
    nomor = np.arange(len(sekat))

    kosong = np.zeros(0, 'int64')
    kanal0, _ = muka_air_kanal(g, p, kosong, kosong)
    kanal1, _ = muka_air_kanal(g, p, sel[existing], nomor[existing])
    pakai = existing | tambahan
    kanal2, kendali2 = muka_air_kanal(g, p, sel[pakai], nomor[pakai])

    koreksi, info_stasiun, stasiun_di_luar = None, [], 0
    if kondisi_awal == 'tmat':
        koreksi, info_stasiun, stasiun_di_luar = koreksi_tmat(g, p, muka_air_tanah(g, p, kanal1), list(stasiun))
        if koreksi is None:
            raise ValueError('Tidak ada stasiun TMAT dengan bacaan di dalam KHG ini; pakai kondisi awal model.')

    def muka_tanah(q, kanal):
        t = muka_air_tanah(g, q, kanal)
        return t if koreksi is None else t + koreksi

    tanah0, tanah1, tanah2 = (muka_tanah(p, k) for k in (kanal0, kanal1, kanal2))

    kering1, kering2 = tanah1 > ambang, tanah2 > ambang
    terbasahi = kering1 & ~kering2
    bakar = g['frek_d'] > 0
    berulang = g['frek_d'] > 1
    luas = len(tanah1) * ha
    n_tambahan = int((tambahan & (sel >= 0)).sum())
    luas_basah = float(terbasahi.sum() * ha)

    # kontribusi tiap sekat tambahan: lahan terbasahi yang kanal terdekatnya dikendalikan sekat itu
    andil = np.bincount(kendali2[g['dekat_d']][terbasahi] + 1, minlength=len(sekat) + 1)[1:] * ha
    urutan = np.argsort(-andil)
    teratas = [{'id': sekat[i]['id'], 'kode': sekat[i]['kode'], 'terbasahi_ha': round(float(andil[i]), 1),
                'lokasi': [round(sekat[i]['lon'], 6), round(sekat[i]['lat'], 6)]}
               for i in urutan[:10] if tambahan[i] and andil[i] > 0]
    tanpa_andil = int((tambahan & (sel >= 0) & (andil == 0)).sum())

    # rentang: efektivitas sekat -/+ 0,2 dan jarak pengaruh x0,5 / x2
    rentang = [luas_basah]
    for de in (-0.2, 0.2):
        q = {**p, 'efektivitas': min(1.0, max(0.1, p['efektivitas'] + de))}
        k1, _ = muka_air_kanal(g, q, sel[existing], nomor[existing])
        k2, _ = muka_air_kanal(g, q, sel[pakai], nomor[pakai])
        for fl in (0.5, 2.0):
            q['jarak_pengaruh_m'] = p['jarak_pengaruh_m'] * fl
            rentang.append(float(((muka_tanah(q, k1) > ambang) & ~(muka_tanah(q, k2) > ambang)).sum() * ha))

    titik = sel_lahan(g, [(h['x'], h['y']) for h in hotspot]) if hotspot else np.zeros(0, 'int64')
    panas = [{'type': 'Feature', 'geometry': {'type': 'Point', 'coordinates': [h['lon'], h['lat']]},
              'properties': {'waktu': str(h['waktu'])[:10],
                             'kering_sebelum': bool(kering1[i]), 'kering_sesudah': bool(kering2[i])}}
             for h, i in zip(hotspot, titik.tolist()) if i >= 0]

    sel_m = g['meta']['res'] / 1000
    alur = []
    for r in g['alur']:
        m = r['sel'][1]
        alur.append({'type': 'Feature', 'geometry': {'type': 'LineString', 'coordinates': r['xy']},
                     'properties': {'id': r['id'], 'kode': r['kode'], 'jenis': r['jenis'], 'turun_m': r['turun_m'],
                                    'tahan_sebelum': bool(kanal0[m] - kanal1[m] > 0.05),
                                    'tahan_sesudah': bool(kanal0[m] - kanal2[m] > 0.05),
                                    'naik_m': round(float(kanal1[m] - kanal2[m]), 2)}})

    def ringkas(kering, tanah, kanal):
        return {
            'kering_ha': round(float(kering.sum() * ha)), 'kering_persen': round(100 * float(kering.mean()), 1),
            'muka_air_rata_m': round(float(tanah.mean()), 2),
            'bekas_terbakar_kering_ha': round(float((kering & bakar).sum() * ha)),
            'terbakar_berulang_kering_ha': round(float((kering & berulang).sum() * ha)),
            'kanal_tertahan_km': round(float((kanal0 - kanal > 0.05).sum() * sel_m), 1),
        }

    return {
        'khg_id': khg_id, 'nama': g['meta']['nama'], 'varian': g['meta'].get('varian'), 'skenario': skenario, 'parameter': p,
        'grid': {k: g['meta'].get(k) for k in ('res', 'dem', 'halus_m', 'dibuat')},
        'kondisi_awal': {
            'sumber': kondisi_awal,
            'statistik': statistik_tmat if kondisi_awal == 'tmat' else None,
            'stasiun': info_stasiun,
            'stasiun_di_luar': stasiun_di_luar,
            'koreksi_rata_m': round(float(koreksi.mean()), 3) if koreksi is not None else None,
        },
        'luas_ha': round(luas), 'kanal_km': round(len(g['zc']) * sel_m, 1),
        'bekas_terbakar_ha': round(float(bakar.sum() * ha)),
        'tanpa_sekat': ringkas(tanah0 > ambang, tanah0, kanal0),
        'sebelum': {**ringkas(kering1, tanah1, kanal1), 'sekat': int((existing & (sel >= 0)).sum())},
        'sesudah': {**ringkas(kering2, tanah2, kanal2), 'sekat': int((pakai & (sel >= 0)).sum())},
        'hotspot': {
            'jumlah': len(panas),
            'kering_sebelum': sum(h['properties']['kering_sebelum'] for h in panas),
            'kering_sesudah': sum(h['properties']['kering_sesudah'] for h in panas),
            'titik': {'type': 'FeatureCollection', 'features': panas},
        },
        'dampak': {
            'sekat_tambahan': n_tambahan,
            'sekat_di_luar_kanal': int((pakai & (sel < 0)).sum()),
            'terbasahi_ha': round(luas_basah),
            'terbasahi_rentang_ha': [round(min(rentang)), round(max(rentang))],
            'bekas_terbakar_terbasahi_ha': round(float((terbasahi & bakar).sum() * ha)),
            'terbakar_berulang_terbasahi_ha': round(float((terbasahi & berulang).sum() * ha)),
            'kenaikan_rata_m': round(float((tanah1 - tanah2).mean()), 3),
            'ha_per_sekat': round(luas_basah / n_tambahan, 2) if n_tambahan else None,
            'biaya_total': biaya_per_sekat * n_tambahan if biaya_per_sekat else None,
            'biaya_per_ha': round(biaya_per_sekat * n_tambahan / luas_basah) if biaya_per_sekat and luas_basah else None,
            'sekat_tanpa_andil': tanpa_andil,
            'sekat_teratas': teratas,
        },
        'peta': {
            'sudut': g['meta']['sudut'],
            'sebelum': gambar(g, tanah1, BATAS_DALAM, WARNA_DALAM),
            'sesudah': gambar(g, tanah2, BATAS_DALAM, WARNA_DALAM),
            'kenaikan': gambar(g, tanah1 - tanah2, BATAS_NAIK, WARNA_NAIK, kosongkan_di_bawah=BATAS_NAIK[0]),
            'elevasi': g['elevasi']['gambar'],
            'elevasi_rentang_m': [g['elevasi']['min_m'], g['elevasi']['maks_m']],
            'medan': ({**g['meta']['medan'], 'ubin': f"/simulasi-data/{g['stem']}/medan/{{z}}/{{x}}/{{y}}.png"}
                      if g['meta'].get('medan') else None),
            'legenda': {'kedalaman': {'batas': BATAS_DALAM, 'warna': WARNA_DALAM},
                        'kenaikan': {'batas': BATAS_NAIK, 'warna': WARNA_NAIK},
                        'elevasi': g['elevasi']['legenda']},
        },
        'alur': {'type': 'FeatureCollection', 'features': alur},
    }


if __name__ == '__main__':   # cek cepat: python3 api/simulasi_model.py
    x = np.concatenate([np.random.default_rng(0).normal(0.4, 0.4, 100000), BATAS_DALAM]).astype('float32')
    assert np.array_equal(digitize1(x, BATAS_DALAM), (np.digitize(x, BATAS_DALAM) + 1).astype('uint8'))
    print('ok')
