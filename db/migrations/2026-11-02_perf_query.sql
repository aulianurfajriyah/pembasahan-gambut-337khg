-- Query lebih cepat untuk dashboard, daftar KHG, dan ubin KHG (lihat 01_schema.sql, 02_trigger_fungsi.sql,
-- 03_views.sql, 10_api_views.sql). ALTER ref.khg menulis ulang tabel (±35 dtk, ref.khg terkunci selama itu).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- query lambat: SELECT * FROM pg_stat_statements

-- 1. ref.varian_utama bisa di-inline planner: subquery EXISTS dipindah ke fungsi kecil yang hanya dipanggil untuk
--    baris impor varian DEM (sumber IMPOR_KHG:*). Sebelumnya fungsi dipanggil per baris di setiap view.
CREATE OR REPLACE FUNCTION ref.varian_utama_impor(p_khg int, p_sumber text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM ref.varian_dem v WHERE v.khg_id = p_khg AND v.utama AND v.sumber = p_sumber)
$$;
CREATE OR REPLACE FUNCTION ref.varian_utama(p_khg int, p_sumber text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_sumber IS NULL OR p_sumber NOT LIKE 'IMPOR_KHG:%' OR ref.varian_utama_impor(p_khg, p_sumber)
$$;

-- 2. bbox KHG tersimpan: daftar & detail KHG tidak lagi membaca seluruh batas (49 MB) tiap request
ALTER TABLE ref.khg
  ADD COLUMN IF NOT EXISTS bbox_xmin double precision GENERATED ALWAYS AS (ST_XMin(geom)) STORED,
  ADD COLUMN IF NOT EXISTS bbox_ymin double precision GENERATED ALWAYS AS (ST_YMin(geom)) STORED,
  ADD COLUMN IF NOT EXISTS bbox_xmax double precision GENERATED ALWAYS AS (ST_XMax(geom)) STORED,
  ADD COLUMN IF NOT EXISTS bbox_ymax double precision GENERATED ALWAYS AS (ST_YMax(geom)) STORED;

CREATE OR REPLACE VIEW api.khg AS
SELECT k.id, k.kode, k.nama, p.nama AS provinsi, p.singkatan AS provinsi_singkat, k.target_2026, k.luas_ha,
       st.nomor AS versi, st.status, st.diajukan_oleh, st.diajukan_at, st.reviewer, st.diputuskan_at,
       s.hotspot_30h, s.hotspot_tahun_ini, s.kanal_km,
       -- sekat & pintu air dihitung langsung (bukan dari materialized view) agar edit QGIS langsung terlihat;
       -- data varian DEM hanya dihitung untuk varian utama (ref.varian_dem)
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.status = 'rencana'
           AND ref.varian_utama(k.id, x.sumber)) AS sekat_rencana,
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.status = 'existing') AS sekat_existing,
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.dipilih_bangun
           AND ref.varian_utama(k.id, x.sumber)) AS sekat_final,
       (SELECT count(*) FROM peta.pintu_air x WHERE x.khg_id = k.id AND ref.varian_utama(k.id, x.sumber)) AS pintu_air,
       (SELECT count(*) FROM peta.pompa x WHERE x.khg_id = k.id AND ref.varian_utama(k.id, x.sumber)) AS pompa,
       (SELECT round(sum(panjang_m) / 1000, 1) FROM peta.kanal c WHERE c.khg_id = k.id AND c.status = 'aktif'
           AND coalesce(c.sumber, '') NOT LIKE 'IMPOR_KHG:%') AS kanal_aktif_km,
       s.porsi_pernah_terbakar, s.porsi_gambut_dalam,
       round(100 * (0.4 * coalesce(s.porsi_pernah_terbakar, 0) + 0.3 * coalesce(s.porsi_gambut_dalam, 0)
                  + 0.3 * coalesce(s.hotspot_30h::numeric / nullif((SELECT max(hotspot_30h) FROM api.khg_statistik), 0), 0)))::int AS skor_prioritas,
       k.geom,
       -- bbox terpisah agar klien bisa memusatkan peta tanpa mengunduh seluruh batas KHG
       k.bbox_xmin, k.bbox_ymin, k.bbox_xmax, k.bbox_ymax,
       (SELECT round(coalesce(sum(panjang_m), 0) / 1000, 1) FROM peta.kanal c
         WHERE c.khg_id = k.id AND c.dipilih_digunakan AND ref.varian_utama(k.id, c.sumber)) AS kanal_terpilih_km
  FROM ref.khg k
  JOIN ref.provinsi p ON p.id = k.provinsi_utama_id
  LEFT JOIN alur.v_khg_status st ON st.khg_id = k.id
  LEFT JOIN api.khg_statistik s ON s.khg_id = k.id;

-- 3. ubin KHG hanya membawa atribut yang dipakai peta web (LH-KHG khg-map.tsx, khg-layers.ts, poster-map.tsx).
--    Hitungan sekat/pintu air/kanal per KHG (mahal) tetap ada di koleksi khg & khg-ringkas.
CREATE OR REPLACE FUNCTION api.khg_ubin(z integer, x integer, y integer) RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE AS $$
SELECT ST_AsMVT(t, 'khg', 4096, 'geom') FROM (
  SELECT ST_AsMVTGeom(ST_Transform(CASE WHEN z < 8 THEN k.geom_sederhana ELSE k.geom END, 3857),
                      ST_TileEnvelope(z, x, y), 4096, 64, true) AS geom,
         a.id, a.kode, a.nama, a.provinsi, a.provinsi_singkat, a.target_2026, a.luas_ha, a.versi, a.status,
         a.hotspot_30h, a.hotspot_tahun_ini, a.kanal_km, a.pompa, a.porsi_pernah_terbakar, a.porsi_gambut_dalam,
         a.skor_prioritas
    FROM ref.khg k JOIN api.khg a ON a.id = k.id
   WHERE k.geom && ST_Transform(ST_TileEnvelope(z, x, y, margin => 64.0 / 4096), 4326)
) t
$$;

-- 4. dashboard: satu scan kanal untuk km aktif & total (sebelumnya dua scan penuh)
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
  kn.aktif AS kanal_aktif_km, kn.total AS kanal_total_km,
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
  (SELECT count(DISTINCT khg_id) FROM peta.sekat WHERE dipilih_bangun AND ref.varian_utama(khg_id, sumber)) AS khg_dengan_sekat_final
  -- kanal (657 ribu baris) cukup satu kali scan untuk km aktif & total
  FROM (SELECT round(coalesce(sum(panjang_m) FILTER (WHERE status = 'aktif'), 0) / 1000, 1) AS aktif,
               round(coalesce(sum(panjang_m), 0) / 1000, 1) AS total
          FROM peta.kanal WHERE coalesce(sumber, '') NOT LIKE 'IMPOR_KHG:%') kn;

COMMIT;
