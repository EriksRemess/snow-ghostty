#!/usr/bin/env python3
"""Fetch a pinned Ghostty source snapshot with read-only gh calls.

Agents must run this outside the sandbox because gh is used. No credentials
are stored. An existing checkout is never silently replaced.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "upstream.lock.json").read_text())
vendor = root / "vendor/ghostty"
patches = [root / entry["file"] for entry in lock["patches"]]
for entry, patch in zip(lock["patches"], patches):
    if hashlib.sha256(patch.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("Local patch checksum mismatch: " + entry["file"])
cache = root / ".research"
cache.mkdir(exist_ok=True)
archive = cache / lock["source_archive"]

if not vendor.exists():
    if not archive.exists():
        pending = archive.with_suffix(".pending")
        with pending.open("wb") as stream:
            subprocess.run(["gh", "api", lock["source_archive_api"]], stdout=stream, check=True)
        pending.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock["source_archive_sha256"]:
        raise SystemExit("Pinned source archive checksum mismatch")
    vendor.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=vendor.parent) as directory:
        with tarfile.open(archive) as source:
            source.extractall(directory, filter="data")
        entries = list(Path(directory).iterdir())
        if len(entries) != 1 or not entries[0].is_dir():
            raise SystemExit("Unexpected upstream archive layout")
        shutil.move(entries[0], vendor)
    (vendor / "VERSION").write_text(lock["version"])
    (vendor / "LIB_VERSION").write_text(lock["lib_version"])

if (vendor / "VERSION").read_text().strip() != lock["version"]:
    raise SystemExit("Existing vendor directory has another version; inspect it before replacing")
if (vendor / ".snow-ghostty-source-revision").exists() and (vendor / ".snow-ghostty-source-revision").read_text().strip() != lock["revision"]:
    raise SystemExit("Existing vendor directory has another revision; inspect it before replacing")
for patch in patches:
    with patch.open() as stream:
        needed = subprocess.run(["patch", "--dry-run", "--forward", "--batch", "--fuzz=0", "-p1"], cwd=vendor, stdin=stream, capture_output=True)
    if needed.returncode == 0:
        with patch.open() as stream:
            subprocess.run(["patch", "--forward", "--batch", "--fuzz=0", "-p1"], cwd=vendor, stdin=stream, check=True)
    else:
        # --forward also prevents patch from silently ignoring --reverse and
        # accepting an unpatched file as though the reverse patch had succeeded.
        with patch.open() as stream:
            present = subprocess.run(["patch", "--dry-run", "--reverse", "--forward", "--batch", "--fuzz=0", "-p1"], cwd=vendor, stdin=stream, capture_output=True)
        if present.returncode:
            raise SystemExit("Patch neither applies nor is already present: " + patch.name)
(vendor / ".snow-ghostty-source-revision").write_text(lock["revision"] + "\n")
print("Ghostty source ready:", lock["revision"])
