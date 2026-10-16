#!/usr/bin/env python3
"""Read-only integrity check for the Circle 1 A protection baseline.

The repository root is derived from this file, so the command works from any
current directory. Only protection-result.json and protection-audit.md are
written. Baseline and historical evidence files are read-only inputs.
"""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
OUTPUT_DIR = SCRIPT_PATH.parent
PROTECTION_PATH = OUTPUT_DIR / "a-protection.json"
HISTORICAL_BASELINE_PATH = OUTPUT_DIR / "historical-evidence-baseline.json"
DELIVERY_MANIFEST_PATH = REPO_ROOT / "outputs" / "circle1-a3" / "delivery-manifest.json"
SUPPLEMENTAL_PROTECTION_PATH = OUTPUT_DIR / "supplemental-protection.json"
RESULT_PATH = OUTPUT_DIR / "protection-result.json"
AUDIT_PATH = OUTPUT_DIR / "protection-audit.md"

EXPECTED_PROTECTED_FILES = 43
EXPECTED_A3_DELIVERY_FILES = 12
HISTORICAL_DIRECTORY_PREFIX = "circle1-a"
SELF_DIRECTORY_NAME = "circle1-ab-merge"
EXPLICIT_HISTORICAL_DIRECTORY = "circle1-ab-review"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def safe_repo_path(relative_path: str) -> Path:
    """Resolve a slash-separated repository path and reject traversal."""
    if not isinstance(relative_path, str) or not relative_path or "\\" in relative_path:
        raise ValueError(f"invalid repository-relative path: {relative_path!r}")
    parsed = PurePosixPath(relative_path)
    if parsed.is_absolute() or any(part in ("", ".", "..") for part in parsed.parts):
        raise ValueError(f"unsafe repository-relative path: {relative_path!r}")
    resolved = (REPO_ROOT / Path(*parsed.parts)).resolve()
    try:
        resolved.relative_to(REPO_ROOT)
    except ValueError as error:
        raise ValueError(f"path resolves outside repository: {relative_path!r}") from error
    return resolved


def relative_posix(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def scan_historical_evidence() -> tuple[list[str], dict[str, dict[str, Any]], list[str]]:
    output_root = REPO_ROOT / "outputs"
    directories: list[str] = []
    files: dict[str, dict[str, Any]] = {}
    issues: list[str] = []

    if not output_root.is_dir():
        return directories, files, ["outputs directory is missing"]

    candidates = []
    for child in output_root.iterdir():
        if not child.is_dir():
            continue
        is_historical = child.name.startswith(HISTORICAL_DIRECTORY_PREFIX)
        is_explicit = child.name == EXPLICIT_HISTORICAL_DIRECTORY
        if (is_historical or is_explicit) and child.name != SELF_DIRECTORY_NAME:
            candidates.append(child)

    for directory in sorted(candidates, key=lambda item: item.name):
        try:
            resolved_dir = directory.resolve()
            resolved_dir.relative_to(REPO_ROOT)
        except (OSError, ValueError):
            issues.append(f"historical directory resolves outside repository: {directory.name}")
            continue

        directories.append(relative_posix(directory))
        for candidate in directory.rglob("*"):
            if not candidate.is_file():
                continue
            try:
                resolved_file = candidate.resolve()
                resolved_file.relative_to(REPO_ROOT)
                file_hash = sha256_file(resolved_file)
                size_bytes = resolved_file.stat().st_size
            except (OSError, ValueError) as error:
                issues.append(f"cannot hash historical file {relative_posix(candidate)}: {error}")
                continue

            relative_path = relative_posix(candidate)
            files[relative_path] = {"sha256": file_hash, "size_bytes": size_bytes}

    return directories, files, issues


def compare_historical_evidence(baseline: Any) -> dict[str, Any]:
    issues: list[str] = []
    if not isinstance(baseline, dict) or not isinstance(baseline.get("files"), list):
        return {
            "status": "invalid_baseline",
            "issues": ["historical baseline must contain a files array"],
            "missing_files": [],
            "changed_files": [],
            "added_files": [],
            "unchanged_files": 0,
            "new_files_are_informational": True,
        }

    current_directories, current_files, scan_issues = scan_historical_evidence()
    issues.extend(scan_issues)
    baseline_files: dict[str, dict[str, Any]] = {}
    for record in baseline["files"]:
        if not isinstance(record, dict):
            issues.append("historical baseline has a non-object file record")
            continue
        path = record.get("path")
        expected_hash = record.get("sha256")
        try:
            safe_repo_path(path)
        except (TypeError, ValueError) as error:
            issues.append(str(error))
            continue
        if path in baseline_files:
            issues.append(f"duplicate historical baseline path: {path}")
            continue
        if not isinstance(expected_hash, str) or len(expected_hash) != 64:
            issues.append(f"invalid historical baseline SHA-256 for {path}")
            continue
        baseline_files[path] = record

    missing_files = sorted(set(baseline_files) - set(current_files))
    added_files = sorted(set(current_files) - set(baseline_files))
    changed_files = []
    unchanged_count = 0
    for path in sorted(set(baseline_files) & set(current_files)):
        expected_hash = baseline_files[path]["sha256"].lower()
        current_hash = current_files[path]["sha256"].lower()
        if expected_hash == current_hash:
            unchanged_count += 1
        else:
            changed_files.append(
                {
                    "path": path,
                    "expected_sha256": baseline_files[path]["sha256"],
                    "actual_sha256": current_files[path]["sha256"],
                }
            )

    baseline_directories = baseline.get("directories", [])
    if not isinstance(baseline_directories, list):
        baseline_directories = []
        issues.append("historical baseline directories must be an array")
    missing_directories = sorted(set(baseline_directories) - set(current_directories))
    added_directories = sorted(set(current_directories) - set(baseline_directories))
    review_required = bool(missing_files or changed_files or missing_directories or issues)
    status = "review_required" if review_required else ("additions_only" if added_files or added_directories else "unchanged")

    return {
        "status": status,
        "baseline_captured_at_utc": baseline.get("captured_at_utc"),
        "baseline_directory_count": len(baseline_directories),
        "current_directory_count": len(current_directories),
        "baseline_file_count": len(baseline_files),
        "current_file_count": len(current_files),
        "unchanged_files": unchanged_count,
        "missing_files": missing_files,
        "changed_files": changed_files,
        "added_files": added_files,
        "missing_directories": missing_directories,
        "added_directories": added_directories,
        "issues": issues,
        "new_files_are_informational": True,
        "directories_are_informational_when_added": True,
    }


def check_protected_files(protection: Any) -> tuple[dict[str, Any], dict[str, str]]:
    issues: list[str] = []
    if not isinstance(protection, dict) or not isinstance(protection.get("files"), list):
        return ({"status": "invalid_baseline", "issues": ["a-protection.json must contain a files array"], "entries": []}, {})

    records: dict[str, dict[str, Any]] = {}
    for record in protection["files"]:
        if not isinstance(record, dict):
            issues.append("A protection list has a non-object entry")
            continue
        relative_path = record.get("file")
        expected_hash = record.get("sha256")
        try:
            safe_repo_path(relative_path)
        except (TypeError, ValueError) as error:
            issues.append(str(error))
            continue
        if relative_path in records:
            issues.append(f"duplicate A protection path: {relative_path}")
            continue
        if not isinstance(expected_hash, str) or len(expected_hash) != 64:
            issues.append(f"invalid A protection SHA-256 for {relative_path}")
            continue
        records[relative_path] = record

    if len(records) != EXPECTED_PROTECTED_FILES:
        issues.append(f"expected {EXPECTED_PROTECTED_FILES} protected files; baseline contains {len(records)} valid unique paths")

    entries = []
    actual_hashes: dict[str, str] = {}
    for relative_path in sorted(records):
        expected_hash = records[relative_path]["sha256"]
        target = safe_repo_path(relative_path)
        if not target.is_file():
            actual_hash = None
            status = "missing"
        else:
            actual_hash = sha256_file(target)
            actual_hashes[relative_path] = actual_hash
            status = "match" if actual_hash.lower() == expected_hash.lower() else "changed"
        entries.append(
            {
                "file": relative_path,
                "expected_sha256": expected_hash,
                "actual_sha256": actual_hash,
                "status": status,
            }
        )

    mismatches = [entry for entry in entries if entry["status"] != "match"]
    return (
        {
            "status": "review_required" if mismatches or issues else "match",
            "expected_file_count": EXPECTED_PROTECTED_FILES,
            "baseline_file_count": len(records),
            "matched_count": len(entries) - len(mismatches),
            "missing_count": sum(entry["status"] == "missing" for entry in entries),
            "changed_count": sum(entry["status"] == "changed" for entry in entries),
            "issues": issues,
            "entries": entries,
        },
        actual_hashes,
    )


def check_supplemental_protection() -> dict[str, Any]:
    """Check the optional extra hash list without changing its baseline."""
    if not SUPPLEMENTAL_PROTECTION_PATH.is_file():
        return {
            "status": "not_configured",
            "expected_file_count": 0,
            "matched_count": 0,
            "missing_count": 0,
            "changed_count": 0,
            "issues": [],
            "entries": [],
            "new_files_are_informational": True,
            "unlisted_files_enumerated": False,
        }
    try:
        supplemental = load_json(SUPPLEMENTAL_PROTECTION_PATH)
    except (OSError, json.JSONDecodeError) as error:
        return {
            "status": "invalid_baseline",
            "expected_file_count": 0,
            "matched_count": 0,
            "missing_count": 0,
            "changed_count": 0,
            "issues": [f"cannot parse supplemental protection baseline: {error}"],
            "entries": [],
            "new_files_are_informational": True,
            "unlisted_files_enumerated": False,
        }

    issues: list[str] = []
    if not isinstance(supplemental, dict) or not isinstance(supplemental.get("files"), list):
        return {
            "status": "invalid_baseline",
            "expected_file_count": 0,
            "matched_count": 0,
            "missing_count": 0,
            "changed_count": 0,
            "issues": ["supplemental-protection.json must contain a files array"],
            "entries": [],
            "new_files_are_informational": True,
            "unlisted_files_enumerated": False,
        }

    records: dict[str, dict[str, Any]] = {}
    for record in supplemental["files"]:
        if not isinstance(record, dict):
            issues.append("supplemental protection list has a non-object entry")
            continue
        relative_path = record.get("file")
        expected_hash = record.get("sha256")
        try:
            safe_repo_path(relative_path)
        except (TypeError, ValueError) as error:
            issues.append(str(error))
            continue
        if relative_path in records:
            issues.append(f"duplicate supplemental protection path: {relative_path}")
            continue
        if not isinstance(expected_hash, str) or len(expected_hash) != 64:
            issues.append(f"invalid supplemental protection SHA-256 for {relative_path}")
            continue
        records[relative_path] = record

    entries = []
    for relative_path in sorted(records):
        expected_hash = records[relative_path]["sha256"]
        target = safe_repo_path(relative_path)
        if not target.is_file():
            actual_hash = None
            status = "missing"
        else:
            actual_hash = sha256_file(target)
            status = "match" if actual_hash.lower() == expected_hash.lower() else "changed"
        entries.append(
            {
                "file": relative_path,
                "expected_sha256": expected_hash,
                "actual_sha256": actual_hash,
                "status": status,
            }
        )

    mismatches = [entry for entry in entries if entry["status"] != "match"]
    return {
        "status": "review_required" if mismatches or issues else "match",
        "baseline_file": relative_posix(SUPPLEMENTAL_PROTECTION_PATH),
        "baseline_sha256": sha256_file(SUPPLEMENTAL_PROTECTION_PATH),
        "expected_file_count": len(records),
        "matched_count": len(entries) - len(mismatches),
        "missing_count": sum(entry["status"] == "missing" for entry in entries),
        "changed_count": sum(entry["status"] == "changed" for entry in entries),
        "issues": issues,
        "entries": entries,
        "new_files_are_informational": True,
        "unlisted_files_enumerated": False,
        "addition_note": "The supplemental baseline is an explicit hash list with no directory inventory; unlisted source paths are not inferred as violations.",
    }


def check_a3_delivery(protection: Any, protected_hashes: dict[str, str]) -> dict[str, Any]:
    issues: list[str] = []
    if not DELIVERY_MANIFEST_PATH.is_file():
        return {"status": "invalid_baseline", "issues": ["A3 delivery manifest is missing"], "entries": []}
    try:
        manifest = load_json(DELIVERY_MANIFEST_PATH)
    except (OSError, json.JSONDecodeError) as error:
        return {"status": "invalid_baseline", "issues": [f"cannot parse A3 delivery manifest: {error}"], "entries": []}
    if not isinstance(manifest, dict):
        return {"status": "invalid_baseline", "issues": ["A3 delivery manifest must be a JSON object"], "entries": []}

    protection_checks = protection.get("a3DeliveryCheck", []) if isinstance(protection, dict) else []
    if not isinstance(protection_checks, list):
        protection_checks = []
        issues.append("a-protection.json a3DeliveryCheck must be an array")
    protection_check_map: dict[str, Any] = {}
    for record in protection_checks:
        if not isinstance(record, dict) or not isinstance(record.get("file"), str):
            issues.append("a3DeliveryCheck has an invalid entry")
            continue
        if record["file"] in protection_check_map:
            issues.append(f"duplicate A3 protection check path: {record['file']}")
            continue
        protection_check_map[record["file"]] = record

    if len(manifest) != EXPECTED_A3_DELIVERY_FILES:
        issues.append(f"expected {EXPECTED_A3_DELIVERY_FILES} A3 manifest entries; found {len(manifest)}")
    if set(manifest) != set(protection_check_map):
        issues.append("A3 manifest paths do not match a-protection.json a3DeliveryCheck paths")

    protection_expected = {
        record["file"]: record["sha256"]
        for record in protection.get("files", [])
        if isinstance(record, dict) and isinstance(record.get("file"), str) and isinstance(record.get("sha256"), str)
    } if isinstance(protection, dict) else {}

    entries = []
    for relative_path in sorted(manifest):
        try:
            safe_repo_path(relative_path)
        except (TypeError, ValueError) as error:
            issues.append(str(error))
            entries.append({"file": relative_path, "status": "invalid_path"})
            continue

        manifest_record = manifest[relative_path]
        if not isinstance(manifest_record, dict) or not isinstance(manifest_record.get("sha256"), str):
            issues.append(f"A3 manifest entry has no sha256: {relative_path}")
            entries.append({"file": relative_path, "status": "invalid_entry"})
            continue
        manifest_hash = manifest_record["sha256"]
        protected_hash = protection_expected.get(relative_path)
        target = safe_repo_path(relative_path)
        actual_hash = sha256_file(target) if target.is_file() else None
        check = protection_check_map.get(relative_path)
        baseline_check_ok = isinstance(check, dict) and check.get("matches") is True
        hashes_consistent = protected_hash is not None and protected_hash.lower() == manifest_hash.lower()
        if actual_hash is None:
            status = "missing"
        elif not hashes_consistent or not baseline_check_ok:
            status = "baseline_inconsistent"
        elif actual_hash.lower() != manifest_hash.lower():
            status = "changed"
        else:
            status = "match"
        entries.append(
            {
                "file": relative_path,
                "manifest_sha256": manifest_hash,
                "protection_sha256": protected_hash,
                "actual_sha256": actual_hash,
                "a_protection_check_matches": baseline_check_ok,
                "status": status,
            }
        )

    bad_entries = [entry for entry in entries if entry.get("status") != "match"]
    return {
        "status": "review_required" if bad_entries or issues else "match",
        "expected_file_count": EXPECTED_A3_DELIVERY_FILES,
        "manifest_file": relative_posix(DELIVERY_MANIFEST_PATH),
        "manifest_sha256": sha256_file(DELIVERY_MANIFEST_PATH),
        "manifest_entry_count": len(manifest),
        "matched_count": len(entries) - len(bad_entries),
        "issues": issues,
        "entries": entries,
    }


def build_audit(result: dict[str, Any]) -> str:
    protection = result["a_protection"]
    supplemental = result["supplemental_protection"]
    delivery = result["a3_delivery"]
    history = result["historical_evidence"]
    lines = [
        "# A 保护只读检查",
        "",
        f"- 检查时间（UTC）：`{result['generated_at_utc']}`",
        f"- 仓库：`{result['repository_root']}`",
        f"- 总状态：`{result['status']}`",
        f"- A 保护文件：{protection.get('matched_count', 0)}/{protection.get('expected_file_count', EXPECTED_PROTECTED_FILES)} 匹配，缺失 {protection.get('missing_count', 0)}，变化 {protection.get('changed_count', 0)}。",
        f"- 补充保护文件：{supplemental.get('matched_count', 0)}/{supplemental.get('expected_file_count', 0)} 匹配，缺失 {supplemental.get('missing_count', 0)}，变化 {supplemental.get('changed_count', 0)}；新增不升级为违规。",
        f"- A3 交付清单：{delivery.get('matched_count', 0)}/{delivery.get('expected_file_count', EXPECTED_A3_DELIVERY_FILES)} 匹配。",
        f"- 历史证据：基线 {history.get('baseline_file_count', 0)} 项，当前 {history.get('current_file_count', 0)} 项；缺失 {len(history.get('missing_files', []))}，变化 {len(history.get('changed_files', []))}，新增 {len(history.get('added_files', []))}。新增项仅报告，不自动判违规。",
        "",
        "本报告只校验既有 A 保护哈希、A3 交付清单与历史输出哈希。B4 业务源码仍在变化且未纳入最终验收；本结果不代表 A+B 合并验收。脚本不会改动被检查源码或历史证据。",
    ]

    for title, rows in (
        ("A 保护文件需要复核", [entry for entry in protection.get("entries", []) if entry["status"] != "match"]),
        ("补充保护文件需要复核", [entry for entry in supplemental.get("entries", []) if entry["status"] != "match"]),
        ("A3 交付文件需要复核", [entry for entry in delivery.get("entries", []) if entry.get("status") != "match"]),
    ):
        if rows:
            lines.extend(["", f"## {title}", ""])
            lines.extend(f"- `{entry.get('file')}`：`{entry.get('status')}`" for entry in rows)

    if history.get("missing_files") or history.get("changed_files") or history.get("issues"):
        lines.extend(["", "## 历史证据需要复核", ""])
        for path in history.get("missing_files", []):
            lines.append(f"- 缺失：`{path}`")
        for entry in history.get("changed_files", []):
            lines.append(f"- 哈希变化：`{entry['path']}`")
        for issue in history.get("issues", []):
            lines.append(f"- 检查问题：{issue}")
    if history.get("added_files"):
        lines.extend(["", "## 新增历史输出（信息项）", ""])
        lines.extend(f"- `{path}`" for path in history["added_files"])

    lines.append("")
    return "\n".join(lines)


def run() -> int:
    required_inputs = (PROTECTION_PATH, HISTORICAL_BASELINE_PATH, DELIVERY_MANIFEST_PATH)
    missing_inputs = [str(path) for path in required_inputs if not path.is_file()]
    if missing_inputs:
        print("Required read-only baseline input is missing:", *missing_inputs, sep="\n- ", file=sys.stderr)
        return 2

    try:
        protection = load_json(PROTECTION_PATH)
        historical_baseline = load_json(HISTORICAL_BASELINE_PATH)
    except (OSError, json.JSONDecodeError) as error:
        print(f"Cannot read a baseline input: {error}", file=sys.stderr)
        return 2

    protection_result, protected_hashes = check_protected_files(protection)
    supplemental_result = check_supplemental_protection()
    delivery_result = check_a3_delivery(protection, protected_hashes)
    historical_result = compare_historical_evidence(historical_baseline)
    attention_required = any(
        section.get("status") in ("review_required", "invalid_baseline")
        for section in (protection_result, supplemental_result, delivery_result, historical_result)
    )
    result = {
        "schema_version": 1,
        "generated_at_utc": utc_now(),
        "repository_root": str(REPO_ROOT),
        "scope": {
            "protected_file_count": EXPECTED_PROTECTED_FILES,
            "a3_delivery_file_count": EXPECTED_A3_DELIVERY_FILES,
            "supplemental_protection_file": relative_posix(SUPPLEMENTAL_PROTECTION_PATH),
            "historical_outputs": "outputs/circle1-a* and outputs/circle1-ab-review, excluding outputs/circle1-ab-merge",
            "writes_only": [relative_posix(RESULT_PATH), relative_posix(AUDIT_PATH)],
        },
        "status": "attention_required" if attention_required else "match",
        "a_protection": protection_result,
        "supplemental_protection": supplemental_result,
        "a3_delivery": delivery_result,
        "historical_evidence": historical_result,
        "limitations": [
            "This is a hash and file-inventory check; it does not assess behavior or correctness.",
            "B4 business source files are changing and are not subject to final acceptance here.",
            "Added historical evidence is informational and does not automatically count as a violation.",
            "Unlisted supplemental source files are not inferred as additions because that baseline has no directory inventory; hash changes and missing listed paths require review.",
            "A matching hash does not establish that the historical evidence itself proves runtime or cloud behavior.",
        ],
    }

    # Keep writes constrained to the two designated report files.
    RESULT_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    AUDIT_PATH.write_text(build_audit(result), encoding="utf-8")

    print(
        "{status}: A files {matched}/{expected}; supplemental files {supplemental_matched}/{supplemental_expected}; "
        "A3 files {a3_matched}/{a3_expected}; "
        "historical files unchanged={unchanged}, missing={missing}, changed={changed}, added={added}".format(
            status=result["status"],
            matched=protection_result.get("matched_count", 0),
            expected=protection_result.get("expected_file_count", EXPECTED_PROTECTED_FILES),
            supplemental_matched=supplemental_result.get("matched_count", 0),
            supplemental_expected=supplemental_result.get("expected_file_count", 0),
            a3_matched=delivery_result.get("matched_count", 0),
            a3_expected=delivery_result.get("expected_file_count", EXPECTED_A3_DELIVERY_FILES),
            unchanged=historical_result.get("unchanged_files", 0),
            missing=len(historical_result.get("missing_files", [])),
            changed=len(historical_result.get("changed_files", [])),
            added=len(historical_result.get("added_files", [])),
        )
    )
    return 1 if attention_required else 0


if __name__ == "__main__":
    raise SystemExit(run())
