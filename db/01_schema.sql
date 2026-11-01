-- =====================================================================
-- Pembasahan Gambut 337 KHG — skema inti
--   ref  : referensi wilayah, KHG, perusahaan, lookup (jarang berubah)
--   peta : fitur spasial yang di-CRUD dari QGIS & Web
--   alur : versi KHG, review, komentar, audit, ekspor poster
--   analisis : layer analisis besar, baca-saja (unit tematik, kontur)
-- Semua geometri EPSG:4326, PK bigint identity (aman untuk QGIS).
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS peta;
CREATE SCHEMA IF NOT EXISTS alur;
CREATE SCHEMA IF NOT EXISTS analisis;

-- ---------------------------------------------------------------- ref
CREATE TABLE ref.provinsi (
  id        smallint PRIMARY KEY,           -- kode BPS
  nama      text NOT NULL UNIQUE,
  singkatan text NOT NULL,                  -- label UI: "Kalteng"
  pulau     text NOT NULL
);
INSERT INTO ref.provinsi VALUES      -- kode Kemendagri/BPS (38 provinsi)
 (11,'Aceh','Aceh','Pulau Sumatera'),(12,'Sumatera Utara','Sumut','Pulau Sumatera'),
 (13,'Sumatera Barat','Sumbar','Pulau Sumatera'),(14,'Riau','Riau','Pulau Sumatera'),
 (15,'Jambi','Jambi','Pulau Sumatera'),(16,'Sumatera Selatan','Sumsel','Pulau Sumatera'),
 (17,'Bengkulu','Bengkulu','Pulau Sumatera'),(18,'Lampung','Lampung','Pulau Sumatera'),
 (19,'Kepulauan Bangka Belitung','Babel','Pulau Sumatera'),(21,'Kepulauan Riau','Kepri','Pulau Sumatera'),
 (31,'DKI Jakarta','DKI','Pulau Jawa'),(32,'Jawa Barat','Jabar','Pulau Jawa'),
 (33,'Jawa Tengah','Jateng','Pulau Jawa'),(34,'DI Yogyakarta','DIY','Pulau Jawa'),
 (35,'Jawa Timur','Jatim','Pulau Jawa'),(36,'Banten','Banten','Pulau Jawa'),
 (51,'Bali','Bali','Kepulauan Nusa Tenggara'),(52,'Nusa Tenggara Barat','NTB','Kepulauan Nusa Tenggara'),
 (53,'Nusa Tenggara Timur','NTT','Kepulauan Nusa Tenggara'),
 (61,'Kalimantan Barat','Kalbar','Pulau Kalimantan'),(62,'Kalimantan Tengah','Kalteng','Pulau Kalimantan'),
 (63,'Kalimantan Selatan','Kalsel','Pulau Kalimantan'),(64,'Kalimantan Timur','Kaltim','Pulau Kalimantan'),
 (65,'Kalimantan Utara','Kaltara','Pulau Kalimantan'),
 (71,'Sulawesi Utara','Sulut','Pulau Sulawesi'),(72,'Sulawesi Tengah','Sulteng','Pulau Sulawesi'),
 (73,'Sulawesi Selatan','Sulsel','Pulau Sulawesi'),(74,'Sulawesi Tenggara','Sultra','Pulau Sulawesi'),
 (75,'Gorontalo','Gorontalo','Pulau Sulawesi'),(76,'Sulawesi Barat','Sulbar','Pulau Sulawesi'),
 (81,'Maluku','Maluku','Kepulauan Maluku'),(82,'Maluku Utara','Malut','Kepulauan Maluku'),
 (91,'Papua','Papua','Pulau Papua'),(92,'Papua Barat','Papua Bar.','Pulau Papua'),
 (93,'Papua Selatan','Papua Sel.','Pulau Papua'),(94,'Papua Tengah','Papua Teng.','Pulau Papua'),
 (95,'Papua Pegunungan','Papua Peg.','Pulau Papua'),(96,'Papua Barat Daya','PBD','Pulau Papua');

CREATE TABLE ref.kabupaten (
  id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provinsi_id smallint NOT NULL REFERENCES ref.provinsi,
  nama        text NOT NULL,
  UNIQUE (provinsi_id, nama)
);
CREATE TABLE ref.kecamatan (
  id           int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kabupaten_id int NOT NULL REFERENCES ref.kabupaten,
  nama         text NOT NULL,
  UNIQUE (kabupaten_id, nama)
);
CREATE TABLE ref.desa (
  id                    int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kecamatan_id          int NOT NULL REFERENCES ref.kecamatan,
  nama                  text NOT NULL,
  kode_bps              text UNIQUE,              -- diisi bila tersedia
  target_pemulihan_2026 boolean NOT NULL DEFAULT false,  -- termasuk 2004 desa target
  geom                  geometry(MultiPolygon,4326),     -- terisi untuk desa target (AOI)
  UNIQUE (kecamatan_id, nama)
);
CREATE INDEX ON ref.desa USING gist (geom);

CREATE TABLE ref.khg (
  id                int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kode              text UNIQUE,                  -- "KHG.14.12"; belum ada di data sumber
  nama              text NOT NULL UNIQUE,
  provinsi_utama_id smallint NOT NULL REFERENCES ref.provinsi,
  target_2026       boolean NOT NULL DEFAULT false,  -- KHG di 2004 desa target (345 KHG)
  luas_ha           numeric(12,2),
  geom              geometry(MultiPolygon,4326),     -- dissolve unit analisis nasional
  -- batas disederhanakan ±50 m (3,2 juta -> ±150 ribu titik) untuk ubin peta zoom < 8 (api.khg_ubin)
  geom_sederhana    geometry GENERATED ALWAYS AS (ST_SimplifyPreserveTopology(geom, 0.0005)) STORED
);
CREATE INDEX ON ref.khg USING gist (geom);

CREATE TABLE ref.perusahaan (
  id         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nama       text NOT NULL UNIQUE,
  izin_usaha text                                 -- Perkebunan Kelapa Sawit, PBPH, ...
);

-- Lookup: tabel (bukan ENUM) supaya QGIS Value Relation & dropdown web langsung pakai
CREATE TABLE ref.jenis_kanal   (kode smallint PRIMARY KEY, label text NOT NULL UNIQUE);
INSERT INTO ref.jenis_kanal VALUES (1,'Kanal Primer'),(2,'Kanal Sekunder'),(3,'Kanal Tersier');

CREATE TABLE ref.status_kanal  (kode text PRIMARY KEY, label text NOT NULL, warna text);
INSERT INTO ref.status_kanal VALUES
 ('aktif','Aktif','#22b8cf'),('tidak_aktif','Tidak aktif','#9aa0a6'),('tersumbat','Tersumbat','#b08968');

CREATE TABLE ref.status_sekat  (kode text PRIMARY KEY, label text NOT NULL, warna text);
INSERT INTO ref.status_sekat VALUES
 ('rencana','Rencana','#c9a227'),('existing','Existing','#8b5a2b'),
 ('rusak','Rusak','#d9480f'),('dibongkar','Dibongkar','#868e96');

CREATE TABLE ref.status_pompa  (kode text PRIMARY KEY, label text NOT NULL, warna text);
INSERT INTO ref.status_pompa VALUES
 ('rencana','Rencana','#7048e8'),('terpasang','Terpasang','#5f3dc4'),('rusak','Rusak','#d9480f');

CREATE TABLE ref.kondisi_sumur (kode text PRIMARY KEY, label text NOT NULL, warna text);
INSERT INTO ref.kondisi_sumur VALUES
 ('berfungsi','Berfungsi','#2f9e44'),('rusak','Rusak','#e03131'),
 ('belum_verifikasi','Belum verifikasi','#f08c00');

CREATE TABLE ref.status_alur   (kode text PRIMARY KEY, label text NOT NULL, urutan smallint, warna text);
INSERT INTO ref.status_alur VALUES
 ('draft','Draft',1,'#868e96'),('proses','Proses',2,'#1098ad'),('review','Review',3,'#f08c00'),
 ('revisi','Revisi',4,'#e8590c'),('approved','Approved',5,'#2f9e44'),('printed','Printed',6,'#1c7ed6');

-- Varian DEM per KHG (scripts/impor_paket.py). Lapisan yang bergantung pada DEM (pompa, jalur pompa, kanal
-- terpilih, sekat usulan, sub-KHG) disimpan per varian dengan sumber = 'IMPOR_KHG:<kode>'; web memilih varian
-- yang tampil, statistik KHG hanya menghitung varian utama (ref.varian_utama).
CREATE TABLE ref.varian_dem (
  khg_id  int NOT NULL REFERENCES ref.khg,
  kode    text NOT NULL CHECK (kode ~ '^[A-Z0-9]+$'),   -- LIDAR, DEMNAS, WORLDDEM, BRGM, ...
  label   text NOT NULL,                               -- "LiDAR 25 m"
  utama   boolean NOT NULL DEFAULT false,
  urutan  smallint NOT NULL DEFAULT 1,
  catatan text,
  sumber  text GENERATED ALWAYS AS ('IMPOR_KHG:' || kode) STORED,
  PRIMARY KEY (khg_id, kode)
);
CREATE UNIQUE INDEX varian_dem_satu_utama ON ref.varian_dem (khg_id) WHERE utama;

-- diisi dari data saat load
CREATE TABLE ref.fungsi_kawasan  (kode text PRIMARY KEY, label text NOT NULL);
CREATE TABLE ref.penutupan_lahan (nama text PRIMARY KEY);
CREATE TABLE ref.kerusakan_eg    (nama text PRIMARY KEY, urutan smallint);

-- ---------------------------------------------------------------- peta
-- Kolom meta (khg_id, created_*, updated_*, rev) ditambahkan ke semua tabel peta
-- oleh blok DO di bawah — satu definisi, tidak diulang per tabel.
CREATE TABLE peta.sungai (
  id     bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  nama   text,
  sumber text,
  geom   geometry(MultiLineString,4326) NOT NULL
);
CREATE TABLE peta.kanal (
  id          bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode        text,                                   -- "K-05"
  jenis_kanal smallint REFERENCES ref.jenis_kanal,
  status      text REFERENCES ref.status_kanal,       -- NULL = belum disurvei (dicek validasi)
  keterangan  text,                                   -- "survei lapangan Sep 2026"
  sumber      text,                                   -- 'OSM_2025' untuk hasil load
  id_asal     bigint,                                 -- OBJECTID kanal seamless OSM
  dipilih_digunakan boolean NOT NULL DEFAULT false,   -- kanal terpilih untuk rencana pembasahan
  geom        geometry(MultiLineString,4326) NOT NULL,
  panjang_m   numeric GENERATED ALWAYS AS (round(ST_Length(geom::geography)::numeric,1)) STORED
);
CREATE TABLE peta.sekat (
  id               bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode             text,                              -- "SK-24", unik per KHG
  status           text NOT NULL DEFAULT 'rencana' REFERENCES ref.status_sekat,
  kanal_id         bigint REFERENCES peta.kanal ON DELETE SET NULL,
  id_kontur_asal   bigint,                            -- Id garis kontur (Kontur_108_KHG) pembentuk titik
  jenis_kanal      smallint REFERENCES ref.jenis_kanal,
  panjang_kanal_m  numeric,
  elevasi_kontur_m numeric(8,2),
  sumber           text NOT NULL DEFAULT 'manual',    -- 'BRGM_PPEG_2026' untuk hasil load
  fid_asal         bigint UNIQUE,                     -- fid_sekat di GeoPackage
  qc_flag          text,
  dipilih_bangun   boolean NOT NULL DEFAULT false,  -- sekat final: dipilih operator untuk dibangun
  geom             geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.sekat_konteks (   -- 1:1, hasil overlay BRGM; bisa dihitung ulang
  sekat_id                bigint PRIMARY KEY REFERENCES peta.sekat ON DELETE CASCADE,
  desa_id                 int REFERENCES ref.desa,
  perusahaan_id           int REFERENCES ref.perusahaan,
  nama_kawasan_konservasi text,
  fungsi_kawasan          text REFERENCES ref.fungsi_kawasan,
  penutupan_lahan_2022    text REFERENCES ref.penutupan_lahan,
  kerusakan_eg_2024       text REFERENCES ref.kerusakan_eg,
  fungsi_eg_250k          text,
  fungsi_eg_ketebalan     text,
  tebal_gambut_kelas      text,
  tanah_gambut            text,
  sk_feg_50k              text,
  kedalaman_gambut_bbsdlp text,
  kematangan_gambut       text,
  landform                text,
  gambut_bbsdlp           boolean,
  lahan_gambut            boolean,
  buffer                  text,
  tahun_terbakar          smallint[],
  frekuensi_terbakar      text,
  terdampak_kanal         boolean,
  program_dmpg            text,
  prioritas_intervensi    text,
  luas_poligon_analisis_ha numeric
);
CREATE TABLE peta.sekat_bangunan (  -- 1:1, detail sekat existing (infrastruktur hidrologis)
  sekat_id        bigint PRIMARY KEY REFERENCES peta.sekat ON DELETE CASCADE,
  kodefikasi      text,                               -- "KSE-RIAU-2017-118" (tidak unik di sumber)
  kode_rencana    text,
  khg_nama_asal   text,
  tipe            text,                               -- "KSE-2L-P-3"
  jenis_bangunan  text,                               -- Sekat Kanal / Spillway / Non Spillway
  bahan           text,                               -- Kayu / Beton
  tahun_bangun    smallint,
  anggaran        text,
  kegiatan        text,
  pekerjaan       text,
  pelaksana       text,
  perusahaan_id   int REFERENCES ref.perusahaan,
  perijinan       text,
  kode_pt         text,
  tahun_data      smallint,
  keterangan      text,                               -- REALISASI / RENCANA
  sumber_data     text,
  sisfo_id        text,
  detail          text
);
CREATE TABLE peta.pompa (
  id                 bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode               text,                            -- "P-04"
  status             text NOT NULL DEFAULT 'rencana' REFERENCES ref.status_pompa,
  kapasitas_m3_menit numeric(8,2),
  sungai_id          bigint REFERENCES peta.sungai ON DELETE SET NULL,
  kanal_id           bigint REFERENCES peta.kanal ON DELETE SET NULL,
  jarak_sungai_m     numeric(8,1),
  estimasi_layanan_ha numeric(10,1),
  skor               numeric(3,2) CHECK (skor BETWEEN 0 AND 1),
  skor_sumber_air    numeric(3,2) CHECK (skor_sumber_air BETWEEN 0 AND 1),
  skor_kanal         numeric(3,2) CHECK (skor_kanal BETWEEN 0 AND 1),
  skor_gambut        numeric(3,2) CHECK (skor_gambut BETWEEN 0 AND 1),
  skor_terbakar      numeric(3,2) CHECK (skor_terbakar BETWEEN 0 AND 1),
  sumber             text,
  atribut            jsonb,                           -- atribut hidrolika dari sumber (scripts/impor_khg.sh)
  geom               geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.jalur_pompa (     -- rute pompa -> lahan sasaran lewat kanal (tanpa kolom meta)
  id         bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode       text,                                    -- route_id sumber
  panjang_m  numeric(10,1),
  angkat_m   numeric(6,2),                            -- lift
  debit_m3s  numeric(8,3),
  layanan_ha numeric(10,1),
  sumber     text,
  atribut    jsonb,
  khg_id     int REFERENCES ref.khg,
  geom       geometry(MultiLineString,4326) NOT NULL
);
CREATE INDEX ON peta.jalur_pompa USING gist (geom);
CREATE INDEX ON peta.jalur_pompa (khg_id);
CREATE TABLE peta.badan_air (       -- sungai/danau berupa poligon (tanpa kolom meta)
  id     bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  nama   text,
  sumber text,
  khg_id int REFERENCES ref.khg,
  geom   geometry(MultiPolygon,4326) NOT NULL
);
CREATE INDEX ON peta.badan_air USING gist (geom);
CREATE INDEX ON peta.badan_air (khg_id);
CREATE TABLE peta.pintu_air (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode text, keterangan text,
  tahun_bangun smallint, bahan text, pelaksana text,
  perusahaan_id int REFERENCES ref.perusahaan,
  sumber text,
  geom geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.posko_karhutla (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  nama text, keterangan text,
  geom geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.logger_tmat (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode text UNIQUE, ext_id text UNIQUE,
  nama text, sumber text,
  atribut jsonb,                                       -- ringkasan stasiun dari sumber (perusahaan, unit, statistik)
  geom geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.hotspot (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  waktu            timestamptz NOT NULL,
  satelit          text,                              -- NOAA20, NOAA21, SNPP, Terra, Aqua
  instrumen        text,                              -- VIIRS / MODIS
  kepercayaan      text CHECK (kepercayaan IN ('tinggi','sedang','rendah')),
  kepercayaan_nilai smallint,                         -- MODIS 0-100 (bila ada)
  frp_mw           numeric(8,2),
  brightness_k     numeric(6,2),
  siang_malam      char(1),
  provinsi         text, kabupaten text, kecamatan text, desa text,  -- dari sumber, tanpa FK
  format_sumber    text NOT NULL,                     -- 'firms' | 'kml_sipongi'
  berkas_sumber    text,
  sumber           text,                              -- NULL = load nasional; diisi oleh impor per KHG
  geom geometry(Point,4326) NOT NULL
);
CREATE TABLE peta.areal_terbakar (   -- overlay 2015-2026: 1 poligon = 1 kombinasi tahun
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  tahun_terbakar smallint[] NOT NULL,
  frekuensi      smallint GENERATED ALWAYS AS (cardinality(tahun_terbakar)) STORED,
  sumber         text,
  geom geometry(MultiPolygon,4326) NOT NULL
);
CREATE TABLE peta.ketebalan_gambut (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kelas text,                                          -- "4.0 - 4.5 meter"
  tebal_min_m numeric(4,1), tebal_max_m numeric(4,1),
  geom geometry(MultiPolygon,4326) NOT NULL
);
CREATE TABLE peta.konsesi (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  perusahaan_id int REFERENCES ref.perusahaan,
  jenis text,                                          -- izin usaha: PBPH, Perkebunan Kelapa Sawit, ...
  sumber text,
  geom geometry(MultiPolygon,4326) NOT NULL
);
CREATE TABLE peta.sumur_bor (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kode text UNIQUE,                                    -- "SB-14-0412"
  desa_id int REFERENCES ref.desa,
  kedalaman_m numeric(5,1),
  kondisi text NOT NULL DEFAULT 'belum_verifikasi' REFERENCES ref.kondisi_sumur,
  tahun_bangun smallint,
  pelaksana text,                                      -- "Eks. BRGM"
  penanggung_jawab text,                               -- "MPA Teluk Meranti"
  catatan text,
  ext_id text UNIQUE, synced_at timestamptz,
  geom geometry(Point,4326) NOT NULL
);

-- time series (non-spasial)
CREATE TABLE peta.tmat_bacaan (
  logger_id bigint NOT NULL REFERENCES peta.logger_tmat ON DELETE CASCADE,
  waktu     timestamptz NOT NULL,
  tmat_m    numeric(5,2) NOT NULL,                     -- kedalaman muka air tanah (m, positif = di bawah permukaan)
  PRIMARY KEY (logger_id, waktu)
);
CREATE TABLE peta.sumur_debit (
  sumur_id  bigint NOT NULL REFERENCES peta.sumur_bor ON DELETE CASCADE,
  tanggal   date NOT NULL,
  debit_lps numeric(6,2),
  catatan   text,
  PRIMARY KEY (sumur_id, tanggal)
);

-- kolom meta + index untuk semua tabel spasial peta
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sungai','kanal','sekat','pompa','pintu_air','posko_karhutla',
    'logger_tmat','hotspot','areal_terbakar','ketebalan_gambut','konsesi','sumur_bor'] LOOP
    EXECUTE format($f$
      ALTER TABLE peta.%1$I
        ADD COLUMN khg_id      int REFERENCES ref.khg,
        ADD COLUMN created_at  timestamptz NOT NULL DEFAULT now(),
        ADD COLUMN created_by  text,
        ADD COLUMN updated_at  timestamptz NOT NULL DEFAULT now(),
        ADD COLUMN updated_by  text,
        ADD COLUMN updated_via text CHECK (updated_via IN ('qgis','web','api','sync','import')),
        ADD COLUMN rev         int NOT NULL DEFAULT 1;
      CREATE INDEX ON peta.%1$I USING gist (geom);
      CREATE INDEX ON peta.%1$I (khg_id);$f$, t);
  END LOOP;
END $$;
CREATE UNIQUE INDEX ON peta.sekat (khg_id, kode);
CREATE UNIQUE INDEX ON peta.pompa (khg_id, kode);
CREATE UNIQUE INDEX ON peta.kanal (khg_id, kode);
CREATE INDEX ON peta.sekat (status);
CREATE INDEX ON peta.sekat (khg_id, status);
CREATE INDEX ON peta.sekat (khg_id) WHERE dipilih_bangun;
CREATE INDEX ON peta.kanal (khg_id) WHERE dipilih_digunakan;
CREATE INDEX ON peta.hotspot (waktu);
CREATE INDEX ON peta.areal_terbakar USING gin (tahun_terbakar);
CREATE INDEX ON peta.kanal (sumber, id_asal);
CREATE INDEX ON peta.sekat (kanal_id);
CREATE INDEX ON peta.sekat_konteks (desa_id);
CREATE INDEX ON peta.sekat_konteks (perusahaan_id);

-- ---------------------------------------------------------------- alur
CREATE TABLE alur.pengguna (
  id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username text NOT NULL UNIQUE,     -- = role PG untuk editor QGIS, = app.pengguna untuk Web
  nama     text NOT NULL,            -- "R. Siregar"
  instansi text,                     -- "KLH", "Dit. PPEG"
  peran    text NOT NULL CHECK (peran IN ('analis','reviewer','admin'))
);

CREATE TABLE alur.khg_versi (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  khg_id           int NOT NULL REFERENCES ref.khg,
  nomor            int NOT NULL,                       -- v14
  status           text NOT NULL DEFAULT 'draft' REFERENCES ref.status_alur,
  dibuat_at        timestamptz NOT NULL DEFAULT now(),
  diajukan_oleh    text,
  diajukan_at      timestamptz,
  reviewer         text,
  diputuskan_at    timestamptz,
  catatan_reviewer text,
  validasi         jsonb,                              -- snapshot hasil alur.validasi_khg
  UNIQUE (khg_id, nomor)
);
-- paling banyak satu versi terbuka (bisa diedit) per KHG
CREATE UNIQUE INDEX khg_versi_satu_terbuka ON alur.khg_versi (khg_id)
  WHERE status IN ('draft','proses','review','revisi');

CREATE TABLE alur.perubahan (      -- audit semua edit peta.* (QGIS maupun Web)
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  waktu     timestamptz NOT NULL DEFAULT now(),
  tabel     text NOT NULL,
  fitur_id  bigint NOT NULL,
  khg_id    int REFERENCES ref.khg,
  versi_id  bigint REFERENCES alur.khg_versi,
  aksi      char(1) NOT NULL CHECK (aksi IN ('I','U','D')),
  via       text NOT NULL,
  pengguna  text NOT NULL,
  data_lama jsonb,
  data_baru jsonb
);
CREATE INDEX ON alur.perubahan (versi_id);
CREATE INDEX ON alur.perubahan (tabel, fitur_id);
CREATE INDEX ON alur.perubahan (khg_id, waktu DESC);

CREATE TABLE alur.komentar (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  versi_id   bigint NOT NULL REFERENCES alur.khg_versi ON DELETE CASCADE,
  tabel      text,                                     -- NULL = komentar level KHG
  fitur_id   bigint,
  parent_id  bigint REFERENCES alur.komentar ON DELETE CASCADE,
  pengguna   text NOT NULL,
  isi        text NOT NULL,
  selesai    boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((tabel IS NULL) = (fitur_id IS NULL))
);
CREATE INDEX ON alur.komentar (versi_id);
CREATE INDEX ON alur.komentar (tabel, fitur_id);

CREATE TABLE alur.template_poster (
  id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nama      text NOT NULL,                             -- "Poster Pembasahan v3 · QGIS"
  versi     text,
  file_path text NOT NULL,                             -- .qpt layout QGIS
  aktif     boolean NOT NULL DEFAULT true
);
CREATE TABLE alur.ekspor_poster (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  versi_id      bigint NOT NULL REFERENCES alur.khg_versi,
  template_id   int NOT NULL REFERENCES alur.template_poster,
  batch_id      uuid,                                  -- "Antrian Ekspor Batch"
  kertas        text NOT NULL CHECK (kertas IN ('A0','A1','A2','A3')),
  orientasi     text NOT NULL CHECK (orientasi IN ('lanskap','potret')),
  periode_mulai date, periode_selesai date,            -- periode hotspot
  dpi           smallint NOT NULL DEFAULT 300,
  status        text NOT NULL DEFAULT 'menunggu'
                CHECK (status IN ('menunggu','merender','selesai','gagal','dibatalkan')),
  progres       smallint NOT NULL DEFAULT 0 CHECK (progres BETWEEN 0 AND 100),
  file_path     text,
  ukuran_bytes  bigint,
  pesan_error   text,
  dibuat_oleh   text NOT NULL DEFAULT session_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  selesai_at    timestamptz
);
CREATE INDEX ON alur.ekspor_poster (status, created_at);
CREATE INDEX ON alur.ekspor_poster (batch_id);

-- ---------------------------------------------------------------- analisis (baca-saja)
-- Unit analisis integrasi tematik PPEG (hasil intersect desa x KHG x konsesi x kawasan x gambut x terbakar).
CREATE TABLE analisis.unit_target_2026 (   -- 2004 desa target (Analysis_2004_Desa...)
  id                      bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  khg_id                  int REFERENCES ref.khg,   -- NULL = NON KHG
  desa_id                 int REFERENCES ref.desa,
  perusahaan_id           int REFERENCES ref.perusahaan,
  jenis_kanal             smallint REFERENCES ref.jenis_kanal,
  nama_kawasan_konservasi text,
  fungsi_kawasan          text REFERENCES ref.fungsi_kawasan,
  penutupan_lahan_2022    text REFERENCES ref.penutupan_lahan,
  kerusakan_eg_2024       text REFERENCES ref.kerusakan_eg,
  fungsi_eg_250k          text,
  fungsi_eg_ketebalan     text,
  tebal_gambut_kelas      text,
  tanah_gambut            text,
  sk_feg_50k              text,
  kedalaman_gambut_bbsdlp text,
  kematangan_gambut       text,
  landform                text,
  gambut_bbsdlp           boolean,
  lahan_gambut            boolean,
  buffer                  text,
  tahun_terbakar          smallint[],
  frekuensi_terbakar      text,
  terdampak_kanal         boolean,
  program_dmpg            text,
  prioritas_intervensi    text,
  luas_ha                 numeric,
  geom                    geometry(MultiPolygon,4326) NOT NULL
);
CREATE TABLE analisis.unit_nasional (LIKE analisis.unit_target_2026 INCLUDING ALL);  -- ALL_Analysis nasional

CREATE TABLE analisis.kontur (             -- Kontur_108_KHG_Target_BRGM
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  khg_id int REFERENCES ref.khg,
  elevasi_m numeric(8,2),
  geom geometry(MultiLineString,4326) NOT NULL
);
CREATE TABLE analisis.kontur_lidar (       -- LIDAR_Kontur_50cm (Riau, Jambi, Sumsel)
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  khg_id int REFERENCES ref.khg,
  elevasi_m numeric(8,2),
  geom geometry(MultiLineString,4326) NOT NULL
);

-- Lapisan per KHG dari scripts/impor_khg.sh (sub-KHG berskor prioritas, pembagian program DMPG)
CREATE TABLE analisis.unit_prioritas (
  id             bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  unit_id        text NOT NULL,                     -- "KHG_KAHSEB_S01"
  kelas          text,
  peringkat      smallint,
  skor_dampak    numeric(6,4),
  skor_kelayakan numeric(6,4),
  skor_urgensi   numeric(6,4),
  skor_risiko    numeric(6,4),
  pengelola      text,
  luas_ha        numeric(12,1),
  sumber         text,
  atribut        jsonb,                             -- seluruh kolom indikator sumber
  khg_id         int REFERENCES ref.khg,
  geom           geometry(MultiPolygon,4326) NOT NULL
);
CREATE INDEX ON analisis.unit_prioritas USING gist (geom);
CREATE INDEX ON analisis.unit_prioritas (khg_id);
CREATE TABLE analisis.dmpg (
  id      bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  program text NOT NULL,                           -- "Intervensi KLH/BPLH", "Intervensi Perusahaan", ...
  luas_ha numeric(12,1),
  sumber  text,
  khg_id  int REFERENCES ref.khg,
  geom    geometry(MultiPolygon,4326) NOT NULL
);
CREATE INDEX ON analisis.dmpg USING gist (geom);
CREATE INDEX ON analisis.dmpg (khg_id);
-- index dibuat setelah load (lebih cepat) — lihat 07_load_bluebook.sql
