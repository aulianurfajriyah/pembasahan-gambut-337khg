-- Sekat final (dipilih untuk dibangun) untuk DB yang sudah dibangun sebelum kolom ini ada.
-- Jalankan sebagai postgres:  psql -f db/migrations/2026-10-03_sekat_final.sql  lalu  psql -f db/10_api_views.sql
-- Build baru lewat setup.sh tidak perlu file ini (sudah ada di 01/03/10).
BEGIN;
ALTER TABLE peta.sekat ADD COLUMN IF NOT EXISTS dipilih_bangun boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS sekat_khg_id_status_idx ON peta.sekat (khg_id, status);
CREATE INDEX IF NOT EXISTS sekat_khg_id_final_idx ON peta.sekat (khg_id) WHERE dipilih_bangun;

CREATE OR REPLACE VIEW alur.v_dashboard AS
SELECT
  (SELECT count(DISTINCT khg_id) FROM alur.khg_versi WHERE status IN ('approved','printed')) AS khg_disetujui,
  (SELECT count(*) FROM ref.khg) AS khg_total,
  (SELECT count(*) FROM alur.khg_versi
    WHERE status IN ('approved','printed') AND diputuskan_at >= now() - interval '7 days') AS khg_disetujui_minggu_ini,
  (SELECT count(*) FROM peta.pompa WHERE status = 'rencana') AS pompa_rencana,
  (SELECT count(*) FROM peta.pompa WHERE created_at >= now() - interval '7 days') AS pompa_minggu_ini,
  (SELECT round(coalesce(sum(panjang_m) FILTER (WHERE status = 'aktif'), 0) / 1000, 1) FROM peta.kanal) AS kanal_aktif_km,
  (SELECT round(coalesce(sum(panjang_m), 0) / 1000, 1) FROM peta.kanal) AS kanal_total_km,
  (SELECT count(*) FROM peta.hotspot WHERE waktu >= now() - interval '30 days') AS hotspot_30h,
  (SELECT count(*) FROM peta.hotspot
    WHERE waktu >= now() - interval '60 days' AND waktu < now() - interval '30 days') AS hotspot_30h_sebelumnya,
  (SELECT count(*) FROM peta.v_tmat_alert) AS logger_alert,
  (SELECT count(DISTINCT khg_id) FROM peta.v_tmat_alert) AS khg_alert,
  (SELECT count(*) FROM peta.sekat) AS sekat_total,
  (SELECT count(*) FROM peta.sekat WHERE status = 'existing') AS sekat_existing,
  (SELECT jsonb_object_agg(status, n) FROM
     (SELECT status, count(*) AS n FROM alur.v_khg_status GROUP BY 1) s) AS status_alur,
  (SELECT count(*) FROM peta.sekat WHERE dipilih_bangun) AS sekat_final,
  (SELECT count(DISTINCT khg_id) FROM peta.sekat WHERE dipilih_bangun) AS khg_dengan_sekat_final;
COMMIT;
