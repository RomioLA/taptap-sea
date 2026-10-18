"""Compare this task's owned files with the untouched opening snapshots."""
from pathlib import Path
import difflib
import hashlib
import json

root = Path(__file__).resolve().parents[2]
out = root / "outputs/seven-days-cycle"
baseline = out / "before"
paths = [str(p.relative_to(baseline)).replace("\\", "/")
         for p in baseline.rglob("*.lua")]
paths += ["scripts/tests/SevenDaysRunTests.lua",
          "scripts/tests/SeaDayNightCycleTests.lua",
          "tests/run_seven_days_cycle.py"]
patches, manifest = [], []
for path in sorted(set(paths)):
    prior = baseline / path
    current = root / path
    before = prior.read_text(encoding="utf-8-sig") if prior.exists() else ""
    after = current.read_text(encoding="utf-8-sig")
    if before == after:
        continue
    patches.extend(difflib.unified_diff(before.splitlines(keepends=True),
        after.splitlines(keepends=True), fromfile="before/" + path,
        tofile="current/" + path))
    manifest.append({"path": path, "new": not prior.exists(),
        "sha256": hashlib.sha256(current.read_bytes()).hexdigest()})
(out / "task-only.diff").write_text("".join(patches), encoding="utf-8")
(out / "changed-files.json").write_text(json.dumps(manifest,
    ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"changedFiles": len(manifest), "paths": [r["path"] for r in manifest]}))
