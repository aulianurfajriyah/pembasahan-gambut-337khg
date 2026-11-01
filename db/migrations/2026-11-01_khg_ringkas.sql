-- Koleksi khg-ringkas: KHG tanpa batas poligon untuk daftar/tabel/dashboard web (lihat 10_api_views.sql).
BEGIN;
CREATE OR REPLACE VIEW api.khg_ringkas AS
SELECT id, kode, nama, provinsi, provinsi_singkat, target_2026, luas_ha, versi, status, diajukan_oleh, diajukan_at,
       reviewer, diputuskan_at, hotspot_30h, hotspot_tahun_ini, kanal_km, sekat_rencana, sekat_existing, sekat_final,
       pintu_air, pompa, kanal_aktif_km, porsi_pernah_terbakar, porsi_gambut_dalam, skor_prioritas,
       bbox_xmin, bbox_ymin, bbox_xmax, bbox_ymax, kanal_terpilih_km,
       ST_SetSRID(ST_MakePoint((bbox_xmin + bbox_xmax) / 2, (bbox_ymin + bbox_ymax) / 2), 4326)::geometry(Point, 4326) AS geom
  FROM api.khg;
GRANT SELECT ON api.khg_ringkas TO gambut_baca;
COMMIT;
