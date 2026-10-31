-- Status alur "proses" + varian DEM per KHG (scripts/impor_paket.py), untuk DB yang sudah dibangun.
-- Jalankan sebagai postgres:  psql -f db/migrations/2026-10-30_varian_dem.sql  lalu  psql -f db/10_api_views.sql
-- Build baru lewat setup.sh tidak perlu file ini (sudah ada di 01/02). Aman dijalankan ulang.
--
-- Satu KHG bisa diolah dengan beberapa DEM (DEMNAS, LiDAR, WorldDEM, DTM BRGM). Lapisan yang bergantung
-- pada DEM (pompa, jalur pompa, kanal terpilih, sekat usulan, sub-KHG) disimpan per varian dengan
-- sumber = 'IMPOR_KHG:<kode>'; lapisan lain dipakai bersama (sumber = 'IMPOR_KHG'). Web memilih varian
-- yang ditampilkan; statistik KHG hanya menghitung varian utama.
\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------- status "proses" (data KHG sedang diolah)
INSERT INTO ref.status_alur VALUES ('proses', 'Proses', 2, '#1098ad') ON CONFLICT (kode) DO NOTHING;
UPDATE ref.status_alur SET urutan = v.u
  FROM (VALUES ('draft', 1), ('proses', 2), ('review', 3), ('revisi', 4), ('approved', 5), ('printed', 6)) v(k, u)
 WHERE kode = v.k;

-- proses = versi terbuka (masih bisa diedit dan diajukan review), seperti draft
DROP INDEX IF EXISTS alur.khg_versi_satu_terbuka;
CREATE UNIQUE INDEX khg_versi_satu_terbuka ON alur.khg_versi (khg_id)
  WHERE status IN ('draft','proses','review','revisi');

CREATE OR REPLACE FUNCTION alur.versi_terbuka(p_khg int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE vid bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('khg_versi'), p_khg);
  SELECT id INTO vid FROM alur.khg_versi
   WHERE khg_id = p_khg AND status IN ('draft','proses','review','revisi');
  IF vid IS NULL THEN
    INSERT INTO alur.khg_versi (khg_id, nomor)
    SELECT p_khg, coalesce(max(nomor), 0) + 1 FROM alur.khg_versi WHERE khg_id = p_khg
    RETURNING id INTO vid;
  END IF;
  RETURN vid;
END $$;

CREATE OR REPLACE FUNCTION alur.ajukan_review(p_versi bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE alur.khg_versi
     SET status = 'review',
         diajukan_oleh = coalesce(nullif(current_setting('app.pengguna', true), ''), session_user),
         diajukan_at = now(),
         validasi = (SELECT jsonb_agg(to_jsonb(x)) FROM alur.validasi_khg(p_versi) x)
   WHERE id = p_versi AND status IN ('draft','proses','revisi');
  IF NOT FOUND THEN RAISE EXCEPTION 'Versi % bukan draft/proses/revisi', p_versi; END IF;
END $$;

-- ---------------------------------------------------------------- varian DEM
CREATE TABLE IF NOT EXISTS ref.varian_dem (
  khg_id  int NOT NULL REFERENCES ref.khg,
  kode    text NOT NULL CHECK (kode ~ '^[A-Z0-9]+$'),   -- LIDAR, DEMNAS, WORLDDEM, BRGM, ...
  label   text NOT NULL,                               -- "LiDAR 25 m"
  utama   boolean NOT NULL DEFAULT false,              -- dipakai statistik & tampilan awal
  urutan  smallint NOT NULL DEFAULT 1,
  catatan text,
  sumber  text GENERATED ALWAYS AS ('IMPOR_KHG:' || kode) STORED,
  PRIMARY KEY (khg_id, kode)
);
CREATE UNIQUE INDEX IF NOT EXISTS varian_dem_satu_utama ON ref.varian_dem (khg_id) WHERE utama;

-- true bila baris ikut dihitung/ditampilkan secara bawaan: bukan data varian, atau data varian utama
CREATE OR REPLACE FUNCTION ref.varian_utama(p_khg int, p_sumber text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_sumber IS NULL OR p_sumber NOT LIKE 'IMPOR_KHG:%'
      OR EXISTS (SELECT 1 FROM ref.varian_dem v WHERE v.khg_id = p_khg AND v.utama AND v.sumber = p_sumber)
$$;

GRANT SELECT ON ref.varian_dem TO gambut_baca;

-- view dashboard/daftar/legenda (03_views.sql): data varian DEM hanya dihitung untuk varian utama
CREATE OR REPLACE VIEW alur.v_khg_daftar AS
WITH hs AS (SELECT khg_id, count(*) AS n FROM peta.hotspot
             WHERE waktu >= now() - interval '30 days' GROUP BY 1),
-- data varian DEM (sumber IMPOR_KHG:*) hanya dihitung untuk varian utama; salinan kanal varian tidak dihitung
pm AS (SELECT khg_id, count(*) AS n FROM peta.pompa WHERE ref.varian_utama(khg_id, sumber) GROUP BY 1),
kn AS (SELECT khg_id,
              round(sum(panjang_m) FILTER (WHERE status = 'aktif') / 1000, 1) AS km_aktif,
              round(sum(panjang_m) / 1000, 1) AS km_total
         FROM peta.kanal WHERE coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%' GROUP BY 1),
sk AS (SELECT s.khg_id, count(*) AS n,
              count(*) FILTER (WHERE s.status = 'rencana')  AS rencana,
              count(*) FILTER (WHERE s.status = 'existing') AS existing,
              avg((c.frekuensi_terbakar <> 'NON Terbakar')::int) AS porsi_terbakar,
              avg((c.fungsi_eg_ketebalan LIKE '%>= 3%')::int)    AS porsi_gambut_dalam
         FROM peta.sekat s LEFT JOIN peta.sekat_konteks c ON c.sekat_id = s.id
        WHERE ref.varian_utama(s.khg_id, s.sumber)
        GROUP BY 1),
akhir AS (SELECT DISTINCT ON (khg_id) khg_id, waktu, via, pengguna
            FROM alur.perubahan ORDER BY khg_id, waktu DESC)
SELECT k.id, k.kode, k.nama, p.singkatan AS provinsi, p.id AS provinsi_id,
       coalesce(k.luas_ha, round((ST_Area(k.geom::geography) / 1e4)::numeric, 0)) AS luas_ha,
       coalesce(hs.n, 0) AS hotspot_30h,
       coalesce(pm.n, 0) AS pompa,
       kn.km_aktif AS kanal_aktif_km, kn.km_total AS kanal_total_km,
       coalesce(sk.n, 0) AS sekat, coalesce(sk.rencana, 0) AS sekat_rencana,
       coalesce(sk.existing, 0) AS sekat_existing,
       st.versi_id, st.nomor AS versi, st.status,
       coalesce(akhir.waktu, st.dibuat_at) AS terakhir_diubah, akhir.via AS diubah_via,
       akhir.pengguna AS diubah_oleh,
       round(100 * (0.4 * coalesce(sk.porsi_terbakar, 0)
                  + 0.3 * coalesce(sk.porsi_gambut_dalam, 0)
                  + 0.3 * coalesce(hs.n::numeric / nullif(max(hs.n) OVER (), 0), 0)))::int AS skor_prioritas
  FROM ref.khg k
  JOIN ref.provinsi p ON p.id = k.provinsi_utama_id
  LEFT JOIN alur.v_khg_status st ON st.khg_id = k.id
  LEFT JOIN hs ON hs.khg_id = k.id
  LEFT JOIN pm ON pm.khg_id = k.id
  LEFT JOIN kn ON kn.khg_id = k.id
  LEFT JOIN sk ON sk.khg_id = k.id
  LEFT JOIN akhir ON akhir.khg_id = k.id;

CREATE OR REPLACE VIEW alur.v_dashboard AS
SELECT
  -- KHG yang punya versi approved/printed tetap dihitung walau sedang ada draft baru
  (SELECT count(DISTINCT khg_id) FROM alur.khg_versi WHERE status IN ('approved','printed')) AS khg_disetujui,
  (SELECT count(*) FROM ref.khg) AS khg_total,
  (SELECT count(*) FROM alur.khg_versi
    WHERE status IN ('approved','printed') AND diputuskan_at >= now() - interval '7 days') AS khg_disetujui_minggu_ini,
  -- data varian DEM hanya dihitung untuk varian utama (ref.varian_dem)
  (SELECT count(*) FROM peta.pompa WHERE status = 'rencana' AND ref.varian_utama(khg_id, sumber)) AS pompa_rencana,
  (SELECT count(*) FROM peta.pompa WHERE created_at >= now() - interval '7 days' AND ref.varian_utama(khg_id, sumber)) AS pompa_minggu_ini,
  (SELECT round(coalesce(sum(panjang_m) FILTER (WHERE status = 'aktif'), 0) / 1000, 1) FROM peta.kanal
    WHERE coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%') AS kanal_aktif_km,
  (SELECT round(coalesce(sum(panjang_m), 0) / 1000, 1) FROM peta.kanal WHERE coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%') AS kanal_total_km,
  (SELECT count(*) FROM peta.hotspot WHERE waktu >= now() - interval '30 days') AS hotspot_30h,
  (SELECT count(*) FROM peta.hotspot
    WHERE waktu >= now() - interval '60 days' AND waktu < now() - interval '30 days') AS hotspot_30h_sebelumnya,
  (SELECT count(*) FROM peta.v_tmat_alert) AS logger_alert,
  (SELECT count(DISTINCT khg_id) FROM peta.v_tmat_alert) AS khg_alert,
  (SELECT count(*) FROM peta.sekat WHERE ref.varian_utama(khg_id, sumber)) AS sekat_total,
  (SELECT count(*) FROM peta.sekat WHERE status = 'existing') AS sekat_existing,
  (SELECT jsonb_object_agg(status, n) FROM
     (SELECT status, count(*) AS n FROM alur.v_khg_status GROUP BY 1) s) AS status_alur,
  (SELECT count(*) FROM peta.sekat WHERE dipilih_bangun AND ref.varian_utama(khg_id, sumber)) AS sekat_final,
  (SELECT count(DISTINCT khg_id) FROM peta.sekat WHERE dipilih_bangun AND ref.varian_utama(khg_id, sumber)) AS khg_dengan_sekat_final;

CREATE OR REPLACE VIEW peta.v_khg_legenda AS
          SELECT khg_id, 'sungai' AS layer, count(*) AS jumlah FROM peta.sungai GROUP BY 1
UNION ALL SELECT khg_id, 'kanal_aktif', count(*) FROM peta.kanal WHERE status = 'aktif' GROUP BY 1
UNION ALL SELECT khg_id, 'kanal_tidak_aktif', count(*) FROM peta.kanal WHERE status IN ('tidak_aktif', 'tersumbat') GROUP BY 1
UNION ALL SELECT khg_id, 'kanal_belum_disurvei', count(*) FROM peta.kanal WHERE status IS NULL AND coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%' GROUP BY 1
UNION ALL SELECT khg_id, 'pompa', count(*) FROM peta.pompa WHERE ref.varian_utama(khg_id, sumber) GROUP BY 1
UNION ALL SELECT khg_id, 'pintu_air', count(*) FROM peta.pintu_air GROUP BY 1
UNION ALL SELECT khg_id, 'sekat_existing', count(*) FROM peta.sekat WHERE status = 'existing' GROUP BY 1
UNION ALL SELECT khg_id, 'sekat_rencana', count(*) FROM peta.sekat WHERE status = 'rencana' AND ref.varian_utama(khg_id, sumber) GROUP BY 1
UNION ALL SELECT khg_id, 'sekat_final', count(*) FROM peta.sekat WHERE dipilih_bangun AND ref.varian_utama(khg_id, sumber) GROUP BY 1
UNION ALL SELECT khg_id, 'sumur_bor', count(*) FROM peta.sumur_bor GROUP BY 1
UNION ALL SELECT khg_id, 'hotspot_tahun_ini', count(*) FROM peta.hotspot
           WHERE waktu >= date_trunc('year', now()) GROUP BY 1
UNION ALL SELECT khg_id, 'areal_terbakar', count(*) FROM peta.areal_terbakar GROUP BY 1
UNION ALL SELECT khg_id, 'logger_tmat', count(*) FROM peta.logger_tmat GROUP BY 1
UNION ALL SELECT khg_id, 'posko_karhutla', count(*) FROM peta.posko_karhutla GROUP BY 1
UNION ALL SELECT khg_id, 'konsesi', count(*) FROM peta.konsesi GROUP BY 1;
COMMIT;
