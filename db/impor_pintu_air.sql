-- Pintu air hasil model pompa (lapisan gates_required) untuk satu varian DEM, dari impor.pintu_air (diisi
-- scripts/impor_paket.py). Tiap pintu air adalah sekat usulan yang harus berupa pintu agar air pompa bisa lewat;
-- titiknya sama dengan sekat usulan varian ini, jadi sekat itu dipindah: dihapus dari peta.sekat (disalin dulu ke
-- cadangan.sekat) dan dimuat sebagai peta.pintu_air dengan sumber yang sama. Bisa diulang (pintu air varian ini
-- dihapus dulu); sekat yang sudah dipindah tidak ada lagi, jadi pengulangan tidak menghapus sekat lain.
-- Variabel psql: khg (id ref.khg), sumber ('IMPOR_KHG:<kode>').
\set ON_ERROR_STOP on

BEGIN;
-- sama dengan impor_paket.sql: impor bukan suntingan (tanpa audit/versi), anak sekat dihapus manual
SET LOCAL session_replication_role = replica;

DELETE FROM peta.pintu_air WHERE khg_id = :khg AND sumber = :'sumber';

INSERT INTO peta.pintu_air (kode, keterangan, sumber, khg_id, geom, created_by, updated_by, updated_via)
SELECT 'PA-' || (n.n + row_number() OVER (ORDER BY i.ogc_fid)),
       nullif(concat_ws('; ', 'pintu air rute pompa',
                        'rute ' || (to_jsonb(i)->>'route_ids'), 'sekat ' || (to_jsonb(i)->>'sekat_id')), ''),
       :'sumber', :khg, ST_GeometryN(i.geom, 1), 'import', 'import', 'import'
  FROM impor.pintu_air i,
       (SELECT coalesce(max(substring(kode FROM '\d+$')::int), 0) AS n
          FROM peta.pintu_air WHERE khg_id = :khg AND kode ~ '^PA-\d+$') n
 WHERE i.geom IS NOT NULL;

CREATE TEMP TABLE sekat_pintu ON COMMIT DROP AS
SELECT DISTINCT s.id
  FROM peta.sekat s
  JOIN peta.pintu_air p ON p.khg_id = :khg AND p.sumber = :'sumber'
 WHERE s.khg_id = :khg AND s.sumber = :'sumber' AND s.dipilih_bangun
   AND s.geom && ST_Expand(p.geom, 0.0001)
   AND ST_DWithin(s.geom::geography, p.geom::geography, 1);

CREATE SCHEMA IF NOT EXISTS cadangan;
CREATE TABLE IF NOT EXISTS cadangan.sekat AS SELECT now() AS dicadangkan_at, * FROM peta.sekat WITH NO DATA;
INSERT INTO cadangan.sekat SELECT now(), s.* FROM peta.sekat s WHERE s.id IN (SELECT id FROM sekat_pintu);
DELETE FROM peta.sekat_bangunan WHERE sekat_id IN (SELECT id FROM sekat_pintu);
DELETE FROM peta.sekat_konteks WHERE sekat_id IN (SELECT id FROM sekat_pintu);
DELETE FROM peta.sekat WHERE id IN (SELECT id FROM sekat_pintu);

SELECT (SELECT count(*) FROM peta.pintu_air WHERE khg_id = :khg AND sumber = :'sumber') AS pintu_air,
       (SELECT count(*) FROM sekat_pintu) AS sekat_dipindah;
COMMIT;
