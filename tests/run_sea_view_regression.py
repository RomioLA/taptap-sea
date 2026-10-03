"""Run every scripts/tests/*Tests.lua suite in a fresh Lua 5.4 state.

SeaFusionRenderTests uses the existing NVGCapture as a recorder only. This
runner deliberately does not invoke the PNG export path in render_sea_fusion.py.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time
import traceback
sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "scripts"
TEST_ROOT = SCRIPT_ROOT / "tests"
OUTPUT_ROOT = ROOT / "outputs" / "sea-view-upgrade"
FALLBACK_LUPA_ROOT = Path(r"C:\codex\taptap-sea\.tmp\sea-test-deps")


def load_lua_runtime_type():
    candidates = [ROOT / ".tmp" / "sea-test-deps", FALLBACK_LUPA_ROOT]
    attempted = []
    for candidate in candidates:
        if not candidate.is_dir() or not any((candidate / "lupa").glob("lua54*")):
            continue
        attempted.append(str(candidate))
        sys.path.insert(0, str(candidate))
        try:
            from lupa.lua54 import LuaRuntime
            return LuaRuntime, str(candidate)
        except ImportError:
            sys.path.remove(str(candidate))
            sys.modules.pop("lupa", None)
            for key in tuple(sys.modules):
                if key.startswith("lupa."):
                    sys.modules.pop(key, None)
    raise RuntimeError(
        "Lupa Lua 5.4 is unavailable; checked "
        + (", ".join(attempted) if attempted else "no dependency directory")
    )


def load_recorder_type():
    source = ROOT / "tests" / "render_sea_fusion.py"
    spec = importlib.util.spec_from_file_location("sea_fusion_recorder", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not import recorder module from {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.NVGCapture


def plain(value):
    if hasattr(value, "items"):
        pairs = list(value.items())
        if pairs and all(isinstance(key, int) for key, _ in pairs):
            return [plain(value[key]) for key in sorted(key for key, _ in pairs)]
        return {str(key): plain(item) for key, item in pairs}
    return value


def bind_transform(lua, recorder):
    def transform(ctx, a, b, c, d, e, f):
        matrix = tuple(float(value) for value in (a, b, c, d, e, f))
        recorder._call("nvgTransform", ctx, *matrix)
        recorder._multiply(matrix)

    lua.globals().nvgTransform = transform


def make_lua(LuaRuntime):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (
        SCRIPT_ROOT.as_posix() + "/?.lua;"
        + SCRIPT_ROOT.as_posix() + "/?/init.lua;"
        + lua.globals().package.path
    )
    return lua


def run_syntax_checks(LuaRuntime, files):
    lua = make_lua(LuaRuntime)
    compile_lua = lua.eval(
        "function(source, name) local chunk, err = load(source, name); "
        "return chunk ~= nil, err end"
    )
    rows = []
    for path in files:
        try:
            ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
            rows.append({"file": path.relative_to(SCRIPT_ROOT).as_posix(),
                         "passed": bool(ok), "error": None if ok else str(error)})
        except Exception as error:
            rows.append({"file": path.relative_to(SCRIPT_ROOT).as_posix(),
                         "passed": False, "error": f"{type(error).__name__}: {error}"})
    return lua.eval("_VERSION"), rows


def summarize_report(report):
    if report is None:
        return {"passed": True, "checks": [], "reportKind": "no_return_assert_suite"}
    value = plain(report)
    if isinstance(value, bool):
        return {"passed": value, "checks": [], "reportKind": "boolean"}
    if not isinstance(value, dict):
        return {"passed": True, "checks": [], "reportKind": type(value).__name__}

    checks = value.get("results")
    if checks is None:
        checks = value.get("tests", [])
    if not isinstance(checks, list):
        checks = []
    rows = []
    for index, check in enumerate(checks, start=1):
        if isinstance(check, dict):
            rows.append({
                "name": str(check.get("name", f"check_{index}")),
                "passed": check.get("passed") is not False,
                "error": check.get("error") or None,
            })
        else:
            rows.append({"name": f"check_{index}", "passed": bool(check), "error": None})
    passed = all(row["passed"] for row in rows)
    if value.get("passed") is False or str(value.get("status", "")).upper() == "FAIL":
        passed = False
    if isinstance(value.get("passed"), (int, float)) and value.get("total"):
        passed = passed and value["passed"] == value["total"]
    return {
        "passed": passed,
        "checks": rows,
        "reportKind": "results" if rows else "table",
        "reportedStatus": value.get("status"),
        "reportedError": value.get("error"),
        "reportedPassed": value.get("passed"),
        "reportedTotal": value.get("total"),
    }


def run_one(LuaRuntime, Recorder, path):
    module_name = "tests." + path.stem
    lua = make_lua(LuaRuntime)
    lua_logs = []
    lua.globals().print = lambda *args: lua_logs.append(" ".join(str(arg) for arg in args))
    recorder_capture = Recorder()
    recorder = recorder_capture.bind(lua)
    bind_transform(lua, recorder_capture)
    run_module = lua.eval(
        "function(name, recorder) local module = require(name); "
        "return module.Run(recorder) end"
    )
    try:
        # This suite has a deliberate injectable Persistence argument rather
        # than a recorder argument. Keep its real module dependency intact.
        if path.stem == "Circle1B3CloudTests":
            report = lua.eval(
                'function(name) local module=require(name); '
                'return module.Run(require("Gameplay.Persistence")) end'
            )(module_name)
        else:
            report = run_module(module_name, recorder)
        summary = summarize_report(report)
        return {
            "suite": path.stem,
            "passed": summary["passed"],
            "checkCount": len(summary["checks"]),
            "checks": summary["checks"],
            "reportKind": summary["reportKind"],
            "reportedStatus": summary.get("reportedStatus"),
            "reportedError": summary.get("reportedError"),
            "reportedPassed": summary.get("reportedPassed"),
            "reportedTotal": summary.get("reportedTotal"),
            "luaPrintCount": len(lua_logs),
        }
    except Exception as error:
        return {
            "suite": path.stem,
            "passed": False,
            "checkCount": 0,
            "checks": [],
            "error": f"{type(error).__name__}: {error}",
            "traceback": traceback.format_exc(),
        }


def write_evidence(result):
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = OUTPUT_ROOT / f"validation-regression-{stamp}-{time.time_ns()}"
    json_path = base.with_suffix(".json")
    markdown_path = base.with_suffix(".md")
    with json_path.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write("\n")

    failures = [suite for suite in result["suites"] if not suite["passed"]]
    syntax_failures = [row for row in result["syntax"] if not row["passed"]]
    lines = [
        "# Sea view-upgrade regression",
        "",
        f"- Result: **{result['status']}**",
        f"- Lua runtime: {result.get('luaVersion') or 'unavailable'}",
        f"- Isolated test suites: {len(result['suites'])}",
        f"- Lua syntax files: {len(result['syntax'])}",
        "- NVGCapture use: recording only; no PNG was exported",
        "- Native Maker engine and visual acceptance: **NOT RUN**",
        "",
    ]
    if failures or syntax_failures:
        lines.extend(["## Failures", ""])
        for row in syntax_failures:
            lines.append(f"- Lua syntax {row['file']}: {row.get('error')}")
        for suite in failures:
            if suite.get("error"):
                lines.append(f"- {suite['suite']}: {suite['error']}")
            elif suite.get("reportedError"):
                lines.append(f"- {suite['suite']}: {suite['reportedError']}")
            elif suite.get("reportedStatus"):
                lines.append(f"- {suite['suite']}: reported status {suite['reportedStatus']}")
            for check in suite["checks"]:
                if not check["passed"]:
                    lines.append(f"- {suite['suite']} / {check['name']}: {check.get('error')}")
        lines.append("")
    lines.extend(["## Suites", ""])
    for suite in result["suites"]:
        mark = "PASS" if suite["passed"] else "FAIL"
        lines.append(f"- {mark}: {suite['suite']} ({suite['checkCount']} checks)")
        if not suite["passed"] and suite.get("reportedStatus"):
            lines.append(f"  - reported status: {suite['reportedStatus']}")
        if not suite["passed"] and suite.get("reportedError"):
            lines.append(f"  - reported error: {suite['reportedError']}")
        for check in suite["checks"]:
            if not check["passed"]:
                lines.append(f"  - {check['name']}: {check.get('error')}")
    lines.extend(["", f"JSON evidence: {json_path.name}", ""])
    with markdown_path.open("x", encoding="utf-8") as output:
        output.write("\n".join(lines))
    print(json.dumps({
        "status": result["status"],
        "luaVersion": result.get("luaVersion"),
        "suiteCount": len(result["suites"]),
        "passedSuites": sum(suite["passed"] for suite in result["suites"]),
        "failedSuites": [suite["suite"] for suite in failures],
        "syntaxCount": len(result["syntax"]),
        "syntaxFailures": len(syntax_failures),
        "json": str(json_path),
        "markdown": str(markdown_path),
    }, ensure_ascii=False))


def main():
    result = {
        "task": "isolated Lua regression across scripts/tests/*Tests.lua",
        "sourceRoot": str(SCRIPT_ROOT),
        "status": "BLOCKED_ENVIRONMENT",
        "luaVersion": None,
        "lupaDependencyRoot": None,
        "syntax": [],
        "suites": [],
        "nvgCapture": "record-only; no PNG export",
        "nativeEngineVisualAcceptance": "NOT_RUN",
        "nvgMockVisualAcceptance": False,
    }
    try:
        LuaRuntime, dependency_root = load_lua_runtime_type()
        Recorder = load_recorder_type()
        result["lupaDependencyRoot"] = dependency_root
        version, result["syntax"] = run_syntax_checks(LuaRuntime, sorted(SCRIPT_ROOT.rglob("*.lua")))
        result["luaVersion"] = version
        suites = sorted(TEST_ROOT.glob("*Tests.lua"))
        result["suites"] = [run_one(LuaRuntime, Recorder, path) for path in suites]
        syntax_passed = all(row["passed"] for row in result["syntax"])
        suites_passed = all(row["passed"] for row in result["suites"])
        result["status"] = "PASS" if syntax_passed and suites_passed else "FAIL"
        result["sourceHashes"] = {
            path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(suites)
        }
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        result["status"] = "BLOCKED_ENVIRONMENT" if result["luaVersion"] is None else "FAIL"
    write_evidence(result)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
