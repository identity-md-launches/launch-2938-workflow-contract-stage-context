#!/usr/bin/env python3
"""Export only the compiler's ABIs; run forge build first. Standard library only."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for name in ("SqueekRaider", "RaiderCard"):
    artifact = root / "out" / f"{name}.sol" / f"{name}.json"
    abi = json.loads(artifact.read_text())["abi"]
    destination = root / "docs" / "abi" / f"{name}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(abi, indent=2) + "\n")
    print(destination.relative_to(root))
