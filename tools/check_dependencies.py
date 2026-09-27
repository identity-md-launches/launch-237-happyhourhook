#!/usr/bin/env python3
"""Verify all vendored dependency files against the committed provenance ledger."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
lock = json.loads((ROOT / "docs" / "dependencies.lock.json").read_text())
records = lock["files"] + lock["licenseFiles"]
expected = {record["path"] for record in records}
actual = {path.relative_to(ROOT).as_posix() for path in (ROOT / "lib").rglob("*") if path.is_file()}
if expected != actual:
    raise SystemExit(f"Dependency inventory mismatch: {sorted(expected ^ actual)}")
for record in records:
    path = ROOT / record["path"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
        raise SystemExit(f"Dependency content mismatch: {record['path']}")
print(f"Verified {len(records)} vendored source/license files.")
