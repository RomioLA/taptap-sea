"""Run fixed-world-content regressions with isolated Lua 5.4 runtimes."""
from argparse import ArgumentParser
import json
import os
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def plain(value):
    if hasattr(value, "items"):
        pairs = list(value.items())
        if pairs and all(isinstance(key, int) for key, _ in pairs):
            return [plain(value[key]) for key in sorted(key for key, _ in pairs)]
        return {str(key): plain(item) for key, item in pairs}
    return value


def make_runtime(LuaRuntime):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (
        (ROOT / "scripts/?.lua").as_posix() + ";"
        + (ROOT / "scripts/?/init.lua").as_posix() + ";"
        + lua.globals().package.path
    )
    log = []
    lua.globals().print = lambda *args: log.append(" ".join(str(arg) for arg in args)[:2000])
    return lua, log


def run_module(name, LuaRuntime):
    lua, log = make_runtime(LuaRuntime)
    try:
        report = plain(lua.eval(f'require("{name}").Run()'))
        if not isinstance(report, dict):
            raise TypeError("suite did not return a result table")
        rows = report.get("results", report.get("checks", []))
        if isinstance(rows, dict):
            rows = list(rows.values())
        skipped = [row for row in rows if row.get("skipped")]
        failures = [
            {"name": row.get("name", "unnamed"), "error": row.get("error", "failed")}
            for row in rows if not row.get("passed") and not row.get("skipped")
        ]
        passed = not failures and (bool(rows) or report.get("passed") is True)
        return {
            "name": name,
            "passed": passed,
            "testCount": int(report.get("total", len(rows))),
            "skippedCount": len(skipped),
            "tests": rows,
            "failures": failures,
            "error": "",
            "log": "\n".join(log)[:4000],
        }
    except Exception as error:
        return {
            "name": name, "passed": False, "testCount": 0, "skippedCount": 0,
            "failures": [], "error": str(error)[:3000], "log": "\n".join(log)[:4000],
        }


def run_script(filename, LuaRuntime):
    lua, log = make_runtime(LuaRuntime)
    path = ROOT / "scripts/tests" / filename
    try:
        lua.execute(path.read_text(encoding="utf-8-sig"))
        output = "\n".join(log)
        match = re.search(r"PERSISTENCE_REGRESSION_PASS\s+(\d+)", output)
        if not match:
            raise AssertionError("persistence regression completion marker missing")
        return {
            "name": filename,
            "passed": True,
            "testCount": int(match.group(1)),
            "skippedCount": 0,
            "tests": [{"name": "spec-completed", "passed": True, "assertionCount": int(match.group(1))}],
            "failures": [],
            "error": "",
            "log": output[:4000],
        }
    except Exception as error:
        return {
            "name": filename, "passed": False, "testCount": 0, "skippedCount": 0,
            "failures": [], "error": str(error)[:3000], "log": "\n".join(log)[:4000],
        }


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lupa-root",
        type=Path,
        default=None,
        help="directory containing the compatible lupa.lua54 package",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="full JSON result path (default: outputs/world-content/results.json)",
    )
    args = parser.parse_args()
    lupa_root = args.lupa_root or os.environ.get("TAPTAP_SEA_LUPA_ROOT")
    if lupa_root is None:
        lupa_root = ROOT / ".tmp/game-loop-test-runtime"
    lupa_root = Path(lupa_root).resolve()
    sys.path.insert(0, str(lupa_root))
    try:
        from lupa.lua54 import LuaRuntime
    except Exception as error:
        print(json.dumps({
            "passed": False,
            "error": f"cannot import Lua 5.4 runtime from {lupa_root}: {error}",
        }, ensure_ascii=False))
        return 2

    # Circle1B2 UI tests use an in-memory widget double; no engine or live UI is started.
    modules = (
        "tests.WorldContentTests",
        "tests.Circle1B2BarrelTests",
        "tests.Circle1B2ProgressTests",
        "tests.Circle1B2ScopeTests",
        "tests.Circle1B2ThrowTests",
        "tests.Circle1B2UITests",
        "tests.Circle1B3SpatialTests",
        "tests.Circle1BFishingFlowTests",
        "tests.Circle1BPendingCatchTests",
        "tests.Circle1B3SevenDaysTests",
    )
    suites = [run_module(name, LuaRuntime) for name in modules]
    suites.append(run_script("PersistenceRegressionSpec.lua", LuaRuntime))
    failures = [
        {"suite": suite["name"], "name": item["name"], "error": item["error"]}
        for suite in suites for item in suite["failures"]
    ]
    failures.extend(
        {"suite": suite["name"], "error": suite["error"]}
        for suite in suites if suite["error"]
    )
    skipped = sum(suite["skippedCount"] for suite in suites)
    result = {
        "luaVersion": "Lua 5.4",
        "lupaRoot": str(lupa_root),
        "passed": not failures and skipped == 0,
        "allRequestedVerified": not failures and skipped == 0,
        "suiteCount": len(suites),
        "testCount": sum(suite["testCount"] for suite in suites),
        "skippedCount": skipped,
        "suites": suites,
        "failures": failures[:30],
        "guiStarted": False,
    }
    output_path = args.output or ROOT / "outputs/world-content/results.json"
    if not output_path.is_absolute():
        output_path = ROOT / output_path
    output_path = output_path.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    summary = {
        "passed": result["passed"],
        "allRequestedVerified": result["allRequestedVerified"],
        "suiteCount": result["suiteCount"],
        "testCount": result["testCount"],
        "skippedCount": result["skippedCount"],
        "suites": [
            {"name": suite["name"], "passed": suite["passed"],
             "testCount": suite["testCount"], "failureCount": len(suite["failures"]),
             "error": suite["error"]}
            for suite in suites
        ],
        "failures": failures[:12],
        "report": str(output_path),
        "guiStarted": False,
    }
    print(json.dumps(summary, ensure_ascii=False, separators=(",", ":"))[:6000])
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
