"""
Generate the legacy-vs-rebuild diagram in three formats from one definition.

  docs/legacy_vs_rebuild.excalidraw   open and edit at https://excalidraw.com
  docs/legacy_vs_rebuild.svg          renders inline on GitHub
  docs/legacy_vs_rebuild.png          for LinkedIn and slides (needs rsvg-convert)

Usage:  python3 tools/make_diagram.py
"""

import json
import os
import random
import shutil
import subprocess
from xml.sax.saxutils import escape

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "docs")
NAME = "legacy_vs_rebuild"

random.seed(7)

# --------------------------------------------------------------- palette ---
AMBER, AMBER_FILL, AMBER_HEAD = "#f59e0b", "#ffe8cc", "#ffd8a8"
BLUE, BLUE_FILL, BLUE_HEAD = "#4a9eed", "#d0ebff", "#a5d8ff"
RED, RED_FILL, RED_TEXT = "#ef4444", "#ffc9c9", "#c92a2a"
GREEN, GREEN_FILL, GREEN_TEXT = "#22c55e", "#b2f2bb", "#15803d"
YELLOW_FILL = "#fff3bf"
INK, MUTED = "#1e1e1e", "#757575"

# ------------------------------------------------------- diagram content ---
# (label, note_under_box, note_colour) per stage, for each side.
LEGACY = [
    ("1. Read 2 CSVs", None),
    ("2. Filter status + date", "3 records gone, no log"),
    ("3. Summarize to AUM", "duplicate row counted twice"),
    ("4. Inner join, J anchor only", "6 records gone. $2.45M unbilled"),
    ("5. Rate / 4, minimum first", "one rate on the whole balance"),
    ("6. billing 116, exceptions 0", "empty every run since 2019"),
]
REBUILD = [
    ("1. Land 4 CSVs as text", None),
    ("2. Conform and validate", None),
    ("3. Build billable AUM", None),
    ("4. Join, unmatched logged", None),
    ("5. Marginal tiers, days / 365", None),
    ("6. billing 115, exceptions 33", "every variance attributed, 0 defects"),
]

LEFT_X, RIGHT_X, COL_W, BOX_H = 60, 480, 320, 58
ROW_Y0, ROW_PITCH = 196, 95
EXC = dict(x=850, y=291, w=230, h=200)
CANVAS_W, CANVAS_H = 1130, 800

# ------------------------------------------------------ shape primitives ---
# One neutral description of every element; both writers read from it.
shapes = []   # dicts: kind=rect|text|arrow


def rect(id_, x, y, w, h, label, stroke, fill, size=18, width=2):
    shapes.append(dict(kind="rect", id=id_, x=x, y=y, w=w, h=h, label=label,
                       stroke=stroke, fill=fill, size=size, width=width))


def text(id_, x, y, s, size, colour):
    shapes.append(dict(kind="text", id=id_, x=x, y=y, text=s, size=size,
                       colour=colour))


def arrow(id_, x1, y1, x2, y2, colour, start=None, end=None):
    shapes.append(dict(kind="arrow", id=id_, x1=x1, y1=y1, x2=x2, y2=y2,
                       colour=colour, start=start, end=end))


def build():
    text("title", 450, 34, "Legacy vs rebuild", 28, INK)
    text("subtitle", 296, 76,
         "Same six stages. Only one side tells you what it dropped.", 18, MUTED)

    rect("head_l", LEFT_X, 120, COL_W, 46, "Legacy Alteryx", AMBER, AMBER_HEAD, 22)
    rect("head_r", RIGHT_X, 120, COL_W, 46, "Rebuilt in SQL", BLUE, BLUE_HEAD, 22)

    for i, ((ll, ln), (rl, rn)) in enumerate(zip(LEGACY, REBUILD)):
        y = ROW_Y0 + i * ROW_PITCH
        last = i == len(LEGACY) - 1
        rect(f"l{i+1}", LEFT_X, y, COL_W, BOX_H, ll,
             RED if last else AMBER, RED_FILL if last else AMBER_FILL,
             width=3 if (last or i == 3) else 2)
        if ln:
            text(f"l{i+1}_note", LEFT_X + 4, y + BOX_H + 5, ln, 16, RED_TEXT)
        rect(f"r{i+1}", RIGHT_X, y, COL_W, BOX_H, rl,
             GREEN if last else BLUE, GREEN_FILL if last else BLUE_FILL,
             width=3 if last else 2)
        if rn:
            text(f"r{i+1}_note", RIGHT_X + 4, y + BOX_H + 5, rn, 16, GREEN_TEXT)

    rect("exc", EXC["x"], EXC["y"], EXC["w"], EXC["h"],
         "exception_log\n\n33 rows\n25 reason codes\n10 blocking",
         AMBER, YELLOW_FILL, 18, 3)

    # Stages 2-4 of the rebuild each send excluded records to the one log.
    for n, dy_end in ((2, 335), (3, 395), (4, 455)):
        y = ROW_Y0 + (n - 1) * ROW_PITCH + BOX_H / 2
        arrow(f"to_exc_{n}", RIGHT_X + COL_W, y, EXC["x"], dy_end, AMBER,
              start=f"r{n}", end="exc")


# ------------------------------------------------------ excalidraw writer ---
def _base(id_, type_, x, y, w, h, stroke, fill="transparent", width=2):
    return {
        "id": id_, "type": type_, "x": x, "y": y, "width": w, "height": h,
        "angle": 0, "strokeColor": stroke, "backgroundColor": fill,
        "fillStyle": "solid", "strokeWidth": width, "strokeStyle": "solid",
        "roughness": 1, "opacity": 100, "groupIds": [], "frameId": None,
        "roundness": None, "seed": random.randint(1, 2**31 - 1),
        "version": 1, "versionNonce": random.randint(1, 2**31 - 1),
        "isDeleted": False, "boundElements": [], "updated": 1,
        "link": None, "locked": False,
    }


def _text_el(id_, x, y, s, size, colour, container=None, w=None, h=None):
    lines = s.split("\n")
    w = w or max(len(l) for l in lines) * size * 0.55
    h = h or len(lines) * size * 1.25
    el = _base(id_, "text", x, y, w, h, colour)
    el.update({
        "text": s, "originalText": s, "fontSize": size, "fontFamily": 1,
        "textAlign": "center" if container else "left",
        "verticalAlign": "middle" if container else "top",
        "containerId": container, "lineHeight": 1.25, "autoResize": True,
    })
    return el


def to_excalidraw():
    els = []
    by_id = {}
    for s in shapes:
        if s["kind"] == "rect":
            r = _base(s["id"], "rectangle", s["x"], s["y"], s["w"], s["h"],
                      s["stroke"], s["fill"], s["width"])
            r["roundness"] = {"type": 3}
            lines = s["label"].split("\n")
            th = len(lines) * s["size"] * 1.25
            t = _text_el(s["id"] + "_t", s["x"] + 8,
                         s["y"] + (s["h"] - th) / 2, s["label"], s["size"],
                         INK, container=s["id"], w=s["w"] - 16, h=th)
            r["boundElements"].append({"type": "text", "id": t["id"]})
            els += [r, t]
            by_id[s["id"]] = r
        elif s["kind"] == "text":
            els.append(_text_el(s["id"], s["x"], s["y"], s["text"],
                                s["size"], s["colour"]))
    for s in shapes:
        if s["kind"] != "arrow":
            continue
        dx, dy = s["x2"] - s["x1"], s["y2"] - s["y1"]
        a = _base(s["id"], "arrow", s["x1"], s["y1"], abs(dx), abs(dy), s["colour"])
        a.update({
            "points": [[0, 0], [dx, dy]], "lastCommittedPoint": None,
            "startArrowhead": None, "endArrowhead": "arrow",
            "startBinding": {"elementId": s["start"], "focus": 0, "gap": 1},
            "endBinding": {"elementId": s["end"], "focus": 0, "gap": 1},
            "elbowed": False,
        })
        for end in (s["start"], s["end"]):
            by_id[end]["boundElements"].append({"type": "arrow", "id": s["id"]})
        els.append(a)
    return {
        "type": "excalidraw", "version": 2,
        "source": "https://github.com/fee-billing-migration",
        "elements": els,
        "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None},
        "files": {},
    }


# ------------------------------------------------------------- svg writer ---
FONT = "DejaVu Sans, Helvetica, Arial, sans-serif"


def to_svg():
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS_W}" '
        f'height="{CANVAS_H}" viewBox="0 0 {CANVAS_W} {CANVAS_H}" '
        f'font-family="{FONT}">',
        '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" '
        'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{AMBER}"/></marker></defs>',
        f'<rect width="{CANVAS_W}" height="{CANVAS_H}" fill="#ffffff"/>',
    ]
    for s in shapes:
        if s["kind"] == "rect":
            out.append(
                f'<rect x="{s["x"]}" y="{s["y"]}" width="{s["w"]}" '
                f'height="{s["h"]}" rx="10" fill="{s["fill"]}" '
                f'stroke="{s["stroke"]}" stroke-width="{s["width"]}"/>')
            lines = s["label"].split("\n")
            lh = s["size"] * 1.25
            cy = s["y"] + s["h"] / 2 - (len(lines) - 1) * lh / 2
            for j, line in enumerate(lines):
                if line:
                    out.append(
                        f'<text x="{s["x"] + s["w"] / 2}" '
                        f'y="{cy + j * lh + s["size"] * 0.35:.1f}" '
                        f'font-size="{s["size"]}" fill="{INK}" '
                        f'text-anchor="middle">'
                        f'{escape(line)}</text>')
        elif s["kind"] == "text":
            out.append(
                f'<text x="{s["x"]}" y="{s["y"] + s["size"]}" '
                f'font-size="{s["size"]}" fill="{s["colour"]}">'
                f'{escape(s["text"])}</text>')
        elif s["kind"] == "arrow":
            out.append(
                f'<line x1="{s["x1"]}" y1="{s["y1"]}" x2="{s["x2"] - 3}" '
                f'y2="{s["y2"]}" stroke="{s["colour"]}" stroke-width="2.5" '
                f'marker-end="url(#ah)"/>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    build()
    os.makedirs(OUT, exist_ok=True)

    ex_path = os.path.join(OUT, NAME + ".excalidraw")
    with open(ex_path, "w", encoding="utf-8") as fh:
        json.dump(to_excalidraw(), fh, indent=2)
    print(f"  {os.path.relpath(ex_path, BASE)}")

    svg_path = os.path.join(OUT, NAME + ".svg")
    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write(to_svg())
    print(f"  {os.path.relpath(svg_path, BASE)}")

    png_path = os.path.join(OUT, NAME + ".png")
    if shutil.which("rsvg-convert"):
        subprocess.run(["rsvg-convert", "-z", "2", "-o", png_path, svg_path],
                       check=True)
        print(f"  {os.path.relpath(png_path, BASE)}  (2x)")
    else:
        print("  png skipped: rsvg-convert not installed")


if __name__ == "__main__":
    main()
