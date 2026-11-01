-- Ubin KHG zoom rendah dengan batas disederhanakan (lihat 01_schema.sql ref.khg.geom_sederhana, 10_api_views.sql api.khg_ubin).
-- ALTER menghitung ulang ke-866 batas (±35 dtk, ref.khg terkunci selama itu).
BEGIN;
ALTER TABLE ref.khg ADD COLUMN geom_sederhana geometry GENERATED ALWAYS AS (ST_SimplifyPreserveTopology(geom, 0.0005)) STORED;

-- ubin MVT KHG untuk peta web (Martin sumber khg_ubin, Caddy /tiles/khg). Zoom < 8 memakai batas disederhanakan
-- (lebih kecil dari 1 piksel ubin di zoom itu), zoom >= 8 batas asli. Atribut = api.khg tanpa geometri & bbox.
CREATE OR REPLACE FUNCTION api.khg_ubin(z integer, x integer, y integer) RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE AS $$
SELECT ST_AsMVT(t, 'khg', 4096, 'geom') FROM (
  SELECT ST_AsMVTGeom(ST_Transform(CASE WHEN z < 8 THEN k.geom_sederhana ELSE k.geom END, 3857),
                      ST_TileEnvelope(z, x, y), 4096, 64, true) AS geom,
         a.id, a.kode, a.nama, a.provinsi, a.provinsi_singkat, a.target_2026, a.luas_ha, a.versi, a.status,
         a.diajukan_oleh, a.diajukan_at, a.reviewer, a.diputuskan_at, a.hotspot_30h, a.hotspot_tahun_ini, a.kanal_km,
         a.sekat_rencana, a.sekat_existing, a.sekat_final, a.pintu_air, a.pompa, a.kanal_aktif_km,
         a.porsi_pernah_terbakar, a.porsi_gambut_dalam, a.skor_prioritas, a.kanal_terpilih_km
    FROM ref.khg k JOIN api.khg a ON a.id = k.id
   WHERE k.geom && ST_Transform(ST_TileEnvelope(z, x, y, margin => 64.0 / 4096), 4326)
) t
$$;
COMMIT;
