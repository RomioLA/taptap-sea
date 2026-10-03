"""Materialize approved root data as Maker-readable Lua modules; never edit outputs."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLES = {"items.lua": "Items.lua", "fish.lua": "Fish.lua"}


def synchronize(root: Path = ROOT, *, check: bool = False) -> list[str]:
    """Only these two approved tables are copied; no schema/number transformations."""
    pending = []
    for source_name, module_name in TABLES.items():
        source = root / "data" / source_name
        output = root / "scripts" / "GeneratedData" / module_name
        payload = source.read_bytes()
        signature = hashlib.sha256(payload).hexdigest()
        header = (
            f"-- GENERATED from data/{source_name}; edit the source, never this file.\n"
            "-- Regenerate: python tests/sync_runtime_data.py; verify: add --check.\n"
            f"-- Source SHA-256: {signature}\n"
        ).encode("utf-8")
        expected = header + payload
        if output.exists() and output.read_bytes() == expected:
            continue
        if output.exists() and not output.read_bytes().startswith(b"-- GENERATED from data/"):
            raise ValueError(f"Refusing to overwrite a non-generated file: {output}")
        pending.append((output, expected))
    if check and pending:
        raise ValueError("Runtime data is stale or missing: " + ", ".join(
            str(path.relative_to(root)) for path, _ in pending
        ) + "; run python tests/sync_runtime_data.py before preview/build.")
    changed = []
    for output, expected in pending:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(expected)
        changed.append(output.relative_to(root).as_posix())
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail without writing if outputs differ")
    args = parser.parse_args()
    try:
        changed = synchronize(check=args.check)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print("RUNTIME_DATA_SYNC_PASS", ", ".join(changed) if changed else "already synchronized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
