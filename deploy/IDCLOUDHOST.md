# Deploy ke IDCloudHost (Jakarta)

Satu VM berisi semuanya: PostGIS + pygeoapi + Caddy (backend) dan web Next.js (repo `LH-KHG`).
Data tetap di Indonesia (PP 71/2019).

| Alamat | Tanpa domain | Dengan domain |
|---|---|---|
| OGC API | `https://<IP-dengan-strip>.sslip.io` | `https://api.domainanda.id` |
| Web | `https://app.<IP-dengan-strip>.sslip.io` | `https://domainanda.id` |

Struktur folder lokal yang diharapkan (dua repo bersebelahan):
```
GitHub/
  pembasahan-gambut-337khg/   <- jalankan semua perintah dari sini
  LH-KHG/                     <- web, ikut di-deploy otomatis
```

## 1. Buat VM di panel IDCloudHost (±10 menit, Anda sendiri)
1. Login ke <https://console.idcloudhost.com>, isi saldo (transfer/VA/QRIS).
2. **Cloud VPS → Create**:
   - Lokasi: **Jakarta**
   - OS: **Ubuntu 24.04 LTS**
   - Spesifikasi: **4 vCPU, 8 GB RAM, disk 160 GB** (minimal 120 GB). Pilih tipe disk NVMe/SSD bila ada.
   - Username + password: isi sendiri, simpan. Ini hanya dipakai sekali di langkah 3.
   - Aktifkan **Public IPv4**.
3. Catat **IP publik** VM.
4. Bila panel punya *Firewall / Security Group*, buka port **22, 80, 443** (TCP) saja.

## 2. Buat dump database (lokal)
DB lokal harus sedang jalan (`docker ps` menampilkan `gambut_db`). ±5 menit, hasil ±3,3 GB:
```bash
mkdir -p output && docker exec gambut_db pg_dump -U postgres -Fc -Z 6 gambut > output/gambut_$(date +%F).dump
```

## 3. Siapkan VM (±5 menit)
```bash
IP=<IP publik> LOGIN=<username dari panel> ./deploy/bootstrap.sh
```
Password VM diminta dua kali (memasang SSH key, lalu `sudo`). Skrip memasang Docker, firewall, fail2ban,
swap, dan user `gambut`, lalu **mematikan login password SSH dan login root**. Setelah ini masuk dengan
`ssh -i ~/.ssh/gambut_vps gambut@<IP>`.

## 4. Deploy (±20-40 menit, kebanyakan upload dump)
```bash
BACKUP=1 ./deploy/deploy.sh
```
Database kosong (skema saja, data diimpor belakangan, tanpa dump): `KOSONG=1 ./deploy/deploy.sh`.
Disk 60 GB: jangan pakai `BACKUP=1` (7 dump harian tidak muat); simpan backup di luar server.
Skrip mengunggah dump, me-restore DB, menyalakan API + HTTPS, mem-build dan menyalakan web, memasang
backup harian 02:00, lalu uji asap. Kredensial produksi ditulis ke `docs/KREDENSIAL_PRODUKSI.md` (gitignore).
Upload bisa dilanjutkan: kalau koneksi putus, jalankan ulang perintah yang sama.

## 5. Pakai domain sendiri (opsional)
1. Di DNS domain, buat **A record** `api` → IP dan `@` (atau `app`) → IP.
2. Tunggu DNS aktif (`dig +short api.domainanda.id` menampilkan IP), lalu:
   ```bash
   DOMAIN=api.domainanda.id WEB_DOMAIN=domainanda.id BACKUP=1 ./deploy/deploy.sh
   ```
   Caddy mengurus sertifikat HTTPS otomatis; web di-build ulang dengan URL API yang baru.
   Selalu sertakan `DOMAIN`/`WEB_DOMAIN` yang sama di setiap deploy berikutnya.

## Operasional
| Tugas | Perintah |
|---|---|
| Update kode backend / web | `git pull` di kedua repo, lalu jalankan ulang `./deploy/deploy.sh` (dengan variabel yang sama) |
| Deploy backend saja | `WEB_DIR= ./deploy/deploy.sh` |
| Ubah biaya per sekat / basemap | Edit `ESTIMASI_BIAYA_PER_SEKAT` / `BASEMAP_STYLE_URL` di `/srv/gambut/db/.env` di server, lalu jalankan ulang `deploy.sh` |
| Log web / API | `ssh -i ~/.ssh/gambut_vps gambut@<IP> 'cd /srv/gambut/db && docker compose logs --tail 50 web api'` |
| Edit dari QGIS | `ssh -i ~/.ssh/gambut_vps -N -L 5433:localhost:5432 gambut@<IP>`, lalu konek QGIS ke `localhost:5433` |
| Backup manual | `ssh … /srv/gambut/db/backup.sh` (disimpan 7 hari di `/srv/backup`) |

## Catatan
- **Web publik read-only.** `OGC_API_USER`/`OGC_API_PASSWORD` sengaja tidak dipasang di server: web belum
  punya login, jadi siapa pun bisa mengedit kalau keduanya diisi.
- Backup harian ada di disk VM yang sama. Untuk backup di luar server, salin dump berkala ke Cloudflare R2
  atau ke laptop (`rsync -e "ssh -i ~/.ssh/gambut_vps" gambut@<IP>:/srv/backup/ ./backup/`).
- Folder `simulasi/data/` dan `lapisan/` ikut disinkron (±450 MB); `simulasi/dem/` tidak dibutuhkan server.
