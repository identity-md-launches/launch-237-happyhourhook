#!/usr/bin/env python3
"""Export or verify ABI arrays using the repository's pinned Foundry configuration."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()

for name in ("LaunchToken", "HappyHourHook"):
    result = subprocess.run(
        ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    abi = json.loads(result.stdout)
    target = ROOT / "docs" / "abi" / f"{name}.json"
    if args.check:
        if not target.exists() or json.loads(target.read_text()) != abi:
            raise SystemExit(f"ABI needs regeneration: {target.relative_to(ROOT)}")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(abi, indent=2) + "\n")
    print(f"{'Verified' if args.check else 'Exported'} {target.relative_to(ROOT)}")
