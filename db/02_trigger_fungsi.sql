-- =====================================================================
-- Trigger & fungsi: audit/versi otomatis untuk edit dari QGIS maupun Web.
-- Web: di awal transaksi  SET LOCAL app.pengguna = 'd.putri'; SET LOCAL app.via = 'web';
-- QGIS: login dengan role PG per editor -> pengguna = session_user, via = 'qgis'.
-- OGC API (pygeoapi): role ogc_writer punya default  app.via = 'api'  (lihat 05_roles.sql).
-- =====================================================================

-- Versi terbuka (draft/proses/review/revisi) untuk sebuah KHG; dibuat otomatis bila belum ada
CREATE FUNCTION alur.versi_terbuka(p_khg int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE vid bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('khg_versi'), p_khg);
  SELECT id INTO vid FROM alur.khg_versi
   WHERE khg_id = p_khg AND status IN ('draft','proses','review','revisi');
  IF vid IS NULL THEN
    INSERT INTO alur.khg_versi (khg_id, nomor)
    SELECT p_khg, coalesce(max(nomor), 0) + 1 FROM alur.khg_versi WHERE khg_id = p_khg
    RETURNING id INTO vid;
  END IF;
  RETURN vid;
END $$;

-- true bila baris ikut dihitung/ditampilkan secara bawaan: bukan data varian DEM, atau data varian utama
CREATE FUNCTION ref.varian_utama(p_khg int, p_sumber text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_sumber IS NULL OR p_sumber NOT LIKE 'IMPOR_KHG:%'
      OR EXISTS (SELECT 1 FROM ref.varian_dem v WHERE v.khg_id = p_khg AND v.utama AND v.sumber = p_sumber)
$$;

-- BEFORE INSERT/UPDATE: khg_id dari geometri (bila kosong), kolom meta, rev
CREATE FUNCTION alur.isi_meta() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  u text := coalesce(nullif(current_setting('app.pengguna', true), ''), session_user);
  v text := coalesce(nullif(current_setting('app.via', true), ''), 'qgis');
BEGIN
  IF NEW.khg_id IS NULL THEN
    SELECT k.id INTO NEW.khg_id FROM ref.khg k WHERE ST_Intersects(k.geom, NEW.geom) LIMIT 1;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := now();
    NEW.created_by := u;
    NEW.rev := 1;
  ELSE
    NEW.created_at := OLD.created_at;
    NEW.created_by := OLD.created_by;
    NEW.rev := OLD.rev + 1;
  END IF;
  NEW.updated_at := now();
  NEW.updated_by := u;
  NEW.updated_via := v;
  RETURN NEW;
END $$;

-- BEFORE INSERT: kode otomatis per KHG (P-10, SK-25) bila tidak diisi
CREATE FUNCTION alur.isi_kode() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prefix text := TG_ARGV[0];
BEGIN
  IF NEW.kode IS NULL AND NEW.khg_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(TG_TABLE_NAME), NEW.khg_id);
    EXECUTE format(
      'SELECT %L || (coalesce(max(substring(kode FROM ''\d+$'')::int), 0) + 1)
         FROM peta.%I WHERE khg_id = $1 AND kode ~ ''\d+$''', prefix || '-', TG_TABLE_NAME)
      INTO NEW.kode USING NEW.khg_id;
  END IF;
  RETURN NEW;
END $$;

-- AFTER INSERT/UPDATE/DELETE: log ke alur.perubahan, dikaitkan ke versi terbuka KHG
CREATE FUNCTION alur.catat_perubahan() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  meta text[] := ARRAY['created_at','created_by','updated_at','updated_by','updated_via','rev'];
  lama jsonb; baru jsonb; k int;
BEGIN
  IF TG_OP <> 'INSERT' THEN lama := to_jsonb(OLD) - meta; END IF;
  IF TG_OP <> 'DELETE' THEN baru := to_jsonb(NEW) - meta; END IF;
  IF TG_OP = 'UPDATE' AND lama = baru THEN RETURN NULL; END IF;   -- simpan tanpa perubahan
  k := coalesce((baru->>'khg_id')::int, (lama->>'khg_id')::int);
  INSERT INTO alur.perubahan (tabel, fitur_id, khg_id, versi_id, aksi, via, pengguna, data_lama, data_baru)
  VALUES (TG_TABLE_NAME, coalesce(baru->>'id', lama->>'id')::bigint, k,
          CASE WHEN k IS NOT NULL THEN alur.versi_terbuka(k) END,
          left(TG_OP, 1),
          coalesce(nullif(current_setting('app.via', true), ''), 'qgis'),
          coalesce(nullif(current_setting('app.pengguna', true), ''), session_user),
          lama, baru);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  -- meta untuk semua tabel spasial peta
  FOREACH t IN ARRAY ARRAY['sungai','kanal','sekat','pompa','pintu_air','posko_karhutla',
    'logger_tmat','hotspot','areal_terbakar','ketebalan_gambut','konsesi','sumur_bor'] LOOP
    EXECUTE format('CREATE TRIGGER a_meta BEFORE INSERT OR UPDATE ON peta.%I
                    FOR EACH ROW EXECUTE FUNCTION alur.isi_meta()', t);
  END LOOP;
  -- audit hanya untuk layer perencanaan yang diedit analis
  -- (hotspot, areal terbakar, ketebalan gambut = data impor, tidak diaudit)
  FOREACH t IN ARRAY ARRAY['sungai','kanal','sekat','pompa','pintu_air','posko_karhutla',
    'logger_tmat','konsesi','sumur_bor'] LOOP
    EXECUTE format('CREATE TRIGGER z_audit AFTER INSERT OR UPDATE OR DELETE ON peta.%I
                    FOR EACH ROW EXECUTE FUNCTION alur.catat_perubahan()', t);
  END LOOP;
END $$;
CREATE TRIGGER b_kode BEFORE INSERT ON peta.pompa FOR EACH ROW EXECUTE FUNCTION alur.isi_kode('P');
CREATE TRIGGER b_kode BEFORE INSERT ON peta.sekat FOR EACH ROW EXECUTE FUNCTION alur.isi_kode('SK');
CREATE TRIGGER b_kode BEFORE INSERT ON peta.kanal FOR EACH ROW EXECUTE FUNCTION alur.isi_kode('K');

-- ------------------------------------------------ Validasi otomatis (panel Review)
-- "K-1, K-2, ... (+12272 lainnya)" — pesan tetap pendek walau ribuan fitur gagal
CREATE FUNCTION alur.daftar_singkat(a text[], n int DEFAULT 10) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT array_to_string(a[1:n], ', ')
         || CASE WHEN cardinality(a) > n THEN format(' (+%s lainnya)', cardinality(a) - n) ELSE '' END $$;

CREATE FUNCTION alur.validasi_khg(p_versi bigint, p_maks_jarak_air numeric DEFAULT 500)
RETURNS TABLE (cek text, tingkat text, lolos boolean, pesan text)
LANGUAGE sql STABLE AS $$
  WITH v AS (SELECT khg_id FROM alur.khg_versi WHERE id = p_versi),
  pompa AS (SELECT p.* FROM peta.pompa p JOIN v USING (khg_id)),
  jauh AS (
    SELECT kode FROM pompa p
     WHERE NOT EXISTS (SELECT 1 FROM peta.sungai s
                        WHERE s.geom && ST_Expand(p.geom, p_maks_jarak_air / 100000.0)   -- prefilter pakai index (1° > 100 km)
                          AND ST_DWithin(s.geom::geography, p.geom::geography, p_maks_jarak_air))
       AND NOT EXISTS (SELECT 1 FROM peta.kanal k WHERE k.status = 'aktif'
                          AND k.geom && ST_Expand(p.geom, p_maks_jarak_air / 100000.0)
                          AND ST_DWithin(k.geom::geography, p.geom::geography, p_maks_jarak_air))),
  di_konsesi AS (
    SELECT DISTINCT p.kode FROM pompa p JOIN peta.konsesi c ON ST_Intersects(c.geom, p.geom)),
  tanpa_status AS (SELECT kode FROM peta.kanal JOIN v USING (khg_id) WHERE status IS NULL),
  tanpa_kapasitas AS (SELECT kode FROM pompa WHERE kapasitas_m3_menit IS NULL),
  invalid AS (
    SELECT 'kanal '   || coalesce(kode, id::text) AS f FROM peta.kanal   JOIN v USING (khg_id) WHERE NOT ST_IsValid(geom)
    UNION ALL
    SELECT 'sungai '  || id FROM peta.sungai  JOIN v USING (khg_id) WHERE NOT ST_IsValid(geom)
    UNION ALL
    SELECT 'konsesi ' || id FROM peta.konsesi JOIN v USING (khg_id) WHERE NOT ST_IsValid(geom))
  SELECT 'pompa_dekat_air', 'error', count(*) = 0,
         CASE WHEN count(*) = 0 THEN format('Semua pompa maksimal %s m dari sumber air', p_maks_jarak_air)
              ELSE format('%s pompa lebih dari %s m dari sumber air (%s)', count(*), p_maks_jarak_air, alur.daftar_singkat(array_agg(kode ORDER BY kode))) END
    FROM jauh
  UNION ALL
  SELECT 'pompa_luar_konsesi', 'error', count(*) = 0,
         CASE WHEN count(*) = 0 THEN 'Tidak ada pompa di dalam konsesi'
              ELSE format('%s pompa di dalam konsesi (%s)', count(*), alur.daftar_singkat(array_agg(kode ORDER BY kode))) END
    FROM di_konsesi
  UNION ALL
  SELECT 'kanal_berstatus', 'error', count(*) = 0,
         CASE WHEN count(*) = 0 THEN 'Semua kanal memiliki status'
              ELSE format('%s kanal tanpa status (%s)', count(*), alur.daftar_singkat(array_agg(kode ORDER BY kode))) END
    FROM tanpa_status
  UNION ALL
  SELECT 'pompa_kapasitas', 'peringatan', count(*) = 0,
         CASE WHEN count(*) = 0 THEN 'Semua pompa memiliki kapasitas'
              ELSE format('%s pompa tanpa kapasitas (%s)', count(*), alur.daftar_singkat(array_agg(kode ORDER BY kode))) END
    FROM tanpa_kapasitas
  UNION ALL
  SELECT 'geometri_valid', 'error', count(*) = 0,
         CASE WHEN count(*) = 0 THEN 'Geometri valid'
              ELSE format('%s geometri tidak valid (%s)', count(*), alur.daftar_singkat(array_agg(f ORDER BY f))) END
    FROM invalid;
$$;

-- ------------------------------------------------ Alur kerja
CREATE FUNCTION alur.ajukan_review(p_versi bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE alur.khg_versi
     SET status = 'review',
         diajukan_oleh = coalesce(nullif(current_setting('app.pengguna', true), ''), session_user),
         diajukan_at = now(),
         validasi = (SELECT jsonb_agg(to_jsonb(x)) FROM alur.validasi_khg(p_versi) x)
   WHERE id = p_versi AND status IN ('draft','proses','revisi');
  IF NOT FOUND THEN RAISE EXCEPTION 'Versi % bukan draft/proses/revisi', p_versi; END IF;
END $$;

CREATE FUNCTION alur.putuskan(p_versi bigint, p_keputusan text, p_catatan text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_keputusan NOT IN ('approved','revisi') THEN
    RAISE EXCEPTION 'Keputusan harus approved/revisi';
  END IF;
  UPDATE alur.khg_versi
     SET status = p_keputusan,
         reviewer = coalesce(nullif(current_setting('app.pengguna', true), ''), session_user),
         diputuskan_at = now(),
         catatan_reviewer = p_catatan
   WHERE id = p_versi AND status = 'review';
  IF NOT FOUND THEN RAISE EXCEPTION 'Versi % tidak sedang direview', p_versi; END IF;
END $$;

-- Ekspor poster selesai -> versi approved menjadi printed
CREATE FUNCTION alur.tandai_dicetak() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE alur.khg_versi SET status = 'printed' WHERE id = NEW.versi_id AND status = 'approved';
  RETURN NULL;
END $$;
CREATE TRIGGER ekspor_selesai AFTER UPDATE OF status ON alur.ekspor_poster
  FOR EACH ROW WHEN (NEW.status = 'selesai' AND OLD.status <> 'selesai')
  EXECUTE FUNCTION alur.tandai_dicetak();

-- ------------------------------------------------ Mode: Tambah Pompa (saran lokasi)
-- Kandidat = titik sampel di sepanjang kanal aktif, disaring jarak ke sungai, tebal gambut,
-- dan buffer konsesi; 1 kandidat terbaik per kanal.
-- penyederhanaan: bobot skor 0.35/0.25/0.20/0.20 sementara; sesuaikan dengan SOP Dit. PPEG.
CREATE FUNCTION peta.saran_lokasi_pompa(
  p_khg int, p_maks_jarak numeric DEFAULT 500, p_min_tebal numeric DEFAULT 3,
  p_buffer_konsesi numeric DEFAULT 100, p_jarak_sampel numeric DEFAULT 100, p_limit int DEFAULT 3)
RETURNS TABLE (peringkat bigint, skor numeric, skor_sumber_air numeric, skor_kanal numeric,
               skor_gambut numeric, skor_terbakar numeric, jarak_sungai_m numeric,
               sungai_id bigint, kanal_id bigint, tebal_gambut_m numeric,
               jarak_konsesi_m numeric, geom geometry(Point,4326))
LANGUAGE sql STABLE AS $$
  WITH sampel AS (
    SELECT k.id AS kanal_id, k.jenis_kanal, (ST_Dump(ST_LineInterpolatePoints(
             d.geom, least(1.0, p_jarak_sampel / greatest(ST_Length(d.geom::geography), 1))))).geom AS geom
      FROM peta.kanal k, ST_Dump(k.geom) d
     WHERE k.khg_id = p_khg AND k.status = 'aktif'),
  kandidat AS (
    SELECT s.*, sg.id AS sungai_id,
           ST_Distance(sg.geom::geography, s.geom::geography)::numeric AS d_air,
           tg.tebal,
           -- penyederhanaan: jarak planar x 111320 m/derajat (galat < 2% di lintang Indonesia);
           --           geodesik ke poligon konsesi/terbakar hasil dissolve terlalu mahal (±1 dtk/titik)
           (SELECT min(ST_Distance(c.geom, s.geom))::numeric * 111320
              FROM peta.konsesi c WHERE ST_DWithin(c.geom, s.geom, 0.05)) AS d_konsesi,
           (SELECT coalesce(max(a.frekuensi), 0) FROM peta.areal_terbakar a
             WHERE ST_DWithin(a.geom, s.geom, 2000 / 111320.0)) AS n_terbakar
      FROM sampel s
      CROSS JOIN LATERAL (SELECT id, geom FROM peta.sungai ORDER BY geom <-> s.geom LIMIT 1) sg
      CROSS JOIN LATERAL (SELECT max(tebal_min_m) AS tebal FROM peta.ketebalan_gambut t
                           WHERE ST_Intersects(t.geom, s.geom)) tg),
  skor AS (
    SELECT *, round(1 - d_air / p_maks_jarak, 2) AS s_air,
           CASE jenis_kanal WHEN 1 THEN 1.0 WHEN 2 THEN 0.8 ELSE 0.6 END AS s_kanal,
           round(least(1, tebal / 7.0), 2) AS s_gambut,
           round(least(1, 0.4 + n_terbakar * 0.2), 2) AS s_terbakar
      FROM kandidat
     WHERE d_air <= p_maks_jarak AND tebal >= p_min_tebal
       AND (d_konsesi IS NULL OR d_konsesi >= p_buffer_konsesi)),
  terbaik AS (
    SELECT DISTINCT ON (kanal_id) *, round(0.35*s_air + 0.25*s_kanal + 0.20*s_gambut + 0.20*s_terbakar, 2) AS total
      FROM skor ORDER BY kanal_id, 0.35*s_air + 0.25*s_kanal + 0.20*s_gambut + 0.20*s_terbakar DESC)
  SELECT row_number() OVER (ORDER BY total DESC), total, s_air, s_kanal, s_gambut, s_terbakar,
         round(d_air, 1), sungai_id, kanal_id, tebal, round(d_konsesi, 1), geom
    FROM terbaik ORDER BY total DESC LIMIT p_limit;
$$;
