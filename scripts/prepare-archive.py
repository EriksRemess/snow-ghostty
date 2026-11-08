#!/usr/bin/env python3
"""Prefer libSystem's memory/math functions using the Linux OSXCross tools."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--tools", type=Path, required=True, help="OSXCross target/bin directory")
args = parser.parse_args()
source = args.source.resolve()
output = args.output.resolve()
tools = args.tools.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
prefix = "x86_64-apple-darwin10-"

with tempfile.TemporaryDirectory(prefix="ghostty-archive-") as directory:
    work = Path(directory)
    archive = work / "libghostty-vt.a"
    shutil.copyfile(source, archive)
    subprocess.run([str(tools / (prefix + "ar")), "x", str(archive), "compiler_rt.o"], cwd=work, check=True)
    (work / "compiler_rt.o").chmod(0o644)
    # Use the same list as upstream's Darwin libsystem_override.sh.
    script = Path("vendor/ghostty/src/build/libsystem_override.sh").read_text()
    remove = set(script.split('<<\'EOF\'\n', 1)[1].split("\nEOF", 1)[0].splitlines())
    symbols = subprocess.check_output(["llvm-nm", "--defined-only", "--extern-only", "--format=posix", str(work / "compiler_rt.o")], text=True)
    keep = sorted({line.split()[0] for line in symbols.splitlines() if line.split() and line.split()[0] not in remove})
    (work / "keep.txt").write_text("\n".join(keep) + "\n")
    subprocess.run([str(tools / (prefix + "nmedit")), "-s", str(work / "keep.txt"), str(work / "compiler_rt.o")], check=True)
    subprocess.run([str(tools / (prefix + "ar")), "r", str(archive), "compiler_rt.o"], cwd=work, check=True)
    subprocess.run([str(tools / (prefix + "ranlib")), str(archive)], check=True)
    shutil.copyfile(archive, output)
