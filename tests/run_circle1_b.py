"""Circle 1 B: installed Lua 5.4, protocol doubles, isolated regression suites.

No engine, GUI, cloud, install, build, or public screenshot output is used.
"""
from pathlib import Path
import json
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/circle1-b"
sys.path.insert(0, str(ROOT / ".tmp/game-loop-test-runtime"))
from lupa.lua54 import LuaRuntime


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
        + (ROOT / "scripts/?/init.lua").as_posix() + ";" + lua.globals().package.path
    )
    lua.globals().print = lambda *args: log.append(" ".join(str(arg) for arg in args)[:2000])
    return lua


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    syntax_lua = runtime([])
    compile_lua = syntax_lua.eval("function(s,n) local f,e=load(s,n);return f~=nil,e end")
    syntax = []
    for path in sorted((ROOT / "scripts").rglob("*.lua")):
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
        syntax.append({"file": path.relative_to(ROOT).as_posix(), "passed": bool(ok), "error": error})

    suites = []
    for module in ("Circle1BFishingFlowTests", "Circle1BPendingCatchTests",
                   "ABIntegrationTests", "ArchitectureIntegrationTests", "SeaFusedSceneTests"):
        log = []
        lua = runtime(log)
        suite = {"name": module, "kind": "protocol" if module.startswith("Circle1B") else "regression"}
        try:
            report = plain(lua.eval(f'require("Tests.{module}").Run()'))
            rows = report.get("results", report.get("checks", []))
            if isinstance(rows, dict):
                rows = list(rows.values())
            suite["tests"] = rows
            suite["report"] = report
            suite["passed"] = all(row.get("passed") for row in rows if not row.get("skipped"))
            suite["skippedCount"] = sum(bool(row.get("skipped")) for row in rows)
            if not rows:
                suite["passed"] = report.get("passed", False)
        except Exception as error:
            suite.update(passed=False, error=str(error), tests=[])
        suite["log"] = "\n".join(log)[:16000]
        suites.append(suite)

    for filename in ("GameLoopSpec.lua", "GameLoopUISpec.lua", "PersistenceRegressionSpec.lua",
                     "NumericEconomySpec.lua", "ShopStockSpec.lua"):
        log = []
        lua = runtime(log)
        suite = {"name": filename, "kind": "regression"}
        try:
            lua.execute((ROOT / "scripts/Tests" / filename).read_text(encoding="utf-8-sig"))
            suite["passed"] = True
        except Exception as error:
            suite.update(passed=False, error=str(error))
        suite["log"] = "\n".join(log)[:16000]
        suites.append(suite)

    # Preserve the existing audit: balance targets must never become runtime quotas.
    forbidden = ("dailyFishingLimit", "newGamePlusTunaBonus", "newGamePlusIncomeMultiplier",
                 "newGamePlusCatchRate", "eventPoolCount", "tunaChance", "eventReward")
    audit_failures = []
    for folder in ("Gameplay", "config", "data"):
        for path in (ROOT / "scripts" / folder).glob("*.lua"):
            source = path.read_text(encoding="utf-8-sig")
            for word in forbidden:
                if word in source:
                    audit_failures.append({"file": path.relative_to(ROOT).as_posix(), "word": word})

    failures = [row for suite in suites for row in suite.get("tests", [])
                if not row.get("passed") and not row.get("skipped")]
    failures += [{"suite": suite["name"], "error": suite.get("error", "suite failed")}
                 for suite in suites if not suite["passed"] and not suite.get("tests")]
    failures += [row for row in syntax if not row["passed"]] + audit_failures
    skipped = [{"suite": suite["name"], **row} for suite in suites
               for row in suite.get("tests", []) if row.get("skipped")]
    result = {"luaVersion": str(syntax_lua.eval("_VERSION")), "syntax": syntax, "suites": suites,
              "allExecutedPassed": not failures, "allRequestedVerified": not failures and not skipped,
              "unverifiedDependencyTests": skipped, "failures": failures,
              "guiVerified": False, "realOceanFishingVerified": False, "quotaAudit": audit_failures}
    path = OUT / "regression-result.json"
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"allExecutedPassed": result["allExecutedPassed"], "luaFiles": len(syntax),
                      "suites": [{"name": suite["name"], "passed": suite["passed"],
                                  "testCount": len(suite.get("tests", [])),
                                  "skippedCount": suite.get("skippedCount", 0)} for suite in suites],
                      "failureCount": len(failures), "unverifiedDependencyCount": len(skipped),
                      "failures": failures[:12], "report": str(path)}, ensure_ascii=False)[:6500])
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
