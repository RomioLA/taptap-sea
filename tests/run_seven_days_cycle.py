"""Local seven-day/NG+ and sea-cycle regression, without Maker or cloud writes.

Reuses the project's isolated suites and NanoVG recorder. Reports go to this
task's output directory; existing reports and test dependencies are preserved.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/seven-days-cycle/final"
for dependency in (ROOT / ".tmp/game-loop-test-runtime", ROOT / "outputs/seven-days-cycle/deps"):
    sys.path.insert(0, str(dependency))


def load_runner(name, source):
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main():
    from lupa.lua54 import LuaRuntime

    sea = load_runner("cycle_sea_regression", ROOT / "tests/run_sea_view_regression.py")
    player = load_runner("cycle_player_regression", ROOT / "scripts/tests/Circle1B3Run.py")
    Recorder = sea.load_recorder_type()
    # Internal legacy suites still require Tests.*, while newer files use tests.*.
    # Normalize both names on case-sensitive hosts without filesystem changes.
    original_runtime = sea.make_lua

    def runtime(runtime_type):
        lua = original_runtime(runtime_type)
        lua.execute('''
            table.insert(package.searchers, 2, function(name)
                if name:sub(1, 6) ~= "Tests." then return nil end
                local path = package.searchpath("tests." .. name:sub(7), package.path)
                if path then return assert(loadfile(path)), path end
            end)
        ''')
        return lua

    sea.make_lua = runtime
    def player_runtime(log):
        lua = runtime(LuaRuntime)
        lua.globals().print = lambda *args: log.append(" ".join(str(arg) for arg in args))
        return lua

    player.runtime = player_runtime
    version, syntax = sea.run_syntax_checks(LuaRuntime, sorted((ROOT / "scripts").rglob("*.lua")))
    suites = [sea.run_one(LuaRuntime, Recorder, path)
              for path in sorted((ROOT / "scripts/tests").glob("*Tests.lua"))]
    specs = [player.run_script(filename, "player") for filename in (
        "GameLoopSpec.lua", "GameLoopUISpec.lua", "PersistenceRegressionSpec.lua",
        "NumericEconomySpec.lua", "ShopStockSpec.lua")]
    failed = [suite for suite in suites + specs if not suite["passed"]]
    result = {"luaVersion": version, "syntax": syntax, "suites": suites,
              "playerSpecs": specs, "failures": failed,
              "passed": not failed and all(row["passed"] for row in syntax),
              "nativePreviewVerified": False, "realCloudVerified": False}
    OUT.mkdir(parents=True, exist_ok=True)
    report = OUT / "regression.json"
    report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": result["passed"], "syntaxFiles": len(syntax),
                      "suites": len(suites), "playerSpecs": len(specs),
                      "checks": sum(suite["checkCount"] for suite in suites),
                      "failedSuites": [suite.get("suite", suite.get("name")) for suite in failed],
                      "report": str(report)}, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
