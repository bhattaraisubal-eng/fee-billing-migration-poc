"""
Alteryx workflow inventory and complexity scorer.

A .yxmd file is plain XML. This walks a file or a folder of them and reports:

  * every tool, its type, and its configuration in one line
  * every formula expression and filter condition (the business logic)
  * every file path the workflow reads or writes
  * unconnected Join anchors -- silent record loss, the single most common
    source of parity breaks on a migration
  * a complexity score to sequence a migration backlog into waves

Built for the as-is analysis of one workflow, then reused to triage the rest of
the estate without opening Designer 30 times.

Usage:
    python3 tools/yxmd_inventory.py legacy/FeeBilling_Quarterly_v7_FINAL.yxmd
    python3 tools/yxmd_inventory.py legacy/            --csv inventory.csv
"""

import argparse
import csv
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

# Alteryx plugin name -> short tool name. Add to this as the estate reveals more.
TOOL_NAMES = {
    "DbFileInput": "Input Data",
    "DbFileOutput": "Output Data",
    "AlteryxSelect": "Select",
    "Filter": "Filter",
    "Formula": "Formula",
    "Join": "Join",
    "JoinMultiple": "Join Multiple",
    "Union": "Union",
    "Summarize": "Summarize",
    "Sort": "Sort",
    "Unique": "Unique",
    "Sample": "Sample",
    "FindReplace": "Find Replace",
    "TextInput": "Text Input",
    "MultiRowFormula": "Multi-Row Formula",
    "MultiFieldFormula": "Multi-Field Formula",
    "AppendFields": "Append Fields",
    "CrossTab": "Cross Tab",
    "Transpose": "Transpose",
    "RecordID": "Record ID",
    "Macro": "Macro",
    "RunCommand": "Run Command",
    "Python": "Python",
    "R": "R Tool",
    "DynamicInput": "Dynamic Input",
    "BlockUntilDone": "Block Until Done",
    "TextBox": "Comment",
    "ToolContainer": "Container",
}

# Tools that make a migration materially harder, and why.
COMPLEXITY_WEIGHTS = {
    "Macro": 8,          # opaque; must be opened separately
    "Run Command": 8,    # shells out, often to undocumented scripts
    "Python": 6,
    "R Tool": 6,
    "Dynamic Input": 5,  # schema decided at runtime
    "Multi-Row Formula": 4,  # ordered/stateful logic, awkward in SQL
    "Cross Tab": 3,
    "Transpose": 2,
    "Find Replace": 2,
    "Join Multiple": 2,
    "Join": 1,
    "Formula": 1,
    "Filter": 1,
    "Summarize": 1,
}

JOIN_ANCHORS = {"Join": {"Left", "Right", "Join"}, "Join Multiple": {"Output"}}


def short_name(plugin):
    if not plugin:
        return "Unknown"
    leaf = plugin.split(".")[-1]
    return TOOL_NAMES.get(leaf, leaf)


def text_of(node, path):
    el = node.find(path)
    return (el.text or "").strip() if el is not None else ""


def one_line(s, limit=120):
    s = re.sub(r"\s+", " ", (s or "").strip())
    return s if len(s) <= limit else s[: limit - 1] + "…"


def parse_workflow(path):
    tree = ET.parse(path)
    root = tree.getroot()

    wf = {
        "file": os.path.basename(path),
        "version": root.get("yxmdVer", ""),
        "author": text_of(root, "./Properties/MetaInfo/Author"),
        "description": text_of(root, "./Properties/MetaInfo/Description"),
        "tools": [],
        "logic": [],
        "paths": [],
        "warnings": [],
    }

    for node in root.findall("./Nodes/Node"):
        tool_id = node.get("ToolID")
        gui = node.find("./GuiSettings")
        plugin = gui.get("Plugin") if gui is not None else ""
        name = short_name(plugin)
        cfg = node.find("./Properties/Configuration")
        detail = ""

        if cfg is not None:
            if name in ("Input Data", "Output Data"):
                f = cfg.find("./File")
                fpath = (f.text or "").strip() if f is not None else ""
                detail = fpath
                if fpath:
                    wf["paths"].append({
                        "tool_id": tool_id,
                        "direction": "read" if name == "Input Data" else "write",
                        "path": fpath,
                    })
                if f is not None and name == "Input Data":
                    ignore = cfg.find("./FormatSpecificOptions/IgnoreErrors")
                    if ignore is not None and (ignore.text or "").strip() == "True":
                        wf["warnings"].append(
                            f"Tool {tool_id} ({name}): IgnoreErrors=True -- bad rows "
                            f"are silently coerced or dropped on read")

            elif name == "Filter":
                expr = text_of(cfg, "./Expression")
                mode = text_of(cfg, "./Mode")
                detail = f"[{mode}] {expr}"
                wf["logic"].append({"tool_id": tool_id, "kind": "Filter",
                                    "field": "", "expression": expr})
                for lit in re.findall(r"\d{4}-\d{2}-\d{2}", expr):
                    wf["warnings"].append(
                        f"Tool {tool_id} (Filter): hard-coded date literal {lit} "
                        f"-- edited by hand each run")

            elif name in ("Formula", "Multi-Row Formula", "Multi-Field Formula"):
                parts = []
                for ff in cfg.findall(".//FormulaField"):
                    field = ff.get("field", "")
                    expr = ff.get("expression", "")
                    parts.append(f"{field} = {one_line(expr, 60)}")
                    wf["logic"].append({"tool_id": tool_id, "kind": name,
                                        "field": field, "expression": expr})
                    nums = re.findall(r"(?<![\w.])\d{2,}(?:\.\d+)?", expr)
                    if len(nums) >= 3:
                        wf["warnings"].append(
                            f"Tool {tool_id} ({name}): {len(nums)} numeric literals in "
                            f"'{field}' -- business rates/thresholds hard-coded in the "
                            f"workflow rather than a reference table")
                detail = " | ".join(parts)

            elif name == "Summarize":
                acts = [f"{sf.get('action')}({sf.get('field')})"
                        for sf in cfg.findall(".//SummarizeField")]
                detail = ", ".join(acts)

            elif name in ("Join", "Join Multiple"):
                keys = []
                for ji in cfg.findall("./JoinInfo"):
                    side = ji.get("connection", "")
                    flds = [f.get("field") for f in ji.findall("./Field")]
                    keys.append(f"{side}:{'+'.join(flds)}")
                detail = " = ".join(keys) if keys else "by record position"

            elif name == "Select":
                sel = cfg.findall(".//SelectField")
                kept = sum(1 for s in sel if s.get("selected") == "True")
                detail = f"{kept} of {len(sel)} fields kept"

            elif name == "Sort":
                detail = ", ".join(
                    f"{f.get('field')} {f.get('order')}"
                    for f in cfg.findall(".//Field"))

            elif name == "Comment":
                detail = one_line(text_of(cfg, "./Text"), 200)

        wf["tools"].append({"tool_id": tool_id, "tool": name,
                            "plugin": plugin, "detail": one_line(detail, 160)})

    # ---- connection graph: find anchors that go nowhere ------------------
    used = set()
    for c in root.findall("./Connections/Connection"):
        o = c.find("./Origin")
        if o is not None:
            used.add((o.get("ToolID"), o.get("Connection")))

    by_id = {t["tool_id"]: t for t in wf["tools"]}
    for tool_id, tool in by_id.items():
        expected = JOIN_ANCHORS.get(tool["tool"])
        if not expected:
            continue
        missing = sorted(a for a in expected if (tool_id, a) not in used)
        if missing and tool["tool"] == "Join":
            if "Join" in missing:
                continue  # join output unused entirely; different problem
            wf["warnings"].append(
                f"Tool {tool_id} (Join): {', '.join(missing)} anchor(s) unconnected "
                f"-- unmatched records are discarded with no audit trail")

    for t in wf["tools"]:
        if t["tool"] == "Filter" and (t["tool_id"], "False") not in used:
            wf["warnings"].append(
                f"Tool {t['tool_id']} (Filter): False anchor unconnected "
                f"-- excluded records are not reported anywhere")

    counted = [t for t in wf["tools"] if t["tool"] not in ("Comment", "Container")]
    wf["tool_count"] = len(counted)
    wf["complexity"] = sum(COMPLEXITY_WEIGHTS.get(t["tool"], 1) for t in counted)
    wf["wave"] = ("1 - simple" if wf["complexity"] <= 15
                  else "2 - moderate" if wf["complexity"] <= 35
                  else "3 - complex")
    return wf


def report(wf):
    print("=" * 78)
    print(f"{wf['file']}   (Designer {wf['version']}, author: {wf['author'] or 'unknown'})")
    if wf["description"]:
        print(f"  {wf['description']}")
    print("=" * 78)

    print(f"\nTOOLS ({wf['tool_count']} functional)")
    for t in wf["tools"]:
        print(f"  {t['tool_id']:>3}  {t['tool']:<18} {t['detail']}")

    print(f"\nFILE DEPENDENCIES ({len(wf['paths'])})")
    for p in wf["paths"]:
        print(f"  {p['direction']:<6} {p['path']}")

    print(f"\nBUSINESS LOGIC TO MIGRATE ({len(wf['logic'])} expressions)")
    for lg in wf["logic"]:
        label = f"{lg['kind']} {lg['tool_id']}"
        target = f" -> {lg['field']}" if lg["field"] else ""
        print(f"  {label}{target}")
        for line in (lg["expression"] or "").splitlines():
            if line.strip():
                print(f"      {line.strip()}")

    print(f"\nMIGRATION RISKS AUTO-DETECTED ({len(wf['warnings'])})")
    for w in wf["warnings"]:
        print(f"  ! {w}")

    print(f"\nCOMPLEXITY {wf['complexity']}  ->  wave {wf['wave']}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help=".yxmd file or a folder of them")
    ap.add_argument("--csv", help="write the one-row-per-workflow backlog here")
    args = ap.parse_args()

    if os.path.isdir(args.target):
        files = sorted(glob.glob(os.path.join(args.target, "**", "*.yxm*"), recursive=True))
    else:
        files = [args.target]
    if not files:
        sys.exit(f"no .yxmd files found at {args.target}")

    results = []
    for f in files:
        try:
            wf = parse_workflow(f)
        except ET.ParseError as e:
            print(f"!! {os.path.basename(f)}: unparseable XML ({e})")
            continue
        results.append(wf)
        report(wf)

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["workflow", "designer_version", "author", "tool_count",
                        "expressions", "inputs", "outputs", "risks_detected",
                        "complexity", "proposed_wave"])
            for wf in results:
                w.writerow([
                    wf["file"], wf["version"], wf["author"], wf["tool_count"],
                    len(wf["logic"]),
                    sum(1 for p in wf["paths"] if p["direction"] == "read"),
                    sum(1 for p in wf["paths"] if p["direction"] == "write"),
                    len(wf["warnings"]), wf["complexity"], wf["wave"],
                ])
        print(f"backlog written to {args.csv} ({len(results)} workflows)")


if __name__ == "__main__":
    main()
