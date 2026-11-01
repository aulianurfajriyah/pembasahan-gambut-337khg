-- Data uji minimal untuk CI (db/tests.sql butuh KHG ini dengan beberapa sekat). Bukan data asli.
\set ON_ERROR_STOP on
SET session_replication_role = replica;   -- tanpa trigger audit/versi, sama seperti impor
INSERT INTO ref.khg (nama, provinsi_utama_id, target_2026, luas_ha, geom)
SELECT 'KHG Sungai Matan - Sungai Rantaupanjang', (SELECT min(id) FROM ref.provinsi), true, 10000,
       ST_Multi(ST_MakeEnvelope(110.0, -1.1, 110.1, -1.0, 4326));
INSERT INTO alur.khg_versi (khg_id, nomor) SELECT id, 1 FROM ref.khg;
INSERT INTO peta.sekat (kode, status, khg_id, geom)
SELECT 'SK-' || g, 'existing', k.id, ST_SetSRID(ST_MakePoint(110.0 + g * 0.02, -1.05 + (g % 2) * 0.02), 4326)
  FROM ref.khg k, generate_series(1, 4) g;
-- kanal OSM bernomor K-1..K-3 tanpa status survei: tests.sql memeriksa penomoran dan validasi kanal_berstatus
INSERT INTO peta.kanal (kode, jenis_kanal, status, sumber, khg_id, geom)
SELECT 'K-' || g, 1, NULL, 'OSM_2025', k.id,
       ST_Multi(ST_MakeLine(ST_MakePoint(110.01, -1.09 + g * 0.02), ST_MakePoint(110.09, -1.09 + g * 0.02)))
  FROM ref.khg k, generate_series(1, 3) g;
RESET session_replication_role;
