"""Run A/B integration acceptance on real Lua modules without the engine UI."""
from __future__ import annotations

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = ROOT / ".tmp" / "sea-test-deps"
sys.path.insert(0, str(DEPENDENCIES))

from lupa.lua54 import LuaRuntime  # noqa: E402  (dependency path is project-local)


def table_rows(value):
    return [dict(value[index]) for index in range(1, len(value) + 1)]


def main() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)
    scripts = (ROOT / "scripts").resolve()
    lua.globals().package.path = (
        str(scripts / "?.lua").replace("\\", "/")
        + ";"
        + str(scripts / "?/init.lua").replace("\\", "/")
        + ";"
        + lua.globals().package.path
    )

    compile_lua = lua.eval(
        "function(source, name) local fn, err = load(source, name); return fn ~= nil, err end"
    )
    syntax = []
    for path in sorted(scripts.rglob("*.lua")):
        ok, error = compile_lua(
            path.read_text(encoding="utf-8-sig"), "@" + path.relative_to(ROOT).as_posix()
        )
        syntax.append(
            {
                "file": path.relative_to(ROOT).as_posix(),
                "passed": bool(ok),
                "error": "" if ok else str(error),
            }
        )

    try:
        report = lua.eval('require("tests.ABIntegrationTests").Run')()
        tests = table_rows(report["results"])
        suite_error = ""
    except Exception as error:  # Keep syntax results and return a machine-readable failure.
        tests = [{"name": "ABIntegrationTests.Run", "passed": False, "error": str(error)}]
        suite_error = str(error)

    result = {
        "luaVersion": str(lua.eval("_VERSION")),
        "syntax": syntax,
        "tests": tests,
        "nativeRuntimeVerified": False,
        "suiteError": suite_error,
        "passed": all(entry["passed"] for entry in syntax)
        and all(entry["passed"] for entry in tests),
    }
    output = ROOT / "screenshots" / "ab-integration-tests.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "passed": result["passed"],
                "luaFiles": len(syntax),
                "testCount": len(tests),
                "failures": [entry for entry in tests if not entry["passed"]]
                + [entry for entry in syntax if not entry["passed"]],
                "output": str(output),
            },
            ensure_ascii=False,
        )
    )
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
