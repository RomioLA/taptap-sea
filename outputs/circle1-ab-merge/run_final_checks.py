"""Current-worktree Circle 1 A+B final regression entry point.

Every suite gets a fresh Lua 5.4 runtime whose Lua module path is restricted to
this checkout's scripts/ directory. This runner never composes source trees,
uses a D: fallback, starts Maker, or writes evidence outside final-checks/.
The default readiness stage inspects the host and available suites without
calling any suite Run function.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import re
import sys
import traceback
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = (ROOT / "scripts").resolve()
MERGE = (ROOT / "outputs" / "circle1-ab-merge").resolve()
OUT = (MERGE / "final-checks").resolve()
SELF_CHECK_FILE = MERGE / "runner-selfcheck.json"
FINAL_SOURCE_READY_FILE = MERGE / "final-source-ready.json"
A_PROTECTION_FILE = MERGE / "a-protection.json"
B4_REVIEWED_SUITE_FILE = MERGE / "b4-final-suite-manifest.json"
MERGE_MODULES = ("tests.Circle1ABMergeFrameBudgetTests",)

A1_MODULES = (
    "tests.Circle1AFishLocksTests",
    "tests.Circle1APredationCooldownTests",
    "tests.SeaRuntimeTests",
    "tests.SurfaceRiseTests",
    "tests.SurfaceSignalsTests",
    "tests.SeaStabilityTests",
)
A2_MODULES = (
    "tests.Circle1A2BarrelTests",
    "tests.Circle1A2ScopeTests",
    "tests.Circle1A2SignalsTests",
)
A2_RECORDER_MODULES = (
    "tests.Circle1A2BarrelRenderTests",
    "tests.Circle1A2FishingTests",
    "tests.SeaFusionRenderTests",
)
A3_MODULES = (
    "tests.Circle1A3ExperienceTests",
    "tests.Circle1A3InputTests",
    "tests.Circle1A3PortTests",
    "tests.Circle1A3RecognitionTests",
    "tests.Circle1A3SignalsTests",
    "tests.Circle1A3StabilityTests",
)
LEGACY_MODULES = (
    "tests.ABIntegrationTests",
    "tests.ArchitectureIntegrationTests",
    "tests.SeaFusedSceneTests",
)
PLAYER_MODULES = (
    "tests.GameLoopSpec",
    "tests.GameLoopUISpec",
    "tests.PersistenceRegressionSpec",
    "tests.NumericEconomySpec",
    "tests.ShopStockSpec",
)

STAGES = (
    "readiness", "a1", "a2", "a3", "legacy",
    "b1", "b2", "b3", "b4", "players", "merge", "all",
)
B4_TEST_RE = re.compile(r"(?i)^(?:circle1)?b4.*(?:tests?|spec)\.lua$")
BN_TEST_RE = {
    n: re.compile(rf"(?i)^(?:circle1)?b{n}.*(?:tests?|spec)\.lua$")
    for n in (1, 2, 3)
}
B1_LEGACY_TEST_NAMES = {"circle1bfishingflowtests.lua", "circle1bpendingcatchtests.lua"}


def _python_dependency_paths() -> list[Path]:
    # These are Python package roots only. In particular the D: entry is used
    # only for its installed Lupa wheel; it is never added to Lua package.path.
    return [Path(r"D:/sillytavern-data/taptap-sea-B/.tmp/game-loop-test-runtime"),
            ROOT / "outputs" / "remote-review-20261002" / "test-runtime",
            ROOT / ".tmp" / "sea-test-deps"]


def _add_python_dependency_paths() -> None:
    for path in reversed(_python_dependency_paths()):
        if path.is_dir() and str(path) not in sys.path:
            sys.path.insert(0, str(path))


def _lua_runtime():
    _add_python_dependency_paths()
    from lupa.lua54 import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().__final_checks_scripts_root = SCRIPTS.as_posix()
    # Do not append Lupa's default paths: require() can load current scripts/
    # Lua modules only. Removing native searchers also prevents a package path
    # or CWD change from silently supplying a second source tree.
    lua.execute("""
        package.path = __final_checks_scripts_root .. "/?.lua;"
            .. __final_checks_scripts_root .. "/?/init.lua"
        package.cpath = ""
        for i = #package.searchers, 3, -1 do package.searchers[i] = nil end
    """)
    return lua


def _lua_to_python(value: Any) -> Any:
    if not callable(getattr(value, "keys", None)):
        return value
    keys = list(value.keys())
    if not keys:
        return {}
    if all(isinstance(key, (int, float)) and int(key) == key and key > 0 for key in keys):
        max_key = int(max(keys))
        if len(keys) == max_key:
            return [_lua_to_python(value[index]) for index in range(1, max_key + 1)]
    return {
        str(key): _lua_to_python(value[key])
        for key in sorted(keys, key=lambda item: str(item))
    }


def _module_file(module_name: str) -> Path:
    return SCRIPTS / (module_name.replace(".", "/") + ".lua")


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _discover_b_modules(number: int) -> list[dict[str, str]]:
    matcher = B4_TEST_RE if number == 4 else BN_TEST_RE[number]
    rows: list[dict[str, str]] = []
    if not SCRIPTS.is_dir():
        return rows
    for path in sorted(SCRIPTS.rglob("*.lua"), key=lambda item: item.as_posix().casefold()):
        if not any(part.casefold() == "tests" for part in path.relative_to(SCRIPTS).parts[:-1]):
            continue
        legacy_b1_match = (number == 1 and path.name.casefold() in B1_LEGACY_TEST_NAMES)
        if not matcher.match(path.name) and not legacy_b1_match:
            continue
        resolved = path.resolve()
        if not _is_under(resolved, SCRIPTS):
            continue
        module = ".".join(path.relative_to(SCRIPTS).with_suffix("").parts)
        rows.append({"module": module, "file": resolved.relative_to(ROOT).as_posix()})
    if number == 4 and not rows and B4_REVIEWED_SUITE_FILE.is_file():
        # B4 updated existing B2/B3 suites rather than creating B4-named Lua files.
        # Root records the reviewed actual suites with exact current source hashes.
        try:
            reviewed = json.loads(B4_REVIEWED_SUITE_FILE.read_text(encoding="utf-8-sig"))
            entries = reviewed.get("modules", [])
            if reviewed.get("status") != "reviewed" or not entries:
                return []
            for entry in entries:
                path = (ROOT / entry["file"]).resolve()
                module = entry["module"]
                if (not _is_under(path, SCRIPTS) or not path.is_file()
                        or not any(p.casefold() == "tests" for p in path.relative_to(SCRIPTS).parts[:-1])
                        or path.suffix != ".lua" or _module_file(module).resolve() != path
                        or hashlib.sha256(path.read_bytes()).hexdigest().casefold() != entry["sha256"].casefold()):
                    return []
                rows.append({"module": module, "file": path.relative_to(ROOT).as_posix(),
                             "source": "root-reviewed B4 changes to existing suites"})
        except (OSError, ValueError, KeyError, TypeError):
            return []
    return rows


def _discover_b4_delivery_notes() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not MERGE.is_dir():
        return rows
    for path in sorted(MERGE.rglob("*.md"), key=lambda item: item.as_posix().casefold()):
        name = path.name.casefold()
        if "b4" not in name or "交付" not in name:
            continue
        if path.name == "合并准备.md" or not _is_under(path, MERGE):
            continue
        try:
            size = path.stat().st_size
        except OSError:
            size = 0
        if size <= 0:
            continue
        rows.append({"file": path.resolve().relative_to(ROOT).as_posix(), "bytes": size})
    return rows


def _source_hash_entries(snapshot: Any) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    if isinstance(snapshot, dict):
        for name, value in snapshot.items():
            digest = value.get("sha256") if isinstance(value, dict) else value
            if isinstance(name, str) and isinstance(digest, str):
                entries.append((name, digest))
    elif isinstance(snapshot, list):
        for value in snapshot:
            if not isinstance(value, dict):
                continue
            name = value.get("file", value.get("path"))
            digest = value.get("sha256")
            if isinstance(name, str) and isinstance(digest, str):
                entries.append((name, digest))
    return entries


def _final_source_ready() -> dict[str, Any]:
    result: dict[str, Any] = {
        "file": FINAL_SOURCE_READY_FILE.relative_to(ROOT).as_posix(),
        "present": FINAL_SOURCE_READY_FILE.is_file(),
        "status": "missing",
        "snapshotEntryCount": 0,
        "matchedEntryCount": 0,
        "currentLuaFileCount": 0,
        "missingSnapshotEntries": [],
        "mismatches": [],
        "ready": False,
    }
    if not FINAL_SOURCE_READY_FILE.is_file():
        return result
    try:
        marker = json.loads(FINAL_SOURCE_READY_FILE.read_text(encoding="utf-8"))
    except Exception as error:
        result["status"] = "invalid_json"
        result["error"] = str(error)
        return result
    if not isinstance(marker, dict):
        result["status"] = "invalid_shape"
        return result
    marker_status = marker.get("status")
    result["status"] = str(marker_status) if marker_status is not None else "missing_status"
    snapshot = marker.get("sourceHashSnapshot", marker.get("sourceHashes"))
    entries = _source_hash_entries(snapshot)
    result["snapshotEntryCount"] = len(entries)
    snapshot_names = {Path(name).as_posix().casefold() for name, _ in entries}
    current_lua_files = sorted(
        path.resolve().relative_to(ROOT).as_posix()
        for path in SCRIPTS.rglob("*.lua")
        if _is_under(path, SCRIPTS)
    ) if SCRIPTS.is_dir() else []
    result["currentLuaFileCount"] = len(current_lua_files)
    result["missingSnapshotEntries"] = [name for name in current_lua_files
                                        if name.casefold() not in snapshot_names]
    for relative_name, expected in entries:
        candidate = Path(relative_name)
        if candidate.is_absolute() or ".." in candidate.parts:
            result["mismatches"].append({"file": relative_name, "reason": "unsafe path"})
            continue
        path = (ROOT / candidate).resolve()
        if not _is_under(path, SCRIPTS):
            result["mismatches"].append({"file": relative_name,
                                         "reason": "snapshot entries must resolve under current scripts/"})
            continue
        if not path.is_file():
            result["mismatches"].append({"file": relative_name, "reason": "file missing"})
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual.casefold() != expected.casefold():
            result["mismatches"].append({"file": relative_name, "reason": "sha256 changed",
                                         "expected": expected, "actual": actual})
            continue
        result["matchedEntryCount"] += 1
    result["ready"] = (str(marker_status).casefold() == "ready"
                        and bool(entries) and not result["mismatches"]
                        and not result["missingSnapshotEntries"])
    if str(marker_status).casefold() == "ready" and not entries:
        result["status"] = "ready_without_hash_snapshot"
    elif str(marker_status).casefold() == "ready" and result["mismatches"]:
        result["status"] = "ready_hash_mismatch"
    elif str(marker_status).casefold() == "ready" and result["missingSnapshotEntries"]:
        result["status"] = "ready_incomplete_hash_snapshot"
    return result


def _a_protection_audit() -> dict[str, Any]:
    result: dict[str, Any] = {
        "file": A_PROTECTION_FILE.relative_to(ROOT).as_posix(),
        "available": A_PROTECTION_FILE.is_file(),
        "checked": 0,
        "matched": 0,
        "mismatches": [],
    }
    if not A_PROTECTION_FILE.is_file():
        return result
    try:
        baseline = json.loads(A_PROTECTION_FILE.read_text(encoding="utf-8"))
    except Exception as error:
        result["error"] = str(error)
        return result
    for row in baseline.get("files", []):
        if not isinstance(row, dict):
            continue
        relative_name = row.get("file")
        expected = row.get("sha256")
        if not isinstance(relative_name, str) or not isinstance(expected, str):
            continue
        result["checked"] += 1
        candidate = (ROOT / relative_name).resolve()
        if not _is_under(candidate, ROOT) or not candidate.is_file():
            result["mismatches"].append({"file": relative_name, "reason": "file missing or outside workspace"})
            continue
        actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if actual.casefold() == expected.casefold():
            result["matched"] += 1
        else:
            result["mismatches"].append({"file": relative_name,
                                         "reason": "sha256 differs from A protection baseline",
                                         "expected": expected, "actual": actual})
    a3_rows = baseline.get("a3DeliveryCheck", [])
    if isinstance(a3_rows, list):
        expected_by_file = {
            row.get("file"): row.get("sha256")
            for row in baseline.get("files", [])
            if isinstance(row, dict) and isinstance(row.get("file"), str)
            and isinstance(row.get("sha256"), str)
        }
        a3_matches = 0
        for row in a3_rows:
            if not isinstance(row, dict) or not isinstance(row.get("file"), str):
                continue
            relative_name = row["file"]
            candidate = (ROOT / relative_name).resolve()
            expected = expected_by_file.get(relative_name)
            if (expected and _is_under(candidate, ROOT) and candidate.is_file()
                    and hashlib.sha256(candidate.read_bytes()).hexdigest().casefold() == expected.casefold()):
                a3_matches += 1
        result["a3DeliveryCheck"] = {
            "matched": a3_matches,
            "total": len(a3_rows),
        }
    return result


def _scripts_lua_snapshot() -> dict[str, str]:
    if not SCRIPTS.is_dir():
        return {}
    rows: dict[str, str] = {}
    paths = sorted(SCRIPTS.rglob("*.lua"), key=lambda item: item.as_posix().casefold())
    for path in paths:
        resolved = path.resolve()
        if not _is_under(resolved, SCRIPTS) or not resolved.is_file():
            continue
        relative = resolved.relative_to(ROOT).as_posix()
        rows[relative] = hashlib.sha256(resolved.read_bytes()).hexdigest()
    return rows


def _snapshot_changes(before: dict[str, str], after: dict[str, str]) -> list[dict[str, Any]]:
    changes: list[dict[str, Any]] = []
    for name in sorted(set(before) | set(after), key=str.casefold):
        old, new = before.get(name), after.get(name)
        if old != new:
            changes.append({"file": name, "beforeSha256": old, "afterSha256": new,
                            "change": "added" if old is None else
                                     "removed" if new is None else "modified"})
    return changes


def _group_inventory() -> dict[str, dict[str, Any]]:
    b4_tests = _discover_b_modules(4)
    notes = _discover_b4_delivery_notes()
    source_ready = _final_source_ready()
    b4_ready = bool(b4_tests and notes and source_ready["ready"])
    groups: dict[str, dict[str, Any]] = {}
    fixed = {
        "a1": list(A1_MODULES),
        "a2": list(A2_MODULES + A2_RECORDER_MODULES),
        "a3": list(A3_MODULES),
        "legacy": list(LEGACY_MODULES),
        "players": list(PLAYER_MODULES),
        "merge": list(MERGE_MODULES),
    }
    for name, modules in fixed.items():
        rows = [{"module": module,
                 "file": _module_file(module).resolve().relative_to(ROOT).as_posix(),
                 "exists": _module_file(module).is_file()}
                for module in modules]
        groups[name] = {
            "readiness": "available" if all(row["exists"] for row in rows) else "incomplete",
            "execution": "not_tested",
            "modules": rows,
        }
    for number in (1, 2, 3, 4):
        found = _discover_b_modules(number)
        readiness = "available" if found else "not_ready"
        if number == 4:
            readiness = "available" if b4_ready else "not_ready"
        groups[f"b{number}"] = {
            "readiness": readiness,
            "execution": "not_tested",
            "modules": found,
            "deliveryNotes": notes if number == 4 else [],
            "finalSourceReady": source_ready if number == 4 else None,
        }
    return groups


def _host_readiness() -> dict[str, Any]:
    result: dict[str, Any] = {
        "pythonVersion": sys.version,
        "pythonExecutable": str(Path(sys.executable).resolve()),
        "lua54Available": False,
        "luaVersion": None,
        "lupaImportError": None,
        "lupaModuleFile": None,
        "lupaVersion": None,
        "dependencyPaths": [
            {"path": path.as_posix(), "exists": path.is_dir()}
            for path in _python_dependency_paths()
        ],
    }
    try:
        _add_python_dependency_paths()
        import lupa
        lua = _lua_runtime()
        result["lua54Available"] = True
        result["luaVersion"] = lua.eval("_VERSION")
        result["lupaModuleFile"] = str(Path(lupa.__file__).resolve())
        result["lupaVersion"] = getattr(lupa, "__version__", None)
        result["luaModulePath"] = lua.eval("package.path")
        result["luaCPath"] = lua.eval("package.cpath")
        result["nativeSearchersRemoved"] = lua.eval("#package.searchers") == 2
    except Exception as error:
        result["lupaImportError"] = str(error)
    return result


def _b4_ready(groups: dict[str, dict[str, Any]]) -> bool:
    return groups["b4"]["readiness"] == "available"


def _refresh_b4_readiness(groups: dict[str, dict[str, Any]], report: dict[str, Any]) -> bool:
    """Re-read all B4 gates immediately before the first requested suite."""
    modules = _discover_b_modules(4)
    delivery_notes = _discover_b4_delivery_notes()
    source_status = _final_source_ready()
    ready = bool(modules and delivery_notes and source_status["ready"])
    b4 = groups["b4"]
    b4["readiness"] = "available" if ready else "not_ready"
    b4["modules"] = modules
    b4["deliveryNotes"] = delivery_notes
    b4["finalSourceReady"] = source_status
    report["b4Gate"]["ready"] = ready
    report["b4Gate"]["finalSourceReady"] = source_status
    report["b4Gate"]["reason"] = (
        "delivery note, B4 suite, final-source marker, and current hashes verified"
        if ready else
        "B4 gate changed or became unready before suite start; a nonempty delivery note, "
        "current-tree B4 suite, and matching ready source snapshot are all required"
    )
    return ready


def _capture_type():
    script = ROOT / "tests" / "render_sea_fusion.py"
    if not script.is_file():
        raise FileNotFoundError(f"existing NVGCapture recorder missing: {script}")
    spec = importlib.util.spec_from_file_location("circle1_ab_final_nvg_capture", script)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load the existing NVGCapture recorder")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    capture = getattr(module, "NVGCapture", None)
    if capture is None:
        raise RuntimeError("existing render recorder does not export NVGCapture")
    return capture


def _case_status(case: Any) -> str:
    if not isinstance(case, dict):
        return "not_tested"
    raw_status = str(case.get("status", "")).casefold()
    if case.get("skipped") is True or raw_status in {"skip", "skipped"}:
        return "skipped"
    if case.get("passed") is True or raw_status in {"pass", "passed", "ok"}:
        return "passed"
    if case.get("passed") is False or raw_status in {"fail", "failed", "error"}:
        return "failed"
    return "not_tested"


def _cases_from(report: Any) -> tuple[list[dict[str, Any]], bool]:
    """Return reported test rows and whether a test-row field was present."""
    if not isinstance(report, dict):
        return [], False
    for key in ("tests", "results", "checks"):
        if key not in report:
            continue
        rows = report[key]
        if isinstance(rows, list):
            return [row if isinstance(row, dict) else {"value": row}
                    for row in rows], True
        if isinstance(rows, dict):
            converted = []
            for name, row in rows.items():
                entry = dict(row) if isinstance(row, dict) else {"value": row}
                entry.setdefault("name", name)
                converted.append(entry)
            return converted, True
        return [], True
    return [], False


def _suite_from_report(module_name: str, group: str, report: Any,
                       recorder: Any | None = None) -> dict[str, Any]:
    converted = _lua_to_python(report)
    cases, row_field_present = _cases_from(converted)
    status_text = str(converted.get("status", "")).casefold() if isinstance(converted, dict) else ""
    if status_text in {"pass", "passed", "ok"}:
        for case in cases:
            if isinstance(case.get("value"), str) and set(case) == {"value"}:
                case["name"] = case.pop("value")
                case["passed"] = True
                case["evidence"] = "Assertion suite returned aggregate PASS with named checks."
    if status_text in {"skip", "skipped"}:
        status = "skipped"
    elif status_text in {"fail", "failed", "error"}:
        status = "failed"
    elif cases:
        statuses = [_case_status(case) for case in cases]
        if "failed" in statuses:
            status = "failed"
        elif "not_tested" in statuses:
            status = "not_tested"
        elif "skipped" in statuses:
            status = "skipped"
        else:
            status = "passed"
    elif row_field_present:
        status = "not_tested"
    elif isinstance(converted, dict) and converted.get("passed") is True:
        status = "passed"
    elif isinstance(converted, dict) and converted.get("passed") is False:
        status = "failed"
    elif converted is False:
        status = "failed"
    else:
        status = "not_tested"

    row: dict[str, Any] = {
        "group": group,
        "module": module_name,
        "status": status,
        "cases": cases,
        "reportedCaseCount": len(cases),
        "report": converted,
    }
    if not cases and not row_field_present and status == "passed":
        row["evidence"] = "Run() returned without an exception; suite exposes no case rows."
    if recorder is not None:
        row["nvgCalls"] = dict(sorted(recorder.counts.items()))
        row["nvgCallTotal"] = sum(recorder.counts.values())
        row["capturedElements"] = len(recorder.elements)
    return row


def _run_module(module_name: str, group: str, use_recorder: bool = False) -> dict[str, Any]:
    source_path = _module_file(module_name)
    if not source_path.is_file():
        return {"group": group, "module": module_name, "status": "not_ready",
                "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                "error": f"current scripts module missing: {source_path.relative_to(ROOT).as_posix()}"}
    if not _is_under(source_path, SCRIPTS):
        return {"group": group, "module": module_name, "status": "load_error",
                "sourceFile": source_path.as_posix(),
                "error": "module resolved outside the current scripts/ tree"}
    try:
        lua = _lua_runtime()
    except Exception as error:
        return {"group": group, "module": module_name, "status": "load_error",
                "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                "phase": "lua_runtime_init", "error": str(error)}

    log: list[str] = []
    lua.globals().print = lambda *values: log.append(" ".join(map(str, values))[:2000])
    if group == "players":
        try:
            assertion_count = lua.execute(source_path.read_text(encoding="utf-8-sig"))
            if assertion_count is None:
                summaries = [re.fullmatch(
                    r"(?:GAME_LOOP_SPEC_PASS|GAME_LOOP_UI_MOCK_PASS|PERSISTENCE_REGRESSION_PASS|NUMERIC_ECONOMY_SPEC_PASS|SHOP_STOCK_SPEC_PASS)\s+(\d+)", line)
                    for line in log]
                reported_counts = [int(match.group(1)) for match in summaries if match]
                if len(reported_counts) == 1:
                    assertion_count = reported_counts[0]
            passed = (isinstance(assertion_count, (int, float))
                      and not isinstance(assertion_count, bool) and assertion_count > 0)
            return {"group": group, "module": module_name,
                    "status": "passed" if passed else "not_tested",
                    "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                    "reportedAssertionCount": assertion_count, "cases": [],
                    "log": log, "evidence": "Standalone player script executed with assertions."}
        except Exception as error:
            return {"group": group, "module": module_name, "status": "failed",
                    "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                    "phase": "standalone_script", "error": str(error), "log": log}
    try:
        # Lua 5.4 require also returns loader data; parentheses retain only module.
        module = lua.eval("function(name) return (require(name)) end")(module_name)
    except Exception as error:
        return {"group": group, "module": module_name, "status": "load_error",
                "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                "phase": "require", "error": str(error)}
    try:
        run = module["Run"]
    except Exception:
        run = None
    if not callable(run):
        return {"group": group, "module": module_name, "status": "load_error",
                "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                "phase": "suite_contract", "error": "module has no callable Run()"}

    recorder = None
    recorder_table = None
    if use_recorder:
        try:
            NVGCapture = _capture_type()
            recorder = NVGCapture()
            recorder_table = recorder.bind(lua)
            lua.globals().__nvgRecorder = recorder_table
            lua.globals().__nvgContext = lua.table()
        except Exception as error:
            return {"group": group, "module": module_name, "status": "load_error",
                    "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                    "phase": "recorder_setup", "error": str(error),
                    "traceback": traceback.format_exc(limit=5)}
    try:
        if use_recorder:
            report = run(recorder_table)
        else:
            report = run()
    except Exception as error:
        return {"group": group, "module": module_name, "status": "failed",
                "sourceFile": source_path.resolve().relative_to(ROOT).as_posix(),
                "phase": "run", "error": str(error),
                "traceback": traceback.format_exc(limit=5)}
    suite_result = _suite_from_report(module_name, group, report, recorder)
    suite_result["sourceFile"] = source_path.resolve().relative_to(ROOT).as_posix()
    suite_result["log"] = log
    return suite_result


def _stage_modules(stage: str, groups: dict[str, dict[str, Any]]) -> list[tuple[str, bool]]:
    if stage == "a1":
        return [(name, False) for name in A1_MODULES]
    if stage == "a2":
        return ([(name, False) for name in A2_MODULES]
                + [(name, True) for name in A2_RECORDER_MODULES])
    if stage == "a3":
        return [(name, name == "tests.Circle1A3RecognitionTests") for name in A3_MODULES]
    if stage == "legacy":
        return [(name, False) for name in LEGACY_MODULES]
    if stage == "players":
        return [(name, False) for name in PLAYER_MODULES]
    if stage == "merge":
        return [(name, False) for name in MERGE_MODULES]
    if stage in {"b1", "b2", "b3", "b4"}:
        return [(row["module"], False) for row in groups[stage]["modules"]]
    raise ValueError(f"unsupported test stage: {stage}")


def _requested_test_stages(stages: list[str]) -> list[str]:
    if "all" in stages:
        return ["a1", "a2", "a3", "legacy", "b1", "b2", "b3", "b4", "players", "merge"]
    return [stage for stage in stages if stage != "readiness"]


def _counts(suites: list[dict[str, Any]]) -> dict[str, int]:
    statuses = ("passed", "failed", "skipped", "load_error", "not_ready", "not_tested")
    return {status: sum(1 for suite in suites if suite.get("status") == status)
            for status in statuses}


def _timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def _write_report(prefix: str, report: dict[str, Any]) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / f"{prefix}-{_timestamp()}.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return target


def _base_report(groups: dict[str, dict[str, Any]], host: dict[str, Any]) -> dict[str, Any]:
    return {
        "createdAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "workspace": ROOT.as_posix(),
        "sourcePolicy": {
            "sourceRoot": SCRIPTS.as_posix(),
            "sourceOnlyCurrentTree": True,
            "luaPathRestrictedToCurrentScripts": True,
            "luaModuleSearchRoots": [
                (SCRIPTS / "?.lua").as_posix(),
                (SCRIPTS / "?/init.lua").as_posix(),
            ],
            "nativeLuaSearchersRemoved": host.get("nativeSearchersRemoved", False),
            "dualSourceSearcher": False,
            "externalDSourceFallback": False,
        },
        "host": host,
        "groups": groups,
        "nativeGuiPreviewVerified": False,
        "nativeFrameRateVerified": False,
        "realCloudSdkVerified": False,
    }


def _readiness_report() -> tuple[dict[str, Any], dict[str, dict[str, Any]], dict[str, Any]]:
    host = _host_readiness()
    groups = _group_inventory()
    report = _base_report(groups, host)
    report.update({
        "mode": "readiness",
        "executedStages": [],
        "suiteResults": [],
        "counts": _counts([]),
        "b4Gate": {
            "ready": _b4_ready(groups),
            "requiresNonemptyB4DeliveryNote": True,
            "requiresCurrentScriptsB4Tests": True,
            "requiresRootFinalSourceReadyMarker": True,
            "reason": ("delivery note, B4 suite, final-source marker, and current hashes verified"
                       if _b4_ready(groups) else
                       "waiting for a nonempty B4 delivery note, B4 suite under current scripts, "
                       "and final-source-ready.json with status=ready plus matching source hashes"),
        },
        "aProtectionAudit": _a_protection_audit(),
        "testExecutionStarted": False,
        "ready": bool(host.get("lua54Available") and host.get("nativeSearchersRemoved")),
    })
    return report, groups, host


def _self_check() -> tuple[dict[str, Any], int]:
    report, groups, host = _readiness_report()
    source_scope_ok = (_is_under(Path(__file__).resolve(), MERGE)
                       and SCRIPTS == (ROOT / "scripts").resolve()
                       and OUT == (MERGE / "final-checks").resolve())
    report["selfCheck"] = {
        "runnerCompiles": True,
        "runnerUnderAllowedMergeFolder": _is_under(Path(__file__).resolve(), MERGE),
        "outputDirectoryIsFinalChecksOnly": OUT == (MERGE / "final-checks").resolve(),
        "sourceScopeIsCurrentScriptsOnly": source_scope_ok,
        "lua54HostReady": host.get("lua54Available", False),
        "nativeSearchersRemoved": host.get("nativeSearchersRemoved", False),
        "b4Ready": _b4_ready(groups),
        "finalSourceReadyMarkerReadOnly": True,
        "suiteRunFunctionsCalled": False,
    }
    checks = report["selfCheck"]
    passed = all(checks[key] for key in (
        "runnerCompiles", "runnerUnderAllowedMergeFolder",
        "outputDirectoryIsFinalChecksOnly", "sourceScopeIsCurrentScriptsOnly",
        "lua54HostReady", "nativeSearchersRemoved", "finalSourceReadyMarkerReadOnly"))
    passed = passed and not checks["suiteRunFunctionsCalled"]
    report["selfCheck"]["passed"] = passed
    SELF_CHECK_FILE.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                               encoding="utf-8")
    print(json.dumps({"selfCheckPassed": passed,
                      "luaVersion": host.get("luaVersion"),
                      "b4Ready": checks["b4Ready"],
                      "output": SELF_CHECK_FILE.as_posix()}, ensure_ascii=False))
    return report, (0 if passed else 1)


def _run(stages: list[str], force_b4: bool) -> int:
    report, groups, host = _readiness_report()
    if stages == ["readiness"]:
        target = _write_report("readiness", report)
        print(json.dumps({"ready": report["ready"], "b4Ready": report["b4Gate"]["ready"],
                          "testExecutionStarted": False, "output": target.as_posix()},
                         ensure_ascii=False))
        return 0 if report["ready"] else 2

    if "readiness" in stages:
        report["stageRejection"] = "readiness cannot be combined with test stages"
        target = _write_report("rejected", report)
        print(json.dumps({"accepted": False, "reason": report["stageRejection"],
                          "output": target.as_posix()}, ensure_ascii=False))
        return 2
    if "b4" in stages and not force_b4 and "all" not in stages:
        report["stageRejection"] = ("explicit B4 stage requires --force-b4; this flag never bypasses "
                                     "delivery, test, or final-source gates")
        report["requestedStages"] = stages
        target = _write_report("rejected", report)
        print(json.dumps({"accepted": False, "b4Ready": report["b4Gate"]["ready"],
                          "reason": report["stageRejection"], "output": target.as_posix()},
                         ensure_ascii=False))
        return 2
    if force_b4 and ("b4" not in stages or "all" in stages):
        report["stageRejection"] = "--force-b4 is only valid with the explicit --stage b4 request"
        report["requestedStages"] = stages
        target = _write_report("rejected", report)
        print(json.dumps({"accepted": False, "reason": report["stageRejection"],
                          "output": target.as_posix()}, ensure_ascii=False))
        return 2

    if ("all" in stages or "b4" in stages) and not _b4_ready(groups):
        report["mode"] = "rejected_not_ready"
        report["requestedStages"] = stages
        report["stageRejection"] = ("B4 requires a nonempty delivery note, a test module discovered under current scripts, "
                                     "and final-source-ready.json with status=ready plus matching source hashes")
        report["testExecutionStarted"] = False
        for stage in _requested_test_stages(stages):
            groups[stage]["execution"] = "not_tested"
        target = _write_report("not-ready", report)
        print(json.dumps({"accepted": False, "b4Ready": False,
                          "testExecutionStarted": False,
                          "reason": report["stageRejection"], "output": target.as_posix()},
                         ensure_ascii=False))
        return 2

    requested = _requested_test_stages(stages)
    source_snapshot_before = _scripts_lua_snapshot()
    if ("all" in stages or "b4" in stages) and not _refresh_b4_readiness(groups, report):
        report["mode"] = "rejected_not_ready"
        report["requestedStages"] = requested
        report["stageRejection"] = (
            "B4 final-source readiness must still be true immediately before the first suite; "
            "no suite was started"
        )
        report["testExecutionStarted"] = False
        report["suiteResults"] = []
        report["counts"] = _counts([])
        for stage in requested:
            groups[stage]["execution"] = "not_tested"
        target = _write_report("not-ready", report)
        print(json.dumps({"accepted": False, "b4Ready": False,
                          "testExecutionStarted": False,
                          "reason": report["stageRejection"], "output": target.as_posix()},
                         ensure_ascii=False))
        return 2
    suite_results: list[dict[str, Any]] = []
    for stage in requested:
        group = groups[stage]
        modules = _stage_modules(stage, groups)
        if not modules:
            result = {"group": stage, "module": None, "status": "not_ready",
                      "error": "no B-specific test modules discovered in the current scripts tree"}
            suite_results.append(result)
            group["execution"] = "not_ready"
            continue
        group_results = [_run_module(module, stage, use_recorder)
                         for module, use_recorder in modules]
        suite_results.extend(group_results)
        statuses = {item["status"] for item in group_results}
        group["execution"] = ("passed" if statuses == {"passed"} else
                               "failed" if "failed" in statuses else
                               "load_error" if "load_error" in statuses else
                               "skipped" if "skipped" in statuses else
                               "not_tested" if "not_tested" in statuses else "not_ready")

    source_snapshot_after = _scripts_lua_snapshot()
    source_changes = _snapshot_changes(source_snapshot_before, source_snapshot_after)
    counts = _counts(suite_results)
    passed = (bool(suite_results)
              and all(item.get("status") == "passed" for item in suite_results)
              and not source_changes)
    report.update({
        "mode": "test_execution",
        "requestedStages": requested,
        "executedStages": requested,
        "suiteResults": suite_results,
        "counts": counts,
        "testExecutionStarted": True,
        "sourceHashSnapshotAtTestStart": source_snapshot_before,
        "sourceChangedDuringRun": bool(source_changes),
        "sourceChangesDuringRun": source_changes,
        "passed": passed,
        "exitCode": 0 if passed else 1,
    })
    target = _write_report("run", report)
    print(json.dumps({"passed": passed, "counts": counts,
                      "failed": [{"group": row.get("group"), "module": row.get("module"),
                                  "status": row.get("status"), "error": row.get("error")}
                                 for row in suite_results if row.get("status") != "passed"],
                      "sourceChangedDuringRun": bool(source_changes),
                      "sourceChangesDuringRun": source_changes,
                      "nativeGuiPreviewVerified": False,
                      "nativeFrameRateVerified": False,
                      "realCloudSdkVerified": False,
                      "output": target.as_posix()}, ensure_ascii=False))
    return 0 if passed else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Readiness by default; selected tests use isolated Lua 5.4 runtimes and current scripts only.")
    parser.add_argument("--stage", choices=STAGES, action="extend", nargs="+", default=None,
                        help="readiness (default), a1, a2, a3, legacy, b1-b4, players, or all")
    parser.add_argument("--force-b4", action="store_true",
                        help="explicitly request B4; still requires its note, current-tree tests, and final-source hash gate")
    parser.add_argument("--self-check", action="store_true",
                        help="check runner/host/readiness only, write runner-selfcheck.json, never run suites")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.self_check:
        if args.stage or args.force_b4:
            parser.error("--self-check cannot be combined with test-stage options")
        _, code = _self_check()
        return code
    stages = args.stage or ["readiness"]
    stages = list(dict.fromkeys(stages))
    if len(stages) > 1 and "all" in stages:
        parser.error("all cannot be combined with other stages")
    if "readiness" in stages and len(stages) > 1:
        parser.error("readiness cannot be combined with test stages")
    if args.force_b4 and ("b4" not in stages or "all" in stages):
        parser.error("--force-b4 requires an explicit --stage b4 request and cannot accompany all")
    return _run(stages, args.force_b4)


if __name__ == "__main__":
    raise SystemExit(main())
