# Panduan Demo (untuk presenter)

**Link layanan (OGC API):** https://gambut.178-105-182-162.sslip.io

> Server ini berjalan di VM Hetzner yang sudah ada (cx23, Nuremberg, Jerman), dipakai bersama layanan lain. Karena servernya di Eropa, setiap request dari Indonesia butuh waktu lebih lama dibanding server Singapura. Semua fitur baca bisa diakses publik tanpa login. Login hanya dibutuhkan untuk demo edit (bagian 5). Username/password diberikan terpisah oleh pemilik repo, **bukan** lewat repo ini.

Siapkan sebelum mulai:
- Browser (Chrome/Firefox).
- QGIS ≥ 3.28 (opsional, untuk bagian 4).
- Buka link di atas sekali dari jaringan tempat presentasi untuk mengecek kecepatan. Request pertama ±1 detik; selanjutnya ±0,3–0,5 detik per request.

## Alur demo (±15 menit)

### 1. Apa ini? (2 menit)
- Satu basis data PostGIS untuk UI *Pembasahan Gambut 337 KHG*. Isinya:
  - 866 KHG (345 KHG target 2026)
  - 366 ribu sekat kanal (320 ribu rencana, 46 ribu existing)
  - 658 ribu kanal
  - 168 ribu hotspot Jan–Sep 2026
  - 585 ribu poligon areal terbakar 2015–2026
  - 1,78 juta poligon unit analisis PPEG
- Datanya disajikan lewat **standar OGC API**, sehingga bisa dibuka langsung oleh QGIS, ArcGIS, aplikasi web, maupun Python tanpa integrasi khusus.
- Tunjukkan diagram arsitektur di [01_DESAIN_DATABASE.md](01_DESAIN_DATABASE.md) §1.

### 2. Standar OGC & katalog data (3 menit)
| Tunjukkan | Link | Poin bicara |
|---|---|---|
| Halaman depan | https://gambut.178-105-182-162.sslip.io/?f=html | Layanan publik, format HTML dan JSON |
| Standar yang dipenuhi | https://gambut.178-105-182-162.sslip.io/conformance?f=html | OGC API Features 1–4 (termasuk CRUD), Tiles (MVT), Processes, CQL2 |
| Daftar koleksi | https://gambut.178-105-182-162.sslip.io/collections?f=html | 19 layer. 11 di antaranya baca-saja, 8 bisa diedit |
| Dokumentasi interaktif | https://gambut.178-105-182-162.sslip.io/openapi?f=html | Swagger: setiap endpoint bisa dicoba langsung dari browser |

### 3. Data yang mendukung layar UI (5 menit)
Buka [02_KECOCOKAN_UI.md](02_KECOCOKAN_UI.md) di sebelah browser dan tunjukkan pemetaannya.

| Layar UI | Link demo |
|---|---|
| Daftar KHG (filter provinsi + target) | https://gambut.178-105-182-162.sslip.io/collections/khg/items?f=html&provinsi_singkat=Kalteng&target_2026=true&limit=20 |
| Prioritas Tinggi (urut skor) | https://gambut.178-105-182-162.sslip.io/collections/khg/items?f=json&limit=10&sortby=-skor_prioritas&properties=nama,provinsi_singkat,skor_prioritas,hotspot_30h&skipGeometry=true |
| Detail 1 KHG (peta + atribut) | https://gambut.178-105-182-162.sslip.io/collections/khg/items/328?f=html |
| Layer sekat existing (Riau, P. Padang) | https://gambut.178-105-182-162.sslip.io/collections/sekat/items?f=html&bbox=102.3,0.9,102.4,1.0&status=existing |
| Hotspot kepercayaan tinggi, 1–15 Sep 2026 | https://gambut.178-105-182-162.sslip.io/collections/hotspot/items?f=html&datetime=2026-09-01T00:00:00Z/2026-09-15T23:59:59Z&kepercayaan=tinggi&limit=200 |
| Kanal di sekitar Sebangau | https://gambut.178-105-182-162.sslip.io/collections/kanal/items?f=html&bbox=113.9,-2.9,114.0,-2.8&limit=200 |
| Validasi otomatis (panel Review) | Di Swagger → `POST /processes/validasi-khg/execution`, body `{"inputs":{"khg_id":328}}` |
| KPI Dashboard | Di Swagger → `POST /processes/ringkasan-dashboard/execution`, body `{"inputs":{}}` |

Sampaikan juga dengan jujur apa yang **belum ada datanya** (ringkasan di dokumen 02): sungai sumber air, status kanal aktif hasil survei, data pompa/logger TMAT/sumur bor, dan kode KHG resmi. Strukturnya sudah siap, tinggal diisi.

### 4. Dibuka di QGIS (3 menit, opsional)
1. *Layer → Data Source Manager → **WFS / OGC API - Features** → New*.
2. Isi URL `https://gambut.178-105-182-162.sslip.io`, lalu pilih versi *OGC API - Features* → *Connect*.
3. Tambahkan `khg`, lalu `sekat`. Untuk area kecil, pakai filter extent.
4. Layer besar paling cepat lewat vector tiles: *Vector Tile → New → Generic*, URL `https://gambut.178-105-182-162.sslip.io/collections/kanal/tiles/WebMercatorQuad/{z}/{y}/{x}?f=mvt`, min zoom 9, max zoom 17. Zoom ke Kalteng.

### 5. Edit data + jejak audit (2 menit, opsional, butuh login)
Swagger di server ini tidak punya tombol login, jadi demo edit memakai Terminal. Ganti `USER:PASS` dengan kredensial dari pemilik repo.
```bash
# tanpa login -> ditolak 401 (baca terbuka, tulis terkunci)
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/geo+json" -d '{}' \
  https://gambut.178-105-182-162.sslip.io/collections/pompa/items
```
```bash
# dengan login -> 201; header Location berisi id pompa baru. Kode P-1 & KHG terisi otomatis
curl -i -u USER:PASS -X POST -H "Content-Type: application/geo+json" \
  -d '{"type":"Feature","geometry":{"type":"Point","coordinates":[114.0673,-2.8190]},"properties":{"kapasitas_m3_menit":100}}' \
  https://gambut.178-105-182-162.sslip.io/collections/pompa/items
```
Tunjukkan hasilnya di https://gambut.178-105-182-162.sslip.io/collections/pompa/items?f=html

Poin bicara: setiap perubahan (dari QGIS, web, maupun API) tercatat otomatis di log audit dan masuk ke versi KHG. Inilah yang mengisi layar *Review & Approval* dan *Riwayat Versi*.

Setelah demo, hapus pompa uji:
```bash
curl -u USER:PASS -X DELETE https://gambut.178-105-182-162.sslip.io/collections/pompa/items/<id>
```

## Pertanyaan yang mungkin muncul
| Pertanyaan | Jawaban singkat |
|---|---|
| Berapa biaya hosting? | Demo: ±Rp33 ribu untuk ±36 jam. Produksi yang disarankan: ±Rp20–30 ribu/hari (Hetzner Singapura). GCP Jakarta ±2,5–4,5× lebih mahal. Lihat [05_RENCANA_DEPLOY.md](05_RENCANA_DEPLOY.md) |
| Datanya di Indonesia? | Server saat ini di Jerman (Nuremberg). Kalau PP 71/2019 mewajibkan data di Indonesia, arsitektur yang sama bisa dipindah ke GCP Jakarta atau VPS lokal |
| Kenapa hotspot per bulan tidak bisa dibandingkan? | Jan/Apr/Agu/Sep hanya MODIS, sedangkan Feb–Jul juga VIIRS (lebih banyak titik). Perlu ditarik ulang dari satu sumber |
| Bisa dipakai ArcGIS/aplikasi lain? | Ya. OGC API adalah standar terbuka: ArcGIS Pro, GDAL, Python (owslib/geopandas), MapLibre/OpenLayers |
| Bagaimana kalau server mati? | Seluruh DB bisa dibangun ulang dari data sumber dalam ±10 menit (`db/setup.sh`) atau dari dump dalam ±25 menit (`deploy/`) |
