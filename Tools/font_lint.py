#!/usr/bin/env python3
"""Font / colour literal budget (Zoop 2.0 section 7.1).

Counts hard-coded `.font(.system(size:` and `Color(hex:` outside StrandDesign, per file, and
compares with Tools/font_lint_baseline.json. The budget may only decrease.

    python3 Tools/font_lint.py                  # report; exit 1 if any file exceeds its baseline
    python3 Tools/font_lint.py --update-baseline  # record the current counts (after a migration)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path(__file__).resolve().parent / "font_lint_baseline.json"
PATTERNS = {
    "font": re.compile(r"\.font\(\s*\.system\(\s*size:"),
    "hex": re.compile(r"\bColor\(\s*hex:"),
}
# StrandDesign defines the tokens, so it is exempt; the rest are not app code.
SKIP = ("Packages/StrandDesign/", "android/", "Tools/", ".build/", "build/", "DerivedData/", "Strand.xcodeproj/")


def scan():
    counts = {}
    for path in ROOT.rglob("*.swift"):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith(SKIP) or "/.build/" in rel or "/.claude/" in rel:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        c = {k: len(p.findall(text)) for k, p in PATTERNS.items()}
        if any(c.values()):
            counts[rel] = c
    return counts


def main():
    counts = scan()
    if "--update-baseline" in sys.argv:
        BASELINE.write_text(json.dumps(counts, indent=1, sort_keys=True) + "\n")
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    totals = {k: sum(c[k] for c in counts.values()) for k in PATTERNS}
    over = []
    for rel, c in sorted(counts.items()):
        base = baseline.get(rel, {"font": 0, "hex": 0})
        print(f"{c['font']:4d} font  {c['hex']:4d} hex  {rel}")
        if c["font"] > base["font"] or c["hex"] > base["hex"]:
            over.append(rel)
    print(f"TOTAL font={totals['font']} hex={totals['hex']} files={len(counts)}")
    if over:
        print("Over budget (new hard-coded literals; use ZoopType / StrandPalette):")
        for rel in over:
            print("  " + rel)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
