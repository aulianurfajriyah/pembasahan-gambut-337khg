-- Role & hak akses. Password dikirim dari setup.sh:  psql -v pw_reader=... -v pw_writer=... dst.
--   gambut_baca  (grup) : SELECT semua layer + view UI (tanpa log audit/pengguna)
--   gambut_edit  (grup) : + INSERT/UPDATE/DELETE layer perencanaan di schema peta
--   ogc_reader   (login): dipakai pygeoapi untuk koleksi baca-saja (publik)
--   ogc_writer   (login): dipakai pygeoapi untuk transaksi OGC API (app.via = 'api')
--   web_app      (login): backend aplikasi web (set app.pengguna/app.via per transaksi)
--   editor_qgis  (login): contoh akun editor QGIS; produksi: 1 role per orang
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gambut_baca') THEN CREATE ROLE gambut_baca NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gambut_edit') THEN CREATE ROLE gambut_edit NOLOGIN IN ROLE gambut_baca; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ogc_reader')  THEN CREATE ROLE ogc_reader  LOGIN IN ROLE gambut_baca; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ogc_writer')  THEN CREATE ROLE ogc_writer  LOGIN IN ROLE gambut_edit; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_app')     THEN CREATE ROLE web_app     LOGIN IN ROLE gambut_edit; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'editor_qgis') THEN CREATE ROLE editor_qgis LOGIN IN ROLE gambut_edit; END IF;
END $$;
ALTER ROLE ogc_reader  PASSWORD :'pw_reader'  CONNECTION LIMIT 20;
ALTER ROLE ogc_writer  PASSWORD :'pw_writer'  CONNECTION LIMIT 10;
ALTER ROLE web_app     PASSWORD :'pw_web'     CONNECTION LIMIT 20;
ALTER ROLE editor_qgis PASSWORD :'pw_editor';
ALTER ROLE ogc_writer  SET app.via = 'api';
ALTER ROLE editor_qgis SET app.via = 'qgis';
ALTER ROLE ogc_reader  SET default_transaction_read_only = on;
ALTER ROLE ogc_reader  SET statement_timeout = '30s';

-- baca
GRANT USAGE ON SCHEMA ref, peta, analisis, alur TO gambut_baca;
GRANT SELECT ON ALL TABLES IN SCHEMA ref, peta, analisis TO gambut_baca;
GRANT SELECT ON alur.khg_versi, alur.template_poster, alur.ekspor_poster,
                alur.v_khg_status, alur.v_khg_daftar, alur.v_dashboard TO gambut_baca;

-- edit layer perencanaan (bukan layer impor/analisis)
GRANT INSERT, UPDATE, DELETE ON peta.sungai, peta.kanal, peta.sekat, peta.sekat_konteks, peta.sekat_bangunan,
  peta.pompa, peta.pintu_air, peta.posko_karhutla, peta.logger_tmat, peta.tmat_bacaan,
  peta.sumur_bor, peta.sumur_debit, peta.konsesi TO gambut_edit;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA peta TO gambut_edit;
GRANT SELECT, INSERT, UPDATE ON alur.komentar, alur.ekspor_poster TO gambut_edit;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA alur TO gambut_edit;
GRANT SELECT ON alur.perubahan, alur.komentar TO gambut_edit;   -- riwayat & diff untuk UI
GRANT SELECT ON alur.v_riwayat TO gambut_baca;                  -- riwayat tanpa isi baris

-- audit & versi: hanya lewat trigger (SECURITY DEFINER) -> editor tidak bisa memalsukan log
ALTER FUNCTION alur.catat_perubahan() SECURITY DEFINER SET search_path = pg_catalog, public;
ALTER FUNCTION alur.versi_terbuka(int) SECURITY DEFINER SET search_path = pg_catalog, public;
ALTER FUNCTION alur.tandai_dicetak() SECURITY DEFINER SET search_path = pg_catalog, public;
ALTER FUNCTION alur.ajukan_review(bigint) SECURITY DEFINER SET search_path = pg_catalog, public;
ALTER FUNCTION alur.putuskan(bigint, text, text) SECURITY DEFINER SET search_path = pg_catalog, public;
REVOKE EXECUTE ON FUNCTION alur.ajukan_review(bigint), alur.putuskan(bigint, text, text),
                           alur.versi_terbuka(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION alur.ajukan_review(bigint), alur.putuskan(bigint, text, text) TO web_app, editor_qgis;
