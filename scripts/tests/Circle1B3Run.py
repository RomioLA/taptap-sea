"""Circle 1 B3 staged Lua verification with one Lua runtime per suite.

This is a local, headless protocol simulation. It does not launch the Maker
engine, a GUI, cloud services, or a remote build.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "outputs/circle1-b3"
sys.path.insert(0, str(ROOT / ".tmp/game-loop-test-runtime"))
from lupa.lua54 import LuaRuntime  # noqa: E402


def plain(value):
    if hasattr(value, "items"):
        pairs = list(value.items())
        if pairs and all(isinstance(key, int) for key, _ in pairs):
            return [plain(value[key]) for key in sorted(key for key, _ in pairs)]
        return {str(key): plain(item) for key, item in pairs}
    return value


def runtime(log):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (
        (ROOT / "scripts/?.lua").as_posix() + ";"
        + (ROOT / "scripts/?/init.lua").as_posix() + ";"
        + lua.globals().package.path
    )
    lua.globals().print = lambda *args: log.append(" ".join(str(arg) for arg in args)[:2000])
    return lua


def rows_from(report):
    rows = report.get("results", report.get("checks", []))
    if isinstance(rows, dict):
        rows = list(rows.values())
    return rows if isinstance(rows, list) else []


def run_module(module, group):
    started_at = time.perf_counter()
    log = []
    suite = {"group": group, "name": module, "kind": "protocol"}
    try:
        lua = runtime(log)
        report = plain(lua.eval(f'require("Tests.{module}").Run()'))
        rows = rows_from(report) if isinstance(report, dict) else []
        skipped = [row for row in rows if row.get("skipped")]
        failures = [row for row in rows if not row.get("passed") and not row.get("skipped")]
        suite.update(report=report, tests=rows, skippedCount=len(skipped),
                     failureCount=len(failures), passed=not failures and not skipped)
        if not rows:
            suite["passed"] = bool(report.get("passed", False)) if isinstance(report, dict) else bool(report)
    except Exception as error:  # A suite load/Run error is a real failure.
        suite.update(passed=False, error=f"{type(error).__name__}: {error}", tests=[],
                     skippedCount=0, failureCount=1)
    suite["log"] = "\n".join(log)[:12000]
    suite["elapsedSeconds"] = round(time.perf_counter() - started_at, 6)
    return suite


def run_script(filename, group):
    path = ROOT / "scripts/Tests" / filename
    log = []
    suite = {"group": group, "name": filename, "kind": "existing-regression"}
    try:
        lua = runtime(log)
        lua.execute(path.read_text(encoding="utf-8-sig"))
        suite.update(passed=True, skippedCount=0, failureCount=0)
    except Exception as error:
        suite.update(passed=False, error=f"{type(error).__name__}: {error}",
                     skippedCount=0, failureCount=1)
    suite["log"] = "\n".join(log)[:12000]
    return suite


def run_syntax():
    lua = runtime([])
    compile_lua = lua.eval("function(s,n) local f,e=load(s,n); return f~=nil,e end")
    records = []
    for path in sorted((ROOT / "scripts").rglob("*.lua")):
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
        records.append({"file": path.relative_to(ROOT).as_posix(),
                        "passed": bool(ok), "error": error})
    return records


def protocol_modules():
    paths = sorted((ROOT / "scripts/Tests").glob("Circle1B[12]*Tests.lua"))
    modules = [path.stem for path in paths]
    for name in ("Circle1BFishingFlowTests", "Circle1BPendingCatchTests"):
        if name not in modules:
            modules.append(name)
    return modules


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=("syntax", "b3", "protocol", "player", "a", "all"),
                        default="all", help="run one phase or the complete B3 verification")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    phases = {"all": ("syntax", "b3", "protocol", "player", "a"),
              "syntax": ("syntax",), "b3": ("b3",),
              "protocol": ("protocol",), "player": ("player",), "a": ("a",)}[args.suite]
    syntax = run_syntax() if "syntax" in phases else []
    suites = []
    if "b3" in phases:
        b3_files = sorted((ROOT / "scripts/Tests").glob("Circle1B3*Tests.lua"))
        if not b3_files:
            suites.append({"group": "b3", "name": "B3 test discovery", "kind": "protocol",
                           "passed": False, "error": "no Circle1B3*Tests.lua suites found",
                           "tests": [], "skippedCount": 0, "failureCount": 1})
        else:
            suites.extend(run_module(path.stem, "b3") for path in b3_files)
    if "protocol" in phases:
        suites.extend(run_module(name, "prior-protocol") for name in protocol_modules())
    if "player" in phases:
        for filename in ("GameLoopSpec.lua", "GameLoopUISpec.lua", "PersistenceRegressionSpec.lua",
                         "NumericEconomySpec.lua", "ShopStockSpec.lua"):
            suites.append(run_script(filename, "player-regression"))
    if "a" in phases:
        # These established A regression files are executed as-is and reported
        # separately; skipped cases remain unverified rather than passing.
        for module in ("ABIntegrationTests", "ArchitectureIntegrationTests", "SeaFusedSceneTests"):
            suites.append(run_module(module, "existing-a-regression"))

    failures = []
    skipped = []
    for suite in suites:
        tests = suite.get("tests", [])
        failures.extend({"suite": suite["name"], **row} for row in tests
                        if not row.get("passed") and not row.get("skipped"))
        skipped.extend({"suite": suite["name"], **row} for row in tests if row.get("skipped"))
        if not suite["passed"] and not tests:
            failures.append({"suite": suite["name"], "error": suite.get("error", "suite failed")})
    failures.extend({"suite": row["file"], "error": row.get("error")}
                    for row in syntax if not row["passed"])
    result = {
        "runner": "Circle1B3Run",
        "selectedSuite": args.suite,
        "executedPhases": list(phases),
        "luaVersion": str(runtime([]).eval("_VERSION")),
        "syntax": syntax,
        "suites": suites,
        "allExecutedPassed": not failures,
        "allRequestedVerified": not failures and not skipped,
        "failures": failures,
        "unverifiedSkippedCases": skipped,
        "guiVerified": False,
        "realOceanRuntimeVerified": False,
        "realCloudVerified": False,
        "sevenDayRouteKind": "headless protocol simulation; ocean travel is a test double",
    }
    destination = OUT / "regression-result.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary = {
        "selectedSuite": args.suite,
        "allExecutedPassed": result["allExecutedPassed"],
        "allRequestedVerified": result["allRequestedVerified"],
        "syntaxFiles": len(syntax),
        "suites": [{"group": row["group"], "name": row["name"], "passed": row["passed"],
                    "skippedCount": row.get("skippedCount", 0),
                    "elapsedSeconds": row.get("elapsedSeconds")} for row in suites],
        "failureCount": len(failures),
        "unverifiedSkipCount": len(skipped),
        "failureSummary": [{"suite": row.get("suite"), "name": row.get("name"),
                            "error": str(row.get("error", ""))[:600]} for row in failures[:6]],
        "report": str(destination),
    }
    print(json.dumps(summary, ensure_ascii=False)[:3800])
    return 0 if not failures and not skipped else 1


if __name__ == "__main__":
    raise SystemExit(main())
