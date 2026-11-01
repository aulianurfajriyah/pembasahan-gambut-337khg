# Panduan Kirim Data ke Database VM

Semua data (±20 GB) sudah ada di PostgreSQL lokal pengembang (container `gambut_db`). VM produksi dipasang
dengan database kosong (`KOSONG=1 ./deploy/deploy.sh`). Data tidak diimpor ulang dari berkas sumber: isi DB
lokal dikirim utuh ke VM dengan satu perintah.

```
DB lokal (gambut_db) --pg_dump--> output/kirim.dump --rsync--> VM --pg_restore--> DB VM
lapisan/, simulasi/data/  --rsync-->  VM
```

## Persiapan (sekali)

1. Kunci SSH pengembang harus terdaftar untuk pengguna `gambut` di VM. Pemilik VM menambahkan kunci publik
   (`~/.ssh/<kunci>.pub`) ke `/home/gambut/.ssh/authorized_keys`, lalu uji koneksinya:
   ```bash
   ssh -i ~/.ssh/<kunci> gambut@<IP> true
   ```
2. Docker lokal jalan dan container `gambut_db` aktif.
3. Sisa disk laptop minimal ±5 GB untuk dump sementara.

## Kirim data

```bash
IP=<IP VM> KEY=~/.ssh/<kunci> scripts/kirim_db_vm.sh
```

Langkah yang dijalankan skrip:

1. `pg_dump` DB lokal ke `output/kirim.dump` (±4 GB).
2. Unggah dump ke VM.
3. Di VM, DB lama dicadangkan dulu ke `/srv/backup/sebelum_kirim.dump`. Setelah itu skema `ref`, `peta`,
   `analisis`, `alur`, dan `api` dihapus, lalu dump di-restore.
4. Semua migrasi ditandai sudah terpasang (`db/migrasi.sh --tandai`). Role dan view API dipasang ulang.
   Password di VM tidak berubah.
5. Isi `lapisan/` dan `simulasi/data/` disinkron ke VM. Berkas di VM yang tidak ada di laptop dihapus. Folder yang
   kosong di laptop dilewati, jadi isinya di VM tetap aman.
6. `VACUUM (ANALYZE)` membuat statistik planner (tidak ikut di dump). API dinyalakan lagi, statistik
   dashboard disegarkan, lalu dicek dengan satu request.

Kalau unggahan terputus, ulangi dengan `LEWATI_DUMP=1` agar dump tidak dibuat ulang dan unggahan dilanjutkan.

**Peringatan:** kiriman ini mengganti seluruh isi DB VM. Suntingan yang dibuat di VM (lewat QGIS atau API)
sejak kiriman terakhir akan hilang. Salinan DB VM sebelum kiriman tetap ada di
`/srv/backup/sebelum_kirim.dump`. Hapus file itu kalau disk VM sempit (60 GB).

## Perubahan skema setelah VM berisi data

Untuk perubahan skema kecil, tidak perlu mengirim ulang seluruh DB:

1. Tulis file baru `db/migrations/<YYYY-MM-DD>_<nama>.sql`. Isinya dibungkus `BEGIN; ... COMMIT;`.
2. Tulis juga perubahan yang sama di `01-03` atau `10_api_views.sql`, supaya build baru tidak butuh migrasi.
3. Pasang migrasi itu ke DB lokal dan ke VM:
   ```bash
   db/migrasi.sh
   PSQL="ssh -i ~/.ssh/<kunci> gambut@<IP> docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1" db/migrasi.sh
   ```
   Migrasi yang sudah tercatat di `ref.migrasi` dilewati. Migrasi yang gagal tidak dicatat dan bisa diulang.
4. Kalau migrasi mengubah view `api.*`, jalankan juga `10_api_views.sql` di VM:
   ```bash
   ssh -i ~/.ssh/<kunci> gambut@<IP> docker exec -i gambut_db psql -X -q -U postgres -d gambut < db/10_api_views.sql
   ```

DB lokal yang dibangun sebelum `ref.migrasi` ada perlu dicatat sekali dulu: jalankan `db/migrasi.sh --tandai`
kalau DB itu sudah memuat semua migrasi, atau `db/migrasi.sh --semua` untuk DB lama, misalnya dari dump
2026-09-30.

## Suntingan kecil langsung di VM

- **QGIS**: buka tunnel, lalu sambungkan ke `localhost:5434`, db `gambut`, user `editor_qgis`.
  ```bash
  ssh -i ~/.ssh/<kunci> -N -L 5434:localhost:5432 gambut@<IP>
  ```
- **OGC API**: `POST /collections/<koleksi>/items` dengan Basic Auth `admin` (lihat `docs/03_API_OGC.md`).

Suntingan di VM akan tertimpa pada kiriman DB berikutnya. Kalau suntingan itu perlu dipertahankan, tarik dulu
DB VM ke laptop sebelum mengirim lagi.
