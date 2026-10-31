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
