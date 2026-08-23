"""Rebuilds Assets/Fonts/tabler-icons.ttf from Tabler's outline SVGs at a
custom stroke width.

The shipped font contains ONLY the glyphs listed in codepoints.json (at
their official Tabler codepoints) plus brand logos from simple-icons at
private codepoints (brands.json, 0xF900+). To add a Tabler icon: find its
name and codepoint at https://tabler.io/icons, add it to codepoints.json,
use the codepoint in XAML, re-run this script. Brand logos: add the
simple-icons slug to brands.json with a free 0xF9xx codepoint.

Setup (once):
    npm install @tabler/icons oslllo-svg-fixer simple-icons
    pip install fonttools

Usage:
    python build.py [--stroke 1.25]
"""

import argparse
import json
import pathlib
import subprocess
import tempfile

from fontTools.fontBuilder import FontBuilder
from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import SVGPath

HERE = pathlib.Path(__file__).parent
TARGET = HERE / ".." / ".." / "src" / "Zharp.App" / "Assets" / "Fonts" / "tabler-icons.ttf"
SVG_SOURCE = HERE / "node_modules" / "@tabler" / "icons" / "icons" / "outline"

# Metrics copied from the original Tabler webfont so glyphs align identically.
UPM, ASCENT, DESCENT, ADVANCE = 1000, 900, -100, 1000


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stroke", default="1.25", help="stroke width on the 24px grid")
    args = parser.parse_args()

    codepoints = json.loads((HERE / "codepoints.json").read_text())

    with tempfile.TemporaryDirectory() as tmp:
        raw = pathlib.Path(tmp) / "raw"
        fixed = pathlib.Path(tmp) / "fixed"
        raw.mkdir()
        fixed.mkdir()

        for name in codepoints:
            svg = (SVG_SOURCE / f"{name}.svg").read_text(encoding="utf-8")
            svg = svg.replace('stroke-width="2"', f'stroke-width="{args.stroke}"')
            (raw / f"{name}.svg").write_text(svg, encoding="utf-8")

        # Fonts hold filled outlines; strokes must be traced to paths first.
        subprocess.run(
            ["npx", "oslllo-svg-fixer", "-s", str(raw), "-d", str(fixed)],
            check=True, shell=True, cwd=HERE,
        )

        transform = Transform(UPM / 24.0, 0, 0, -UPM / 24.0, 0, ASCENT)
        brands = json.loads((HERE / "brands.json").read_text()) if (HERE / "brands.json").exists() else {}
        overlap = set(codepoints.values()) & set(brands.values())
        if overlap:
            raise SystemExit(f"codepoint collision: {sorted(hex(c) for c in overlap)}")
        order = [".notdef"] + sorted(codepoints) + sorted(brands)
        glyphs, metrics, cmap = {}, {}, {}
        glyphs[".notdef"] = TTGlyphPen(None).glyph()
        metrics[".notdef"] = (ADVANCE, 0)

        def add_glyph(name, svg_path, codepoint):
            pen = TTGlyphPen(None)
            SVGPath(str(svg_path), transform=transform).draw(Cu2QuPen(pen, max_err=1.0))
            glyph = pen.glyph()
            bounds = BoundsPen(None)
            glyph.draw(bounds, glyphs)
            glyphs[name] = glyph
            metrics[name] = (ADVANCE, int(bounds.bounds[0]) if bounds.bounds else 0)
            cmap[codepoint] = name

        for name in sorted(codepoints):
            add_glyph(name, fixed / f"{name}.svg", codepoints[name])

        # Brand logos ship as filled paths already - no stroke tracing needed.
        for name in sorted(brands):
            add_glyph(name, HERE / "node_modules" / "simple-icons" / "icons" / f"{name}.svg",
                      brands[name])

    builder = FontBuilder(UPM, isTTF=True)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap(cmap)
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    builder.setupNameTable({
        "familyName": "tabler-icons", "styleName": "Regular",
        "fullName": "tabler-icons", "psName": "tabler-icons",
        "uniqueFontIdentifier": f"tabler-icons-light-{args.stroke}",
    })
    builder.setupOS2(sTypoAscender=ASCENT, sTypoDescender=DESCENT,
                     sTypoLineGap=90, usWinAscent=990, usWinDescent=104)
    builder.setupPost()
    builder.save(str(TARGET.resolve()))
    print(f"wrote {TARGET.resolve()} ({len(cmap)} glyphs, stroke {args.stroke})")


if __name__ == "__main__":
    main()
