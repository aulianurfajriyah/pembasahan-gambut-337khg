-- skor_prioritas tanpa window function: filter bbox/id kini turun ke ref.khg (ubin KHG ±400 ms -> ±15 ms).
-- Hasil skor sama (hotspot maksimum dari api.khg_statistik, satu baris per KHG).
BEGIN;
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
       ST_XMin(k.geom) AS bbox_xmin, ST_YMin(k.geom) AS bbox_ymin,
       ST_XMax(k.geom) AS bbox_xmax, ST_YMax(k.geom) AS bbox_ymax,
       (SELECT round(coalesce(sum(panjang_m), 0) / 1000, 1) FROM peta.kanal c
         WHERE c.khg_id = k.id AND c.dipilih_digunakan AND ref.varian_utama(k.id, c.sumber)) AS kanal_terpilih_km
  FROM ref.khg k
  JOIN ref.provinsi p ON p.id = k.provinsi_utama_id
  LEFT JOIN alur.v_khg_status st ON st.khg_id = k.id
  LEFT JOIN api.khg_statistik s ON s.khg_id = k.id;
COMMIT;
