-- Kanal terpilih (digunakan untuk pembasahan) untuk DB yang sudah dibangun sebelum kolom ini ada.
-- Jalankan sebagai postgres; build baru lewat setup.sh sudah menyertakannya (01/10).
BEGIN;
ALTER TABLE peta.kanal ADD COLUMN IF NOT EXISTS dipilih_digunakan boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS kanal_khg_id_terpilih_idx ON peta.kanal (khg_id) WHERE dipilih_digunakan;

CREATE OR REPLACE VIEW api.kanal AS
SELECT c.id, c.kode, j.label AS jenis_kanal, coalesce(sk.label, 'Belum disurvei') AS status,
       c.panjang_m, k.nama AS khg, c.sumber, c.geom, c.dipilih_digunakan
  FROM peta.kanal c
  LEFT JOIN ref.jenis_kanal j ON j.kode = c.jenis_kanal
  LEFT JOIN ref.status_kanal sk ON sk.kode = c.status
  LEFT JOIN ref.khg k ON k.id = c.khg_id;

CREATE OR REPLACE VIEW api.khg AS
SELECT k.id, k.kode, k.nama, p.nama AS provinsi, p.singkatan AS provinsi_singkat, k.target_2026, k.luas_ha,
       st.nomor AS versi, st.status, st.diajukan_oleh, st.diajukan_at, st.reviewer, st.diputuskan_at,
       s.hotspot_30h, s.hotspot_tahun_ini, s.kanal_km,
       -- sekat & pintu air dihitung langsung (bukan dari materialized view) agar edit QGIS langsung terlihat
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.status = 'rencana') AS sekat_rencana,
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.status = 'existing') AS sekat_existing,
       (SELECT count(*) FROM peta.sekat x WHERE x.khg_id = k.id AND x.dipilih_bangun) AS sekat_final,
       (SELECT count(*) FROM peta.pintu_air x WHERE x.khg_id = k.id) AS pintu_air,
       (SELECT count(*) FROM peta.pompa x WHERE x.khg_id = k.id) AS pompa,
       (SELECT round(sum(panjang_m) / 1000, 1) FROM peta.kanal c WHERE c.khg_id = k.id AND c.status = 'aktif') AS kanal_aktif_km,
       s.porsi_pernah_terbakar, s.porsi_gambut_dalam,
       round(100 * (0.4 * coalesce(s.porsi_pernah_terbakar, 0) + 0.3 * coalesce(s.porsi_gambut_dalam, 0)
                  + 0.3 * coalesce(s.hotspot_30h::numeric / nullif(max(s.hotspot_30h) OVER (), 0), 0)))::int AS skor_prioritas,
       k.geom,
       -- bbox terpisah agar klien bisa memusatkan peta tanpa mengunduh seluruh batas KHG
       ST_XMin(k.geom) AS bbox_xmin, ST_YMin(k.geom) AS bbox_ymin,
       ST_XMax(k.geom) AS bbox_xmax, ST_YMax(k.geom) AS bbox_ymax,
       (SELECT round(coalesce(sum(panjang_m), 0) / 1000, 1) FROM peta.kanal c
         WHERE c.khg_id = k.id AND c.dipilih_digunakan) AS kanal_terpilih_km
  FROM ref.khg k
  JOIN ref.provinsi p ON p.id = k.provinsi_utama_id
  LEFT JOIN alur.v_khg_status st ON st.khg_id = k.id
  LEFT JOIN api.khg_statistik s ON s.khg_id = k.id;

COMMIT;
