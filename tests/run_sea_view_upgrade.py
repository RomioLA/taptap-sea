"""Run the Sea view-upgrade pure-Lua regression suite and write append-only evidence."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import time
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "scripts"
OUTPUT_ROOT = ROOT / "outputs" / "sea-view-upgrade"
FALLBACK_LUPA_ROOT = Path(r"C:\codex\taptap-sea\.tmp\sea-test-deps")


def load_lua_runtime():
    candidates = [ROOT / ".tmp" / "sea-test-deps", FALLBACK_LUPA_ROOT]
    attempted = []
    for candidate in candidates:
        if not candidate.is_dir():
            continue
        if not any((candidate / "lupa").glob("lua54*")):
            continue
        attempted.append(str(candidate))
        sys.path.insert(0, str(candidate))
        try:
            from lupa.lua54 import LuaRuntime
            return LuaRuntime(unpack_returned_tuples=True)
        except ImportError:
            sys.path.remove(str(candidate))
            sys.modules.pop("lupa", None)
            for key in tuple(sys.modules):
                if key.startswith("lupa."):
                    sys.modules.pop(key, None)
    raise RuntimeError(
        "Lupa Lua 5.4 is unavailable; checked " +
        (", ".join(attempted) if attempted else "no dependency directory")
    )


def plain(value):
    if hasattr(value, "items"):
        pairs = list(value.items())
        if pairs and all(isinstance(key, int) for key, _ in pairs):
            return [plain(value[key]) for key in sorted(key for key, _ in pairs)]
        return {str(key): plain(item) for key, item in pairs}
    return value


def write_evidence(result):
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = OUTPUT_ROOT / f"validation-{stamp}-{time.time_ns()}"
    json_path = base.with_suffix(".json")
    markdown_path = base.with_suffix(".md")
    with json_path.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write("\n")

    test_rows = result.get("tests", [])
    syntax_rows = result.get("syntax", [])
    failures = [row for row in test_rows if not row.get("passed")]
    syntax_failures = [row for row in syntax_rows if not row.get("passed")]
    lines = [
        "# Sea view-upgrade validation",
        "",
        f"- Result: **{result.get('status', 'UNKNOWN')}**",
        f"- Lua runtime: {result.get('luaVersion', 'unavailable')}",
        f"- Lua syntax files: {len(syntax_rows)}",
        f"- Logic checks: {len(test_rows)}",
        "- Native engine and visual acceptance: **NOT RUN**",
        "- NanoVG mock visual acceptance: **not claimed**",
        "",
    ]
    if failures or syntax_failures:
        lines.extend(["## Failures", ""])
        for row in syntax_failures:
            lines.append(f"- Lua syntax {row.get('file')}: {row.get('error')}")
        for row in failures:
            lines.append(f"- {row.get('name')}: {row.get('error')}")
        lines.append("")
    lines.extend(["## Checks", ""])
    for row in test_rows:
        mark = "PASS" if row.get("passed") else "FAIL"
        lines.append(f"- {mark}: {row.get('name')}")
    lines.append("")
    lines.append(f"JSON evidence: {json_path.name}")
    with markdown_path.open("x", encoding="utf-8") as output:
        output.write("\n".join(lines) + "\n")
    print(json.dumps({
        "status": result.get("status"),
        "luaVersion": result.get("luaVersion"),
        "syntaxCount": len(syntax_rows),
        "logicCheckCount": len(test_rows),
        "failureCount": len(failures) + len(syntax_failures),
        "json": str(json_path),
        "markdown": str(markdown_path),
    }, ensure_ascii=False))


def main():
    result = {
        "suite": "SeaViewUpgradeTests",
        "sourceRoot": str(SCRIPT_ROOT),
        "status": "BLOCKED_ENVIRONMENT",
        "luaVersion": None,
        "syntax": [],
        "tests": [],
        "nativeEngineVisualAcceptance": "NOT_RUN",
        "nvgMockVisualAcceptance": False,
    }
    try:
        lua = load_lua_runtime()
        result["luaVersion"] = lua.eval("_VERSION")
        lua.globals().package.path = (
            SCRIPT_ROOT.as_posix() + "/?.lua;" +
            SCRIPT_ROOT.as_posix() + "/?/init.lua;" +
            lua.globals().package.path
        )
        compile_lua = lua.eval(
            "function(source, name) local chunk, err = load(source, name); "
            "return chunk ~= nil, err end"
        )
        for path in sorted(SCRIPT_ROOT.rglob("*.lua")):
            ok, error = compile_lua(
                path.read_text(encoding="utf-8-sig"),
                "@" + path.as_posix(),
            )
            result["syntax"].append({
                "file": path.relative_to(SCRIPT_ROOT).as_posix(),
                "passed": bool(ok),
                "error": error,
            })

        report = lua.eval('require("tests.SeaViewUpgradeTests").Run')()
        result["tests"] = plain(report["results"])
        result["metrics"] = plain(report["metrics"])
        result["evidence"] = plain(report["evidence"])
        result["testSuiteStatus"] = report["status"]
        result["sourceHashes"] = {
            path.relative_to(SCRIPT_ROOT).as_posix():
                hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(SCRIPT_ROOT.rglob("*.lua"))
        }
        result["status"] = (
            "PASS"
            if all(row["passed"] for row in result["syntax"])
            and all(row["passed"] for row in result["tests"])
            and report["passed"]
            else "FAIL"
        )
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        result["status"] = "BLOCKED_ENVIRONMENT" if result["luaVersion"] is None else "FAIL"

    write_evidence(result)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
