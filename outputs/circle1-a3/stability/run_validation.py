"""Run only A3 task-4/task-6 pure-Lua evidence without changing shared runners."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
MODULES = (
    "tests.Circle1A3StabilityTests",
    "tests.Circle1A3ExperienceTests",
)

spec = importlib.util.spec_from_file_location(
    "circle1_a2_readonly_helpers", ROOT / "tests" / "run_circle1_a2.py")
if spec is None or spec.loader is None:
    raise RuntimeError("could not load the existing Lua test helpers")
helpers = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helpers
spec.loader.exec_module(helpers)


def write(name: str, value: object) -> None:
    (OUT / name).write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_tests() -> dict[str, object]:
    checks = []
    for module in MODULES:
        source = ROOT / "scripts" / (module.replace(".", "/") + ".lua")
        lua = helpers._lua(ROOT / "scripts")
        try:
            report = lua.eval("require(...).Run()", module)
            rows = helpers._result_rows(report)
            checks.append({
                "module": module,
                "passed": bool(rows) and all(row.get("passed", False) for row in rows),
                "results": rows,
                "metrics": helpers._lua_value(report["metrics"]),
            })
        except Exception as error:
            checks.append({"module": module, "passed": False, "error": str(error)})
    result = {
        "checks": checks,
        "passed": len(checks) == len(MODULES) and all(row["passed"] for row in checks),
        "verificationKind": "pure-Lua/Lupa runtime; no native player or engine UI",
    }
    write("results.json", result)
    return result


def syntax_check() -> dict[str, object]:
    lua = helpers._lua(ROOT / "scripts")
    compile_lua = lua.eval("function(source,name) local f,e=load(source,name); return f~=nil,e end")
    checks = []
    for module in MODULES:
        path = ROOT / "scripts" / (module.replace(".", "/") + ".lua")
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
        checks.append({"file": path.relative_to(ROOT).as_posix(), "passed": bool(ok), "error": error})
    result = {"luaVersion": lua.eval("_VERSION"), "files": checks,
              "passed": all(row["passed"] for row in checks)}
    write("syntax.json", result)
    return result


if __name__ == "__main__":
    syntax = syntax_check()
    tests = run_tests()
    report = {"syntax": syntax, "tests": tests,
              "passed": syntax["passed"] and tests["passed"],
              "nativeGameplayMeasured": False}
    write("validation.json", report)
    print(json.dumps({"passed": report["passed"], "modules": [
        {"module": row["module"], "passed": row["passed"]} for row in tests["checks"]]},
        ensure_ascii=False))
    sys.exit(0 if report["passed"] else 1)
