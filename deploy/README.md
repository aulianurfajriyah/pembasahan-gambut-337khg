# Deploy ke Hetzner Cloud (Singapura) — otomatis

> Memakai **IDCloudHost** (Jakarta) atau VPS lain? Lihat [IDCLOUDHOST.md](IDCLOUDHOST.md): `bootstrap.sh` menggantikan langkah A dan `provision.sh`.

Pembagian kerja:
- **Anda:** membuat akun, membayar, dan membuat API token. Tiga langkah, ±15 menit.
- **Skrip:** semua langkah lainnya.

## A. Langkah Anda (sekali saja)
1. **Daftar akun** di <https://accounts.hetzner.com/signUp>. Verifikasi email, lalu lengkapi identitas dan metode pembayaran (kartu kredit/PayPal). Hetzner kadang meminta verifikasi KTP/paspor untuk akun baru; tunggu sampai akun aktif.
2. **Buat project** di <https://console.hetzner.cloud> → *New project* → beri nama `gambut`.
3. **Buat API token.** Di project `gambut`: *Security → API tokens → Generate API token*. Beri nama `deploy`, pilih izin **Read & Write**, lalu salin token (hanya ditampilkan sekali).
4. Di Terminal, **jalankan sendiri** perintah berikut, lalu tempel token saat diminta. Token tersimpan di `~/.config/hcloud/cli.toml`, bukan di project ini.
   ```bash
   hcloud context create gambut
   ```

## B. Langkah otomatis
```bash
./deploy/provision.sh
```
Skrip ini:
- membuat SSH key khusus, firewall (22/80/443), dan VM `cpx22` (2 vCPU, 4 GB) di Singapura **tanpa backup** (mode demo). Untuk produksi: `TYPE=cpx32 BACKUP=1 ./deploy/provision.sh`;
- menolak tipe yang sudah tidak bisa dipesan di lokasi itu (misalnya cpx31 di Singapura) dan menampilkan daftar yang tersedia;
- menampilkan harga resmi dari API Hetzner;
- **meminta konfirmasi "ya" sebelum membuat server** (karena menimbulkan tagihan).

```bash
./deploy/deploy.sh
```
Skrip ini:
- menunggu VM siap, lalu menyinkronkan file;
- membuat password produksi baru;
- meng-upload dump 3,3 GB (bisa dilanjutkan kalau koneksi putus) dan me-restore-nya;
- membuat role dan view API;
- menyalakan pygeoapi + Caddy dengan HTTPS otomatis;
- memasang cron backup harian **hanya jika** `BACKUP=1`;
- menyetel memori PostgreSQL/pygeoapi otomatis sesuai RAM server;
- menjalankan uji asap.

Hasil akhirnya:
- API di `https://<IP-dengan-strip>.sslip.io`
- kredensial di `docs/KREDENSIAL_PRODUKSI.md`

**Memakai domain sendiri** (misalnya `api.gambut.go.id`):
1. Buat A record ke IP server.
2. Jalankan ulang:
   ```bash
   DOMAIN=api.gambut.go.id ./deploy/deploy.sh
   ```
Skrip bersifat idempoten: aman dijalankan ulang untuk update, dan tidak me-restore ulang kalau DB sudah berisi.

## C. Operasional
| Tugas | Perintah |
|---|---|
| SSH ke server | `ssh -i ~/.ssh/gambut_hetzner gambut@<IP>` |
| Edit dari QGIS (tunnel) | `ssh -i ~/.ssh/gambut_hetzner -N -L 5433:localhost:5432 gambut@<IP>`, lalu konek QGIS ke `localhost:5433` |
| Update kode/SQL/konfigurasi | `./deploy/deploy.sh` |
| Lihat log | `ssh … 'cd /srv/gambut/db && docker compose logs --tail 50 api'` |
| Backup manual | `ssh … /srv/gambut/db/backup.sh` (otomatis setiap 02:00, disimpan 7 hari di `/srv/backup`) |
| Hentikan tagihan (hapus server) | `hcloud server delete gambut-prod` (backup Hetzner ikut hilang, **unduh dump dulu**) |

Opsi lain: `TYPE=cx33 LOC=nbg1 ./deploy/provision.sh` untuk Jerman (lebih murah, latensi lebih tinggi).

## C2. VM yang sudah ada (dipakai bersama)
Untuk VM yang sudah menjalankan layanan lain dan punya Caddy di host (port 80/443 sudah terpakai):
```bash
IP=178.105.182.162 KEY=~/.ssh/vm_hetzner ./deploy/deploy_shared.sh
```
Skrip ini memasang stack di `/opt/gambut` tanpa container Caddy (override [`docker-compose.shared.yml`](docker-compose.shared.yml)), membatasi memori container, menambah `/etc/caddy/conf.d/gambut.caddy` di Caddy host, lalu menjalankan uji asap. DB hanya di `127.0.0.1:5433` (akses lewat SSH tunnel). Kredensial tersalin ke `deploy/.env.shared` dan `docs/KREDENSIAL_PRODUKSI.md` (keduanya di-gitignore).

## D. Riwayat deploy
| Tanggal | Server | Hasil |
|---|---|---|
| 30 Sep 2026 | `gambut-prod` cpx22 Singapura, 5.223.68.87, €0,0497/jam | Deploy ±25 menit (sebagian besar upload dump 3,3 GB). Tes lolos. RAM terpakai ±1,8/3,8 GB, disk 18/75 GB. Server dihapus setelah demo |
| 31 Okt 2026 | VM bersama `twin-vm` cx23 Nuremberg, 178.105.182.162, tanpa biaya tambahan | `deploy_shared.sh` ±10 menit (upload ±30 MB/s). Tes lolos, 19 koleksi, tiles, processes, tulis dengan login, tunnel DB. API: https://gambut.178-105-182-162.sslip.io. Container dibatasi 1,2 GB (DB) + 0,8 GB (API); disk VM sisa ±10 GB |

## E. Ubin Martin & koleksi khg-ringkas (1 Nov 2026) dan rollback
Peta web mengambil ubin MVT dari Martin (`/tiles/<layer>/{z}/{x}/{y}`, [api/martin.yaml](../api/martin.yaml)), bukan dari pygeoapi. Daftar, tabel, dan dashboard KHG memakai koleksi `khg-ringkas` (tanpa batas poligon). Ubin pygeoapi dan koleksi `khg` tidak diubah, jadi web versi lama tetap jalan di BE baru.

Sebelum deploy, versi lama disimpan di VM:
- image web lama: `db-web:rollback`
- `api/` dan `db/docker-compose.yml` lama: `/srv/backup/rollback_tiles.tgz`

**Rollback cepat (±1 menit, tanpa build).** Web lama kembali memakai ubin pygeoapi dan koleksi `khg`. Martin boleh tetap jalan karena tidak dipakai.
```bash
ssh -i ~/.ssh/gambut_vps gambut@<IP> 'cd /srv/gambut/db && docker tag db-web:rollback db-web:latest && docker compose up -d --no-build --force-recreate web'
```

**Rollback penuh BE (opsional).** Kembalikan berkas lama, lalu hapus Martin. View `api.khg_ringkas` tidak mengganggu dan boleh tetap ada.
```bash
ssh -i ~/.ssh/gambut_vps gambut@<IP> 'cd /srv/gambut && tar xzf /srv/backup/rollback_tiles.tgz && cd db && docker compose rm -sf martin && docker compose up -d --force-recreate api proxy'
```
Setelah itu revert PR di kedua repo (BE dan LH-KHG) supaya deploy berikutnya tidak memasang ulang perubahan ini.

## F. Performa BE/DB (2 Nov 2026) dan rollback
Perubahan: migrasi `db/migrations/2026-11-02_perf_query.sql` (fungsi `ref.varian_utama` bisa di-inline, bbox KHG tersimpan di `ref.khg`, ubin `api.khg_ubin` hanya membawa atribut yang dipakai web, dashboard satu kali scan kanal, extension `pg_stat_statements`), cache hasil dashboard (30 dtk) dan simulasi (6 hasil per worker) di `api/gambut_processes.py`, worker pygeoapi `gthread` 4 thread, dan setelan Postgres baru (`random_page_cost`, `pg_stat_statements`, log query > 500 ms). Tanpa perubahan data.

Urutan deploy (piecewise, jangan `deploy.sh`):
1. Backup definisi skema: `docker exec gambut_db pg_dump -U postgres -d gambut --schema-only -Fc > /srv/backup/skema_sebelum_perf.dump`, dan `tar czf /srv/backup/rollback_perf.tgz api db/docker-compose.yml deploy/docker-compose.prod.yml`.
2. rsync `api/`, `db/` (tanpa `.env`), `deploy/docker-compose.prod.yml`.
3. `PSQL="docker exec -i gambut_db psql -X -q -U postgres -d gambut -v ON_ERROR_STOP=1" db/migrasi.sh` (ALTER `ref.khg` mengunci tabel beberapa detik).
4. `docker compose up -d db api martin proxy` (db restart ±10 dtk untuk `shared_preload_libraries`).

Query lambat setelahnya: `SELECT calls, round(mean_exec_time) AS ms, left(query, 120) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;`

**Rollback.** Kembalikan berkas lama lalu recreate container: `tar xzf /srv/backup/rollback_perf.tgz && cd db && docker compose up -d --force-recreate db api proxy`. Fungsi, view, dan kolom bbox baru tidak perlu dihapus: hasilnya sama dengan versi lama. Bila tetap ingin skema lama, pasang ulang definisi `ref.varian_utama`, `api.khg`, `api.khg_ubin`, `alur.v_dashboard` dari commit sebelum PR ini.
