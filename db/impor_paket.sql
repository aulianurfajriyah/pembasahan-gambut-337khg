-- Impor satu unit data KHG dari schema impor (diisi scripts/impor_paket.py) ke peta.* / analisis.*.
-- Variabel psql:
--   khg     id ref.khg
--   sumber  'IMPOR_KHG' (lapisan bersama) atau 'IMPOR_KHG:<kode>' (lapisan satu varian DEM, lihat 11_varian_dem.sql)
--   ganti   on/off: unit bersama saja. Untuk setiap lapisan yang ada di berkas, data lama KHG ini dari sumber
--           lain (kanal OSM, sekat existing BRGM, konsesi, areal terbakar, hotspot nasional) dihapus dan
--           disalin dulu ke schema cadangan.
--   berkas_hotspot  nama berkas hotspot (dicatat di peta.hotspot.berkas_sumber)
-- Unit bersama menghapus semua hasil impor sebelumnya di KHG ini (IMPOR_KHG dan semua IMPOR_KHG:*), jadi harus
-- dijalankan sebelum unit varian. Nama kolom sumber berbeda antarpaket (shapefile memotong nama kolom menjadi
-- 10 huruf); kolom dibaca lewat to_jsonb() dengan beberapa nama alternatif.
\set ON_ERROR_STOP on

SELECT nama AS khg_nama,
       CASE WHEN ST_Y(ST_Centroid(geom)) < 0 THEN 32700 ELSE 32600 END
         + floor((ST_X(ST_Centroid(geom)) + 180) / 6)::int + 1 AS utm,
       :'sumber' = 'IMPOR_KHG' AS bersama
  FROM ref.khg WHERE id = :khg \gset
\echo == :khg_nama, sumber :sumber

SELECT to_regclass('impor.khg') IS NOT NULL AS ada_khg,
       to_regclass('impor.kanal') IS NOT NULL AS ada_kanal,
       to_regclass('impor.kanal_terpilih') IS NOT NULL AS ada_kanal_terpilih,
       to_regclass('impor.jalur_pompa') IS NOT NULL AS ada_jalur,
       to_regclass('impor.rute_kanal_terpilih') IS NOT NULL AS ada_rute_terpilih,
       to_regclass('impor.pompa') IS NOT NULL AS ada_pompa,
       to_regclass('impor.sekat_existing') IS NOT NULL AS ada_sekat_existing,
       to_regclass('impor.sekat_usulan') IS NOT NULL AS ada_sekat_usulan,
       to_regclass('impor.sungai') IS NOT NULL AS ada_sungai,
       to_regclass('impor.badan_air') IS NOT NULL AS ada_badan_air,
       to_regclass('impor.areal_terbakar') IS NOT NULL AS ada_terbakar,
       to_regclass('impor.hotspot') IS NOT NULL AS ada_hotspot,
       to_regclass('impor.usaha') IS NOT NULL AS ada_usaha,
       to_regclass('impor.konsesi') IS NOT NULL AS ada_konsesi,
       to_regclass('impor.dmpg') IS NOT NULL AS ada_dmpg,
       to_regclass('impor.unit_prioritas') IS NOT NULL AS ada_unit,
       to_regclass('impor.tma_stasiun') IS NOT NULL AS ada_tma,
       to_regclass('impor.tma_harian') IS NOT NULL AS ada_tma_harian \gset

BEGIN;
-- trigger meta/kode/audit dimatikan: impor bukan suntingan, tidak membuka versi KHG.
-- Ini juga mematikan aksi FK (CASCADE / SET NULL), jadi anak dihapus manual.
SET LOCAL session_replication_role = replica;

-- '', '-', 'None' -> NULL
CREATE OR REPLACE FUNCTION impor.b(text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(nullif(nullif(nullif(btrim($1), ''), '-'), 'None'), 'NULL') $$;
-- teks -> angka (NULL bila bukan angka)
CREATE OR REPLACE FUNCTION impor.n(text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN btrim($1) ~ '^-?\d+(\.\d+)?([eE][-+]?\d+)?$' THEN btrim($1)::numeric END $$;
-- nilai kolom pertama yang terisi dari beberapa nama alternatif
CREATE OR REPLACE FUNCTION impor.k(j jsonb, VARIADIC nama text[]) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT impor.b(j->>n) FROM unnest(nama) WITH ORDINALITY u(n, i) WHERE impor.b(j->>n) IS NOT NULL ORDER BY i LIMIT 1 $$;
-- kelas kanal teks -> ref.jenis_kanal
CREATE OR REPLACE FUNCTION impor.jenis_kanal(text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN $1 ~* 'primer' THEN 1 WHEN $1 ~* 'sekunder' THEN 2 WHEN $1 ~* 'tersier' THEN 3 END::smallint $$;
-- nomor berikutnya untuk kode "<prefix>-n" per KHG (sama dengan trigger alur.isi_kode)
CREATE OR REPLACE FUNCTION impor.nomor(tabel regclass, khg int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  EXECUTE format('SELECT coalesce(max(substring(kode FROM ''\d+$'')::int), 0) FROM %s
                   WHERE khg_id = $1 AND kode ~ ''\d+$''', tabel) INTO n USING khg;
  RETURN n;
END $$;
-- salin baris yang akan dihapus ke cadangan.<tabel> (dibuat bila belum ada)
CREATE OR REPLACE FUNCTION impor.cadangkan(tabel regclass, syarat text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE t text := 'cadangan.' || split_part(tabel::text, '.', 2); n bigint;
BEGIN
  CREATE SCHEMA IF NOT EXISTS cadangan;
  IF to_regclass(t) IS NULL THEN
    EXECUTE format('CREATE TABLE %s AS SELECT now() AS dicadangkan_at, * FROM %s WITH NO DATA', t, tabel);
  END IF;
  EXECUTE format('INSERT INTO %s SELECT now(), * FROM %s WHERE %s', t, tabel, syarat);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- hapus impor sebelumnya
-- unit bersama: semua hasil impor di KHG ini; unit varian: hanya varian ini
SELECT CASE WHEN :'bersama'::boolean THEN 'IMPOR_KHG%' ELSE :'sumber' END AS pola \gset
DELETE FROM peta.tmat_bacaan WHERE logger_id IN (SELECT id FROM peta.logger_tmat WHERE khg_id = :khg AND sumber LIKE :'pola');
DELETE FROM peta.logger_tmat WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.sekat_bangunan WHERE sekat_id IN (SELECT id FROM peta.sekat WHERE khg_id = :khg AND sumber LIKE :'pola');
DELETE FROM peta.sekat_konteks WHERE sekat_id IN (SELECT id FROM peta.sekat WHERE khg_id = :khg AND sumber LIKE :'pola');
DELETE FROM peta.sekat WHERE khg_id = :khg AND sumber LIKE :'pola';
UPDATE peta.sekat SET kanal_id = NULL
 WHERE kanal_id IN (SELECT id FROM peta.kanal WHERE khg_id = :khg AND sumber LIKE :'pola');
DELETE FROM peta.pompa WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.kanal WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.jalur_pompa WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.sungai WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.badan_air WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.areal_terbakar WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.hotspot WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM peta.konsesi WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM analisis.dmpg WHERE khg_id = :khg AND sumber LIKE :'pola';
DELETE FROM analisis.unit_prioritas WHERE khg_id = :khg AND sumber LIKE :'pola';

-- ---------------------------------------------------------------- ganti data lama (sumber lain) yang sama jenisnya
\if :ganti
\if :ada_kanal
SELECT impor.cadangkan('peta.kanal', format('khg_id = %s AND coalesce(sumber, '''') NOT LIKE ''IMPOR_KHG%%''', :khg)) AS cadangan_kanal;
UPDATE peta.sekat SET kanal_id = NULL
 WHERE kanal_id IN (SELECT id FROM peta.kanal WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%');
UPDATE peta.pompa SET kanal_id = NULL
 WHERE kanal_id IN (SELECT id FROM peta.kanal WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%');
DELETE FROM peta.kanal WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%';
\endif
\if :ada_sekat_existing
CREATE TEMP TABLE sekat_lama AS
SELECT id FROM peta.sekat WHERE khg_id = :khg AND status <> 'rencana' AND sumber NOT LIKE 'IMPOR_KHG%';
SELECT impor.cadangkan('peta.sekat', 'id IN (SELECT id FROM sekat_lama)') AS cadangan_sekat,
       impor.cadangkan('peta.sekat_bangunan', 'sekat_id IN (SELECT id FROM sekat_lama)') AS cadangan_sekat_bangunan,
       impor.cadangkan('peta.sekat_konteks', 'sekat_id IN (SELECT id FROM sekat_lama)') AS cadangan_sekat_konteks;
DELETE FROM peta.sekat_bangunan WHERE sekat_id IN (SELECT id FROM sekat_lama);
DELETE FROM peta.sekat_konteks WHERE sekat_id IN (SELECT id FROM sekat_lama);
DELETE FROM peta.sekat WHERE id IN (SELECT id FROM sekat_lama);
\endif
\if :ada_terbakar
SELECT impor.cadangkan('peta.areal_terbakar', format('khg_id = %s AND coalesce(sumber, '''') NOT LIKE ''IMPOR_KHG%%''', :khg)) AS cadangan_terbakar;
DELETE FROM peta.areal_terbakar WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%';
\endif
\if :ada_hotspot
SELECT impor.cadangkan('peta.hotspot', format('khg_id = %s AND coalesce(sumber, '''') NOT LIKE ''IMPOR_KHG%%''', :khg)) AS cadangan_hotspot;
DELETE FROM peta.hotspot WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%';
\endif
SELECT :'ada_usaha'::boolean OR :'ada_konsesi'::boolean AS ganti_konsesi \gset
\if :ganti_konsesi
SELECT impor.cadangkan('peta.konsesi', format('khg_id = %s AND coalesce(sumber, '''') NOT LIKE ''IMPOR_KHG%%''', :khg)) AS cadangan_konsesi;
DELETE FROM peta.konsesi WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG%';
\endif
\endif

-- ---------------------------------------------------------------- batas KHG (cek saja)
\if :ada_khg
SELECT round((ST_Area(ST_Union(i.geom)::geography) / 1e4)::numeric) AS luas_berkas_ha,
       round((ST_Area(k.geom::geography) / 1e4)::numeric) AS luas_ref_ha,
       round((100 * ST_Area(ST_SymDifference(ST_Union(ST_MakeValid(i.geom)), k.geom)::geography)
              / ST_Area(k.geom::geography))::numeric, 1) AS beda_persen
  FROM impor.khg i, ref.khg k WHERE k.id = :khg GROUP BY k.geom;
\endif

-- ---------------------------------------------------------------- kanal existing (bersama)
\if :ada_kanal
SELECT impor.nomor('peta.kanal', :khg) AS n \gset
INSERT INTO peta.kanal (kode, jenis_kanal, sumber, id_asal, geom, khg_id, created_by, updated_by, updated_via)
SELECT 'K-' || (:n + row_number() OVER (ORDER BY ogc_fid)),
       impor.jenis_kanal(impor.k(j, 'canal_class', 'kls_kanal', 'klas_kanal', 'ket_kanal', 'kelas_asli')),
       :'sumber', impor.n(impor.k(j, 'objectid', 'objectid_1'))::bigint,
       ST_Multi(ST_CollectionExtract(geom, 2)), :khg, 'import', 'import', 'import'
  FROM impor.kanal i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE geom IS NOT NULL AND NOT ST_IsEmpty(ST_CollectionExtract(geom, 2));
\endif

-- ---------------------------------------------------------------- kanal terpilih (varian): baris kanal sendiri
\if :ada_kanal_terpilih
SELECT impor.nomor('peta.kanal', :khg) AS n \gset
INSERT INTO peta.kanal (kode, jenis_kanal, sumber, id_asal, keterangan, dipilih_digunakan, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'K-' || (:n + row_number() OVER (ORDER BY ogc_fid)),
       impor.jenis_kanal(impor.k(j, 'canal_class', 'kls_kanal', 'klas_kanal', 'ket_kanal', 'kelas_asli')),
       :'sumber', impor.n(impor.k(j, 'seg_id'))::bigint,
       nullif(concat_ws('; ', 'segmen ' || impor.k(j, 'seg_id'), 'need_rank ' || impor.k(j, 'need_rank')), ''),
       true, ST_Multi(ST_CollectionExtract(geom, 2)), :khg, 'import', 'import', 'import'
  FROM impor.kanal_terpilih i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE geom IS NOT NULL AND NOT ST_IsEmpty(ST_CollectionExtract(geom, 2));
\endif

-- ---------------------------------------------------------------- jalur pompa
\if :ada_jalur
INSERT INTO peta.jalur_pompa (kode, panjang_m, angkat_m, debit_m3s, layanan_ha, sumber, atribut, khg_id, geom)
SELECT impor.k(j, 'route_id', 'seg_id'), impor.n(impor.k(j, 'length_m')), impor.n(impor.k(j, 'lift_m')),
       impor.n(impor.k(j, 'q_required_m3s', 'q_required')), impor.n(impor.k(j, 'a_served_ha', 'a_served_h')),
       :'sumber', j - 'geom' - 'ogc_fid', :khg, ST_Multi(ST_CollectionExtract(geom, 2))
  FROM impor.jalur_pompa i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE geom IS NOT NULL;

-- tanpa lapisan kanal terpilih: kanal bersama yang separuh panjangnya atau lebih dilalui rute pompa disalin
-- sebagai kanal terpilih varian ini (buffer rute dipecah kecil & berindeks; satu union besar tanpa indeks lambat).
-- Rute acuannya impor.rute_kanal_terpilih bila ada (jalur pompa diganti tanpa mengubah kanal terpilih).
SELECT NOT :'ada_kanal_terpilih'::boolean AND NOT :'bersama'::boolean AS turunkan_terpilih \gset
\if :turunkan_terpilih
\if :ada_rute_terpilih
CREATE TEMP TABLE rute AS
SELECT ST_Subdivide(ST_Buffer(ST_Transform(geom, :utm), 15), 64) AS g FROM impor.rute_kanal_terpilih;
\else
CREATE TEMP TABLE rute AS
SELECT ST_Subdivide(ST_Buffer(ST_Transform(geom, :utm), 15), 64) AS g
  FROM peta.jalur_pompa WHERE khg_id = :khg AND sumber = :'sumber';
\endif
CREATE INDEX ON rute USING gist (g);
CREATE TEMP TABLE kanal_utm AS
SELECT id, ST_Transform(geom, :utm) AS g FROM peta.kanal
 WHERE khg_id = :khg AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%';
CREATE INDEX ON kanal_utm USING gist (g);
ANALYZE rute; ANALYZE kanal_utm;
SELECT impor.nomor('peta.kanal', :khg) AS n \gset
INSERT INTO peta.kanal (kode, jenis_kanal, sumber, id_asal, keterangan, dipilih_digunakan, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'K-' || (:n + row_number() OVER (ORDER BY c.id)), c.jenis_kanal, :'sumber', c.id,
       'dari rute pompa', true, c.geom, :khg, 'import', 'import', 'import'
  FROM peta.kanal c
  JOIN (SELECT k.id FROM kanal_utm k JOIN rute r ON ST_Intersects(k.g, r.g)
         GROUP BY k.id, k.g
        HAVING ST_Length(ST_Intersection(k.g, ST_Union(r.g))) >= 0.5 * ST_Length(k.g)) t ON t.id = c.id;
\endif
\endif

-- ---------------------------------------------------------------- pompa
\if :ada_pompa
SELECT impor.nomor('peta.pompa', :khg) AS n \gset
INSERT INTO peta.pompa (kode, status, kapasitas_m3_menit, sumber, atribut, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'P-' || (:n + row_number() OVER (ORDER BY ogc_fid)), 'rencana',
       round(impor.n(impor.k(j, 'q_m3s')) * 60, 2), :'sumber', j - 'geom' - 'ogc_fid',
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.pompa i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE geom IS NOT NULL;
\endif

-- ---------------------------------------------------------------- sekat existing (+ detail bangunan)
\if :ada_sekat_existing
SELECT impor.nomor('peta.sekat', :khg) AS n \gset
CREATE TEMP TABLE sekat_baru AS
SELECT to_jsonb(i) AS j, ST_GeometryN(i.geom, 1) AS geom,
       (SELECT coalesce(max(id), 0) FROM peta.sekat) + row_number() OVER (ORDER BY ogc_fid) AS new_id,
       :n + row_number() OVER (ORDER BY ogc_fid) AS nomor
  FROM impor.sekat_existing i WHERE i.geom IS NOT NULL;

INSERT INTO peta.sekat (id, kode, status, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT new_id, 'SK-' || nomor,
       CASE WHEN upper(impor.k(j, 'keterangan')) = 'RENCANA' THEN 'rencana' ELSE 'existing' END,
       :'sumber', geom, :khg, 'import', 'import', 'import'
  FROM sekat_baru;
SELECT setval(pg_get_serial_sequence('peta.sekat', 'id'), (SELECT max(id) FROM peta.sekat));

INSERT INTO ref.perusahaan (nama, izin_usaha)
SELECT DISTINCT ON (impor.k(j, 'perusahaan')) impor.k(j, 'perusahaan'), impor.k(j, 'perijinan') FROM sekat_baru s
 WHERE impor.k(j, 'perusahaan') IS NOT NULL AND impor.k(j, 'perusahaan') NOT IN ('NON KONSESI/PERIZINAN', 'NON KONSESI')
   AND NOT EXISTS (SELECT 1 FROM ref.perusahaan p WHERE p.nama = impor.k(s.j, 'perusahaan'))
 ORDER BY impor.k(j, 'perusahaan');

INSERT INTO peta.sekat_bangunan (sekat_id, kodefikasi, kode_rencana, khg_nama_asal, tipe, jenis_bangunan, bahan,
                                 tahun_bangun, anggaran, kegiatan, pekerjaan, pelaksana, perusahaan_id, perijinan,
                                 kode_pt, tahun_data, keterangan, sumber_data, sisfo_id, detail)
SELECT s.new_id, impor.k(j, 'kodefikasi'), impor.k(j, 'kode_renca', 'kode_rencana'), impor.k(j, 'khg'),
       impor.k(j, 'tipe'), initcap(impor.k(j, 'jenis')), initcap(impor.k(j, 'bahan')),
       nullif(impor.n(impor.k(j, 'tahun')), 0)::smallint, impor.k(j, 'anggaran'), impor.k(j, 'kegiatan'),
       upper(impor.k(j, 'pekerjaan')), impor.k(j, 'pelaksana'), pr.id, impor.k(j, 'perijinan'), impor.k(j, 'kode_pt'),
       CASE WHEN impor.k(j, 'data') ~ '^\d+$' THEN impor.k(j, 'data')::smallint END,
       impor.k(j, 'keterangan'), impor.k(j, 'source'), impor.k(j, 'sisfo'), impor.k(j, 'detail')
  FROM sekat_baru s LEFT JOIN ref.perusahaan pr ON pr.nama = impor.k(s.j, 'perusahaan');
\endif

-- ---------------------------------------------------------------- sekat usulan = rencana, final (dipilih dibangun)
\if :ada_sekat_usulan
SELECT impor.nomor('peta.sekat', :khg) AS n \gset
INSERT INTO peta.sekat (kode, status, dipilih_bangun, elevasi_kontur_m, sumber, qc_flag, geom, khg_id,
                        created_by, updated_by, updated_via)
SELECT 'SK-' || (:n + row_number() OVER (ORDER BY ogc_fid)), 'rencana', true,
       round(impor.n(impor.k(j, 'z_land_m')), 2), :'sumber',
       nullif(concat_ws(';', impor.k(j, 'sekat_type'), impor.k(j, 'ts_flag')), ''),
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.sekat_usulan i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE geom IS NOT NULL;
\endif

-- sekat hasil impor -> kanal terdekat (<= 30 m) di KHG ini, bukan salinan kanal varian
UPDATE peta.sekat s SET kanal_id = n.kanal_id, jenis_kanal = n.jenis_kanal, panjang_kanal_m = n.panjang_m
  FROM (SELECT x.id, k.id AS kanal_id, k.jenis_kanal, k.panjang_m
          FROM peta.sekat x
         CROSS JOIN LATERAL (
           SELECT id, jenis_kanal, panjang_m FROM peta.kanal k
            WHERE k.khg_id = :khg AND coalesce(k.sumber, '') NOT LIKE 'IMPOR_KHG:%'
              AND k.geom && ST_Expand(x.geom, 0.0005)
              AND ST_DWithin(k.geom::geography, x.geom::geography, 30)
            ORDER BY k.geom <-> x.geom LIMIT 1) k
         WHERE x.khg_id = :khg AND x.sumber = :'sumber') n
 WHERE s.id = n.id;

-- ---------------------------------------------------------------- sungai (garis) & badan air (poligon)
\if :ada_sungai
INSERT INTO peta.sungai (nama, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT impor.k(j, 'toponim', 'namobj', 'nama', 'nama_unsur'), :'sumber', ST_Multi(ST_CollectionExtract(geom, 2)),
       :khg, 'import', 'import', 'import'
  FROM impor.sungai i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE NOT ST_IsEmpty(ST_CollectionExtract(geom, 2));
\endif
\if :ada_badan_air
INSERT INTO peta.badan_air (nama, sumber, khg_id, geom)
SELECT impor.k(j, 'namobj', 'nama'), :'sumber', :khg, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
  FROM impor.badan_air i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(geom), 3));
\endif

-- ---------------------------------------------------------------- areal terbakar: kolom ba_<tahun> terisi = terbakar
\if :ada_terbakar
INSERT INTO peta.areal_terbakar (tahun_terbakar, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT coalesce((SELECT array_agg(substring(e.key FROM 4)::smallint ORDER BY e.key)
                   FROM jsonb_each_text(to_jsonb(i)) e
                  WHERE e.key ~ '^ba_\d{4}$' AND impor.b(e.value) IS NOT NULL AND e.value NOT IN ('0', '0.0')), '{}'),
       :'sumber', ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)), :khg, 'import', 'import', 'import'
  FROM impor.areal_terbakar i
 WHERE NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(geom), 3));
\endif

-- ---------------------------------------------------------------- hotspot (kepercayaan sedang + tinggi)
-- FIRMS: acq_date/acq_time/confidence; paket web: tanggal/jam_utc/kepercayaan (tanggal bisa "Agustus 2026")
\if :ada_hotspot
INSERT INTO peta.hotspot (waktu, satelit, instrumen, kepercayaan, kepercayaan_nilai, frp_mw, brightness_k,
                          siang_malam, format_sumber, berkas_sumber, sumber, geom, khg_id,
                          created_by, updated_by, updated_via)
SELECT w.waktu, coalesce(impor.k(j, 'satellite'), impor.k(j, 'sumber')), impor.k(j, 'instrument'), kpc,
       CASE WHEN j->>'confidence' ~ '^\d+$' THEN (j->>'confidence')::smallint END,
       impor.n(impor.k(j, 'frp', 'frp_mw')), impor.n(impor.k(j, 'bright_ti4', 'brightness')),
       left(impor.k(j, 'daynight'), 1), CASE WHEN j ? 'acq_date' THEN 'firms' ELSE 'paket' END,
       :'berkas_hotspot', :'sumber', ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.hotspot i,
       LATERAL (SELECT to_jsonb(i) AS j) x,
       LATERAL (SELECT coalesce(impor.k(j, 'acq_date', 'tanggal'), '') AS tgl,
                       lpad(regexp_replace(coalesce(impor.k(j, 'acq_time', 'jam_utc'), '0'), '\D', '', 'g'), 4, '0') AS jam) t,
       LATERAL (SELECT CASE
                  WHEN t.tgl ~ '^\d{4}-\d{2}-\d{2}' THEN
                    (left(t.tgl, 10)::date + make_interval(hours => left(t.jam, 2)::int, mins => right(t.jam, 2)::int))
                      AT TIME ZONE 'UTC'
                  ELSE make_date(coalesce(impor.n(impor.k(j, 'tahun'))::int, substring(t.tgl FROM '\d{4}')::int),
                                 coalesce(array_position(ARRAY['januari','februari','maret','april','mei','juni','juli',
                                   'agustus','september','oktober','november','desember'],
                                   lower(substring(t.tgl FROM '^[A-Za-z]+'))), 1), 1)::timestamptz
                END AS waktu) w,
       -- VIIRS: h/n/l; MODIS: 0-100; paket web: sedang/tinggi
       LATERAL (SELECT CASE WHEN lower(coalesce(j->>'kepercayaan', j->>'confidence')) IN ('h', 'high', 'tinggi') THEN 'tinggi'
                            WHEN lower(coalesce(j->>'kepercayaan', j->>'confidence')) IN ('n', 'nominal', 'sedang') THEN 'sedang'
                            WHEN j->>'confidence' ~ '^\d+$' AND (j->>'confidence')::int >= 80 THEN 'tinggi'
                            WHEN j->>'confidence' ~ '^\d+$' AND (j->>'confidence')::int >= 30 THEN 'sedang'
                       END AS kpc) k
 WHERE kpc IS NOT NULL AND w.waktu IS NOT NULL;
\endif

-- ---------------------------------------------------------------- konsesi & DMPG
-- unit analisis usaha (kolom perusahaan, izin_usaha, prog_dmpg_): di-dissolve
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
           AND impor.b(perusahaan) IS NOT NULL
         GROUP BY 1, 2) x
  LEFT JOIN ref.perusahaan pr ON pr.nama = x.nama;

\if :ada_dmpg
\else
INSERT INTO analisis.dmpg (program, luas_ha, sumber, khg_id, geom)
SELECT program, round((ST_Area(g::geography) / 1e4)::numeric, 1), :'sumber', :khg, ST_Multi(ST_CollectionExtract(g, 3))
  FROM (SELECT impor.b(prog_dmpg_) AS program, ST_Union(ST_MakeValid(geom), 1e-7) AS g
          FROM impor.usaha WHERE impor.b(prog_dmpg_) IS NOT NULL GROUP BY 1) x;
\endif
\endif

-- konsesi siap pakai (paket web: izin_usaha, satu poligon per izin)
\if :ada_konsesi
INSERT INTO ref.perusahaan (nama, izin_usaha)
SELECT DISTINCT ON (impor.k(j, 'perusahaan')) impor.k(j, 'perusahaan'), impor.k(j, 'izin_usaha')
  FROM impor.konsesi i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE impor.k(j, 'perusahaan') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM ref.perusahaan p WHERE p.nama = impor.k(j, 'perusahaan'))
 ORDER BY impor.k(j, 'perusahaan');
INSERT INTO peta.konsesi (perusahaan_id, jenis, sumber, geom, khg_id, created_by, updated_by, updated_via)
SELECT pr.id, impor.k(j, 'izin_usaha', 'keg_usaha'), :'sumber', ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)),
       :khg, 'import', 'import', 'import'
  FROM impor.konsesi i, LATERAL (SELECT to_jsonb(i) AS j) x
  LEFT JOIN ref.perusahaan pr ON pr.nama = impor.k(j, 'perusahaan')
 WHERE NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(geom), 3));
\endif

-- zona program DMPG (paket web: prog_dmpg_ + luas_ha, atau unit analisis yang di-dissolve per program)
\if :ada_dmpg
INSERT INTO analisis.dmpg (program, luas_ha, sumber, khg_id, geom)
SELECT program, round((ST_Area(g::geography) / 1e4)::numeric, 1), :'sumber', :khg, ST_Multi(ST_CollectionExtract(g, 3))
  FROM (SELECT impor.k(j, 'prog_dmpg_', 'prog_dmpg_2025', 'prog_dmpg') AS program, ST_Union(ST_MakeValid(geom), 1e-7) AS g
          FROM impor.dmpg i, LATERAL (SELECT to_jsonb(i) AS j) x
         WHERE impor.k(j, 'prog_dmpg_', 'prog_dmpg_2025', 'prog_dmpg') IS NOT NULL GROUP BY 1) y;
\endif

-- ---------------------------------------------------------------- sub-KHG + skor prioritas
-- kolom shapefile terpotong 10 huruf (skor_dampa, skor_kelay, ...); subkhg_selected pump hanya punya priority_rank
\if :ada_unit
INSERT INTO analisis.unit_prioritas (unit_id, kelas, peringkat, skor_dampak, skor_kelayakan, skor_urgensi,
                                     skor_risiko, pengelola, luas_ha, sumber, atribut, khg_id, geom)
SELECT coalesce(impor.k(j, 'unit_id', 'subkhg_id', 'sub_khg'), 'U' || ogc_fid), impor.k(j, 'kelas'),
       impor.n(impor.k(j, 'peringkat', 'priority_rank', 'priority_r'))::smallint,
       round(impor.n(impor.k(j, 'skor_dampak', 'skor_dampa')), 4),
       round(impor.n(impor.k(j, 'skor_kelayakan', 'skor_kelay')), 4),
       round(impor.n(impor.k(j, 'skor_urgensi', 'skor_urgen')), 4),
       round(impor.n(impor.k(j, 'skor_risiko', 'skor_risik')), 4),
       impor.k(j, 'pengelola'),
       round(coalesce(impor.n(impor.k(j, 'area_km2')) * 100, impor.n(impor.k(j, 'luas_ha')),
                      (ST_Area(geom::geography) / 1e4)::numeric), 1),
       :'sumber', j - 'geom' - 'ogc_fid', :khg, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
  FROM impor.unit_prioritas i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(geom), 3));
\endif

-- ---------------------------------------------------------------- stasiun TMA + bacaan harian
\if :ada_tma
INSERT INTO peta.logger_tmat (kode, ext_id, nama, sumber, atribut, geom, khg_id, created_by, updated_by, updated_via)
SELECT impor.k(j, 'stasiun_id', 'station_id'), impor.k(j, 'id_asal'),
       coalesce(impor.k(j, 'kode_pt', 'name'), impor.k(j, 'stasiun_id', 'station_id')), :'sumber',
       -- kolom deret harian (t20260401, ...) tidak disimpan di sini; lihat peta.tmat_bacaan
       (SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(j) e
         WHERE e.key !~ '^t\d{8}$' AND e.key NOT IN ('geom', 'ogc_fid')),
       ST_GeometryN(geom, 1), :khg, 'import', 'import', 'import'
  FROM impor.tma_stasiun i, LATERAL (SELECT to_jsonb(i) AS j) x
 WHERE impor.k(j, 'stasiun_id', 'station_id') IS NOT NULL
ON CONFLICT DO NOTHING;

\if :ada_tma_harian
-- tma (cm) negatif = di bawah permukaan; tmat_m positif = di bawah permukaan
INSERT INTO peta.tmat_bacaan (logger_id, waktu, tmat_m)
SELECT l.id, (left(impor.k(j, 'tanggal', 'date'), 10))::date::timestamp AT TIME ZONE 'Asia/Jakarta',
       round(-impor.n(impor.k(j, 'tma_cm', 'water_level_cm')) / 100, 2)
  FROM impor.tma_harian h, LATERAL (SELECT to_jsonb(h) AS j) x
  JOIN peta.logger_tmat l ON l.kode = impor.k(j, 'stasiun_id', 'station_id') AND l.khg_id = :khg AND l.sumber = :'sumber'
 WHERE impor.n(impor.k(j, 'tma_cm', 'water_level_cm')) IS NOT NULL AND impor.k(j, 'flag') IS NULL
ON CONFLICT DO NOTHING;
\else
-- tanpa berkas harian: ambil deret kolom t<yyyymmdd> dari tabel stasiun
INSERT INTO peta.tmat_bacaan (logger_id, waktu, tmat_m)
SELECT l.id, to_date(substring(e.key FROM 2), 'YYYYMMDD')::timestamp AT TIME ZONE 'Asia/Jakarta',
       round(-e.value::numeric / 100, 2)
  FROM impor.tma_stasiun i
  JOIN peta.logger_tmat l ON l.kode = impor.k(to_jsonb(i), 'stasiun_id', 'station_id') AND l.sumber = :'sumber'
 CROSS JOIN LATERAL jsonb_each_text(to_jsonb(i)) e
 WHERE e.key ~ '^t\d{8}$' AND impor.n(e.value) IS NOT NULL
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
