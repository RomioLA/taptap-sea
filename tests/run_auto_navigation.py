"""Run the isolated pure-Lua auto-navigation suite and preserve JSON evidence."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCY_DIRS = (
    ROOT / ".tmp" / "sea-test-deps",
    ROOT / ".tmp" / "circle1-review-runtime",
    ROOT / ".tmp" / "game-loop-test-runtime",
)
DEFAULT_OUTPUT = ROOT / ".tmp" / "auto-navigation-tests.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def rows_from_lua(value: Any) -> list[dict[str, Any]]:
    return [
        dict(value[index])
        for index in range(1, len(value) + 1)
    ]


def main() -> int:
    args = parse_args()
    output = args.output.resolve()
    result: dict[str, Any] = {
        "suite": "AutoNavigationTests",
        "project": str(ROOT),
        "tests": [],
        "passed": False,
    }

    for dependency_dir in reversed(DEPENDENCY_DIRS):
        if dependency_dir.is_dir() and str(dependency_dir) not in sys.path:
            sys.path.insert(0, str(dependency_dir))

    try:
        from lupa.lua54 import LuaRuntime  # type: ignore[import-not-found]

        lua = LuaRuntime(encoding="utf-8")
        scripts = (ROOT / "scripts").resolve().as_posix()
        project = ROOT.as_posix()
        lua.globals().package.path = (
            f"{scripts}/?.lua;{scripts}/?/init.lua;"
            f"{project}/?.lua;{project}/?/init.lua;"
            + lua.globals().package.path
        )
        report = lua.eval('require("tests.AutoNavigationTests").Run')()
        tests = rows_from_lua(report["results"])
        result.update(
            {
                "luaVersion": str(lua.eval("_VERSION")),
                "tests": tests,
                "testCount": len(tests),
                "passedCount": sum(1 for test in tests if test.get("passed") is True),
                "failures": [test for test in tests if test.get("passed") is not True],
                "passed": report["passed"] is True
                and all(test.get("passed") is True for test in tests),
            }
        )
    except Exception as error:
        result["setupError"] = f"{type(error).__name__}: {error}"
        result["failures"] = [
            {
                "name": "AutoNavigationTests.Run",
                "passed": False,
                "error": result["setupError"],
            }
        ]

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {
        "passed": result["passed"],
        "testCount": result.get("testCount", 0),
        "passedCount": result.get("passedCount", 0),
        "failures": [
            {
                "name": failure.get("name", "setup"),
                "error": str(failure.get("error", ""))[:400],
            }
            for failure in result.get("failures", [])
        ],
        "output": str(output),
    }
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())