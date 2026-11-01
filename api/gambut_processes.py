"""OGC API - Processes untuk Pembasahan Gambut (plugin pygeoapi).

Proses baca (publik): ringkasan-dashboard, validasi-khg, saran-lokasi-pompa, riwayat-khg, status-sinkron,
                      simulasi-pembasahan
Proses tulis (wajib login di proxy): ajukan-review, putuskan-review, refresh-statistik
"""
import json
import os
import time
from functools import cache, lru_cache

from sqlalchemy import create_engine, text

from pygeoapi.process.base import BaseProcessor, ProcessorExecuteError


@cache
def engine(role):
    pw = os.environ['PW_OGC_WRITER' if role == 'ogc_writer' else 'PW_OGC_READER']
    return create_engine(
        f"postgresql+psycopg2://{role}:{pw}@{os.environ['PG_HOST']}:{os.environ.get('PG_PORT', '5432')}"
        f"/{os.environ['PG_DB']}", pool_pre_ping=True, pool_size=5)


def query(sql, params, role='ogc_reader', write=False):
    """sql boleh berupa list statement; hasil diambil dari statement terakhir (1 transaksi)."""
    stmts = sql if isinstance(sql, list) else [sql]
    with engine(role).begin() if write else engine(role).connect() as con:
        for s in stmts[:-1]:
            con.execute(text(s), params)
        return [dict(r._mapping) for r in con.execute(text(stmts[-1]), params)]


def meta(pid, title, desc, inputs, output, example):
    return {
        'version': '1.0.0', 'id': pid, 'title': {'id': title, 'en': title},
        'description': {'id': desc, 'en': desc},
        'jobControlOptions': ['sync-execute'], 'keywords': ['gambut', 'KHG'],
        'inputs': {k: {'title': k, 'description': d, 'schema': s, 'minOccurs': 1 if req else 0,
                       'maxOccurs': 1} for k, (d, s, req) in inputs.items()},
        'outputs': {'hasil': {'title': 'hasil', 'description': output,
                              'schema': {'type': 'object', 'contentMediaType': 'application/json'}}},
        'example': {'inputs': example}, 'links': [],
    }


INT = {'type': 'integer'}
NUM = {'type': 'number'}


def khg_id(data):
    if data.get('khg_id') is None:
        raise ProcessorExecuteError('khg_id wajib diisi')
    return int(data['khg_id'])


def _status(rows):
    if not rows:
        raise ProcessorExecuteError('KHG tidak ditemukan')
    return json.loads(json.dumps(rows[0], default=str))


class _Base(BaseProcessor):
    META = None

    def __init__(self, processor_def):
        super().__init__(processor_def, self.META)

    def execute(self, data, outputs=None):
        return 'application/json', {'id': 'hasil', 'value': self.run(data)}


class RingkasanDashboard(_Base):
    META = meta('ringkasan-dashboard', 'Ringkasan Dashboard Nasional',
                'KPI kartu Dashboard Nasional dan distribusi status alur kerja KHG.',
                {}, 'Satu objek KPI', {})

    def run(self, data):
        global _dashboard
        if time.monotonic() - _dashboard[0] > 30:   # KPI nasional: cukup segar 30 dtk, query penuhnya ratusan ms
            _dashboard = (time.monotonic(), _status(query('SELECT * FROM alur.v_dashboard', {})))
        return _dashboard[1]


_dashboard = (float('-inf'), None)


class ValidasiKHG(_Base):
    META = meta('validasi-khg', 'Validasi otomatis KHG',
                'Menjalankan aturan validasi (pompa dekat sumber air, di luar konsesi, kanal berstatus, '
                'kapasitas pompa, geometri valid) pada versi terakhir KHG.',
                {'khg_id': ('ID KHG (lihat koleksi khg)', INT, True),
                 'maks_jarak_air_m': ('Jarak maksimum pompa ke sumber air (m), default 500', NUM, False)},
                'Daftar hasil cek', {'khg_id': 1})

    def run(self, data):
        return query("""SELECT v.cek, v.tingkat, v.lolos, v.pesan
                          FROM alur.v_khg_status s, alur.validasi_khg(s.versi_id, :jarak) v
                         WHERE s.khg_id = :khg""",
                     {'khg': khg_id(data), 'jarak': data.get('maks_jarak_air_m', 500)})


class SaranLokasiPompa(_Base):
    META = meta('saran-lokasi-pompa', 'Saran lokasi pompa',
                'Kandidat lokasi pompa di sepanjang kanal aktif, disaring jarak ke sungai, tebal gambut, '
                'dan buffer konsesi; diberi skor kesesuaian 0-1.',
                {'khg_id': ('ID KHG', INT, True),
                 'maks_jarak_m': ('Maks. jarak ke sumber air (m), default 500', NUM, False),
                 'min_tebal_m': ('Min. tebal gambut (m), default 3', NUM, False),
                 'buffer_konsesi_m': ('Buffer konsesi (m), default 100', NUM, False),
                 'jumlah': ('Jumlah saran, default 3', INT, False)},
                'GeoJSON FeatureCollection kandidat', {'khg_id': 1, 'maks_jarak_m': 500})

    def run(self, data):
        rows = query("""SELECT peringkat, skor, skor_sumber_air, skor_kanal, skor_gambut, skor_terbakar,
                               jarak_sungai_m, sungai_id, kanal_id, tebal_gambut_m, jarak_konsesi_m,
                               ST_AsGeoJSON(geom)::json AS geometry
                          FROM peta.saran_lokasi_pompa(:khg, :jarak, :tebal, :buffer, 100, :n)""",
                     {'khg': khg_id(data), 'jarak': data.get('maks_jarak_m', 500),
                      'tebal': data.get('min_tebal_m', 3), 'buffer': data.get('buffer_konsesi_m', 100),
                      'n': data.get('jumlah', 3)})
        feats = [{'type': 'Feature', 'geometry': r.pop('geometry'),
                  'properties': {k: float(v) if v is not None and k != 'peringkat' else v
                                 for k, v in r.items()}} for r in rows]
        return {'type': 'FeatureCollection', 'features': feats}


class AjukanReview(_Base):
    META = meta('ajukan-review', 'Ajukan KHG ke review',
                'Mengubah versi draft/revisi KHG menjadi review dan menyimpan snapshot validasi. Wajib login.',
                {'khg_id': ('ID KHG', INT, True)}, 'Status versi', {'khg_id': 1})

    def run(self, data):
        return _status(query(["SELECT alur.ajukan_review(versi_id) FROM alur.v_khg_status WHERE khg_id = :khg",
                              "SELECT * FROM alur.v_khg_status WHERE khg_id = :khg"],
                             {'khg': khg_id(data)}, role='ogc_writer', write=True))


class PutuskanReview(_Base):
    META = meta('putuskan-review', 'Putuskan review KHG',
                'Reviewer menyetujui (approved) atau meminta revisi (revisi) versi yang sedang direview. Wajib login.',
                {'khg_id': ('ID KHG', INT, True),
                 'keputusan': ("'approved' atau 'revisi'", {'type': 'string', 'enum': ['approved', 'revisi']}, True),
                 'catatan': ('Catatan reviewer', {'type': 'string'}, False)},
                'Status versi', {'khg_id': 1, 'keputusan': 'approved', 'catatan': 'Lokasi sesuai.'})

    def run(self, data):
        return _status(query(["SELECT alur.putuskan(versi_id, :k, :c) FROM alur.v_khg_status WHERE khg_id = :khg",
                              "SELECT * FROM alur.v_khg_status WHERE khg_id = :khg"],
                             {'khg': khg_id(data), 'k': data.get('keputusan'), 'c': data.get('catatan')},
                             role='ogc_writer', write=True))


class RefreshStatistik(_Base):
    META = meta('refresh-statistik', 'Refresh statistik KHG',
                'Menghitung ulang api.khg_statistik (hotspot 30 hari, km kanal, jumlah sekat). Wajib login.',
                {}, 'Waktu refresh', {})

    def run(self, data):
        return _status(query("SELECT api.refresh_statistik() AS waktu", {}, role='ogc_writer', write=True))


class RiwayatKHG(_Base):
    META = meta('riwayat-khg', 'Riwayat perubahan KHG',
                'Perubahan terbaru pada fitur KHG (sekat, kanal, pompa, pintu air, ...): waktu, aksi, '
                'jalur (qgis/api/web), pengguna, dan nama kolom yang berubah. Tanpa isi baris.',
                {'khg_id': ('ID KHG', INT, True),
                 'jumlah': ('Jumlah baris, default 50, maks 200', INT, False)},
                'Daftar perubahan, terbaru dulu', {'khg_id': 1, 'jumlah': 20})

    def run(self, data):
        rows = query("""SELECT id, waktu, tabel, fitur_id, aksi, via, pengguna, kode, kolom_berubah
                          FROM alur.v_riwayat WHERE khg_id = :khg ORDER BY waktu DESC, id DESC LIMIT :n""",
                     {'khg': khg_id(data), 'n': max(1, min(int(data.get('jumlah', 50)), 200))})
        return json.loads(json.dumps(rows, default=str))


class StatusSinkron(_Base):
    META = meta('status-sinkron', 'Status sinkron editor',
                'Jumlah editor (role anggota gambut_edit selain akun layanan) yang sedang tersambung ke '
                'PostGIS, dan waktu perubahan terakhir (opsional per KHG).',
                {'khg_id': ('ID KHG (opsional)', INT, False)},
                'Status sinkron', {'khg_id': 1})

    def run(self, data):
        return _status(query("""
            WITH editor AS (
              SELECT DISTINCT a.usename::text AS nama FROM pg_stat_activity a
               WHERE a.datname = current_database()
                 AND a.usename::text NOT IN ('ogc_writer', 'web_app')
                 AND pg_has_role(a.usename, 'gambut_edit', 'MEMBER'))
            SELECT (SELECT count(*) FROM editor) AS editor_aktif,
                   (SELECT coalesce(array_agg(nama ORDER BY nama), '{}') FROM editor) AS editor,
                   (SELECT max(waktu) FROM alur.v_riwayat
                     WHERE CAST(:khg AS int) IS NULL OR khg_id = CAST(:khg AS int)) AS terakhir_diubah""",
                             {'khg': int(data['khg_id']) if data.get('khg_id') is not None else None}))


class SimulasiPembasahan(_Base):
    META = meta('simulasi-pembasahan', 'Simulasi pembasahan',
                'Perkiraan cepat (indikatif) muka air tanah sebelum/sesudah sekat dibangun untuk satu KHG: '
                'luas terbasahi, bekas terbakar yang terbasahi, efisiensi sekat, peta, dan arah aliran kanal. '
                'Tanpa khg_id: daftar KHG yang sudah disiapkan beserta parameter bawaan.',
                {'khg_id': ('ID KHG', INT, False),
                 'varian': ('Kode varian DEM (ref.varian_dem); bawaan = varian utama', {'type': 'string'}, False),
                 'skenario': ('final = existing + sekat final; rencana = existing + semua rencana',
                              {'type': 'string', 'enum': ['final', 'rencana']}, False),
                 'parameter': ('Parameter model (lihat keluaran tanpa khg_id)', {'type': 'object'}, False),
                 'biaya_per_sekat': ('Biaya per sekat (Rp) untuk hitungan efisiensi', NUM, False),
                 'kondisi_awal': ('model = muka air alami seragam; tmat = dikoreksi bacaan stasiun TMAT',
                                  {'type': 'string', 'enum': ['model', 'tmat']}, False),
                 'statistik_tmat': ('Bacaan TMAT yang dipakai: akhir, rata, atau maks (terdalam)',
                                    {'type': 'string', 'enum': ['akhir', 'rata', 'maks']}, False)},
                'Ringkasan, peta (PNG), dan alur kanal (GeoJSON)', {'khg_id': 522, 'skenario': 'rencana'})

    def run(self, data):
        import simulasi_model as model
        if data.get('khg_id') is None:
            khg = model.daftar()
            varian = {(r['khg_id'], r['kode']): r for r in query(
                "SELECT khg_id, kode, label, utama, urutan FROM ref.varian_dem WHERE khg_id = ANY(:khg)",
                {'khg': [k['khg_id'] for k in khg]})}
            for k in khg:
                v = varian.get((k['khg_id'], k['varian']))
                k.update(varian_label=v['label'] if v else None, utama=bool(v['utama']) if v else True,
                         urutan=v['urutan'] if v else 0)
            khg.sort(key=lambda k: (k['nama'], k['urutan']))
            jumlah = {r['khg_id']: r['n'] for r in query("""
                SELECT l.khg_id, count(*) AS n FROM peta.logger_tmat l
                 WHERE l.khg_id = ANY(:khg) AND EXISTS (SELECT 1 FROM peta.tmat_bacaan b WHERE b.logger_id = l.id)
                 GROUP BY 1""", {'khg': [k['khg_id'] for k in khg]})}
            return {'khg': [{**k, 'stasiun_tmat': jumlah.get(k['khg_id'], 0)} for k in khg],
                    'skenario': model.SKENARIO, 'kondisi_awal': model.KONDISI_AWAL,
                    'statistik_tmat': model.STATISTIK_TMAT,
                    'parameter': {k: {'bawaan': v[0], 'min': v[1], 'maks': v[2], 'keterangan': v[3]}
                                  for k, v in model.PARAM.items()}}
        kid = khg_id(data)
        biaya = data.get('biaya_per_sekat')
        if biaya is not None and (not isinstance(biaya, (int, float)) or isinstance(biaya, bool) or biaya < 0):
            raise ProcessorExecuteError('biaya_per_sekat tidak valid')
        varian = data.get('varian')
        if varian is not None and (not isinstance(varian, str) or not varian.isalnum()):
            raise ProcessorExecuteError('varian tidak valid')
        try:
            grid = model.muat(kid, varian)
            varian = grid['meta'].get('varian')
            # sekat varian DEM (sumber IMPOR_KHG:<kode>): hanya varian grid ini; tanpa varian: varian utama
            sekat = query("""
                SELECT id, kode, status, dipilih_bangun AS final,
                       ST_X(ST_Transform(geom, :epsg)) AS x, ST_Y(ST_Transform(geom, :epsg)) AS y,
                       ST_X(geom) AS lon, ST_Y(geom) AS lat
                  FROM peta.sekat WHERE khg_id = :khg AND status IN ('existing', 'rencana')
                   AND CASE WHEN CAST(:varian AS text) IS NULL THEN ref.varian_utama(khg_id, sumber)
                            ELSE left(coalesce(sumber, ''), 10) <> 'IMPOR_KHG:'
                                 OR sumber = 'IMPOR_KHG:' || CAST(:varian AS text) END""",
                          {'khg': kid, 'epsg': grid['meta']['epsg'], 'varian': varian})
            hotspot = query("""
                SELECT waktu, ST_X(ST_Transform(geom, :epsg)) AS x, ST_Y(ST_Transform(geom, :epsg)) AS y,
                       ST_X(geom) AS lon, ST_Y(geom) AS lat
                  FROM peta.hotspot WHERE khg_id = :khg
                   AND waktu >= date_trunc('year', (SELECT max(waktu) FROM peta.hotspot))""",
                            {'khg': kid, 'epsg': grid['meta']['epsg']})
            kondisi = data.get('kondisi_awal') or 'model'
            statistik = data.get('statistik_tmat') or 'akhir'
            stasiun = []
            if kondisi == 'tmat' and statistik in model.STATISTIK_TMAT:
                stasiun = query("""
                    SELECT l.kode, ST_X(ST_Transform(l.geom, :epsg)) AS x, ST_Y(ST_Transform(l.geom, :epsg)) AS y,
                           ST_X(l.geom) AS lon, ST_Y(l.geom) AS lat, b.n_bacaan,
                           CASE :stat WHEN 'rata' THEN b.rata WHEN 'maks' THEN b.maks ELSE b.akhir END AS tmat_m,
                           CASE :stat WHEN 'akhir' THEN b.tgl_akhir::text WHEN 'maks' THEN b.tgl_maks::text
                                ELSE b.tgl_awal || ' s/d ' || b.tgl_akhir END AS tanggal
                      FROM peta.logger_tmat l
                      JOIN LATERAL (
                        SELECT count(*) AS n_bacaan, avg(tmat_m)::float8 AS rata, max(tmat_m)::float8 AS maks,
                               (array_agg(tmat_m::float8 ORDER BY waktu DESC))[1] AS akhir,
                               (array_agg((waktu AT TIME ZONE 'Asia/Jakarta')::date ORDER BY tmat_m DESC, waktu DESC))[1] AS tgl_maks,
                               min((waktu AT TIME ZONE 'Asia/Jakarta')::date) AS tgl_awal,
                               max((waktu AT TIME ZONE 'Asia/Jakarta')::date) AS tgl_akhir
                          FROM peta.tmat_bacaan t WHERE t.logger_id = l.id) b ON b.n_bacaan > 0
                     WHERE l.khg_id = :khg""", {'khg': kid, 'epsg': grid['meta']['epsg'], 'stat': statistik})
            # kunci = semua masukan model + waktu grid disiapkan: edit sekat / grid baru otomatis jadi kunci baru
            return _simulasi(json.dumps([[kid, sekat, data.get('skenario') or 'final', data.get('parameter') or {},
                                          biaya, hotspot, kondisi, statistik, stasiun, varian],
                                         grid['meta'].get('dibuat')], default=str))
        except ValueError as err:
            raise ProcessorExecuteError(str(err)) from err


@lru_cache(maxsize=6)   # ponytail: cache per worker (±10 MB per hasil); simulasi sama diulang = instan
def _simulasi(kunci):
    import simulasi_model as model
    return model.jalankan(*json.loads(kunci)[0])
