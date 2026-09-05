#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["ezdxf>=1.3"]
# ///
"""Read-only CAD extractor — DXF natively, DWG via the ODA File Converter.

Three subcommands, meant to be used in this order:

    probe   inventory first: units, extents, layers, entity census, blocks
    text    every text-bearing entity (TEXT/MTEXT/ATTRIB/DIMENSION/LEADER)
    geom    geometry of chosen layers: lengths, closed-polyline areas, bboxes

Why an inventory step exists: a real drawing holds 10k-100k entities. Dumping
them into a model context costs more than it informs, and the answer to most
questions ("which layer holds the walls?", "what unit is this in?") is in the
summary. Query narrowly after probing.

This tool never writes to the drawing. Conversion output goes to a temp dir.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import ezdxf
from ezdxf.document import Drawing

# $INSUNITS header value -> name. 0 means the author never declared one, which
# is the common case in Korean architectural DXF; treat it as unknown, not mm.
INSUNITS = {
    0: "unitless", 1: "in", 2: "ft", 3: "mi", 4: "mm", 5: "cm", 6: "m",
    7: "km", 8: "uin", 9: "mil", 10: "yd", 11: "angstrom", 12: "nm",
    13: "um", 14: "dm", 15: "dam", 16: "hm", 17: "gm", 18: "au",
    19: "ly", 20: "pc",
}

TEXT_TYPES = ("TEXT", "MTEXT", "ATTRIB", "ATTDEF", "DIMENSION", "MULTILEADER", "LEADER")


def die(msg: str) -> "None":
    sys.exit(f"error: {msg}")


# --------------------------------------------------------------------------
# loading


def _convert_dwg(path: Path, tmpdir: str) -> Path:
    """DWG is a proprietary binary container; nothing in Python parses it well.

    The ODA File Converter is the only converter treated as production-grade.
    If it is absent we stop loudly — a silent fallback would hand back an empty
    drawing and every downstream count would read as a truthful zero.
    """
    exe = os.environ.get("ODAFC_PATH") or shutil.which("ODAFileConverter")
    if not exe:
        die(
            "DWG needs the ODA File Converter, which is not installed.\n"
            "  install: see references/dwg-setup.md in this skill\n"
            "  or set ODAFC_PATH=/path/to/ODAFileConverter\n"
            "  or ask for a DXF export of the drawing (usually the cheaper route)."
        )
    indir = Path(tmpdir) / "in"
    outdir = Path(tmpdir) / "out"
    indir.mkdir()
    outdir.mkdir()
    shutil.copy(path, indir / path.name)
    # ODAFileConverter <in> <out> <version> <type> <recurse> <audit> [filter]
    proc = subprocess.run(
        [exe, str(indir), str(outdir), "ACAD2018", "DXF", "0", "1", path.name],
        capture_output=True,
        text=True,
    )
    # Success is judged by output, not by exit status: the converter exits
    # non-zero on Linux even on successful runs (ezdxf carries the same note).
    produced = sorted(outdir.glob("*.dxf"))
    if not produced:
        die(
            f"ODA File Converter produced no DXF (exit {proc.returncode}).\n"
            f"  stdout: {proc.stdout.strip()[:400]}\n"
            f"  stderr: {proc.stderr.strip()[:400]}\n"
            "  A headless box usually needs a virtual display: xvfb-run -a <cmd>."
        )
    return produced[0]


def load(path_str: str, tmpdir: str) -> Drawing:
    path = Path(path_str).expanduser()
    if not path.is_file():
        die(f"not a file: {path}")
    suffix = path.suffix.lower()
    if suffix == ".dwg":
        path = _convert_dwg(path, tmpdir)
    elif suffix not in (".dxf", ".dxb"):
        die(
            f"unsupported extension '{suffix}'. This tool reads DXF and DWG.\n"
            "  PDF drawings are a different problem entirely — see the skill body."
        )
    try:
        return ezdxf.readfile(str(path))
    except (ezdxf.DXFStructureError, IOError) as exc:
        die(f"not a readable DXF: {exc}")
    except UnicodeDecodeError:
        die(
            "encoding error — the DXF is probably a legacy code-page file.\n"
            "  retry with: ezdxf.readfile(path, encoding='cp949')  (Korean drawings)"
        )


# --------------------------------------------------------------------------
# geometry helpers


def _wcs_points(entity, points) -> list:
    """Lift OCS points to WCS when the entity sits on a tilted plane.

    Entities carry their coordinates in their own Object Coordinate System.
    While the extrusion is +Z the two systems coincide, so most code that
    ignores OCS looks correct — right up to the mirrored or rotated block where
    extrusion is -Z and every X flips sign.
    """
    extrusion = getattr(entity.dxf, "extrusion", (0, 0, 1))
    if tuple(round(c, 9) for c in extrusion) == (0.0, 0.0, 1.0):
        return [(p[0], p[1]) for p in points]
    ocs = entity.ocs()
    out = []
    for p in points:
        w = ocs.to_wcs((p[0], p[1], 0))
        out.append((w.x, w.y))
    return out


def _polyline_points(entity, distance: float = 1.0) -> list:
    """Polyline vertices with arcs resolved into short straight segments.

    Reading `get_points()` directly loses the bulge value each vertex carries,
    and a bulge is an arc: a half-circle stored as two vertices then measures as
    the chord. On a 1000-unit half-circle that is 1000 instead of 2571, and the
    enclosed area collapses to zero — silently, with no error anywhere.

    `make_path` resolves bulges and lifts OCS to WCS in one step. `distance` is
    the maximum deviation from the true arc, in drawing units.
    """
    from ezdxf import path as ezpath

    try:
        points = [(v.x, v.y) for v in ezpath.make_path(entity).flattening(distance)]
    except (ValueError, TypeError):
        return []
    # make_path repeats the first vertex to close the loop; drop it so callers
    # can decide about closure themselves.
    if len(points) > 2 and math.dist(points[0], points[-1]) < 1e-9:
        points.pop()
    return points


def _length(points: list, closed: bool) -> float:
    pts = points + [points[0]] if closed and len(points) > 2 else points
    return sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def _area(points: list) -> float:
    """Shoelace. Only meaningful for a closed, non-self-intersecting outline."""
    if len(points) < 3:
        return 0.0
    s = 0.0
    for i in range(len(points)):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % len(points)]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2.0


# --------------------------------------------------------------------------
# text extraction


def _entity_texts(entity) -> list:
    """Return [(kind, text)] for one entity. Empty strings are dropped later."""
    kind = entity.dxftype()
    if kind in ("TEXT", "ATTRIB", "ATTDEF"):
        return [(kind, entity.dxf.text)]
    if kind == "MTEXT":
        # plain_text() strips the \pxq;\H1.2x; formatting codes that make raw
        # MTEXT unreadable and unmatchable by regex.
        return [(kind, entity.plain_text(split=False))]
    if kind == "DIMENSION":
        override = entity.dxf.get("text", "")
        if override in ("", "<>"):
            # "<>" means "show the measured value", which is not stored as text.
            try:
                return [("DIMENSION", f"{entity.get_measurement():.6g}")]
            except Exception:
                return []
        return [("DIMENSION", override)]
    if kind == "MULTILEADER":
        try:
            return [("MULTILEADER", entity.get_mtext_context().plain_text(split=False))]
        except Exception:
            return []
    return []


def _location(entity):
    for attr in ("insert", "location", "text_midpoint", "defpoint"):
        if entity.dxf.hasattr(attr):
            p = entity.dxf.get(attr)
            return (round(p[0], 3), round(p[1], 3))
    return ("", "")


# --------------------------------------------------------------------------
# subcommands


def _extents(doc: Drawing, msp):
    """Drawing bounds, preferring the header but not trusting it.

    $EXTMIN/$EXTMAX are a cache that AutoCAD refreshes on regen. A file saved
    without one carries the sentinel ±1e20, and a file edited after the last
    regen carries stale bounds. Both read as plausible numbers to a caller who
    just prints the header, so measure the geometry when the header looks wrong.
    """
    lo = tuple(doc.header.get("$EXTMIN", (0, 0, 0)))
    hi = tuple(doc.header.get("$EXTMAX", (0, 0, 0)))
    sane = all(abs(c) < 1e19 for c in lo[:2] + hi[:2])
    if sane and hi[0] > lo[0] and hi[1] > lo[1]:
        return lo, hi, "header ($EXTMIN/$EXTMAX)"
    try:
        from ezdxf import bbox

        cache = bbox.extents(msp, fast=True)
        if cache.has_data:
            return (tuple(cache.extmin), tuple(cache.extmax),
                    "computed from entities (header was unset/stale)")
    except Exception:
        pass
    return (0, 0, 0), (0, 0, 0), "unknown (header unset and geometry scan failed)"


def cmd_probe(doc: Drawing, args) -> None:
    msp = doc.modelspace()
    header = doc.header
    insunits = header.get("$INSUNITS", 0)
    layers = {}
    census = {}
    inserts = {}
    text_count = 0
    for e in msp:
        kind = e.dxftype()
        census[kind] = census.get(kind, 0) + 1
        layers[e.dxf.layer] = layers.get(e.dxf.layer, 0) + 1
        if kind == "INSERT":
            inserts[e.dxf.name] = inserts.get(e.dxf.name, 0) + 1
        if kind in TEXT_TYPES:
            text_count += 1

    ext_min, ext_max, ext_source = _extents(doc, msp)
    report = {
        "file": args.file,
        "dxfversion": doc.dxfversion,
        "acad_release": doc.acad_release,
        "units": INSUNITS.get(insunits, f"code {insunits}"),
        "units_declared": insunits != 0,
        "measurement": "metric" if header.get("$MEASUREMENT", 1) == 1 else "imperial",
        "extents": {
            "min": [round(c, 3) for c in ext_min[:2]],
            "max": [round(c, 3) for c in ext_max[:2]],
            "size": [round(ext_max[0] - ext_min[0], 3), round(ext_max[1] - ext_min[1], 3)],
            "source": ext_source,
        },
        "modelspace_entities": sum(census.values()),
        "text_entities": text_count,
        "layouts": [name for name in doc.layout_names() if name != "Model"],
        "layers_defined": len(doc.layers),
        "layers_used": dict(sorted(layers.items(), key=lambda kv: -kv[1])),
        "entity_census": dict(sorted(census.items(), key=lambda kv: -kv[1])),
        "block_inserts": dict(sorted(inserts.items(), key=lambda kv: -kv[1])),
        "xrefs": [b.name for b in doc.blocks if b.block.dxf.get("xref_path", "")],
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    print(f"file        {report['file']}")
    print(f"format      {report['dxfversion']} ({report['acad_release']})")
    unit_note = "" if report["units_declared"] else "   <- NOT declared by the author"
    print(f"units       {report['units']}{unit_note}")
    print(f"extents     {report['extents']['min']} .. {report['extents']['max']}"
          f"  size={report['extents']['size']}")
    print(f"            source: {report['extents']['source']}")
    print(f"entities    {report['modelspace_entities']} in modelspace"
          f" ({report['text_entities']} carry text)")
    print(f"layouts     Model + {report['layouts'] or 'none'}")
    if report["xrefs"]:
        print(f"xrefs       {report['xrefs']}   <- external drawings, not loaded here")
    print(f"\nlayers used ({len(report['layers_used'])} of {report['layers_defined']} defined)")
    for name, n in list(report["layers_used"].items())[: args.top]:
        print(f"  {n:>8}  {name}")
    print("\nentity census")
    for name, n in list(report["entity_census"].items())[: args.top]:
        print(f"  {n:>8}  {name}")
    if report["block_inserts"]:
        print("\nblock inserts")
        for name, n in list(report["block_inserts"].items())[: args.top]:
            print(f"  {n:>8}  {name}")


def cmd_text(doc: Drawing, args) -> None:
    msp = doc.modelspace()
    rows = []

    def collect(entity, source: str) -> None:
        for kind, raw in _entity_texts(entity):
            value = " ".join(raw.split())
            if not value:
                continue
            if args.grep and args.grep.lower() not in value.lower():
                return
            x, y = _location(entity)
            rows.append((kind, entity.dxf.layer, x, y, source, value))

    for e in msp:
        if args.layer and e.dxf.layer != args.layer:
            continue
        collect(e, "model")
        if e.dxftype() == "INSERT":
            # Block content is invisible to a plain modelspace walk: the INSERT
            # is one entity, and the text lives inside the block definition.
            # Title blocks and room tags are almost always in here.
            for att in e.attribs:
                collect(att, f"attrib:{e.dxf.name}")
            if args.explode:
                for sub in e.virtual_entities():
                    if sub.dxftype() in TEXT_TYPES:
                        collect(sub, f"block:{e.dxf.name}")

    print(f"# {len(rows)} text entities" + (f" matching {args.grep!r}" if args.grep else ""))
    print("kind\tlayer\tx\ty\tsource\ttext")
    for row in rows[: args.limit]:
        print("\t".join(str(c) for c in row))
    if len(rows) > args.limit:
        print(f"# ... {len(rows) - args.limit} more (raise --limit or narrow with --layer/--grep)")


def cmd_geom(doc: Drawing, args) -> None:
    msp = doc.modelspace()
    query = "LINE LWPOLYLINE POLYLINE CIRCLE ARC"
    rows = []
    totals = {"length": 0.0, "closed_area": 0.0, "closed_count": 0}
    for e in msp.query(query):
        if args.layer and e.dxf.layer != args.layer:
            continue
        kind = e.dxftype()
        length = area = 0.0
        closed = False
        if kind == "LINE":
            start = _wcs_points(e, [(e.dxf.start[0], e.dxf.start[1])])[0]
            end = _wcs_points(e, [(e.dxf.end[0], e.dxf.end[1])])[0]
            length = math.dist(start, end)
            pts = [start, end]
        elif kind == "CIRCLE":
            length = 2 * math.pi * e.dxf.radius
            area = math.pi * e.dxf.radius**2
            closed = True
            c = _wcs_points(e, [(e.dxf.center[0], e.dxf.center[1])])[0]
            r = e.dxf.radius
            pts = [(c[0] - r, c[1] - r), (c[0] + r, c[1] + r)]
        elif kind == "ARC":
            sweep = (e.dxf.end_angle - e.dxf.start_angle) % 360
            length = math.radians(sweep) * e.dxf.radius
            pts = _wcs_points(e, [(e.dxf.center[0], e.dxf.center[1])])
        else:
            pts = _polyline_points(e, args.precision)
            if not pts:
                continue
            closed = bool(e.closed) if hasattr(e, "closed") else bool(e.is_closed)
            length = _length(pts, closed)
            if closed:
                area = _area(pts)
        totals["length"] += length
        if closed and area:
            totals["closed_area"] += area
            totals["closed_count"] += 1
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        rows.append(
            (
                kind,
                e.dxf.layer,
                len(pts),
                "closed" if closed else "open",
                round(length, 3),
                round(area, 3),
                f"{round(min(xs),1)},{round(min(ys),1)}",
                f"{round(max(xs),1)},{round(max(ys),1)}",
            )
        )

    rows.sort(key=lambda r: -r[4])
    unit = INSUNITS.get(doc.header.get("$INSUNITS", 0), "?")
    print(f"# {len(rows)} entities · drawing units = {unit}"
          f" (lengths and areas are in those units, NOT metres)")
    print(f"# total length {totals['length']:.3f}"
          f" · {totals['closed_count']} closed outlines, area sum {totals['closed_area']:.3f}")
    print("kind\tlayer\tpts\tclosed\tlength\tarea\tbbox_min\tbbox_max")
    for row in rows[: args.limit]:
        print("\t".join(str(c) for c in row))
    if len(rows) > args.limit:
        print(f"# ... {len(rows) - args.limit} more (raise --limit or narrow with --layer)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="inventory: units, extents, layers, census, blocks")
    p.add_argument("file")
    p.add_argument("--json", action="store_true")
    p.add_argument("--top", type=int, default=40, help="rows per table (default 40)")
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("text", help="every text-bearing entity as TSV")
    p.add_argument("file")
    p.add_argument("--layer")
    p.add_argument("--grep", help="case-insensitive substring filter")
    p.add_argument("--explode", action="store_true", help="also read TEXT inside block definitions")
    p.add_argument("--limit", type=int, default=500)
    p.set_defaults(func=cmd_text)

    p = sub.add_parser("geom", help="lengths, closed-outline areas and bboxes as TSV")
    p.add_argument("file")
    p.add_argument("--layer")
    p.add_argument("--limit", type=int, default=200)
    p.add_argument("--precision", type=float, default=1.0,
                   help="max deviation when straightening arcs, in drawing units"
                        " (default 1.0 — lower it for metre-unit drawings)")
    p.set_defaults(func=cmd_geom)

    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="cadread-") as tmpdir:
        args.func(load(args.file, tmpdir), args)


if __name__ == "__main__":
    main()
