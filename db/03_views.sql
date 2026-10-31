-- =====================================================================
-- View yang langsung melayani layar UI
-- =====================================================================

-- Status terkini tiap KHG = versi dengan nomor tertinggi
CREATE VIEW alur.v_khg_status AS
SELECT DISTINCT ON (khg_id) khg_id, id AS versi_id, nomor, status, diajukan_oleh, diajukan_at,
       reviewer, diputuskan_at, dibuat_at
  FROM alur.khg_versi
 ORDER BY khg_id, nomor DESC;

-- Layar "Daftar KHG" + panel "Prioritas Tinggi"
-- penyederhanaan: skor_prioritas = 100 x (0.4 porsi terbakar + 0.3 porsi gambut >=3 m + 0.3 hotspot relatif);
--           rumus sementara, ganti sesuai SOP. Jadikan MATERIALIZED VIEW bila > 1 detik.
CREATE VIEW alur.v_khg_daftar AS
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

-- Alert TMAT: bacaan terakhir per logger yang > 0,4 m
CREATE VIEW peta.v_tmat_alert AS
SELECT * FROM (
  SELECT DISTINCT ON (b.logger_id) b.logger_id, l.kode, l.khg_id, b.waktu, b.tmat_m, l.geom
    FROM peta.tmat_bacaan b JOIN peta.logger_tmat l ON l.id = b.logger_id
   ORDER BY b.logger_id, b.waktu DESC) x
 WHERE tmat_m > 0.4;

-- Layar "Dashboard Nasional": satu baris KPI
CREATE VIEW alur.v_dashboard AS
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

-- Panel "Layer" di Workspace Peta: jumlah fitur per layer per KHG
CREATE VIEW peta.v_khg_legenda AS
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

-- Sekat + konteks overlay + nama wilayah (read-only, untuk styling QGIS / poster)
CREATE VIEW peta.v_sekat AS
SELECT s.id, s.kode, s.status, s.jenis_kanal, j.label AS jenis_kanal_label, s.elevasi_kontur_m,
       s.khg_id, k.nama AS nama_khg, pv.singkatan AS provinsi, kb.nama AS kabupaten,
       kc.nama AS kecamatan, d.nama AS desa, pr.nama AS perusahaan, pr.izin_usaha,
       c.fungsi_kawasan, c.penutupan_lahan_2022, c.kerusakan_eg_2024, c.fungsi_eg_ketebalan,
       c.tebal_gambut_kelas, c.kedalaman_gambut_bbsdlp, c.kematangan_gambut, c.landform,
       c.tahun_terbakar, c.frekuensi_terbakar, c.program_dmpg, c.prioritas_intervensi,
       s.qc_flag, s.geom
  FROM peta.sekat s
  LEFT JOIN ref.jenis_kanal j ON j.kode = s.jenis_kanal
  LEFT JOIN ref.khg k ON k.id = s.khg_id
  LEFT JOIN peta.sekat_konteks c ON c.sekat_id = s.id
  LEFT JOIN ref.desa d ON d.id = c.desa_id
  LEFT JOIN ref.kecamatan kc ON kc.id = d.kecamatan_id
  LEFT JOIN ref.kabupaten kb ON kb.id = kc.kabupaten_id
  LEFT JOIN ref.provinsi pv ON pv.id = kb.provinsi_id
  LEFT JOIN ref.perusahaan pr ON pr.id = c.perusahaan_id;

-- Layar "Monitoring Sumur Bor": sumur + debit terakhir
CREATE VIEW peta.v_sumur_bor AS
SELECT s.id, s.kode, d.nama AS desa, k.nama AS nama_khg, s.khg_id, s.kedalaman_m, s.kondisi,
       s.tahun_bangun, s.pelaksana, s.penanggung_jawab, db.tanggal AS tanggal_debit,
       db.debit_lps AS debit_terakhir_lps, s.synced_at, s.geom
  FROM peta.sumur_bor s
  LEFT JOIN ref.desa d ON d.id = s.desa_id
  LEFT JOIN ref.khg k ON k.id = s.khg_id
  LEFT JOIN LATERAL (SELECT tanggal, debit_lps FROM peta.sumur_debit
                      WHERE sumur_id = s.id ORDER BY tanggal DESC LIMIT 1) db ON true;

-- Riwayat perubahan tanpa isi baris (aman untuk dibaca publik): siapa, kapan, fitur apa, kolom apa
CREATE VIEW alur.v_riwayat AS
SELECT p.id, p.waktu, p.tabel, p.fitur_id, p.khg_id, p.aksi, p.via, p.pengguna,
       coalesce(p.data_baru ->> 'kode', p.data_lama ->> 'kode') AS kode,
       CASE WHEN p.aksi = 'U' THEN
         (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p.data_baru) k
           WHERE p.data_baru -> k IS DISTINCT FROM p.data_lama -> k
             AND k NOT IN ('updated_at', 'updated_by', 'updated_via', 'rev', 'created_at', 'created_by')
             -- geometri yang dikirim ulang lewat API (PUT) berubah di digit terakhir; abaikan selisih < 1e-9 derajat
             AND NOT (k = 'geom' AND ST_HausdorffDistance(ST_GeomFromGeoJSON(p.data_lama ->> k),
                                                          ST_GeomFromGeoJSON(p.data_baru ->> k)) < 1e-9))
       END AS kolom_berubah
  FROM alur.perubahan p;
