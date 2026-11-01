-- Schema api: view baca-saja yang dipublikasikan lewat OGC API (pygeoapi).
-- Kolom FK diganti nama yang terbaca manusia. Koleksi yang bisa diedit memakai tabel peta.* langsung.
DROP SCHEMA IF EXISTS api CASCADE;
CREATE SCHEMA api;

-- statistik per KHG (mahal dihitung) -> materialized view, di-refresh berkala
CREATE MATERIALIZED VIEW api.khg_statistik AS
SELECT k.id AS khg_id,
       (SELECT count(*) FROM peta.hotspot h WHERE h.khg_id = k.id
           AND h.waktu >= (SELECT max(waktu) FROM peta.hotspot) - interval '30 days') AS hotspot_30h,
       (SELECT count(*) FROM peta.hotspot h WHERE h.khg_id = k.id
           AND h.waktu >= date_trunc('year', (SELECT max(waktu) FROM peta.hotspot))) AS hotspot_tahun_ini,
       -- baris kanal varian DEM (sumber IMPOR_KHG:*) hanya salinan kanal terpilih, tidak dihitung
       (SELECT round(sum(panjang_m) / 1000, 1) FROM peta.kanal c WHERE c.khg_id = k.id
           AND coalesce(c.sumber, '') NOT LIKE 'IMPOR_KHG:%') AS kanal_km,
       (SELECT count(*) FROM peta.sekat s WHERE s.khg_id = k.id AND s.status = 'rencana') AS sekat_rencana,
       (SELECT count(*) FROM peta.sekat s WHERE s.khg_id = k.id AND s.status = 'existing') AS sekat_existing,
       (SELECT count(*) FROM peta.pintu_air p WHERE p.khg_id = k.id) AS pintu_air,
       (SELECT round(sum(luas_ha) FILTER (WHERE tahun_terbakar IS NOT NULL)
                     / nullif(sum(luas_ha), 0), 3)
          FROM analisis.unit_nasional u WHERE u.khg_id = k.id) AS porsi_pernah_terbakar,
       (SELECT round(sum(luas_ha) FILTER (WHERE fungsi_eg_ketebalan LIKE '%>= 3%')
                     / nullif(sum(luas_ha), 0), 3)
          FROM analisis.unit_nasional u WHERE u.khg_id = k.id) AS porsi_gambut_dalam
  FROM ref.khg k;
CREATE UNIQUE INDEX ON api.khg_statistik (khg_id);

-- KHG: batas + status alur + statistik + skor prioritas (layar Dashboard & Daftar KHG)
-- penyederhanaan: skor_prioritas = 100 x (0.4 porsi terbakar + 0.3 porsi gambut >= 3 m + 0.3 hotspot 30h relatif)
-- hotspot maksimum lewat subquery, bukan window max() OVER (): window menghalangi filter (bbox ubin, id) turun ke
-- ref.khg, sehingga setiap request menghitung ke-866 KHG
CREATE VIEW api.khg AS
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

-- KHG tanpa batas poligon (49 MB) untuk daftar/tabel/dashboard: pygeoapi tetap membaca kolom geometri walau
-- skipGeometry=true, jadi geometri diganti titik tengah bbox
CREATE VIEW api.khg_ringkas AS
SELECT id, kode, nama, provinsi, provinsi_singkat, target_2026, luas_ha, versi, status, diajukan_oleh, diajukan_at,
       reviewer, diputuskan_at, hotspot_30h, hotspot_tahun_ini, kanal_km, sekat_rencana, sekat_existing, sekat_final,
       pintu_air, pompa, kanal_aktif_km, porsi_pernah_terbakar, porsi_gambut_dalam, skor_prioritas,
       bbox_xmin, bbox_ymin, bbox_xmax, bbox_ymax, kanal_terpilih_km,
       ST_SetSRID(ST_MakePoint((bbox_xmin + bbox_xmax) / 2, (bbox_ymin + bbox_ymax) / 2), 4326)::geometry(Point, 4326) AS geom
  FROM api.khg;

-- ubin MVT KHG untuk peta web (Martin sumber khg_ubin, Caddy /tiles/khg). Zoom < 8 memakai batas disederhanakan
-- (lebih kecil dari 1 piksel ubin di zoom itu), zoom >= 8 batas asli. Atribut = api.khg tanpa geometri & bbox.
CREATE FUNCTION api.khg_ubin(z integer, x integer, y integer) RETURNS bytea
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

CREATE VIEW api.desa AS
SELECT d.id, d.kode_bps, d.nama AS desa, kc.nama AS kecamatan, kb.nama AS kabupaten, p.nama AS provinsi,
       d.target_pemulihan_2026, d.geom
  FROM ref.desa d JOIN ref.kecamatan kc ON kc.id = d.kecamatan_id
  JOIN ref.kabupaten kb ON kb.id = kc.kabupaten_id JOIN ref.provinsi p ON p.id = kb.provinsi_id
 WHERE d.geom IS NOT NULL;

CREATE VIEW api.sekat AS
SELECT s.id, s.kode, s.status, s.sumber, j.label AS jenis_kanal, s.kanal_id, s.elevasi_kontur_m,
       k.nama AS khg, d.nama AS desa, pr.nama AS perusahaan,
       b.kodefikasi, b.tipe, b.jenis_bangunan, b.bahan, b.tahun_bangun, b.pelaksana, b.anggaran,
       c.penutupan_lahan_2022, c.kerusakan_eg_2024, c.tebal_gambut_kelas, c.tahun_terbakar,
       c.prioritas_intervensi, c.program_dmpg, s.qc_flag, s.dipilih_bangun, s.updated_at, s.updated_via, s.geom
  FROM peta.sekat s
  LEFT JOIN ref.jenis_kanal j ON j.kode = s.jenis_kanal
  LEFT JOIN ref.khg k ON k.id = s.khg_id
  LEFT JOIN peta.sekat_konteks c ON c.sekat_id = s.id
  LEFT JOIN peta.sekat_bangunan b ON b.sekat_id = s.id
  LEFT JOIN ref.desa d ON d.id = c.desa_id
  LEFT JOIN ref.perusahaan pr ON pr.id = coalesce(c.perusahaan_id, b.perusahaan_id);

CREATE VIEW api.hotspot AS
SELECT h.id, h.waktu, h.satelit, h.instrumen, h.kepercayaan, h.frp_mw, h.provinsi, h.kabupaten,
       h.desa, k.nama AS khg, h.format_sumber, h.geom
  FROM peta.hotspot h LEFT JOIN ref.khg k ON k.id = h.khg_id;

CREATE VIEW api.areal_terbakar AS
SELECT a.id, array_to_string(a.tahun_terbakar, ',') AS tahun_terbakar, a.frekuensi,
       (SELECT max(t) FROM unnest(a.tahun_terbakar) t) AS tahun_terakhir, k.nama AS khg, a.geom
  FROM peta.areal_terbakar a LEFT JOIN ref.khg k ON k.id = a.khg_id;

CREATE VIEW api.konsesi AS
SELECT c.id, pr.nama AS perusahaan, c.jenis, c.sumber, k.nama AS khg, c.geom
  FROM peta.konsesi c LEFT JOIN ref.perusahaan pr ON pr.id = c.perusahaan_id
  LEFT JOIN ref.khg k ON k.id = c.khg_id;

CREATE VIEW api.ketebalan_gambut AS
SELECT t.id, k.nama AS khg, t.kelas, t.tebal_min_m, t.tebal_max_m, t.geom
  FROM peta.ketebalan_gambut t LEFT JOIN ref.khg k ON k.id = t.khg_id;

CREATE VIEW api.sumur_bor AS SELECT * FROM peta.v_sumur_bor;

CREATE VIEW api.kanal AS
SELECT c.id, c.kode, j.label AS jenis_kanal, coalesce(sk.label, 'Belum disurvei') AS status,
       c.panjang_m, k.nama AS khg, c.sumber, c.geom, c.dipilih_digunakan
  FROM peta.kanal c
  LEFT JOIN ref.jenis_kanal j ON j.kode = c.jenis_kanal
  LEFT JOIN ref.status_kanal sk ON sk.kode = c.status
  LEFT JOIN ref.khg k ON k.id = c.khg_id;

-- unit analisis (besar): atribut lengkap untuk analisis/QGIS
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['unit_target_2026', 'unit_nasional'] LOOP
    EXECUTE format($f$
      CREATE VIEW api.%1$I AS
      SELECT u.id, k.nama AS khg, d.nama AS desa, pr.nama AS perusahaan, pr.izin_usaha,
             j.label AS jenis_kanal, u.nama_kawasan_konservasi, u.fungsi_kawasan, u.penutupan_lahan_2022,
             u.kerusakan_eg_2024, u.fungsi_eg_ketebalan, u.tebal_gambut_kelas, u.kedalaman_gambut_bbsdlp,
             u.kematangan_gambut, u.landform, u.lahan_gambut, u.buffer,
             array_to_string(u.tahun_terbakar, ',') AS tahun_terbakar, u.frekuensi_terbakar,
             u.terdampak_kanal, u.program_dmpg, u.prioritas_intervensi, u.luas_ha, u.geom
        FROM analisis.%1$I u
        LEFT JOIN ref.khg k ON k.id = u.khg_id
        LEFT JOIN ref.desa d ON d.id = u.desa_id
        LEFT JOIN ref.perusahaan pr ON pr.id = u.perusahaan_id
        LEFT JOIN ref.jenis_kanal j ON j.kode = u.jenis_kanal$f$, t);
  END LOOP;
END $$;

-- lapisan per KHG (scripts/impor_khg.sh)
CREATE VIEW api.unit_prioritas AS
SELECT u.id, u.unit_id, k.nama AS khg, u.kelas, u.peringkat, u.skor_dampak, u.skor_kelayakan, u.skor_urgensi,
       u.skor_risiko, u.pengelola, u.luas_ha, u.sumber, u.geom
  FROM analisis.unit_prioritas u LEFT JOIN ref.khg k ON k.id = u.khg_id;

CREATE VIEW api.dmpg AS
SELECT d.id, d.program, d.luas_ha, k.nama AS khg, d.sumber, d.geom
  FROM analisis.dmpg d LEFT JOIN ref.khg k ON k.id = d.khg_id;

CREATE VIEW api.jalur_pompa AS
SELECT j.id, j.kode, j.panjang_m, j.angkat_m, j.debit_m3s, j.layanan_ha, k.nama AS khg, j.sumber, j.geom
  FROM peta.jalur_pompa j LEFT JOIN ref.khg k ON k.id = j.khg_id;

CREATE VIEW api.badan_air AS
SELECT b.id, b.nama, k.nama AS khg, b.sumber, b.geom
  FROM peta.badan_air b LEFT JOIN ref.khg k ON k.id = b.khg_id;

-- stasiun TMA + bacaan terakhir; tmat_m positif = muka air di bawah permukaan.
-- bacaan: deret harian sebagai teks JSON [[tanggal, tmat_m], ...] untuk grafik kecil di popup
CREATE VIEW api.stasiun_tma AS
SELECT l.id, l.kode, l.nama, k.nama AS khg, l.sumber,
       l.atribut->>'kode_pt' AS kode_pt, l.atribut->>'unit_id' AS unit_id,
       b.n_bacaan, b.tanggal_awal, b.tanggal_akhir, b.tmat_rata_m, b.tmat_maks_m,
       akhir.tmat_m AS tmat_akhir_m, b.bacaan, l.geom
  FROM peta.logger_tmat l
  LEFT JOIN ref.khg k ON k.id = l.khg_id
  LEFT JOIN LATERAL (
    -- tanggal menurut WIB (bacaan harian disimpan sebagai tengah malam WIB)
    SELECT count(*) AS n_bacaan, min(waktu AT TIME ZONE 'Asia/Jakarta')::date AS tanggal_awal,
           max(waktu AT TIME ZONE 'Asia/Jakarta')::date AS tanggal_akhir,
           round(avg(tmat_m), 2) AS tmat_rata_m, max(tmat_m) AS tmat_maks_m,
           json_agg(json_build_array((waktu AT TIME ZONE 'Asia/Jakarta')::date, tmat_m) ORDER BY waktu)::text AS bacaan
      FROM peta.tmat_bacaan t WHERE t.logger_id = l.id) b ON true
  LEFT JOIN LATERAL (
    SELECT tmat_m FROM peta.tmat_bacaan t WHERE t.logger_id = l.id ORDER BY waktu DESC LIMIT 1) akhir ON true;

CREATE VIEW api.kontur AS
SELECT c.id, c.elevasi_m, k.nama AS khg, c.geom FROM analisis.kontur c LEFT JOIN ref.khg k ON k.id = c.khg_id;
CREATE VIEW api.kontur_lidar AS
SELECT c.id, c.elevasi_m, k.nama AS khg, c.geom FROM analisis.kontur_lidar c LEFT JOIN ref.khg k ON k.id = c.khg_id;

-- refresh statistik oleh role non-owner (dipanggil proses OGC 'refresh-statistik' / cron)
CREATE FUNCTION api.refresh_statistik() RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY api.khg_statistik;
  RETURN now();
END $$;
REVOKE EXECUTE ON FUNCTION api.refresh_statistik() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.refresh_statistik() TO gambut_edit;
GRANT EXECUTE ON FUNCTION alur.ajukan_review(bigint), alur.putuskan(bigint, text, text) TO ogc_writer;

GRANT USAGE ON SCHEMA api TO gambut_baca;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO gambut_baca;
