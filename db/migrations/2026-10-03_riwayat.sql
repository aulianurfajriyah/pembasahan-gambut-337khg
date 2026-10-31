-- Riwayat perubahan publik (tanpa isi baris) untuk Workspace Peta.
-- Jalankan sebagai postgres pada DB yang sudah dibangun; build baru lewat setup.sh sudah menyertakannya.
BEGIN;

-- Riwayat perubahan tanpa isi baris (aman untuk dibaca publik): siapa, kapan, fitur apa, kolom apa
CREATE OR REPLACE VIEW alur.v_riwayat AS
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
GRANT SELECT ON alur.v_riwayat TO gambut_baca;
COMMIT;
