"""Check W2 archive copies, runtime budget and pending manual relocation; never delete."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/art-wave2/ART-W2-01"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    plan = json.loads((OUT / "runtime-staging/relocation-plan.json").read_text(encoding="utf-8"))
    sources = {p: p.read_text(encoding="utf-8-sig") for folder in ("scripts", "tests")
               for p in (ROOT / folder).rglob("*") if p.suffix in (".lua", ".py", ".json")}
    records = []
    for entry in plan["copies"]:
        original, archived = ROOT / entry["original"], ROOT / entry["copy"]
        assert original.resolve().is_relative_to((ROOT / "assets").resolve())
        assert archived.resolve().is_relative_to((ROOT / "outputs/art-wave1").resolve())
        assert sha(archived) == entry["sha256"], f"Archived candidate changed: {archived}"
        exists = original.exists()
        if exists:
            assert sha(original) == entry["sha256"], f"Source candidate changed: {original}"
        # Look for actual source paths, not the same basename in the archive input.
        needles = (entry["original"], str(original), entry["original"].removeprefix("assets/"))
        references = [p.relative_to(ROOT).as_posix() for p, text in sources.items()
                      if any(needle in text for needle in needles)]
        records.append({**entry, "original_exists": exists, "sha256_verified": True,
                        "runtime_source_references": references, "safe_for_manual_removal": not references})
    sizes = {}
    for folder in ("assets", "assets/image", "assets/generated", "scripts"):
        paths = [p for p in (ROOT / folder).rglob("*") if p.is_file()]
        sizes[folder] = {"file_count": len(paths), "bytes": sum(p.stat().st_size for p in paths)}
    total = sizes["assets"]["bytes"] + sizes["scripts"]["bytes"]
    pending = [r for r in records if r["original_exists"]]
    reclaimable = sum(r["bytes"] for r in pending if r["safe_for_manual_removal"])
    runtime = json.loads((ROOT / "assets/image/OceanWave2/manifest.json").read_text(encoding="utf-8"))
    runtime_bytes = sum(e["runtime_bytes"] for e in runtime["assets"].values())
    result = {"copies_verified": len(records), "pending_originals": len(pending),
              "records": records, "sizes": sizes, "assets_plus_scripts_bytes": total,
              "new_runtime_bytes": runtime_bytes, "budget_decimal_bytes": 60000000,
              "over_60MB_bytes": max(0, total - 60000000),
              "actual_relocation_saving_bytes": sum(r["bytes"] for r in records if not r["original_exists"]),
              "pending_reclaimable_bytes": reclaimable,
              "projected_after_manual_removal_bytes": total - reclaimable,
              "source_candidates_not_accidentally_packaged": "NO" if pending else "YES",
              "archive_size": "UNKNOWN; no remote build requested",
              "method": "Raw filesystem byte counts, not a built package; no asset exclusions changed."}
    (OUT / "package-after.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# W1 候选原副本手动移除清单", "",
             "仅在 SHA256 一致、运行源码无原路径引用时，逐文件手动移除原副本。不要删除归档和未选中候选。",
             "本工具没有执行移除，也没有生成批量删除脚本。原件变化时先重新执行本工具检查。", "",
             "| 原路径（项目根相对） | 已校验归档 | 字节 | SHA256 | 可手动移除 |", "|---|---|---:|---|---|"]
    for r in pending:
        lines.append(f"| `{r['original']}` | `{r['copy']}` | {r['bytes']} | `{r['sha256']}` | {'YES' if r['safe_for_manual_removal'] else 'NO: '+str(r['runtime_source_references'])} |")
    lines.extend(["", f"当前待处理 {len(pending)} 个文件；完成后预计可释放 {reclaimable:,} B。",
                  "核对命令：使用已有 Python 运行 `tests/verify_art_wave2.py`，随后运行 `tests/prepare_ocean_ready_art.py --check`。",
                  "移除原副本后需手动重启或刷新本地预览以重建资源清单；停止的会话不会自动启动。"])
    (OUT / "MANUAL_SOURCE_RELOCATION.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k not in ("records", "sizes")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
