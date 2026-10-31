-- Impor lapisan satu KHG dari schema impor (diisi scripts/impor_khg.sh) ke peta.* / analisis.*.
-- Variabel psql: khg (id ref.khg), sumber (label impor). Data lain di KHG tidak disentuh: baris dengan
-- sumber yang sama di KHG ini dihapus dulu, jadi impor ulang folder yang sama aman.
-- Tabel impor.* yang tidak ada (berkasnya tidak ditemukan) dilewati.
\set ON_ERROR_STOP on

SELECT nama AS khg_nama,
       -- UTM zona KHG, untuk hitungan panjang/jarak dalam meter
       CASE WHEN ST_Y(ST_Centroid(geom)) < 0 THEN 32700 ELSE 32600 END
         + floor((ST_X(ST_Centroid(geom)) + 180) / 6)::int + 1 AS utm
  FROM ref.khg WHERE id = :khg \gset
\echo == :khg_nama, UTM EPSG :utm, sumber :sumber

SELECT to_regclass('impor.kanal') IS NOT NULL AS ada_kanal,
       to_regclass('impor.jalur_pompa') IS NOT NULL AS ada_jalur,
       to_regclass('impor.pompa') IS NOT NULL AS ada_pompa,
       to_regclass('impor.sekat_existing') IS NOT NULL AS ada_sekat_existing,
       to_regclass('impor.sekat_usulan') IS NOT NULL AS ada_sekat_usulan,
       to_regclass('impor.sungai') IS NOT NULL AS ada_sungai,
       to_regclass('impor.badan_air') IS NOT NULL AS ada_badan_air,
       to_regclass('impor.areal_terbakar') IS NOT NULL AS ada_terbakar,
       to_regclass('impor.hotspot') IS NOT NULL AS ada_hotspot,
       to_regclass('impor.usaha') IS NOT NULL AS ada_usaha,
       to_regclass('impor.unit_prioritas') IS NOT NULL AS ada_unit,
       to_regclass('impor.tma_stasiun') IS NOT NULL AS ada_tma,
       to_regclass('impor.tma_harian') IS NOT NULL AS ada_tma_harian,
       to_regclass('impor.khg') IS NOT NULL AS ada_khg \gset

BEGIN;
-- trigger meta/kode/audit dimatikan: impor bukan suntingan, tidak membuka versi KHG.
-- Ini juga mematikan aksi FK (CASCADE / SET NULL), jadi anak dihapus manual.
SET LOCAL session_replication_role = replica;

-- '', '-', 'None' -> NULL
CREATE OR REPLACE FUNCTION impor.b(text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(nullif(nullif(btrim($1), ''), '-'), 'None') $$;
-- nomor berikutnya untuk kode "<prefix>-n" per KHG (sama dengan trigger alur.isi_kode)
CREATE OR REPLACE FUNCTION impor.nomor(tabel regclass, khg int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  EXECUTE format('SELECT coalesce(max(substring(kode FROM ''\d+$'')::int), 0) FROM %s
                   WHERE khg_id = $1 AND kode ~ ''\d+$''', tabel) INTO n USING khg;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- hapus impor sebelumnya
DELETE FROM peta.tmat_bacaan WHERE logger_id IN (SELECT id FROM peta.logger_tmat WHERE khg_id = :khg AND sumber = :'sumber');
DELETE FROM peta.logger_tmat WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.sekat_bangunan WHERE sekat_id IN (SELECT id FROM peta.sekat WHERE khg_id = :khg AND sumber = :'sumber');
DELETE FROM peta.sekat WHERE khg_id = :khg AND sumber = :'sumber';
UPDATE peta.sekat SET kanal_id = NULL
 WHERE kanal_id IN (SELECT id FROM peta.kanal WHERE khg_id = :khg AND sumber = :'sumber');
DELETE FROM peta.pompa WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.kanal WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.jalur_pompa WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.sungai WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.badan_air WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.areal_terbakar WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.hotspot WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM peta.konsesi WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM analisis.dmpg WHERE khg_id = :khg AND sumber = :'sumber';
DELETE FROM analisis.unit_prioritas WHERE khg_id = :khg AND sumber = :'sumber';

-- ---------------------------------------------------------------- batas KHG (cek saja)
\if :ada_khg
SELECT round((ST_Area(ST_Union(i.geom)::geography) / 1e4)::numeric) AS luas_berkas_ha,
       round((ST_Area(k.geom::geography) / 1e4)::numeric) AS luas_ref_ha,
       round((100 * ST_Area(ST_SymDifference(ST_Union(i.geom), k.geom)::geography)
              / ST_Area(k.geom::geography))::numeric, 1) AS beda_persen
  FROM impor.khg i, ref.khg k WHERE k.id = :khg GROUP BY k.geom;
\endif

-- ---------------------------------------------------------------- kanal
\if :ada_kanal
SELECT impor.nomor('peta.kanal', :khg) AS n \gset
INSERT INTO peta.kanal (kode, jenis_kanal, sumber, id_asal, geom, khg_id, created_by, updated_by, updated_via)
SELECT 'K-' || (:n + row_number() OVER (ORDER BY ogc_fid)),
       CASE lower(impor.b(to_jsonb(i)->>'canal_class'))
         WHEN 'primer' THEN 1 WHEN 'sekunder' THEN 2 WHEN 'tersier' THEN 3
         ELSE (SELECT kode FROM ref.jenis_kanal WHERE label = impor.b(to_jsonb(i)->>'ket_kanal')) END,
       :'sumber', (to_jsonb(i)->>'objectid')::numeric::bigint, ST_Multi(geom), :khg, 'import', 'import', 'import'
  FROM impor.kanal i WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);
\endif

-- ---------------------------------------------------------------- jalur pompa -> kanal terpilih
\if :ada_jalur
INSERT INTO peta.jalur_pompa (kode, panjang_m, angkat_m, debit_m3s, layanan_ha, sumber, atribut, khg_id, geom)
SELECT impor.b(j->>'route_id'), (j->>'length_m')::numeric, (j->>'lift_m')::numeric,
       (j->>'q_required')::numeric, (j->>'a_served_h')::numeric, :'sumber',
       j - 'geom' - 'ogc_fid', :khg, ST_Multi(geom)
  FROM impor.jalur_pompa i, LATERAL (SELECT to_jsonb(i) AS j) x;

-- kanal hasil impor yang separuh panjangnya atau lebih dilalui rute pompa = kanal terpilih
-- (buffer rute dipecah kecil & berindeks; satu union besar tanpa indeks butuh puluhan menit)
CREATE TEMP TABLE rute AS
SELECT ST_Subdivide(ST_Buffer(ST_Transform(geom, :utm), 15), 64) AS g
  FROM peta.jalur_pompa WHERE khg_id = :khg AND sumber = :'sumber';
CREATE INDEX ON rute USING gist (g);
CREATE TEMP TABLE kanal_utm AS
SELECT id, ST_Transform(geom, :utm) AS g FROM peta.kanal WHERE khg_id = :khg AND sumber = :'sumber';
CREATE INDEX ON kanal_utm USING gist (g);
ANALYZE rute; ANALYZE kanal_utm;
UPDATE peta.kanal c SET dipilih_digunakan = true
  FROM (SELECT k.id FROM kanal_utm k JOIN rute r ON ST_Intersects(k.g, r.g)
         GROUP BY k.id, k.g
        HAVING ST_Length(ST_Intersection(k.g, ST_Union(r.g))) >= 0.5 * ST_Length(k.g)) t
 WHERE c.id = t.id;
\endif

-- ---------------------------------------------------------------- pompa
\if :ada_pompa
SELECT impor.nomor('peta.pompa', :khg) AS n \gset
INSERT INTO peta.pompa (kode, status, kapasitas_m3_menit, sumber, atribut, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'P-' || (:n + row_number() OVER (ORDER BY ogc_fid)), 'rencana',
       round((j->>'q_m3s')::numeric * 60, 2), :'sumber', j - 'geom' - 'ogc_fid',
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.pompa i, LATERAL (SELECT to_jsonb(i) AS j) x;
\endif

-- ---------------------------------------------------------------- sekat existing (+ detail bangunan)
\if :ada_sekat_existing
SELECT impor.nomor('peta.sekat', :khg) AS n \gset
CREATE TEMP TABLE sekat_baru AS
SELECT i.*, (SELECT coalesce(max(id), 0) FROM peta.sekat) + row_number() OVER (ORDER BY ogc_fid) AS new_id,
       :n + row_number() OVER (ORDER BY ogc_fid) AS nomor
  FROM impor.sekat_existing i;

INSERT INTO peta.sekat (id, kode, status, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT new_id, 'SK-' || nomor,
       CASE WHEN upper(impor.b(keterangan)) = 'RENCANA' THEN 'rencana' ELSE 'existing' END,
       :'sumber', ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM sekat_baru;
SELECT setval(pg_get_serial_sequence('peta.sekat', 'id'), (SELECT max(id) FROM peta.sekat));

INSERT INTO ref.perusahaan (nama, izin_usaha)
SELECT DISTINCT impor.b(perusahaan), impor.b(perijinan) FROM sekat_baru s
 WHERE impor.b(perusahaan) IS NOT NULL AND impor.b(perusahaan) NOT IN ('NON KONSESI/PERIZINAN', 'NON KONSESI')
   AND NOT EXISTS (SELECT 1 FROM ref.perusahaan p WHERE p.nama = impor.b(s.perusahaan));

INSERT INTO peta.sekat_bangunan
SELECT s.new_id, impor.b(kodefikasi), impor.b(kode_renca), impor.b(khg), impor.b(tipe),
       initcap(impor.b(jenis)), initcap(impor.b(bahan)), nullif(tahun, 0), impor.b(anggaran),
       impor.b(kegiatan), upper(impor.b(pekerjaan)), impor.b(pelaksana), pr.id, impor.b(perijinan),
       impor.b(kode_pt), CASE WHEN impor.b(data) ~ '^\d+$' THEN impor.b(data)::smallint END,
       impor.b(keterangan), impor.b(source), impor.b(sisfo), impor.b(detail)
  FROM sekat_baru s LEFT JOIN ref.perusahaan pr ON pr.nama = impor.b(s.perusahaan);
\endif

-- ---------------------------------------------------------------- sekat usulan = rencana, final (dipilih dibangun)
\if :ada_sekat_usulan
SELECT impor.nomor('peta.sekat', :khg) AS n \gset
INSERT INTO peta.sekat (kode, status, dipilih_bangun, elevasi_kontur_m, sumber, qc_flag, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'SK-' || (:n + row_number() OVER (ORDER BY ogc_fid)), 'rencana', true,
       round((j->>'z_land_m')::numeric, 2), :'sumber',
       nullif(concat_ws(';', impor.b(j->>'sekat_type'), impor.b(j->>'ts_flag')), ''),
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.sekat_usulan i, LATERAL (SELECT to_jsonb(i) AS j) x;
\endif

-- sekat hasil impor -> kanal hasil impor terdekat (<= 30 m)
UPDATE peta.sekat s SET kanal_id = n.kanal_id, jenis_kanal = n.jenis_kanal, panjang_kanal_m = n.panjang_m
  FROM (SELECT x.id, k.id AS kanal_id, k.jenis_kanal, k.panjang_m
          FROM peta.sekat x
         CROSS JOIN LATERAL (
           SELECT id, jenis_kanal, panjang_m FROM peta.kanal k
            WHERE k.khg_id = :khg AND k.sumber = :'sumber' AND k.geom && ST_Expand(x.geom, 0.0005)
              AND ST_DWithin(k.geom::geography, x.geom::geography, 30)
            ORDER BY k.geom <-> x.geom LIMIT 1) k
         WHERE x.khg_id = :khg AND x.sumber = :'sumber') n
 WHERE s.id = n.id;

-- ---------------------------------------------------------------- sungai (garis) & badan air (poligon)
\if :ada_sungai
INSERT INTO peta.sungai (nama, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT coalesce(impor.b(to_jsonb(i)->>'toponim'), impor.b(to_jsonb(i)->>'namobj'), impor.b(to_jsonb(i)->>'nama')),
       :'sumber', ST_Multi(geom), :khg, 'import', 'import', 'import'
  FROM impor.sungai i;
\endif
\if :ada_badan_air
INSERT INTO peta.badan_air (nama, sumber, khg_id, geom)
SELECT coalesce(impor.b(to_jsonb(i)->>'namobj'), impor.b(to_jsonb(i)->>'nama')), :'sumber', :khg,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
  FROM impor.badan_air i;
\endif

-- ---------------------------------------------------------------- areal terbakar: kolom BA_<tahun> terisi = terbakar
\if :ada_terbakar
INSERT INTO peta.areal_terbakar (tahun_terbakar, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT coalesce((SELECT array_agg(substring(e.key FROM 4)::smallint ORDER BY e.key)
                   FROM jsonb_each_text(to_jsonb(i)) e
                  WHERE e.key ~ '^ba_\d{4}$' AND impor.b(e.value) IS NOT NULL), '{}'),
       :'sumber', ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)), :khg, 'import', 'import', 'import'
  FROM impor.areal_terbakar i;
\endif

-- ---------------------------------------------------------------- hotspot (kepercayaan sedang + tinggi)
\if :ada_hotspot
INSERT INTO peta.hotspot (waktu, satelit, instrumen, kepercayaan, kepercayaan_nilai, frp_mw, brightness_k,
                          siang_malam, format_sumber, berkas_sumber, sumber, geom, khg_id,
                          created_by, updated_by, updated_via)
SELECT ((j->>'acq_date')::date + make_interval(hours => (j->>'acq_time')::int / 100,
                                               mins => (j->>'acq_time')::int % 100)) AT TIME ZONE 'UTC',
       impor.b(j->>'satellite'), impor.b(j->>'instrument'), kpc,
       CASE WHEN j->>'confidence' ~ '^\d+$' THEN (j->>'confidence')::smallint END,
       (j->>'frp')::numeric, (j->>'bright_ti4')::numeric, left(impor.b(j->>'daynight'), 1),
       'firms', :'berkas_hotspot', :'sumber', ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.hotspot i,
       LATERAL (SELECT to_jsonb(i) AS j) x,
       -- VIIRS: h/n/l; MODIS: 0-100
       LATERAL (SELECT CASE WHEN lower(j->>'confidence') IN ('h', 'high') THEN 'tinggi'
                            WHEN lower(j->>'confidence') IN ('n', 'nominal') THEN 'sedang'
                            WHEN j->>'confidence' ~ '^\d+$' AND (j->>'confidence')::int >= 80 THEN 'tinggi'
                            WHEN j->>'confidence' ~ '^\d+$' AND (j->>'confidence')::int >= 30 THEN 'sedang'
                       END AS kpc) k
 WHERE kpc IS NOT NULL;
\endif

-- ---------------------------------------------------------------- konsesi & DMPG (dissolve unit analisis usaha)
\if :ada_usaha
INSERT INTO ref.perusahaan (nama, izin_usaha)
SELECT DISTINCT ON (impor.b(perusahaan)) impor.b(perusahaan), impor.b(izin_usaha) FROM impor.usaha u
 WHERE impor.b(perusahaan) IS NOT NULL AND upper(coalesce(impor.b(izin_usaha), '')) <> 'NON KONSESI'
   AND NOT EXISTS (SELECT 1 FROM ref.perusahaan p WHERE p.nama = impor.b(u.perusahaan))
 ORDER BY impor.b(perusahaan);

INSERT INTO peta.konsesi (perusahaan_id, jenis, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT pr.id, x.izin, :'sumber', ST_Multi(ST_CollectionExtract(x.g, 3)), :khg, 'import', 'import', 'import'
  FROM (SELECT impor.b(perusahaan) AS nama, impor.b(izin_usaha) AS izin, ST_Union(ST_MakeValid(geom), 1e-7) AS g
          FROM impor.usaha WHERE upper(coalesce(impor.b(izin_usaha), '')) <> 'NON KONSESI'
         GROUP BY 1, 2) x
  LEFT JOIN ref.perusahaan pr ON pr.nama = x.nama;

INSERT INTO analisis.dmpg (program, luas_ha, sumber, khg_id, geom)
SELECT program, round(luas, 1), :'sumber', :khg, ST_Multi(ST_CollectionExtract(g, 3))
  FROM (SELECT impor.b(prog_dmpg_) AS program, sum(luas_ha)::numeric AS luas,
               ST_Union(ST_MakeValid(geom), 1e-7) AS g
          FROM impor.usaha WHERE impor.b(prog_dmpg_) IS NOT NULL GROUP BY 1) x;
\endif

-- ---------------------------------------------------------------- sub-KHG + skor prioritas
\if :ada_unit
INSERT INTO analisis.unit_prioritas (unit_id, kelas, peringkat, skor_dampak, skor_kelayakan, skor_urgensi,
                                     skor_risiko, pengelola, luas_ha, sumber, atribut, khg_id, geom)
SELECT j->>'unit_id', impor.b(j->>'kelas'), (j->>'peringkat')::numeric::smallint,
       round((j->>'skor_dampak')::numeric, 4), round((j->>'skor_kelayakan')::numeric, 4),
       round((j->>'skor_urgensi')::numeric, 4), round((j->>'skor_risiko')::numeric, 4),
       impor.b(j->>'pengelola'), round((j->>'area_km2')::numeric * 100, 1), :'sumber',
       j - 'geom' - 'ogc_fid', :khg, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
  FROM impor.unit_prioritas i, LATERAL (SELECT to_jsonb(i) AS j) x;
\endif

-- ---------------------------------------------------------------- stasiun TMA + bacaan harian
\if :ada_tma
INSERT INTO peta.logger_tmat (kode, ext_id, nama, sumber, atribut, geom, khg_id, created_by, updated_by, updated_via)
SELECT j->>'stasiun_id', impor.b(j->>'id_asal'), coalesce(impor.b(j->>'kode_pt'), j->>'stasiun_id'), :'sumber',
       -- kolom deret harian (t20260401, ...) tidak disimpan di sini; lihat peta.tmat_bacaan
       (SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(j) e
         WHERE e.key !~ '^t\d{8}$' AND e.key NOT IN ('geom', 'ogc_fid')),
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.tma_stasiun i, LATERAL (SELECT to_jsonb(i) AS j) x
ON CONFLICT (kode) DO NOTHING;

\if :ada_tma_harian
-- tma_cm sumber negatif = di bawah permukaan; tmat_m positif = di bawah permukaan
INSERT INTO peta.tmat_bacaan (logger_id, waktu, tmat_m)
SELECT l.id, (h.tanggal)::timestamp AT TIME ZONE 'Asia/Jakarta', round(-h.tma_cm::numeric / 100, 2)
  FROM impor.tma_harian h JOIN peta.logger_tmat l ON l.kode = h.stasiun_id AND l.sumber = :'sumber'
 WHERE h.tma_cm IS NOT NULL
ON CONFLICT DO NOTHING;
\else
-- tanpa berkas harian: ambil deret kolom t<yyyymmdd> dari tabel stasiun
INSERT INTO peta.tmat_bacaan (logger_id, waktu, tmat_m)
SELECT l.id, to_date(substring(e.key FROM 2), 'YYYYMMDD')::timestamp AT TIME ZONE 'Asia/Jakarta',
       round(-e.value::numeric / 100, 2)
  FROM impor.tma_stasiun i
  JOIN peta.logger_tmat l ON l.kode = i.stasiun_id AND l.sumber = :'sumber'
 CROSS JOIN LATERAL jsonb_each_text(to_jsonb(i)) e
 WHERE e.key ~ '^t\d{8}$' AND e.value IS NOT NULL
ON CONFLICT DO NOTHING;
\endif
\endif

COMMIT;

-- ---------------------------------------------------------------- ringkasan
SELECT 'kanal' AS lapisan, count(*) AS jumlah, count(*) FILTER (WHERE dipilih_digunakan) AS terpilih
  FROM peta.kanal WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'jalur pompa', count(*), NULL FROM peta.jalur_pompa WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'pompa', count(*), NULL FROM peta.pompa WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'sekat', count(*), count(*) FILTER (WHERE dipilih_bangun) FROM peta.sekat WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'sekat tanpa kanal', count(*), NULL FROM peta.sekat WHERE khg_id = :khg AND sumber = :'sumber' AND kanal_id IS NULL
UNION ALL SELECT 'sungai', count(*), NULL FROM peta.sungai WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'badan air', count(*), NULL FROM peta.badan_air WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'areal terbakar', count(*), NULL FROM peta.areal_terbakar WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'hotspot', count(*), count(*) FILTER (WHERE kepercayaan = 'tinggi') FROM peta.hotspot WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'konsesi', count(*), NULL FROM peta.konsesi WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'dmpg', count(*), NULL FROM analisis.dmpg WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'unit prioritas', count(*), NULL FROM analisis.unit_prioritas WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'stasiun TMA', count(*), NULL FROM peta.logger_tmat WHERE khg_id = :khg AND sumber = :'sumber'
UNION ALL SELECT 'bacaan TMA', count(*), NULL FROM peta.tmat_bacaan t JOIN peta.logger_tmat l ON l.id = t.logger_id
           WHERE l.khg_id = :khg AND l.sumber = :'sumber';

SELECT api.refresh_statistik() AS statistik_diperbarui;
DROP SCHEMA impor CASCADE;
