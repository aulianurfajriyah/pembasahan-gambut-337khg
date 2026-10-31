# Dokumentasi OGC API — Pembasahan Gambut

Base URL lokal: **`http://localhost:8080`**. Produksi: `https://api.<domain>`.
Server: **pygeoapi 0.24.0** di balik Caddy. Spesifikasi OpenAPI yang selalu mutakhir ada di **`/openapi?f=html`** (Swagger UI) atau `/openapi?f=json`.

## 1. Standar yang dipenuhi
Diverifikasi dari `GET /conformance`:
| Standar | Kelas konformansi |
|---|---|
| OGC API – Common Part 1 & 2 | core, landing-page, json, html, oas30, collections |
| **OGC API – Features Part 1** | core, geojson, html, oas30 |
| OGC API – Features Part 2 (CRS) | reproyeksi keluaran `crs=` / `bbox-crs=` |
| OGC API – Features Part 3 (Filtering) | queryables, queryables-query-parameters, **CQL2** basic + text |
| **OGC API – Features Part 4 (CRUD)** | create-replace-delete (POST/PUT/DELETE) |
| **OGC API – Tiles Part 1** | core, tileset, tilesets-list, geodata-tilesets, **MVT** |
| **OGC API – Processes Part 1** | core, json, ogc-process-description, oas30 |

## 2. Autentikasi
| Operasi | Butuh login? |
|---|---|
| Semua `GET`/`HEAD`/`OPTIONS` (landing, koleksi, items, tiles, processes, openapi) | ❌ publik |
| `POST /processes/{ringkasan-dashboard, validasi-khg, saran-lokasi-pompa}/execution` | ❌ publik (baca saja) |
| `POST`/`PUT`/`DELETE` items, proses `ajukan-review`, `putuskan-review`, `refresh-statistik` | ✅ **HTTP Basic Auth** |

Tanpa login, operasi tulis dijawab `401 Unauthorized`. Kredensialnya ada di `docs/KREDENSIAL.md`. Setiap tulis lewat API tercatat di `alur.perubahan` dengan `via = 'api'` dan `pengguna = 'ogc_writer'`.

## 3. Endpoint
| Method | Path | Fungsi |
|---|---|---|
| GET | `/` | Landing page |
| GET | `/conformance` | Daftar standar |
| GET | `/openapi` | Dokumen OpenAPI 3.0 |
| GET | `/collections` | Daftar 19 koleksi |
| GET | `/collections/{id}` | Metadata koleksi (extent, CRS, link) |
| GET | `/collections/{id}/queryables` | Atribut yang bisa difilter (JSON Schema) |
| GET | `/collections/{id}/items` | Query fitur (GeoJSON / HTML / CSV) |
| GET | `/collections/{id}/items/{fid}` | Satu fitur |
| POST | `/collections/{id}/items` | Tambah fitur (koleksi edit) → `201` + header `Location` |
| PUT | `/collections/{id}/items/{fid}` | Ganti/ubah fitur → `204` |
| DELETE | `/collections/{id}/items/{fid}` | Hapus fitur → `200` |
| GET | `/collections/{id}/tiles` | Daftar tileset |
| GET | `/collections/{id}/tiles/{tms}/{z}/{y}/{x}?f=mvt` | Vector tile (Mapbox Vector Tile) |
| GET | `/TileMatrixSets` | `WebMercatorQuad`, `WorldCRS84Quad` |
| GET | `/processes` · `/processes/{id}` | Daftar & deskripsi proses |
| POST | `/processes/{id}/execution` | Jalankan proses (sinkron) |

## 4. Koleksi
### 4a. Baca-saja (dari schema `api`)
| id | Geometri | Isi | Jumlah | Tiles (zoom) |
|---|---|---|---:|---|
| `khg` | MultiPolygon | Batas KHG + status alur, versi, hotspot_30h, kanal_km, sekat, porsi terbakar, porsi gambut ≥ 3 m, `skor_prioritas` | 866 | 0–14 |
| `desa` | MultiPolygon | 2004 desa target 2026 + wilayah administrasi | 2.004 | — |
| `sekat` | Point | Sekat rencana + existing, beserta konteks overlay dan detail bangunan | 366.371 | 10–18 |
| `hotspot` | Point | Hotspot Jan–15 Sep 2026 (`time_field` = `waktu`) | 167.718 | 5–16 |
| `areal-terbakar` | MultiPolygon | Areal terbakar 2015–2026 (`tahun_terbakar`, `frekuensi`, `tahun_terakhir`) | 584.723 | 9–16 |
| `konsesi` | MultiPolygon | Dissolve per perusahaan (`perusahaan`, `jenis`) | 1.070 | — |
| `ketebalan-gambut` | MultiPolygon | Kelas tebal per KHG (`tebal_min_m`, `tebal_max_m`) | 2.938 | — |
| `unit-target-2026` | MultiPolygon | Unit analisis tematik, 2004 desa target | 789.336 | 11–16 |
| `unit-nasional` | MultiPolygon | Unit analisis tematik nasional | 989.398 | 11–16 |
| `kontur` | MultiLineString | Kontur 108 KHG target BRGM (`elevasi_m`) | 159.043 | 11–17 |
| `kontur-lidar` | MultiLineString | Kontur LiDAR 50 cm | 26.968 | — |

### 4b. Bisa diedit (Part 4, tabel `peta.*` langsung)
| id | Geometri | Atribut utama | Catatan |
|---|---|---|---|
| `sekat-edit` | Point | `status` (rencana/existing/rusak/dibongkar), `kanal_id`, `jenis_kanal`, `qc_flag` | `kode` SK-n & `khg_id` otomatis |
| `kanal` | MultiLineString | `status` (aktif/tidak_aktif/tersumbat/null), `jenis_kanal` (1/2/3), `keterangan` | `panjang_m` dihitung otomatis. Tiles z9–17 dari view `api.kanal` |
| `pompa` | Point | `kapasitas_m3_menit`, `status`, `sungai_id`, `kanal_id`, `skor*` | `kode` P-n otomatis |
| `pintu-air` | Point | `kode`, `tahun_bangun`, `bahan`, `pelaksana` | |
| `sungai` | MultiLineString | `nama` | belum ada data |
| `sumur-bor` | Point | `kode`, `kedalaman_m`, `kondisi`, `penanggung_jawab`, `ext_id` | belum ada data |
| `logger-tmat` | Point | `kode`, `ext_id` | belum ada data |
| `posko-karhutla` | Point | `nama`, `keterangan` | belum ada data |

Kolom yang **jangan diisi**, karena diisi trigger: `id` (saat POST), `kode` (boleh diisi manual), `khg_id` (diturunkan dari geometri), `created_*`, `updated_*`, `updated_via`, `rev`, `panjang_m`.

## 5. Parameter query `/items`
| Parameter | Contoh | Keterangan |
|---|---|---|
| `limit`, `offset` | `limit=100&offset=200` | Default 100, maksimum 5000. Paging lewat link `next` |
| `bbox` | `bbox=102.3,0.9,102.4,1.0` | lon/lat (CRS84) |
| `bbox-crs` | `bbox=11390000,100000,11410000,110000&bbox-crs=http://www.opengis.net/def/crs/EPSG/0/3857` | bbox dalam meter Web Mercator |
| `crs` | `crs=http://www.opengis.net/def/crs/EPSG/0/3857` | Reproyeksi keluaran: CRS84, EPSG:4326, EPSG:3857 |
| `datetime` | `datetime=2026-09-01T00:00:00Z/2026-09-15T23:59:59Z` | Hanya koleksi `hotspot` |
| atribut = nilai | `status=existing&provinsi_singkat=Riau` | Filter kesamaan untuk setiap queryable |
| `filter` (CQL2-text) | `filter=nama LIKE '%Kampar%' AND luas_ha > 50000` | Harus di-URL-encode |
| `sortby` | `sortby=-skor_prioritas,nama` | `-` berarti menurun |
| `properties` | `properties=nama,status,skor_prioritas` | Memilih kolom |
| `skipGeometry` | `skipGeometry=true` | Respons jauh lebih kecil untuk tabel/daftar |
| `f` | `f=json` · `f=html` · `f=csv` | Format keluaran |

Setiap respons berisi `numberMatched` (total) dan `numberReturned`.

## 6. Contoh
### Baca
```bash
# 10 KHG prioritas tertinggi (layar "Prioritas Tinggi")
curl "http://localhost:8080/collections/khg/items?f=json&limit=10&sortby=-skor_prioritas&properties=nama,provinsi_singkat,skor_prioritas,hotspot_30h&skipGeometry=true"
```
```bash
# Daftar KHG target 2026 di Riau
curl "http://localhost:8080/collections/khg/items?f=json&provinsi_singkat=Riau&target_2026=true&skipGeometry=true"
```
```bash
# Pencarian nama KHG (CQL2)
curl -G "http://localhost:8080/collections/khg/items" --data-urlencode "filter=nama LIKE '%Kampar%'" -d f=json -d skipGeometry=true
```
```bash
# Sekat existing di sebuah area
curl "http://localhost:8080/collections/sekat/items?f=json&bbox=102.3,0.9,102.4,1.0&status=existing"
```
```bash
# Hotspot kepercayaan tinggi, 1-15 Sep 2026
curl "http://localhost:8080/collections/hotspot/items?f=json&datetime=2026-09-01T00:00:00Z/2026-09-15T23:59:59Z&kepercayaan=tinggi&limit=1000"
```
```bash
# Ekspor CSV tanpa geometri
curl "http://localhost:8080/collections/sekat/items?f=csv&limit=5000&skipGeometry=true" -o sekat.csv
```

### Tulis (Part 4)
```bash
# Tambah pompa -> 201, header Location: /collections/pompa/items/{id}
curl -u USER:PASS -X POST -H "Content-Type: application/geo+json" \
  -d '{"type":"Feature","geometry":{"type":"Point","coordinates":[114.0673,-2.8190]},"properties":{"kapasitas_m3_menit":100}}' \
  http://localhost:8080/collections/pompa/items
```
```bash
# Ubah (PUT) -> 204. WAJIB sertakan "id" di body Feature.
curl -u USER:PASS -X PUT -H "Content-Type: application/geo+json" \
  -d '{"type":"Feature","id":12,"geometry":{"type":"Point","coordinates":[114.0673,-2.8174]},"properties":{"kapasitas_m3_menit":150}}' \
  http://localhost:8080/collections/pompa/items/12
```
```bash
# Ubah status kanal hasil survei: ambil fitur (dengan geometrinya), ubah atribut, kirim balik
curl -s "http://localhost:8080/collections/kanal/items/703598?f=json" \
 | jq '{type, id, geometry, properties: {status: "aktif", keterangan: "survei lapangan Sep 2026"}}' \
 | curl -u USER:PASS -X PUT -H "Content-Type: application/geo+json" -d @- \
     http://localhost:8080/collections/kanal/items/703598
```
```bash
# Hapus -> 200
curl -u USER:PASS -X DELETE http://localhost:8080/collections/pompa/items/12
```
> **Sifat PUT di pygeoapi 0.24** (diuji):
> - Body wajib berisi `id` **dan** `geometry` lengkap. `geometry: null` menghasilkan `500`.
> - Atribut yang tidak dikirim dipertahankan (bersifat *merge*: `kode`, `khg_id`, dan seterusnya tetap), dan `rev` naik 1.
> - **PATCH tidak didukung** (`405`). Untuk mengubah atribut saja, GET dulu lalu PUT kembali dengan geometri yang sama (lihat contoh kanal di atas).

### Vector tiles
```
http://localhost:8080/collections/kanal/tiles/WebMercatorQuad/{z}/{y}/{x}?f=mvt
```
Contoh `z=12, y=2081, x=3344` (Pulang Pisau, Kalteng). Hasil uji: `kanal` 24 KB (0,3 dtk), `sekat` 45 KB (0,5 dtk), `unit-nasional` 45 KB (0,3 dtk). Di luar rentang zoom tileset, server menjawab `404`.

### Processes
```bash
# Validasi otomatis (panel Review)
curl -X POST -H "Content-Type: application/json" -d '{"inputs":{"khg_id":328}}' \
  http://localhost:8080/processes/validasi-khg/execution
# -> {"id":"hasil","value":[{"cek":"pompa_dekat_air","tingkat":"error","lolos":true,"pesan":"..."}, ...]}
```
```bash
# Saran lokasi pompa (Mode: Tambah Pompa) -> GeoJSON FeatureCollection
curl -X POST -H "Content-Type: application/json" \
  -d '{"inputs":{"khg_id":328,"maks_jarak_m":500,"min_tebal_m":3,"buffer_konsesi_m":100,"jumlah":3}}' \
  http://localhost:8080/processes/saran-lokasi-pompa/execution
```
```bash
# KPI Dashboard Nasional
curl -X POST -H "Content-Type: application/json" -d '{"inputs":{}}' \
  http://localhost:8080/processes/ringkasan-dashboard/execution
```
```bash
# Alur kerja (wajib login)
curl -u USER:PASS -X POST -H "Content-Type: application/json" -d '{"inputs":{"khg_id":328}}' \
  http://localhost:8080/processes/ajukan-review/execution
```
```bash
curl -u USER:PASS -X POST -H "Content-Type: application/json" \
  -d '{"inputs":{"khg_id":328,"keputusan":"approved","catatan":"Lokasi sesuai"}}' \
  http://localhost:8080/processes/putuskan-review/execution
```
```bash
curl -u USER:PASS -X POST -H "Content-Type: application/json" -d '{"inputs":{}}' \
  http://localhost:8080/processes/refresh-statistik/execution
```

| Proses | Input | Output | Login |
|---|---|---|---|
| `ringkasan-dashboard` | — | KPI dashboard + distribusi status alur | ❌ |
| `validasi-khg` | `khg_id`, `maks_jarak_air_m`=500 | 5 hasil cek (`cek`, `tingkat`, `lolos`, `pesan`) | ❌ |
| `saran-lokasi-pompa` | `khg_id`, `maks_jarak_m`=500, `min_tebal_m`=3, `buffer_konsesi_m`=100, `jumlah`=3 | FeatureCollection kandidat + skor & sub-skor | ❌ |
| `ajukan-review` | `khg_id` | status versi setelah diajukan | ✅ |
| `putuskan-review` | `khg_id`, `keputusan` (approved/revisi), `catatan` | status versi | ✅ |
| `refresh-statistik` | — | waktu refresh | ✅ |

## 7. Klien
| Klien | Cara pakai |
|---|---|
| **QGIS** (≥ 3.28) | Lihat §7a di bawah (termasuk login untuk edit) |
| **GDAL/OGR** | `ogrinfo OAPIF:http://localhost:8080` · `ogr2ogr -f GPKG sekat.gpkg OAPIF:http://localhost:8080/collections/sekat -spat 102.3 0.9 102.4 1.0 -where "status='existing'"` (sudah diuji: 61 fitur) |
| **ArcGIS Pro** (≥ 2.8) | *Insert → Connections → Server → New OGC API Server* |
| **Python** | `requests` / `owslib.ogcapi.features.Features('http://localhost:8080')` / `geopandas.read_file('http://localhost:8080/collections/khg/items?f=json&limit=5000')` |
| **JavaScript** | MapLibre GL / OpenLayers: sumber `vector` dengan URL tile MVT di atas, atau GeoJSON dari `/items?f=json` |
| **Browser** | Setiap endpoint punya tampilan HTML dengan `?f=html` |

### 7a. QGIS dengan kredensial
1. **Simpan kredensial.** Buka *Settings → Options → Authentication* → **+** → tipe **Basic authentication**. Isi Name `Gambut API` serta username/password API. QGIS menyimpannya terenkripsi dengan *master password*.
2. **Buat koneksi.** Buka *Layer → Data Source Manager → WFS / OGC API - Features → New*. Isi URL layanan (misalnya `https://gambut.178-105-182-162.sslip.io`), lalu pada *Authentication* pilih `Gambut API` → *Detect* / versi **OGC API - Features** → *Connect*.
3. **Tambah layer.** Centang *Only request features overlapping the view extent* untuk layer besar.
4. **Edit.** Koleksi `sekat-edit`, `kanal`, `pompa`, `pintu-air`, `sungai`, `sumur-bor`, `logger-tmat`, dan `posko-karhutla` bisa diedit lewat *Toggle Editing* → *Save*. Membaca tidak butuh login.
   > Editing OAPIF di aplikasi QGIS belum diuji langsung (POST/PUT/DELETE sudah terbukti dengan `curl`). Kalau Save gagal di versi QGIS Anda, gunakan koneksi PostGIS lewat SSH tunnel.
5. **Vector tiles** untuk layer besar: *Vector Tile → New → Generic*, URL `…/collections/kanal/tiles/WebMercatorQuad/{z}/{y}/{x}?f=mvt`, zoom 9–17 (tanpa login).

## 8. Kinerja & batasan (hasil uji lokal)
| Kasus | Waktu |
|---|---|
| `khg` items (866, dengan sort/filter) | 0,15–0,35 dtk |
| `sekat` bbox + filter | 0,06 dtk |
| `hotspot` datetime + filter | 0,25 dtk |
| `unit-nasional` items | ±2,3 dtk (karena menghitung `numberMatched` 989 ribu baris). Gunakan `bbox` atau tiles |
| Tile MVT | 0,02–0,5 dtk |

Batasan lain:
- Maksimum 5.000 fitur per request. Pakai paging `offset` atau `next`.
- Role `ogc_reader` punya `statement_timeout` 30 detik.
- Semua pengguna API bersama memakai satu akun tulis (`ogc_writer`), jadi log audit tidak membedakan orang. Kalau perlu identitas per orang, gunakan aplikasi web (`app.pengguna`) atau akun PostGIS per editor.
