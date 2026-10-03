"""Circle 1 A: real Lua 5.4 regression, syntax, and installed EmmyLua diagnostics.

All evidence goes to outputs/circle1-a. No preview start or remote operation.
Run with an installed Python 3.12; the local Lua dependency is reused, not installed.
"""
from pathlib import Path
import hashlib
import json
import re
import sys
from collections import Counter
from time import perf_counter

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/circle1-a"
MODULES = (
    "tests.Circle1AFishLocksTests", "tests.Circle1APredationCooldownTests",
    "tests.SeaRuntimeTests", "tests.SurfaceRiseTests", "tests.SurfaceSignalsTests",
    "tests.SeaStabilityTests",
    # Read-only compatibility checks: these tests belong to B/shared integration.
    "tests.ArchitectureIntegrationTests", "tests.ABIntegrationTests", "tests.SeaFusedSceneTests",
)


def runtime():
    for path in (ROOT / ".tmp/sea-test-deps", ROOT / "outputs/remote-review-20261002/test-runtime"):
        sys.path.insert(0, str(path))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (ROOT / "scripts/?.lua").as_posix() + ";" + lua.globals().package.path
    return lua


def boundary():
    before = json.loads((OUT / "before.json").read_text(encoding="utf-8"))
    changed = [name for name, digest in before.items()
               if not (ROOT / name).is_file() or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
    allowed = {
        "scripts/Ocean/Fish.lua", "scripts/Ocean/SeaRuntime.lua", "scripts/Ocean/World.lua",
        "scripts/Ocean/Config.lua", "scripts/Ocean/SurfaceSignals.lua",
        "scripts/Systems/EntityStateSystem.lua",
        "scripts/tests/SeaRuntimeTests.lua", "scripts/tests/SurfaceRiseTests.lua",
        "scripts/tests/SurfaceSignalsTests.lua", "scripts/tests/SeaStabilityTests.lua",
    }
    allowed_new = {"scripts/tests/Circle1AFishLocksTests.lua",
                   "scripts/tests/Circle1APredationCooldownTests.lua", "tests/run_circle1_a.py"}
    folders = ("scripts", "tests", "data", "docs", "engine-docs", "urhox-libs",
               "outputs/circle1-tasks-20261003", "screenshots")
    new = [p.relative_to(ROOT).as_posix() for folder in folders for p in (ROOT / folder).rglob("*")
           if p.is_file() and p.relative_to(ROOT).as_posix() not in before]
    violations = [name for name in changed if name not in allowed]
    violations += [name for name in new if name not in allowed_new]
    report = {"changed": changed, "added": new, "violations": violations, "passed": not violations}
    (OUT / "boundary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    delivered = {name: {"beforeSha256": before.get(name),
                        "sha256": hashlib.sha256((ROOT / name).read_bytes()).hexdigest()}
                 for name in changed + new if (ROOT / name).is_file()}
    (OUT / "delivery-manifest.json").write_text(json.dumps(delivered, indent=2), encoding="utf-8")
    return report


def regression():
    start = perf_counter()
    lua = runtime()
    compile_lua = lua.eval("function(s,n) local f,e=load(s,n); return f~=nil,e end")
    syntax = []
    for path in sorted((ROOT / "scripts").rglob("*.lua")):
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
        syntax.append({"file": path.relative_to(ROOT).as_posix(), "passed": ok, "error": error})
    checks = []
    for name in MODULES:
        try:
            report = runtime().eval("require(...).Run()", name)
            rows = [dict(row.items()) for row in report["results"].values()]
            checks.append({"module": name, "passed": all(row["passed"] for row in rows),
                           "tests": rows, "metrics": dict(report["metrics"].items()) if report["metrics"] else {}})
        except Exception as error:
            checks.append({"module": name, "passed": False, "error": str(error)})
    scope = boundary()
    report = {"luaVersion": lua.eval("_VERSION"), "python": sys.executable,
              "syntax": syntax, "checks": checks, "boundary": scope,
              "elapsedSec": perf_counter() - start,
              "nativeGameplayVerified": False, "realABIntegrationVerified": False,
              "passed": all(row["passed"] for row in syntax + checks) and scope["passed"]}
    (OUT / "validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "syntaxCount": len(syntax),
                      "checks": [{"module": row["module"], "passed": row["passed"],
                                  "count": len(row.get("tests", [])), "error": row.get("error"),
                                  "failures": [t for t in row.get("tests", []) if not t["passed"]]} for row in checks],
                      "boundary": scope, "elapsedSec": report["elapsedSec"]}, ensure_ascii=False))
    return 0 if report["passed"] else 1


def lsp():
    # Reuse the existing installed checker/config/filter without editing its file.
    # Only resolve its package from this user's home and redirect its evidence.
    path = ROOT / "tests/check_sea_lsp.py"
    source = path.read_text(encoding="utf-8-sig")
    package = Path.home() / ".taptap-maker/lua-lsp-venv/Lib/site-packages/maker_lua_lsp"
    source, count = re.subn(r"^PACKAGE = .*$", lambda _: "PACKAGE = Path(" + repr(str(package)) + ")", source,
                            count=1, flags=re.MULTILINE)
    assert count == 1 and (package / "bin/emmylua_ls.exe").is_file(), "installed EmmyLua package unavailable"
    source = source.replace("ROOT / 'screenshots' / 'sea-v1-lsp.json'", "ROOT / 'outputs' / 'circle1-a' / 'lsp.json'")
    exec(compile(source, str(path), "exec"), {"__file__": str(path), "__name__": "__main__"})
    current = json.loads((OUT / "lsp.json").read_text(encoding="utf-8"))
    baseline_path = ROOT / "outputs/selective-merge-20261003-surface/lsp.json"
    baseline = json.loads(baseline_path.read_text(encoding="utf-8-sig")) if baseline_path.is_file() else None

    def raw_errors(report):
        return Counter((uri.split("/scripts/", 1)[-1], item.get("code"), item.get("message"))
                       for uri, items in report.get("diagnostics", {}).items()
                       for item in items if item.get("severity") == 1)

    raw = raw_errors(current)
    prior = raw_errors(baseline) if baseline else Counter()
    summary = {"configuredMakerErrors": len(current["errors"]),
               "missingDiagnostics": current["missingDiagnostics"],
               "rawErrorCount": sum(raw.values()), "priorRawErrorCount": sum(prior.values()),
               "baseline": baseline_path.relative_to(ROOT).as_posix() if baseline else None,
               "newRawErrors": [{"file": file, "code": code, "message": message, "count": count}
                                for (file, code, message), count in (raw - prior).items()],
               "note": "Existing installed Maker compatibility filters unchanged; raw diagnostics preserved in lsp.json."}
    (OUT / "lsp-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    raise SystemExit(lsp() if "--lsp" in sys.argv else regression())
