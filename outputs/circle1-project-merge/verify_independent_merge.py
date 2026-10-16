"""Independent, read-only verification of the recorded TapTap project merge."""
from __future__ import annotations

import hashlib
import json
import re
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET


ROOT = Path(r"C:\codex\taptap-sea").resolve()
SOURCE = Path(r"D:\sillytavern-data\taptap-sea-B").resolve()
OUT = ROOT / "outputs/circle1-project-merge"
PLAN_PATH = OUT / "merge-plan.json"
RESULT_PATH = OUT / "merge-result.json"
PROGRESS_PATH = OUT / "merge-progress.json"
TARGET_BEFORE_PATH = OUT / "target-before.json"
HISTORICAL_BASELINE_PATH = ROOT / "outputs/circle1-ab-merge/historical-evidence-baseline.json"
SOURCE_READY_PATH = ROOT / "outputs/circle1-ab-merge/final-source-ready.json"
OUTPUT_PATH = OUT / "independent-verification.json"
FOLDERS = ("docs", "scripts", "data", "assets", "tests", "screenshots", "outputs")
ROOT_FILES = (".gitignore", "AGENTS.md", "CLAUDE.md")
TEAM_DOCS = [f"docs/planning/team/{i:02d}_" + n for i, n in enumerate(
    ("游戏总览.md", "三圈范围.md", "系统规则.md", "数值与物品.md",
     "剧情与事件.md", "视听与交互.md", "进度与待决策.md", "技术约定.md"), 1)]
FORMAL_SHEET_EXCLUDE = re.compile(r"历史|归档|旧版|archive|history", re.IGNORECASE)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inventory(root: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for folder in FOLDERS:
        folder_path = root / folder
        if not folder_path.exists():
            continue
        for path in folder_path.rglob("*"):
            if path.is_file() and not path.resolve().is_relative_to(OUT):
                path.resolve().relative_to(root)
                found[path.relative_to(root).as_posix()] = path
    for name in ROOT_FILES:
        path = root / name
        if path.is_file():
            found[name] = path
    return found


def sheet_names(path: Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read("xl/workbook.xml"))
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    return [node.attrib["name"] for node in root.findall("m:sheets/m:sheet", ns)]


def add_check(checks: list[dict], name: str, ok: bool, details: dict):
    checks.append({"name": name, "status": "PASS" if ok else "FAIL", **details})


def main() -> int:
    plan = read_json(PLAN_PATH)
    result = read_json(RESULT_PATH)
    progress = read_json(PROGRESS_PATH)
    before = read_json(TARGET_BEFORE_PATH)
    historical = read_json(HISTORICAL_BASELINE_PATH)
    source_ready = read_json(SOURCE_READY_PATH)
    plan_rows = plan["files"]
    result_rows = result["files"]
    progress_rows = progress["files"]
    plan_by_path = {row["path"]: row for row in plan_rows}
    result_by_path = {row["path"]: row for row in result_rows}
    progress_by_path = {row["path"]: row for row in progress_rows}
    checks: list[dict] = []
    discrepancies: list[dict] = []

    # Rebuild the selected source inventory and independently re-hash every planned source file.
    actual_source = inventory(SOURCE)
    source_inventory_delta = {
        "missing_from_plan": sorted(set(actual_source) - set(plan_by_path)),
        "absent_from_source": sorted(set(plan_by_path) - set(actual_source)),
    }
    source_hash_mismatches = []
    source_evidence = []
    for rel, row in plan_by_path.items():
        source_path = actual_source.get(rel)
        if source_path is None:
            continue
        actual_hash = sha256(source_path)
        source_evidence.append({"path": rel, "planned_sha256": row["sourceSha256"], "current_source_sha256": actual_hash})
        if actual_hash != row["sourceSha256"]:
            source_hash_mismatches.append({"path": rel, "planned": row["sourceSha256"], "actual": actual_hash})
    add_check(checks, "source_inventory_and_plan_hashes", not any(source_inventory_delta.values()) and not source_hash_mismatches,
              {"source_inventory_count": len(actual_source), "plan_count": len(plan_by_path),
               "inventory_delta": source_inventory_delta, "hash_mismatch_count": len(source_hash_mismatches),
               "hash_mismatches": source_hash_mismatches[:20]})

    plan_counts = dict(Counter(row["action"] for row in plan_rows))
    add_check(checks, "merge_record_consistency", plan_counts == plan["counts"] == result["counts"] and
              set(plan_by_path) == set(result_by_path) == set(progress_by_path) and
              progress.get("completed") == len(plan_rows),
              {"plan_counts": plan_counts, "plan_rows": len(plan_rows), "result_rows": len(result_rows),
               "progress_rows": len(progress_rows), "progress_completed": progress.get("completed"),
               "recorded_source_changed_during_merge": result.get("sourceChangedDuringMerge"),
               "changed_existing_files_recorded": result.get("changedExistingFiles")})

    # Verify every claimed addition in the source, current target, result and final progress snapshot.
    additions = [row for row in plan_rows if row["action"] == "add_missing"]
    addition_mismatches = []
    addition_evidence = []
    for row in additions:
        rel = row["path"]
        target_path = ROOT / Path(rel)
        result_row = result_by_path.get(rel, {})
        progress_row = progress_by_path.get(rel, {})
        actual_source_hash = sha256(SOURCE / Path(rel)) if (SOURCE / Path(rel)).is_file() else None
        actual_target_hash = sha256(target_path) if target_path.is_file() else None
        expected = row["sourceSha256"]
        addition_evidence.append({"path": rel, "planned_source_sha256": expected,
                                  "current_source_sha256": actual_source_hash,
                                  "current_target_sha256": actual_target_hash,
                                  "result_target_after_sha256": result_row.get("targetAfterSha256"),
                                  "progress_target_after_sha256": progress_row.get("targetAfterSha256")})
        if not (actual_source_hash == expected and actual_target_hash == expected and
                result_row.get("targetAfterSha256") == expected and progress_row.get("targetAfterSha256") == expected):
            addition_mismatches.append({"path": rel, "expected": expected, "source": actual_source_hash,
                                        "target": actual_target_hash, "result": result_row.get("targetAfterSha256"),
                                        "progress": progress_row.get("targetAfterSha256")})
    add_check(checks, "all_additions_match_source_sha256", len(additions) == 136 and not addition_mismatches,
              {"addition_count": len(additions), "verified_count": len(additions) - len(addition_mismatches),
               "mismatch_count": len(addition_mismatches), "mismatches": addition_mismatches[:20]})

    # Verify every file in the pre-merge target snapshot still exists with the captured hash.
    before_hashes = before["hashes"]
    before_mismatches = []
    preserved_target_evidence = []
    for rel, expected in before_hashes.items():
        target_path = ROOT / Path(rel)
        actual_hash = sha256(target_path) if target_path.is_file() else None
        preserved_target_evidence.append({"path": rel, "target_before_sha256": expected,
                                          "current_target_sha256": actual_hash})
        if actual_hash != expected:
            before_mismatches.append({"path": rel, "expected": expected, "actual": actual_hash})
    add_check(checks, "preexisting_target_files_unchanged", len(before_hashes) == 838 and
              result.get("existingFilesPreserved") == 838 and result.get("changedExistingFiles") == [] and
              not before_mismatches,
              {"baseline_count": len(before_hashes), "matched_count": len(before_hashes) - len(before_mismatches),
               "mismatch_count": len(before_mismatches), "mismatches": before_mismatches[:20]})

    # Explicitly verify the 27 reviewed C-side code conflicts remain at their pre-merge hashes.
    code_conflicts = [row for row in plan_rows if row["action"] == "keep_reviewed_c_code"]
    code_conflict_mismatches = []
    code_conflict_evidence = []
    for row in code_conflicts:
        rel = row["path"]
        target_path = ROOT / Path(rel)
        actual_hash = sha256(target_path) if target_path.is_file() else None
        code_conflict_evidence.append({"path": rel, "source_sha256": row["sourceSha256"],
                                       "target_before_sha256": row["targetBeforeSha256"],
                                       "current_target_sha256": actual_hash})
        if actual_hash != row["targetBeforeSha256"] or actual_hash == row["sourceSha256"]:
            code_conflict_mismatches.append({"path": rel, "target_before": row["targetBeforeSha256"],
                                             "source": row["sourceSha256"], "actual_target": actual_hash})
    add_check(checks, "reviewed_code_conflicts_kept_from_c", len(code_conflicts) == 27 and not code_conflict_mismatches,
              {"conflict_count": len(code_conflicts), "verified_count": len(code_conflicts) - len(code_conflict_mismatches),
               "mismatch_count": len(code_conflict_mismatches), "mismatches": code_conflict_mismatches[:20]})

    # Check team documents exist in both trees and retain matching source hashes.
    team_mismatches = []
    team_evidence = []
    for rel in TEAM_DOCS:
        plan_row = plan_by_path.get(rel, {})
        source_path, target_path = SOURCE / Path(rel), ROOT / Path(rel)
        source_hash = sha256(source_path) if source_path.is_file() else None
        target_hash = sha256(target_path) if target_path.is_file() else None
        team_evidence.append({"path": rel, "planned_source_sha256": plan_row.get("sourceSha256"),
                              "current_source_sha256": source_hash, "current_target_sha256": target_hash})
        if not (plan_row.get("sourceSha256") and source_hash == plan_row.get("sourceSha256") and
                target_hash == plan_row.get("sourceSha256")):
            team_mismatches.append({"path": rel, "planned": plan_row.get("sourceSha256"),
                                    "source": source_hash, "target": target_hash})
    add_check(checks, "team8_planning_documents_present_and_identical", len(TEAM_DOCS) == 8 and not team_mismatches,
              {"document_count": len(TEAM_DOCS), "documents": TEAM_DOCS, "mismatch_count": len(team_mismatches),
               "mismatches": team_mismatches})

    # Protect the archived A/AB evidence set using its recorded 212-file baseline.
    historical_files = historical["files"]
    historical_mismatches = []
    historical_evidence = []
    for row in historical_files:
        rel = row["path"]
        path = ROOT / Path(rel)
        actual_hash = sha256(path) if path.is_file() else None
        historical_evidence.append({"path": rel, "baseline_sha256": row["sha256"], "current_sha256": actual_hash})
        if actual_hash != row["sha256"]:
            historical_mismatches.append({"path": rel, "expected": row["sha256"], "actual": actual_hash})
    add_check(checks, "historical_a_ab_evidence_baseline_unchanged", historical.get("file_count") == 212 and
              len(historical_files) == 212 and not historical_mismatches,
              {"baseline_count": historical.get("file_count"), "matched_count": len(historical_files) - len(historical_mismatches),
               "mismatch_count": len(historical_mismatches), "mismatches": historical_mismatches[:20],
               "baseline_scope": historical.get("scope")})

    # Confirm the previous final-ready Lua snapshot still matches current C source.
    source_snapshot = source_ready.get("sourceHashSnapshot", {})
    lua_entries = {rel: value.lower() for rel, value in source_snapshot.items() if rel.lower().endswith(".lua")}
    lua_mismatches = []
    lua_evidence = []
    for rel, expected in lua_entries.items():
        path = ROOT / Path(rel)
        actual_hash = sha256(path).lower() if path.is_file() else None
        lua_evidence.append({"path": rel, "final_source_ready_sha256": expected, "current_sha256": actual_hash})
        if actual_hash != expected:
            lua_mismatches.append({"path": rel, "expected": expected, "actual": actual_hash})
    add_check(checks, "final_source_ready_lua_snapshot_unchanged", len(lua_entries) == 86 and not lua_mismatches,
              {"lua_snapshot_count": len(lua_entries), "matched_count": len(lua_entries) - len(lua_mismatches),
               "mismatch_count": len(lua_mismatches), "mismatches": lua_mismatches[:20],
               "source_ready_status": source_ready.get("status")})

    # CRC-check every copied workbook and read worksheet names only from the current v2.1 package XML.
    copied_workbooks = [row["path"] for row in additions if Path(row["path"]).suffix.lower() == ".xlsx"]
    workbook_crc_failures = []
    for rel in copied_workbooks:
        for label, path in (("source", SOURCE / Path(rel)), ("target", ROOT / Path(rel))):
            try:
                with zipfile.ZipFile(path) as archive:
                    bad_member = archive.testzip()
                if bad_member is not None:
                    workbook_crc_failures.append({"path": rel, "side": label, "bad_member": bad_member})
            except Exception as exc:  # report, do not repair
                workbook_crc_failures.append({"path": rel, "side": label, "error": type(exc).__name__ + ": " + str(exc)})
    current_v21 = ROOT / "docs/planning/exports/记录表_新版策划_2026-10-02_v2.1.xlsx"
    current_v21_names = sheet_names(current_v21) if current_v21.is_file() else []
    formal_names = [name for name in current_v21_names if not FORMAL_SHEET_EXCLUDE.search(name)]
    add_check(checks, "copied_workbook_crc_and_current_v21_sheet_names", not workbook_crc_failures and len(formal_names) == 8,
              {"copied_xlsx_count": len(copied_workbooks), "copied_xlsx_paths": copied_workbooks,
               "crc_failures": workbook_crc_failures,
               "current_v21_path": "docs/planning/exports/记录表_新版策划_2026-10-02_v2.1.xlsx",
               "current_v21_sheet_count": len(current_v21_names), "formal_sheet_count": len(formal_names),
               "formal_sheet_names": formal_names,
               "historical_sheet_names": [name for name in current_v21_names if FORMAL_SHEET_EXCLUDE.search(name)]})

    # Keep a concise, explicit list of recorded exclusions and evidence boundaries.
    skipped = [row["path"] for row in plan_rows if row["action"] == "skip_cache"]
    add_check(checks, "expected_cache_exclusions_recorded", len(skipped) == 2,
              {"skip_cache_count": len(skipped), "paths": skipped,
               "other_action_counts": plan_counts})

    all_passed = all(check["status"] == "PASS" for check in checks)
    report = {
        "schema_version": 1,
        "verification_type": "independent_read_only_post_merge_hash_and_archive_integrity_check",
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "source": str(SOURCE),
        "target": str(ROOT),
        "overall_status": "PASS" if all_passed else "FAIL",
        "checks": checks,
        "file_hash_evidence": {
            "current_source_inventory": source_evidence,
            "copied_additions": addition_evidence,
            "preexisting_target_snapshot": preserved_target_evidence,
            "reviewed_code_conflicts": code_conflict_evidence,
            "team_planning_documents": team_evidence,
            "historical_a_ab_baseline": historical_evidence,
            "final_source_ready_lua_snapshot": lua_evidence,
        },
        "limitations": [
            "The merge-time source-stability interval cannot be replayed after the fact; the stored result records an empty sourceChangedDuringMerge list, and this check confirms the current source still matches all planned source hashes.",
            "This verifies file-selection, file-content integrity and archived evidence hashes; it does not establish runtime behavior, native GUI acceptance, cloud behavior, or whole-project completion.",
            "No project validation tool, Lua business test, preview, cloud action, or Git build/commit was run by this verifier."
        ],
    }
    OUTPUT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"overall_status": report["overall_status"], "output": str(OUTPUT_PATH),
                      "checks": [{"name": c["name"], "status": c["status"]} for c in checks]},
                     ensure_ascii=False, indent=2))
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
