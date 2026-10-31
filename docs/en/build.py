"""Build the four English PDF documents (DDD, ERD, Database Schema, SAD).

ERD and Database Schema are generated from schema_snapshot.json (see introspect.sql),
so they always match the real database. Run from anywhere:  python3 docs/en/build.py
Needs: pandoc, Google Chrome, Python playwright, pdftotext (poppler).
"""
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "pdf"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SNAP = json.loads((HERE / "schema_snapshot.json").read_text())
TABLES = {f"{t['schema']}.{t['name']}": t for t in SNAP["tables"]}

DESC = {
    "ref.provinsi": "Province (38 rows, official Ministry of Home Affairs codes as primary key).",
    "ref.kabupaten": "Regency or city within a province.",
    "ref.kecamatan": "District within a regency.",
    "ref.desa": "Village. The 2,004 target villages for 2026 carry a boundary polygon.",
    "ref.khg": "Peat Hydrological Unit (KHG). Boundary dissolved from national analysis units.",
    "ref.perusahaan": "Company holding a plantation, forestry or mining permit.",
    "ref.jenis_kanal": "Code list: canal class (1 primary, 2 secondary, 3 tertiary).",
    "ref.status_kanal": "Code list: canal survey status (active, inactive, blocked).",
    "ref.status_sekat": "Code list: canal block status (planned, existing, damaged, removed).",
    "ref.status_pompa": "Code list: pump status (planned, installed, damaged).",
    "ref.kondisi_sumur": "Code list: deep well condition (working, damaged, unverified).",
    "ref.status_alur": "Code list: plan version status with display order and colour.",
    "ref.fungsi_kawasan": "Code list: forest area function (for example HP, HL, APL).",
    "ref.penutupan_lahan": "Code list: land cover class 2022.",
    "ref.kerusakan_eg": "Code list: peat ecosystem damage level 2024 with severity order.",
    "peta.sungai": "River line used as a water source for pumps. Editable.",
    "peta.kanal": "Canal segment from the 2025 OpenStreetMap seamless canal layer. Editable.",
    "peta.sekat": "Canal block, planned or existing. Editable. Aggregate root.",
    "peta.sekat_konteks": "One to one overlay context of a planned canal block (village, permit, land cover, peat, burn history).",
    "peta.sekat_bangunan": "One to one construction details of an existing canal block (budget, contractor, material, year).",
    "peta.pompa": "Planned or installed pump with suitability scores. Editable.",
    "peta.pintu_air": "Water gate. Editable.",
    "peta.posko_karhutla": "Forest and land fire post. Editable.",
    "peta.logger_tmat": "Groundwater level logger location. Editable.",
    "peta.tmat_bacaan": "Groundwater depth reading per logger and timestamp.",
    "peta.hotspot": "Satellite fire hotspot (MODIS or VIIRS), January to September 2026.",
    "peta.areal_terbakar": "Burned area polygon with the list of burn years 2015 to 2026.",
    "peta.ketebalan_gambut": "Peat thickness class polygon per KHG.",
    "peta.konsesi": "Concession polygon per company, dissolved from analysis units.",
    "peta.sumur_bor": "Deep well. Synchronised from the external Deep Well system. Editable.",
    "peta.sumur_debit": "Daily discharge of a deep well.",
    "peta.v_khg_legenda": "View: feature count per layer and KHG (map legend numbers).",
    "peta.v_sekat": "View: canal block with overlay context and region names.",
    "peta.v_sumur_bor": "View: deep well with latest discharge.",
    "peta.v_tmat_alert": "View: loggers whose latest groundwater depth exceeds 0.4 m.",
    "analisis.unit_nasional": "National analysis unit (overlay of KHG, village, permit, forest function, peat and burn history).",
    "analisis.unit_target_2026": "Analysis unit inside the 2,004 target villages for 2026.",
    "analisis.kontur": "Contour line from WorldDEM for 108 BRGM target KHG.",
    "analisis.kontur_lidar": "Contour line at 50 cm interval from LiDAR (Riau, Jambi, South Sumatra).",
    "alur.pengguna": "Application user profile (name, agency, role).",
    "alur.khg_versi": "Plan version of a KHG. Aggregate root of the review workflow.",
    "alur.perubahan": "Change record written by the audit trigger for every create, update and delete.",
    "alur.komentar": "Review comment on a version or on a single feature, with threaded replies.",
    "alur.template_poster": "Poster layout template (QGIS print layout file).",
    "alur.ekspor_poster": "Poster export job with paper size, progress and output file.",
    "alur.v_khg_status": "View: latest version and status per KHG.",
    "alur.v_khg_daftar": "View: KHG list with counts and priority score (internal).",
    "alur.v_dashboard": "View: one row of national dashboard indicators.",
    "api.khg_statistik": "Materialized view: expensive KHG statistics, refreshed daily.",
}
for n in ["khg", "desa", "sekat", "hotspot", "areal_terbakar", "konsesi", "ketebalan_gambut", "sumur_bor",
          "kanal", "unit_target_2026", "unit_nasional", "kontur", "kontur_lidar"]:
    DESC.setdefault(f"api.{n}", f"Public view published as OGC API collection. Readable names instead of foreign keys.")

CONTEXTS = [
    ("Reference", "Administrative regions, KHG and companies. Shared by every other context.",
     ["ref.provinsi", "ref.kabupaten", "ref.kecamatan", "ref.desa", "ref.khg", "ref.perusahaan"]),
    ("Infrastructure Planning", "Canals, canal blocks, pumps, gates and rivers that form a KHG plan.",
     ["peta.kanal", "peta.sekat", "peta.sekat_konteks", "peta.sekat_bangunan", "peta.pompa", "peta.pintu_air", "peta.sungai"]),
    ("Risk", "Fire hotspots, burned areas, peat thickness and concessions.",
     ["peta.hotspot", "peta.areal_terbakar", "peta.ketebalan_gambut", "peta.konsesi"]),
    ("Field Monitoring", "Groundwater loggers, deep wells, fire posts and their time series.",
     ["peta.logger_tmat", "peta.tmat_bacaan", "peta.sumur_bor", "peta.sumur_debit", "peta.posko_karhutla"]),
    ("Spatial Analysis", "Read-only analysis units and contour lines.",
     ["analisis.unit_nasional", "analisis.unit_target_2026", "analisis.kontur", "analisis.kontur_lidar"]),
    ("Plan Review", "Plan versions, change records, comments and poster exports.",
     ["alur.khg_versi", "alur.perubahan", "alur.komentar", "alur.pengguna", "alur.template_poster", "alur.ekspor_poster"]),
]
LOOKUPS = [k for k in TABLES if k.startswith("ref.") and k not in CONTEXTS[0][2]]
META = {"created_at", "created_by", "updated_at", "updated_by", "updated_via", "rev"}


def fks(t):
    """[(column, parent 'schema.table', not_null)] for a table."""
    out = []
    cols = {c["name"]: c for c in t["columns"] or []}
    for c in t["constraints"] or []:
        if c["type"] == "f":
            col = re.search(r"FOREIGN KEY \((\w+)\)", c["def"]).group(1)
            parent = c["ref_table"] if "." in c["ref_table"] else f"public.{c['ref_table']}"
            out.append((col, parent, cols[col]["not_null"]))
    return out


def pk_cols(t):
    for c in t["constraints"] or []:
        if c["type"] == "p":
            return re.search(r"PRIMARY KEY \(([^)]+)\)", c["def"]).group(1).replace(" ", "").split(",")
    return []


def mtype(sqltype):
    """Mermaid ER attribute types cannot contain spaces or brackets."""
    t = sqltype.replace("timestamp with time zone", "timestamptz").replace("character varying", "varchar")
    m = re.match(r"geometry\((\w+),\d+\)", t)
    if m:
        return m.group(1)
    t = re.sub(r"\(.*?\)", "", t).replace("[]", "_array").replace(" ", "_")
    return t


def ent(key, cols_limit=None, stub=False):
    t = TABLES[key]
    name = key.split(".")[1]
    if stub:
        return f"  {name} {{\n    int id PK\n  }}"
    pks, fkc = pk_cols(t), {c for c, _, _ in fks(t)}
    rows = []
    for c in t["columns"]:
        if c["name"] in META:
            continue
        keys = ",".join(k for k, ok in (("PK", c["name"] in pks), ("FK", c["name"] in fkc)) if ok)
        important = keys or c["type"].startswith("geometry") or c["name"] in ("kode", "nama", "status", "waktu", "tahun_terbakar")
        rows.append((not important, f"    {mtype(c['type'])} {c['name']}{' ' + keys if keys else ''}"))
    if cols_limit:
        rows = sorted(rows, key=lambda r: r[0])[:cols_limit]
    return f"  {name} {{\n" + "\n".join(r for _, r in rows) + "\n  }"


def erd_block(members):
    lines, stubs = ["erDiagram"], set()
    for key in members:
        t = TABLES[key]
        for col, parent, nn in fks(t):
            if parent in LOOKUPS:
                continue
            if parent not in members:
                stubs.add(parent)
            lines.append(f"  {parent.split('.')[1]} {'||' if nn else 'o|'}--o{{ {key.split('.')[1]} : {col}")
    for key in members:
        lines.append(ent(key, cols_limit=9))
    for s in sorted(stubs):
        lines.append(ent(s, stub=True))
    return "\n".join(lines)


def build_erd_md():
    md = ["# Introduction", "",
          "This document shows the entities of the Peat Rewetting Planning database and how they relate. "
          "The diagrams are generated from the live database catalogue, so they match the implementation exactly. "
          f"The snapshot covers {sum(1 for t in SNAP['tables'] if t['kind'] == 'table')} tables, "
          f"{sum(1 for t in SNAP['tables'] if t['kind'] != 'table')} views and "
          f"{sum(len(fks(t)) for t in SNAP['tables'])} foreign keys on PostgreSQL {SNAP['versions']['postgres'].split()[0]} "
          f"with PostGIS {SNAP['versions']['postgis']}.", "",
          "## How to read the diagrams", "",
          "| Notation | Meaning |", "|---|---|",
          "| `\\|\\|--o{` | One parent row has zero or many child rows; the child must have a parent |",
          "| `o\\|--o{` | Optional parent: the foreign key may be empty |",
          "| PK, FK | Primary key, foreign key |",
          "| Point, MultiPolygon, MultiLineString | PostGIS geometry type, always EPSG:4326 (longitude, latitude) |",
          "| Entity with only `id` | Entity from another context, shown for context |", "",
          "To keep the diagrams readable, two groups of columns are left out:", "",
          "- **Audit columns** present on every operational layer: `created_at`, `created_by`, `updated_at`, "
          "`updated_by`, `updated_via`, `rev`.",
          "- **Lookup references** to code lists. They are listed in the section *Code lists*.", "",
          "The full column list of every table is in the *Database Schema* document.", "",
          "# Overview", "",
          "```{.mermaid}", "flowchart LR"]
    for i, (name, _, members) in enumerate(CONTEXTS):
        md.append(f"  C{i}[\"{name}<br/>{len(members)} entities\"]")
    md += ["  C0 --> C1", "  C0 --> C2", "  C0 --> C3", "  C0 --> C4", "  C0 --> C5",
           "  C4 -. dissolve .-> C0", "  C4 -. dissolve .-> C2",
           "  C1 -. change records .-> C5", "  C3 -. change records .-> C5", "```",
           '<p class="figure-note">Figure 1. Contexts and their dependencies. Solid lines are foreign keys, '
           'dotted lines are data flows (dissolve during load, change records written by triggers).</p>', ""]
    md += ["| Context | Entities | Rows |", "|---|---|---:|"]
    for name, _, members in CONTEXTS:
        rows = sum(TABLES[m]["rows"] or 0 for m in members)
        md.append(f"| {name} | {', '.join('`' + m.split('.')[1] + '`' for m in members)} | {rows:,} |")
    md.append("")
    for i, (name, desc, members) in enumerate(CONTEXTS, start=2):
        md += [f"# {name}", "", desc, "", "```{.mermaid}", erd_block(members), "```",
               f'<p class="figure-note">Figure {i}. {name} entities.</p>', "",
               "| Entity | Description | Rows |", "|---|---|---:|"]
        for m in members:
            md.append(f"| `{m}` | {DESC.get(m, '-')} | {TABLES[m]['rows']:,} |")
        md += ["", "| Parent | Child | Foreign key | Cardinality |", "|---|---|---|---|"]
        for m in members:
            for col, parent, nn in fks(TABLES[m]):
                if parent in LOOKUPS:
                    continue
                md.append(f"| `{parent}` | `{m}` | `{col}` | {'1 to many (required)' if nn else '0..1 to many (optional)'} |")
        md.append("")
    md += ["# Code lists", "", "Code lists are small reference tables. They are used as foreign keys instead of "
           "PostgreSQL ENUM types, so QGIS can show them as drop-down lists and new values need only an INSERT.", "",
           "| Code list | Rows | Used by |", "|---|---:|---|"]
    for lk in LOOKUPS:
        users = sorted({f"`{k}.{c}`" for k, t in TABLES.items() for c, p, _ in fks(t) if p == lk})
        md.append(f"| `{lk}` | {TABLES[lk]['rows']} | {', '.join(users) or 'display only'} |")
    md += ["", "# Public read model", "",
           "The `api` schema contains views over the entities above. They join names from the reference "
           "context so that API users see readable values instead of ids. They have no relationships of their own.", "",
           "| View | Built from | Description |", "|---|---|---|"]
    srcmap = {"khg": "ref.khg, alur.v_khg_status, api.khg_statistik", "desa": "ref.desa and regions",
              "sekat": "peta.sekat, sekat_konteks, sekat_bangunan", "kanal": "peta.kanal and code lists",
              "khg_statistik": "hotspot, kanal, sekat, analysis units"}
    for k, t in TABLES.items():
        if k.startswith("api."):
            n = k.split(".")[1]
            md.append(f"| `{k}` | {srcmap.get(n, 'peta or analisis table of the same name')} | {DESC.get(k, '-')} |")
    return "\n".join(md) + "\n"


def strip_on(indexdef):
    return re.sub(r" ON [a-z_]+\.[a-z_0-9]+", "", indexdef)


def trig_when(d):
    return re.sub(r"^CREATE TRIGGER \w+ ", "", d).split(" ON ")[0]


def trig_fn(d):
    return re.search(r"EXECUTE FUNCTION (.+)$", d).group(1)


def page_count(info):
    return re.search(r"Pages:\s+(\d+)", info).group(1)


def human_type(c):
    t = c["type"]
    if c["identity"]:
        t += " identity"
    if c["generated"]:
        t += " generated"
    return t


def cell(s):
    return (s or "").replace("|", "\\|").replace("\n", " ")


def build_schema_md():
    md = ["# Introduction", "",
          "This document is the reference for every table, view, column, constraint, index, trigger and function "
          "in the `gambut` database. It is generated from the live database catalogue "
          f"(PostgreSQL {SNAP['versions']['postgres'].split()[0]}, PostGIS {SNAP['versions']['postgis']}, "
          f"database size {SNAP['db_size'].replace('MB', 'MB')}).", "",
          "# Conventions", "",
          "| Topic | Convention |", "|---|---|",
          "| Coordinate system | Every geometry is stored in EPSG:4326 (longitude, latitude). Distances in metres are computed on the geography type. |",
          "| Primary keys | `bigint` or `int` identity column `id`, one geometry column per table, GiST index on every geometry. This keeps QGIS editing smooth. |",
          "| Names | Indonesian domain names in snake case, matching the language of the analysts (see the DDD glossary). |",
          "| Code lists | Small tables in `ref` referenced by foreign keys, not ENUM types. |",
          "| Audit columns | Every `peta` layer has `khg_id`, `created_at`, `created_by`, `updated_at`, `updated_by`, `updated_via` (qgis, web, api, sync or import) and `rev` (optimistic lock counter). They are filled by triggers. |",
          "| Codes | Human codes (`P-n`, `SK-n`, `K-n`) are unique per KHG and assigned by a trigger when empty. |",
          "| Identity of the writer | `app.pengguna` and `app.via` session settings, falling back to the login role and its default channel. |", "",
          "# Schemas", "",
          "| Schema | Purpose | Tables | Views | Rows | Size |", "|---|---|---:|---:|---:|---:|"]
    purpose = {"ref": "Reference data and code lists", "peta": "Operational map layers, most of them editable",
               "analisis": "Large read-only analysis layers", "alur": "Plan versions, audit and poster exports",
               "api": "Public read model for the OGC API"}
    for s in purpose:
        ts = [t for t in SNAP["tables"] if t["schema"] == s]
        tb = [t for t in ts if t["kind"] == "table"]
        size = sum(t["bytes"] or 0 for t in ts) / 1024 ** 2
        md.append(f"| `{s}` | {purpose[s]} | {len(tb)} | {len(ts) - len(tb)} | "
                  f"{sum(t['rows'] or 0 for t in tb):,} | {size:,.0f} MB |")
    md.append("")
    for s in purpose:
        md += [f"# Schema {s}", "", purpose[s] + ".", ""]
        for t in [t for t in SNAP["tables"] if t["schema"] == s]:
            key = f"{s}.{t['name']}"
            info = t["kind"]
            if t["rows"] is not None:
                info += f", {t['rows']:,} rows, {t['bytes'] / 1024 ** 2:,.1f} MB"
            md += [f"## {key}", "", f"*{info}.* {DESC.get(key, '')}", "",
                   "| Column | Type | Null | Default or note |", "|---|---|---|---|"]
            pks, fkmap = pk_cols(t), {c: p for c, p, _ in fks(t)}
            for c in t["columns"]:
                note = []
                if c["name"] in pks:
                    note.append("primary key")
                if c["name"] in fkmap:
                    note.append(f"references `{fkmap[c['name']]}`")
                if c["default"] and not c["identity"] and not c["generated"]:
                    note.append(f"default `{cell(c['default'])}`")
                if c["generated"]:
                    note.append(f"`{cell(c['default'])}`")
                md.append(f"| `{c['name']}` | `{cell(human_type(c))}` | {'no' if c['not_null'] else 'yes'} | {'; '.join(note) or '-'} |")
            other = [c for c in t["constraints"] or [] if c["type"] in ("u", "c")]
            if other:
                md += ["", "Constraints:", ""] + [f"- `{cell(c['def'])}`" for c in other]
            idx = [i for i in t["indexes"] or [] if " UNIQUE " not in i or "_pkey" not in i]
            if idx:
                md += ["", "Indexes:", ""] + [f"- `{cell(strip_on(i))}`" for i in idx]
            if t["triggers"]:
                md += ["", "Triggers:", ""] + [
                    f"- `{tr['name']}`: `{cell(trig_when(tr['def']))}` executes `{trig_fn(tr['def'])}`"
                    for tr in t["triggers"]]
            md.append("")
    md += ["# Functions", "", "| Function | Returns | Security | Purpose |", "|---|---|---|---|"]
    fdesc = {
        "versi_terbuka": "Returns the open version of a KHG, creating version n+1 when needed.",
        "isi_meta": "Trigger: KHG from geometry, audit columns, revision counter.",
        "isi_kode": "Trigger: next human code per KHG.",
        "catat_perubahan": "Trigger: writes a change record linked to the open version.",
        "validasi_khg": "Runs the five automatic validation rules for a version.",
        "ajukan_review": "Submits a draft or revision for review with a validation snapshot.",
        "putuskan": "Records the reviewer decision (approved or revisi).",
        "tandai_dicetak": "Trigger: marks an approved version as printed after a poster export.",
        "daftar_singkat": "Formats a list of codes, shortened after ten items.",
        "saran_lokasi_pompa": "Ranks candidate pump locations along active canals.",
        "refresh_statistik": "Refreshes the materialized KHG statistics.",
    }
    for f in SNAP["functions"]:
        args = cell(f["args"]).replace("DEFAULT", "default")
        md.append(f"| `{f['schema']}.{f['name']}({args})` | `{cell(f['returns'])}` | "
                  f"{'definer' if f['security_definer'] else 'invoker'} | {fdesc.get(f['name'], '-')} |")
    md += ["", "# Roles and privileges", "", "| Role | Login | Member of | Settings | Purpose |", "|---|---|---|---|---|"]
    rdesc = {"gambut_baca": "Read all layers and public views", "gambut_edit": "Write planning layers, comments and exports",
             "ogc_reader": "pygeoapi read connection", "ogc_writer": "pygeoapi write connection",
             "web_app": "Web application backend", "editor_qgis": "Example QGIS editor account"}
    for r in SNAP["roles"]:
        md.append(f"| `{r['name']}` | {'yes' if r['login'] else 'no'} | {', '.join(r['member_of'] or []) or '-'} | "
                  f"{', '.join('`' + x + '`' for x in (r['settings'] or [])) or '-'} | {rdesc.get(r['name'], '-')} |")
    return "\n".join(md) + "\n"


DOCS = [
    ("01_DDD.md", "Domain-Driven Design", "Domain-Driven Design Document",
     "Business language, bounded contexts, aggregates, domain events and business rules of the peat rewetting planning domain."),
    ("02_ERD.md", "Entity Relationship Diagram", "Entity Relationship Diagram",
     "Entities, relationships and cardinalities of the PostGIS database, grouped by bounded context."),
    ("03_DATABASE_SCHEMA.md", "Database Schema", "Database Schema Reference",
     "Every schema, table, column, constraint, index, trigger, function and role of the gambut database."),
    ("04_SAD.md", "System Architecture", "System Architecture Document",
     "Structure, deployment, runtime behaviour, security, performance and decisions of the system."),
]


def check_text(name, text):
    """House rules: no em dash, no double spaces in prose."""
    bad = []
    if "\u2014" in text:
        bad.append("em dash")
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    prose = "\n".join(l for l in prose.splitlines() if not re.match(r"^\s*(\||-|\d+\.)?\s*$", l))
    for i, line in enumerate(prose.splitlines(), 1):
        if re.search(r"\S  +\S", line):
            bad.append(f"double space: {line.strip()[:70]}")
    assert not bad, f"{name}: {bad[:5]}"


def print_pdf(html, pdf):
    # Wait for the template's ready flag (fonts loaded, Mermaid rendered) before printing;
    # a fixed --virtual-time-budget printed blank diagrams on newer Chrome.
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=CHROME)
        page = browser.new_page()
        page.goto(html.as_uri())
        page.wait_for_selector("body[data-ready='1']", timeout=60000)
        page.pdf(path=str(pdf), prefer_css_page_size=True, print_background=True)
        browser.close()


def main():
    (HERE / "02_ERD.md").write_text(build_erd_md())
    (HERE / "03_DATABASE_SCHEMA.md").write_text(build_schema_md())
    OUT.mkdir(exist_ok=True)
    for fname, short, title, subtitle in DOCS:
        src = HERE / fname
        check_text(fname, src.read_text())
        html = HERE / (src.stem + ".html")
        subprocess.run(["pandoc", str(src), "-f", "markdown-smart", "-t", "html5", "--standalone", "--toc",
                        "--toc-depth=2", "--wrap=none", f"--template={HERE / 'template.html'}", "-M", f"title={title}",
                        "-M", f"short={short}", "-M", "kicker=Peat Rewetting Planning System",
                        "-M", f"subtitle={subtitle}", "-o", str(html)], check=True)
        pdf = OUT / f"{src.stem}.pdf"
        print_pdf(html, pdf)
        text = subprocess.run(["pdftotext", str(pdf), "-"], capture_output=True, text=True).stdout
        assert "\u2014" not in text, f"{pdf.name}: em dash in PDF"
        assert "Syntax error" not in text, f"{pdf.name}: mermaid syntax error"
        pages = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True).stdout
        print(f"{pdf.name}: {page_count(pages)} pages")
        html.unlink()


if __name__ == "__main__":
    main()
