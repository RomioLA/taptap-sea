"""Append-only barrel verification; reuses the A2 test harness without editing it."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
from time import perf_counter

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("circle1_a2_existing_runner", ROOT / "tests/run_circle1_a2.py")
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
runner.REGRESSION_MODULES = (*runner.REGRESSION_MODULES, "tests.Circle1A2BarrelTests")


def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def lsp_check():
    checker = ROOT / "tests/check_sea_lsp.py"
    source = checker.read_text(encoding="utf-8-sig")
    source, count = re.subn(r"^PACKAGE = .*$", lambda _: "PACKAGE = Path(" + repr(str(runner.LSP_PACKAGE)) + ")",
                          source, count=1, flags=re.MULTILINE)
    old = "ROOT / 'screenshots' / 'sea-v1-lsp.json'"
    if count != 1 or source.count(old) != 1:
        raise RuntimeError("Cannot redirect existing LSP checker safely")
    source = source.replace(old, "ROOT / 'outputs' / 'circle1-a2' / 'barrel-addon' / 'lsp.json'")
    try:
        exec(compile(source, str(checker), "exec"), {"__file__": str(checker), "__name__": "__main__"})
    except SystemExit:
        pass
    current = json.loads((OUT / "lsp.json").read_text(encoding="utf-8-sig"))
    previous = json.loads((ROOT / "outputs/circle1-a2/lsp.json").read_text(encoding="utf-8-sig"))
    def errors(report):
        return Counter((uri.split("/scripts/", 1)[-1], item.get("code"), item.get("message"))
                       for uri, items in report.get("diagnostics", {}).items()
                       for item in items if item.get("severity") == 1)
    raw, prior = errors(current), errors(previous)
    new = [{"file": f, "code": c, "message": m, "count": n}
           for (f, c, m), n in (raw - prior).items()]
    result = {"initialized": current.get("initialized"), "missingDiagnostics": current.get("missingDiagnostics"),
              "configuredErrorCount": len(current.get("errors", [])), "rawErrorCount": sum(raw.values()),
              "priorRawErrorCount": sum(prior.values()), "newRawErrors": new,
              "passed": bool(current.get("initialized")) and not current.get("missingDiagnostics")
                        and not current.get("errors") and not new}
    write("lsp-summary.json", result)
    return result


def boundary_check():
    previous = json.loads((OUT / "before.json").read_text(encoding="utf-8-sig"))
    changed = [name for name, sha in previous.items() if not (ROOT / name).is_file()
               or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != sha]
    allowed = {"scripts/Ocean/Config.lua", "scripts/Ocean/World.lua", "scripts/Ocean/SeaRuntime.lua",
               "scripts/Ocean/SeaDraw.lua", "scripts/Ocean/Draw.lua", "scripts/Systems/EntityStateSystem.lua",
               "scripts/tests/SeaRuntimeTests.lua", "scripts/tests/SeaStabilityTests.lua",
               "scripts/tests/SurfaceRiseTests.lua", "scripts/tests/SurfaceSignalsTests.lua",
               "scripts/tests/SeaFusionRenderTests.lua", "scripts/tests/Circle1A2FishingTests.lua"}
    additions = []
    for folder in ("scripts", "tests", "data", "docs", ".project", "engine-docs", "urhox-libs", "examples", "templates", "assets"):
        for path in (ROOT / folder).rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            name = path.relative_to(ROOT).as_posix()
            if name not in previous:
                additions.append(name)
    violations = [name for name in changed if name not in allowed]
    violations.extend(name for name in additions if not re.fullmatch(r"scripts/tests/Circle1A2\w+\.lua", name))
    manifest = {name: {"beforeSha256": previous.get(name),
                      "sha256": hashlib.sha256((ROOT / name).read_bytes()).hexdigest()}
                for name in sorted(set(changed + additions)) if (ROOT / name).is_file()}
    report = {"changed": changed, "added": additions, "violations": violations, "passed": not violations,
              "priorA2EvidencePreserved": not any(name.startswith("outputs/circle1-a2/") for name in changed)}
    write("boundary.json", report)
    write("delivery-manifest.json", manifest)
    return report


def barrel_render_check():
    result = runner._run_recorder_module("tests.Circle1A2BarrelRenderTests")
    report = result["report"]
    rows = report.get("results", report.get("tests", []))
    result["passed"] = report.get("status") in (None, "PASS") and all(
        row.get("passed", False) for row in rows if isinstance(row, dict))
    return result


def pictures():
    result = []
    for name, x in (("outline", 85), ("recognized", 65)):
        lua = runner._lua(ROOT / "scripts")
        cap = runner._capture_type()()
        cap.bind(lua)
        runtime = lua.eval('function() local R=require("Ocean.SeaRuntime"); return R.New({initializeRegions=false}) end')()
        runtime.ship.position.x, runtime.ship.position.y = x, 25
        runtime.movement.SetViewport(runtime.movement, 1920, 1080)
        draw = lua.eval('function() local D=require("Ocean.SeaDraw"); return D end')()
        draw.Scene(lua.table(), 1920, 1080, runtime)
        cap.render_png(1920, 1080, OUT / ("barrel-" + name + ".png"))
        (OUT / ("barrel-" + name + ".svg")).write_text(cap.to_svg(1920, 1080, name), encoding="utf-8")
        result.append({"name": name, "distanceMeters": x - 60, "engineScreenshot": False,
                       "png": "barrel-" + name + ".png"})
    write("offline-images.json", result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="regressions only; no final type validation")
    args = parser.parse_args()
    started = perf_counter()
    report = {"luaSyntax": runner.syntax_check(), "marineRegressions": runner.regression_checks(),
              "previousA2Render": runner.render_checks(), "barrelRender": barrel_render_check()}
    report["boundary"] = boundary_check()
    if not args.quick:
        report["lsp"] = lsp_check()
        report["offlineImages"] = pictures()
    report["elapsedSec"] = perf_counter() - started
    report["nativeEnginePreviewVerified"] = False
    report["realBBarrelConnectionVerified"] = False
    report["status"] = "待验收"
    report["passed"] = all(report[key]["passed"] for key in (
        "luaSyntax", "marineRegressions", "previousA2Render", "barrelRender", "boundary")) and (
        args.quick or report["lsp"]["passed"])
    write("quick-validation.json" if args.quick else "validation.json", report)
    print(json.dumps({"passed": report["passed"], "quick": args.quick, "elapsedSec": report["elapsedSec"]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
