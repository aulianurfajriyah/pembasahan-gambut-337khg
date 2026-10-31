#!/usr/bin/env python3
"""Rekonstruksi jalur pompa dari jaringan kanal hasil pump (layer network_edges, tahap 8) bila rute aslinya
(pump_routes) tidak tersedia.

    python3 scripts/rute_dari_jaringan.py <network.gpkg> <pump_stations> <keluaran.gpkg>

Edge 'selected = 1' adalah ruas kanal terpilih (tahap 6), terpecah-pecah. Tiap kelompok edge terpilih yang
tersambung dihubungkan ke stasiun pompa terdekat lewat jalur terpendek (panjang edge) di jaringan; satu rute =
jalur penghubung + edge kelompok itu. Kelompok yang tidak tersambung ke pompa mana pun tetap ditulis tanpa pompa
(route_id U-nnn, keterangan 'tidak tersambung') agar tidak ada edge terpilih yang hilang.
Hasil ini PENDEKATAN, bukan rute model pump (yang memperhitungkan angkat & debit).
"""
import heapq
import sys
from collections import defaultdict

from osgeo import ogr, osr

ogr.UseExceptions()
osr.UseExceptions()


def main(jaringan, pompa_path, keluaran):
    src = ogr.Open(jaringan)
    lyr = src.GetLayerByName("network_edges")
    srs = lyr.GetSpatialRef()
    edges = {}                       # (a, b) a<b -> (geom wkb, panjang, terpilih)
    xy = {}                          # node -> (x, y)
    for f in lyr:
        a, b = f["from_node"], f["to_node"]
        if a == b:
            continue
        g = f.GetGeometryRef()
        k = (min(a, b), max(a, b))
        if k not in edges or f["selected"]:
            edges[k] = (g.ExportToWkb(), float(f["length_m"]), bool(f["selected"]))
        pts = g.GetPoints()
        xy[a], xy[b] = pts[0][:2], pts[-1][:2]
    nb = defaultdict(list)
    for (a, b), (_, w, _) in edges.items():
        nb[a].append((b, w))
        nb[b].append((a, w))

    # stasiun pompa -> node jaringan terdekat
    ps = ogr.Open(pompa_path)
    pl = ps.GetLayer(0)
    ke = osr.CoordinateTransformation(pl.GetSpatialRef(), srs)
    pompa = {}
    for f in pl:
        g = f.GetGeometryRef().Clone()
        g.Transform(ke)
        x, y = g.GetX(), g.GetY()
        node = min(xy, key=lambda n: (xy[n][0] - x) ** 2 + (xy[n][1] - y) ** 2)
        kode = f["station_id"] if f.GetFieldIndex("station_id") >= 0 else str(f.GetFID())
        pompa[node] = kode

    # Dijkstra multi-sumber dari semua pompa: jarak, simpul sebelumnya, dan pompa asal tiap simpul
    jarak, induk, asal = {}, {}, {}
    antre = [(0.0, n, None, n) for n in pompa]
    while antre:
        d, n, sebelum, p = heapq.heappop(antre)
        if n in jarak:
            continue
        jarak[n], induk[n], asal[n] = d, sebelum, p
        for m, w in nb[n]:
            if m not in jarak:
                heapq.heappush(antre, (d + w, m, n, p))

    # kelompok edge terpilih yang tersambung
    sel_nb = defaultdict(set)
    for (a, b), (_, _, s) in edges.items():
        if s:
            sel_nb[a].add(b)
            sel_nb[b].add(a)
    sudah, kelompok = set(), []
    for v in sel_nb:
        if v in sudah:
            continue
        stack, anggota = [v], set()
        while stack:
            u = stack.pop()
            if u in anggota:
                continue
            anggota.add(u)
            stack.extend(sel_nb[u] - anggota)
        sudah |= anggota
        kelompok.append(anggota)

    drv = ogr.GetDriverByName("GPKG")
    out = drv.CreateDataSource(keluaran)
    ol = out.CreateLayer("pump_routes", srs, ogr.wkbMultiLineString)
    for nama, tipe in [("route_id", ogr.OFTString), ("pompa", ogr.OFTString), ("length_m", ogr.OFTReal),
                       ("penghubung_m", ogr.OFTReal), ("n_edge_terpilih", ogr.OFTInteger),
                       ("keterangan", ogr.OFTString)]:
        ol.CreateField(ogr.FieldDefn(nama, tipe))
    tak_terjangkau, n = 0, 0
    for anggota in sorted(kelompok, key=lambda a: min(jarak.get(v, 1e300) for v in a)):
        mulai = min(anggota, key=lambda v: jarak.get(v, 1e300))
        terjangkau = mulai in jarak
        geom = ogr.Geometry(ogr.wkbMultiLineString)
        sel = [k for k in edges if edges[k][2] and k[0] in anggota and k[1] in anggota]
        for k in sel:
            geom.AddGeometry(ogr.CreateGeometryFromWkb(edges[k][0]))
        penghubung, v = 0.0, mulai
        while terjangkau and v not in pompa:
            u = induk[v]
            k = (min(u, v), max(u, v))
            geom.AddGeometry(ogr.CreateGeometryFromWkb(edges[k][0]))
            penghubung += edges[k][1]
            v = u
        f = ogr.Feature(ol.GetLayerDefn())
        if terjangkau:
            n += 1
            f["route_id"] = f"R-{n:03d}"
            f["pompa"] = pompa[asal[mulai]]
            f["keterangan"] = "rekonstruksi jalur terpendek"
        else:
            tak_terjangkau += 1
            f["route_id"] = f"U-{tak_terjangkau:03d}"
            f["keterangan"] = "tidak tersambung ke pompa"
        f["length_m"] = round(geom.Length(), 1)
        f["penghubung_m"] = round(penghubung, 1)
        f["n_edge_terpilih"] = len(sel)
        f.SetGeometry(geom)
        ol.CreateFeature(f)
    print(f"{len(pompa)} pompa, {len(kelompok)} kelompok edge terpilih: {n} rute ditulis, "
          f"{tak_terjangkau} kelompok tidak tersambung ke pompa (ditulis tanpa pompa)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
