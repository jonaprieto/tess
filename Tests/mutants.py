#!/usr/bin/env python3
"""Mutates Sources/Layout on a copy of the repo and reports what no test notices.

The copy has Layout and its tests only, so each mutant builds in seconds;
Sources/tess goes along because a test reads it. Takes a sample size, or
runs every mutant. Mutants that crash the tests leave crash reports behind.
"""

import glob, os, random, re, shutil, subprocess, sys, tempfile

OPS = [
    (r" < ", " <= "), (r" > ", " >= "), (r" <= ", " < "), (r" >= ", " > "),
    (r" == ", " != "), (r" != ", " == "), (r" && ", " || "), (r" \|\| ", " && "),
    (r" \+ ", " - "), (r" - ", " + "), (r"\bmin\(", "max("), (r"\bmax\(", "min("),
]
PACKAGE = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "mutants",
  targets: [
    .target(name: "Layout"),
    .testTarget(name: "LayoutTests", dependencies: ["Layout"]),
  ])
"""


def sites(files):
    found = []
    for f in files:
        for n, line in enumerate(open(f, encoding="utf-8").read().split("\n")):
            code = re.sub(
                r'"(\\.|[^"\\])*"', lambda m: "_" * len(m.group(0)), line.split("//")[0]
            )
            for pat, rep in OPS:
                found += [(f, n, m.start(), m.end(), rep) for m in re.finditer(pat, code)]
    return found


def test():
    try:
        p = subprocess.run(["swift", "test"], capture_output=True, text=True, timeout=240)
    except subprocess.TimeoutExpired:
        return "killed"
    out = p.stdout + p.stderr
    if "error:" in out and "Test run" not in out:
        return "nobuild"
    return "survived" if p.returncode == 0 and "passed" in out else "killed"


root = os.getcwd()
work = tempfile.mkdtemp(prefix="tess-mutants-")
shutil.copytree(f"{root}/Sources", f"{work}/Sources")
shutil.copytree(f"{root}/Tests/LayoutTests", f"{work}/Tests/LayoutTests")
open(f"{work}/Package.swift", "w").write(PACKAGE)
os.chdir(work)

files = [f for f in glob.glob("Sources/Layout/*.swift") if not f.endswith("Spanish.swift")]
todo = sites(files)
random.Random(42).shuffle(todo)
if len(sys.argv) > 1 and sys.argv[1]:
    todo = todo[: int(sys.argv[1])]
if test() != "survived":
    sys.exit("the tests must pass before mutating")

counts = {"killed": 0, "survived": 0, "nobuild": 0}
for f, n, a, b, rep in todo:
    source = open(f, encoding="utf-8").read()
    lines = source.split("\n")
    original = lines[n]
    lines[n] = original[:a] + rep + original[b:]
    open(f, "w", encoding="utf-8").write("\n".join(lines))
    result = test()
    open(f, "w", encoding="utf-8").write(source)
    counts[result] += 1
    if result == "survived":
        print(f"{f}:{n + 1}: {original.strip()}  ->  {rep.strip()}", flush=True)

shutil.rmtree(work)
valid = counts["killed"] + counts["survived"]
print(counts, f"score {100 * counts['killed'] / max(valid, 1):.1f}%")
