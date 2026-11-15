"""
Generate the per-workflow migration process flow in three formats.

  docs/migration_process.excalidraw   open and edit at https://excalidraw.com
  docs/migration_process.svg          renders inline on GitHub
  docs/migration_process.png          for slides and LinkedIn (needs rsvg-convert)

The process is the method this repository applies to one workflow, written as
the loop every remaining workflow goes through. Three gates; each failure path
loops back to the step that can fix it rather than forward to a later one.

Usage:  python3 tools/make_process_flow.py
"""

import json
import os
import random
import shutil
import subprocess
from xml.sax.saxutils import escape

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "docs")
NAME = "migration_process"
random.seed(11)

INK, MUTED = "#1e1e1e", "#5c5f66"
BLUE, BLUE_FILL = "#4a9eed", "#d0ebff"
PURPLE, PURPLE_FILL = "#8b5cf6", "#e5dbff"
AMBER, AMBER_FILL = "#f59e0b", "#fff3bf"
RED, RED_FILL = "#ef4444", "#ffe3e3"
GREEN, GREEN_FILL = "#22c55e", "#d3f9d8"
FONT = "DejaVu Sans, Helvetica, Arial, sans-serif"

W, H = 1000, 1500
OY = 112                    # vertical offset below the title
CX = 400                    # spine centre
BX, BW, BH = 230, 340, 64   # spine boxes
LX, LW = 670, 280           # failure-path boxes

shapes = []


def node(kind, id_, x, y, w, h, label, stroke, fill, size=17, width=2):
    shapes.append(dict(kind=kind, id=id_, x=x, y=y + OY, w=w, h=h,
                       label=label, stroke=stroke, fill=fill, size=size,
                       width=width))


def text(id_, x, y, s, size, colour, bold=False):
    shapes.append(dict(kind="text", id=id_, x=x, y=y + OY, text=s,
                       size=size, colour=colour, bold=bold))


def band(id_, y, h, label, fill):
    shapes.append(dict(kind="band", id=id_, x=20, y=y + OY, w=W - 40, h=h,
                       fill=fill))
    text(id_ + "_lbl", 34, y + 10, label, 18, MUTED, bold=True)


def arrow(id_, pts, colour=INK, label=None, dashed=False):
    shapes.append(dict(kind="arrow", id=id_,
                       pts=[(x, y + OY) for x, y in pts], colour=colour,
                       label=label, dashed=dashed))


def down(id_, y1, y2, label=None, colour=INK):
    arrow(id_, [(CX, y1), (CX, y2)], colour, label)


def build():
    shapes.append(dict(kind="text", id="title", x=W / 2, y=34,
                       text="Migration process, per workflow", size=28,
                       colour=INK, bold=False, anchor="middle"))
    shapes.append(dict(kind="text", id="subtitle", x=W / 2, y=72,
                       text="Three gates. A failed gate loops back to the step that can fix it.",
                       size=17, colour=MUTED, bold=False, anchor="middle"))

    # Phase bands first so everything else draws on top.
    band("ph1", 55, 200, "DISCOVER", "#eef6ff")
    band("ph2", 265, 250, "ANALYSE", "#fffbe6")
    band("ph3", 525, 95, "BUILD", "#f5f0ff")
    band("ph4", 630, 250, "PROVE", "#e9fbf4")
    band("ph5", 890, 375, "RELEASE", "#eefbef")
    band("ph6", 1275, 85, "", "#ffffff")

    node("ellipse", "start", CX - 150, 0, 300, 46,
         "Next workflow from backlog", BLUE, BLUE_FILL, 17)
    down("s0", 46, 85)

    node("rect", "b1", BX, 85, BW, BH,
         "1. Inventory the workflow\nyxmd_inventory.py", BLUE, BLUE_FILL)
    down("s1", 85 + BH, 185)
    node("rect", "b2", BX, 185, BW, BH,
         "2. Document the as-is\nWORKFLOW_AS_BUILT.md", BLUE, BLUE_FILL)
    down("s2", 185 + BH, 290)

    node("rect", "b3", BX, 290, BW, BH,
         "3. Log gaps, recommend defaults\nGAP_LOG.md", AMBER, AMBER_FILL)
    down("s3", 290 + BH, 385)
    node("diamond", "d1", CX - 140, 385, 280, 120,
         "Decisions\nsigned off?", AMBER, "#ffec99", 17, 3)
    down("s4", 505, 545, "Yes")
    # No: escalate, then back to the gap log.
    node("rect", "l1", LX, 413, LW, BH,
         "Escalate: owner, options,\ncost of each", RED, RED_FILL, 16)
    arrow("n1", [(CX + 140, 445), (LX, 445)], RED, "No")
    arrow("r1", [(LX + LW / 2, 413), (LX + LW / 2, 322), (BX + BW, 322)],
          RED, dashed=True)

    node("rect", "b4", BX, 545, BW, BH,
         "4. Build target SQL\n01-04 *.sql + exception_log", PURPLE, PURPLE_FILL)
    down("s5", 545 + BH, 650)

    node("rect", "b5", BX, 650, BW, BH,
         "5. Reconcile against legacy\n05_parity.sql + 14 tests", GREEN, GREEN_FILL)
    down("s6", 650 + BH, 745)
    node("diamond", "d2", CX - 140, 745, 280, 120,
         "Every variance\nattributed?", GREEN, "#b2f2bb", 17, 3)
    down("s7", 865, 910, "Yes")
    node("rect", "l2", LX, 773, LW, BH,
         "Defect: fix the build,\nor raise a new gap", RED, RED_FILL, 16)
    arrow("n2", [(CX + 140, 805), (LX, 805)], RED, "No")
    arrow("r2", [(LX + LW / 2, 773), (LX + LW / 2, 577), (BX + BW, 577)],
          RED, dashed=True)

    node("rect", "b6", BX, 910, BW, BH,
         "6. Parallel run, one quarter\nCUTOVER_CHECKLIST.md", GREEN, GREEN_FILL)
    down("s8", 910 + BH, 1010)
    node("diamond", "d3", CX - 150, 1010, 300, 130,
         "Blocking cleared,\nUAT signed?", GREEN, "#b2f2bb", 17, 3)
    down("s9", 1140, 1180, "Yes")
    node("rect", "l3", LX, 1043, LW, BH,
         "Resolve exceptions,\nrerun the quarter", RED, RED_FILL, 16)
    arrow("n3", [(CX + 150, 1075), (LX, 1075)], RED, "No")
    arrow("r3", [(LX + LW / 2, 1043), (LX + LW / 2, 942), (BX + BW, 942)],
          RED, dashed=True)

    node("rect", "b7", BX, 1180, BW, BH,
         "7. Cut over\nlegacy disabled, not deleted", GREEN, GREEN_FILL, 17, 3)
    down("s10", 1180 + BH, 1290)

    node("ellipse", "end", CX - 170, 1290, 340, 50,
         "Reuse the pattern library", BLUE, BLUE_FILL, 17)
    # Back to the backlog: the next workflow starts with the scaffolding built.
    arrow("loop", [(CX - 170, 1315), (190, 1315), (190, 23), (CX - 150, 23)],
          BLUE, dashed=True)


# ------------------------------------------------------- excalidraw writer ---
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


def _text(id_, x, y, s, size, colour, container=None, w=None, h=None,
          align="left"):
    lines = s.split("\n")
    w = w or max(len(l) for l in lines) * size * 0.55
    h = h or len(lines) * size * 1.25
    el = _base(id_, "text", x, y, w, h, colour)
    el.update({"text": s, "originalText": s, "fontSize": size,
               "fontFamily": 1, "textAlign": "center" if container else align,
               "verticalAlign": "middle" if container else "top",
               "containerId": container, "lineHeight": 1.25,
               "autoResize": True})
    return el


def to_excalidraw():
    els = []
    kinds = {"rect": "rectangle", "ellipse": "ellipse", "diamond": "diamond"}
    for s in shapes:
        k = s["kind"]
        if k == "band":
            b = _base(s["id"], "rectangle", s["x"], s["y"], s["w"], s["h"],
                      "transparent", s["fill"], 1)
            b["roundness"] = {"type": 3}
            els.append(b)
        elif k in kinds:
            r = _base(s["id"], kinds[k], s["x"], s["y"], s["w"], s["h"],
                      s["stroke"], s["fill"], s["width"])
            if k == "rect":
                r["roundness"] = {"type": 3}
            lines = s["label"].split("\n")
            th = len(lines) * s["size"] * 1.25
            inset = 0.2 if k == "diamond" else 0.04
            t = _text(s["id"] + "_t", s["x"] + s["w"] * inset,
                      s["y"] + (s["h"] - th) / 2, s["label"], s["size"], INK,
                      container=s["id"], w=s["w"] * (1 - 2 * inset), h=th)
            r["boundElements"].append({"type": "text", "id": t["id"]})
            els += [r, t]
        elif k == "text":
            x = s["x"]
            if s.get("anchor") == "middle":
                x -= len(s["text"]) * s["size"] * 0.27
            els.append(_text(s["id"], x, s["y"], s["text"], s["size"],
                             s["colour"]))
        elif k == "arrow":
            x0, y0 = s["pts"][0]
            rel = [[x - x0, y - y0] for x, y in s["pts"]]
            xs = [p[0] for p in rel]
            ys = [p[1] for p in rel]
            a = _base(s["id"], "arrow", x0, y0, max(xs) - min(xs),
                      max(ys) - min(ys), s["colour"])
            a.update({"points": rel, "lastCommittedPoint": None,
                      "startArrowhead": None, "endArrowhead": "arrow",
                      "startBinding": None, "endBinding": None,
                      "elbowed": False,
                      "strokeStyle": "dashed" if s["dashed"] else "solid"})
            els.append(a)
            if s["label"]:
                lx, ly = _label_pos(s)
                els.append(_text(s["id"] + "_l", lx, ly - 9, s["label"], 15,
                                 s["colour"] if s["colour"] != INK else MUTED))
    return {"type": "excalidraw", "version": 2,
            "source": "fee-billing-migration/tools/make_process_flow.py",
            "elements": els,
            "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None},
            "files": {}}


def _label_pos(s):
    (x1, y1), (x2, y2) = s["pts"][0], s["pts"][1]
    if s["id"] == "loop":
        return 198, (s["pts"][1][1] + s["pts"][2][1]) / 2
    if x1 == x2:                       # vertical: label to the right
        return x1 + 8, (y1 + y2) / 2
    return (x1 + x2) / 2 - 10, y1 - 12   # horizontal: label above


# ------------------------------------------------------------- svg writer ---
def to_svg():
    markers = "".join(
        f'<marker id="ah{i}" viewBox="0 0 10 10" refX="9" refY="5" '
        f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
        for i, c in enumerate((INK, RED, BLUE)))
    mid = {INK: 0, RED: 1, BLUE: 2}
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" font-family="{FONT}">',
           f"<defs>{markers}</defs>",
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>']

    def label(s, cx, cy):
        lines = s["label"].split("\n")
        lh = s["size"] * 1.25
        top = cy - (len(lines) - 1) * lh / 2
        for j, line in enumerate(lines):
            step = s["kind"] == "rect" and s["label"][0].isdigit()
            weight = ' font-weight="bold"' if (j == 0 and step) else ""
            colour = MUTED if (j > 0 and step) else INK
            size = s["size"] - 2 if (j > 0 and step) else s["size"]
            out.append(f'<text x="{cx}" y="{top + j * lh + size * 0.35:.1f}" '
                       f'font-size="{size}" fill="{colour}"{weight} '
                       f'text-anchor="middle">{escape(line)}</text>')

    for s in shapes:
        k = s["kind"]
        if k == "band":
            out.append(f'<rect x="{s["x"]}" y="{s["y"]}" width="{s["w"]}" '
                       f'height="{s["h"]}" rx="12" fill="{s["fill"]}"/>')
        elif k == "rect":
            out.append(f'<rect x="{s["x"]}" y="{s["y"]}" width="{s["w"]}" '
                       f'height="{s["h"]}" rx="10" fill="{s["fill"]}" '
                       f'stroke="{s["stroke"]}" stroke-width="{s["width"]}"/>')
            label(s, s["x"] + s["w"] / 2, s["y"] + s["h"] / 2)
        elif k == "ellipse":
            out.append(f'<ellipse cx="{s["x"] + s["w"] / 2}" '
                       f'cy="{s["y"] + s["h"] / 2}" rx="{s["w"] / 2}" '
                       f'ry="{s["h"] / 2}" fill="{s["fill"]}" '
                       f'stroke="{s["stroke"]}" stroke-width="{s["width"]}"/>')
            label(s, s["x"] + s["w"] / 2, s["y"] + s["h"] / 2)
        elif k == "diamond":
            cx, cy = s["x"] + s["w"] / 2, s["y"] + s["h"] / 2
            pts = (f'{cx},{s["y"]} {s["x"] + s["w"]},{cy} '
                   f'{cx},{s["y"] + s["h"]} {s["x"]},{cy}')
            out.append(f'<polygon points="{pts}" fill="{s["fill"]}" '
                       f'stroke="{s["stroke"]}" stroke-width="{s["width"]}"/>')
            label(s, cx, cy)
        elif k == "text":
            anchor = s.get("anchor", "start")
            weight = ' font-weight="bold" letter-spacing="1.5"' if s["bold"] else ""
            out.append(f'<text x="{s["x"]}" y="{s["y"] + s["size"]}" '
                       f'font-size="{s["size"]}" fill="{s["colour"]}"'
                       f'{weight} text-anchor="{anchor}">'
                       f'{escape(s["text"])}</text>')
        elif k == "arrow":
            pts = list(s["pts"])
            # Pull the final point back so the arrowhead meets the edge.
            (xa, ya), (xb, yb) = pts[-2], pts[-1]
            if xa == xb:
                pts[-1] = (xb, yb - 3 if yb > ya else yb + 3)
            else:
                pts[-1] = (xb - 3 if xb > xa else xb + 3, yb)
            dash = ' stroke-dasharray="7 5"' if s["dashed"] else ""
            out.append(f'<polyline points="'
                       + " ".join(f"{x},{y}" for x, y in pts)
                       + f'" fill="none" stroke="{s["colour"]}" '
                       f'stroke-width="2.2"{dash} '
                       f'marker-end="url(#ah{mid[s["colour"]]})"/>')
            if s["label"]:
                lx, ly = _label_pos(s)
                colour = s["colour"] if s["colour"] != INK else MUTED
                out.append(f'<text x="{lx}" y="{ly + 5}" font-size="15" '
                           f'font-weight="bold" fill="{colour}">'
                           f'{escape(s["label"])}</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    build()
    os.makedirs(OUT, exist_ok=True)
    paths = {ext: os.path.join(OUT, f"{NAME}.{ext}")
             for ext in ("excalidraw", "svg", "png")}
    with open(paths["excalidraw"], "w", encoding="utf-8") as fh:
        json.dump(to_excalidraw(), fh, indent=2)
    with open(paths["svg"], "w", encoding="utf-8") as fh:
        fh.write(to_svg())
    for ext in ("excalidraw", "svg"):
        print(f"  {os.path.relpath(paths[ext], BASE)}")
    if shutil.which("rsvg-convert"):
        subprocess.run(["rsvg-convert", "-z", "2", "-o", paths["png"],
                        paths["svg"]], check=True)
        print(f"  {os.path.relpath(paths['png'], BASE)}  (2x)")


if __name__ == "__main__":
    main()
