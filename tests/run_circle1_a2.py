"""Circle 1 A2 regressions, render contracts, and fixed-seed performance comparison.

All generated evidence stays under outputs/circle1-a2. The runner reuses the
bundled Python 3.12 runtime plus the repository's existing Lupa package; it
does not install dependencies or launch Maker preview/build workflows.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import statistics
import sys
from collections import Counter
from pathlib import Path
from time import perf_counter
from typing import Any

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs" / "circle1-a2"
BASELINE = OUT / "baseline"
PYTHON_DEPS = ROOT / "outputs" / "remote-review-20261002" / "test-runtime"
LSP_PACKAGE = Path(r"C:\Users\80739\.taptap-maker\lua-lsp-venv\Lib\site-packages\maker_lua_lsp")

REGRESSION_MODULES = (
    "tests.Circle1AFishLocksTests",
    "tests.Circle1APredationCooldownTests",
    "tests.SeaRuntimeTests",
    "tests.SurfaceRiseTests",
    "tests.SurfaceSignalsTests",
    "tests.SeaStabilityTests",
    "tests.Circle1A2ScopeTests",
    "tests.Circle1A2SignalsTests",
    # Compatibility tests are read-only and protect the shared adapter seams.
    "tests.ArchitectureIntegrationTests",
    "tests.ABIntegrationTests",
    "tests.SeaFusedSceneTests",
)

ALLOWED_CHANGED = {
    "scripts/Ocean/Bootstrap.lua", "scripts/Ocean/Draw.lua", "scripts/Ocean/SeaDraw.lua",
    "scripts/Ocean/SeaRuntime.lua", "scripts/Ocean/SurfaceSignals.lua", "scripts/Ocean/World.lua",
    "scripts/Systems/EntityStateSystem.lua",
    "scripts/tests/SeaRuntimeTests.lua", "scripts/tests/SurfaceRiseTests.lua",
    "scripts/tests/SurfaceSignalsTests.lua", "scripts/tests/SeaFusionRenderTests.lua",
    "scripts/tests/SeaStabilityTests.lua",
}
ALLOWED_NEW = {
    "tests/run_circle1_a2.py",
    "scripts/tests/Circle1A2ScopeTests.lua",
    "scripts/tests/Circle1A2SignalsTests.lua",
    "scripts/tests/Circle1A2FishingTests.lua",
}

SEEDS = (271828, 314159)
UPDATE_STEPS = 240
REPETITIONS = 5
GETTER_LOOPS = 1200

BENCHMARK_LUA = r"""
function(seed, steps, getterLoops)
    local Runtime = require("Ocean.SeaRuntime")
    collectgarbage("collect")
    local beforeMemory = collectgarbage("count")
    local initStart = os.clock()
    local runtime = Runtime.New({ daySeed = seed, departure = { x = 0, y = 0 } })
    local initCpu = os.clock() - initStart
    local routeX = { 0, 1, 1, 0, -1, -1, 0, 0 }
    local routeY = { 1, 1, 0, -1, -1, 0, 1, 0 }
    local updateCpu = 0
    local updateStart = os.clock()
    local signalCheckpointCpu = 0
    local signalRows = {}
    local function appendSignals(step)
        local signalStart = os.clock()
        local birds = runtime.surfaceSignals:GetBirds()
        local splashes = runtime.surfaceSignals:GetSplashes()
        signalCheckpointCpu = signalCheckpointCpu + os.clock() - signalStart
        for _, bird in ipairs(birds) do
            signalRows[#signalRows + 1] = string.format("step=%d|bird|%s|%s|%.6f|%.6f|%.6f|%.6f",
                step, tostring(bird.id), tostring(bird.sourceId), bird.position.x, bird.position.y,
                bird.heading or 0, bird.diveProgress or 0)
        end
        for _, splash in ipairs(splashes) do
            signalRows[#signalRows + 1] = string.format("step=%d|splash|%s|%.6f|%.6f|%.6f|%.6f|%.6f|%.6f",
                step, tostring(splash.sourceId), splash.position.x, splash.position.y,
                splash.heading or 0, splash.remaining or 0, splash.lifetime or 0,
                splash.trailLength or 0)
        end
    end
    for step = 1, steps do
        local route = math.floor((step - 1) / 30) % #routeX + 1
        runtime:Update(0.05, routeX[route], routeY[route])
        if step % 60 == 0 then
            updateCpu = updateCpu + os.clock() - updateStart
            appendSignals(step)
            updateStart = os.clock()
        end
    end
    if steps % 60 ~= 0 then updateCpu = updateCpu + os.clock() - updateStart end

    local rows = {}
    for _, entity in ipairs(runtime.world.entities) do
        if not entity.removed then
            rows[#rows + 1] = string.format(
                "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
                tostring(entity.id), tostring(entity.entityType), tostring(entity.species or ""),
                tostring(entity.active), tostring(entity.frozen), tostring(entity.state),
                string.format("%.6f", entity.position.x), string.format("%.6f", entity.position.y),
                string.format("%.6f", entity.rotation or 0),
                string.format("%.6f", entity.surfaceDepth or 0),
                string.format("%.6f", entity.riseRemaining or 0))
        end
    end
    table.sort(rows)
    local ship = runtime.ship.position
    local digestText = table.concat({
        string.format("seed=%d;time=%.6f;worldtime=%.6f;ship=%.6f,%.6f",
            seed, runtime.time, runtime.world.time, ship.x, ship.y),
        table.concat(rows, "\n"),
    }, "\n")

    local signalStart = os.clock()
    local birdsSeen, splashesSeen = 0, 0
    local lastBirds, lastSplashes = {}, {}
    for _ = 1, getterLoops do
        lastBirds = runtime.surfaceSignals:GetBirds()
        lastSplashes = runtime.surfaceSignals:GetSplashes()
        birdsSeen = birdsSeen + #lastBirds
        splashesSeen = splashesSeen + #lastSplashes
    end
    local signalGetterCpu = os.clock() - signalStart
    table.sort(signalRows)
    local afterMemory = collectgarbage("count")
    local counts = runtime.world:getCounts()
    return {
        seed = seed, steps = steps, getterLoops = getterLoops,
        initCpuSec = initCpu, updateCpuSec = updateCpu,
        signalGetterCpuSec = signalGetterCpu,
        signalCheckpointGetterCpuSec = signalCheckpointCpu,
        memoryDeltaKiB = afterMemory - beforeMemory,
        entityCount = #rows, activeFish = counts.active, frozenFish = counts.frozen,
        sardineCount = counts.sardine, tunaCount = counts.tuna,
        birdGetterCalls = getterLoops, splashGetterCalls = getterLoops,
        birdsSeen = birdsSeen, splashesSeen = splashesSeen,
        digestText = digestText,
        signalDigestText = table.concat(signalRows, "\n"),
    }
end
"""


def _python_paths() -> None:
    # Prefer the project-local test runtime, with the task-preferred path first
    # when it is readable in the current managed environment.
    for path in (ROOT / ".tmp" / "sea-test-deps", PYTHON_DEPS):
        if path.is_dir() and str(path) not in sys.path:
            sys.path.insert(0, str(path))


def _lua(source_root: Path):
    _python_paths()
    from lupa.lua54 import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    source = source_root.as_posix()
    scripts = (ROOT / "scripts").as_posix()
    lua.execute(
        "package.path = "
        + repr(source + "/?.lua;" + source + "/?/init.lua;" + scripts + "/?.lua;"
              + scripts + "/?/init.lua;")
        + " .. package.path"
    )
    return lua


def _lua_value(value: Any) -> Any:
    if not callable(getattr(value, "keys", None)):
        return value
    keys = list(value.keys())
    if not keys:
        return {}
    if all(isinstance(key, (int, float)) and int(key) == key and key > 0 for key in keys):
        max_key = int(max(keys))
        if len(keys) == max_key:
            return [_lua_value(value[index]) for index in range(1, max_key + 1)]
    return {str(key): _lua_value(value[key]) for key in keys}


def _result_rows(report: Any) -> list[dict[str, Any]]:
    rows = report["results"]
    return [_lua_value(rows[index]) for index in range(1, len(rows) + 1)]


def syntax_check() -> dict[str, Any]:
    lua = _lua(ROOT / "scripts")
    compile_lua = lua.eval("function(source,name) local f,e=load(source,name); return f~=nil,e end")
    rows = []
    for path in sorted((ROOT / "scripts").rglob("*.lua")):
        if "__pycache__" in path.parts:
            continue
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + path.as_posix())
        rows.append({"file": path.relative_to(ROOT).as_posix(), "passed": bool(ok), "error": error})
    return {"luaVersion": lua.eval("_VERSION"), "files": rows,
            "passed": all(row["passed"] for row in rows)}


def regression_checks() -> dict[str, Any]:
    checks = []
    missing = []
    for name in REGRESSION_MODULES:
        file_path = ROOT / "scripts" / (name.replace(".", "/") + ".lua")
        if not file_path.is_file():
            missing.append(name)
            continue
        try:
            lua = _lua(ROOT / "scripts")
            report = lua.eval("require(...).Run()", name)
            rows = _result_rows(report)
            checks.append({"module": name, "passed": all(row.get("passed", False) for row in rows),
                           "tests": rows, "metrics": _lua_value(report["metrics"])
                           if report["metrics"] is not None else {}})
        except Exception as error:  # preserve failure detail as test evidence
            checks.append({"module": name, "passed": False, "error": str(error)})
    return {"checks": checks, "missingModules": missing,
            "passed": not missing and all(check["passed"] for check in checks)}


def _capture_type():
    script = ROOT / "tests" / "render_sea_fusion.py"
    spec = importlib.util.spec_from_file_location("circle1_a2_render_capture", script)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load the existing NVGCapture recorder")
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves its defining module during decoration, which
    # requires the module to be present in sys.modules before execution.
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    return module.NVGCapture


def _run_recorder_module(module_name: str) -> dict[str, Any]:
    NVGCapture = _capture_type()
    lua = _lua(ROOT / "scripts")
    recorder = NVGCapture()
    recorder_table = recorder.bind(lua)
    lua.globals().__nvgRecorder = recorder_table
    lua.globals().__nvgContext = lua.table()
    module = lua.eval("function(name) local m=require(name); return m end")(module_name)
    report = module.Run(recorder_table)
    return {"module": module_name, "report": _lua_value(report),
            "nvgCalls": dict(sorted(recorder.counts.items())),
            "nvgCallTotal": sum(recorder.counts.values()),
            "capturedElements": len(recorder.elements)}


def render_checks() -> dict[str, Any]:
    results = []
    for name in ("tests.SeaFusionRenderTests", "tests.Circle1A2FishingTests"):
        file_path = ROOT / "scripts" / (name.replace(".", "/") + ".lua")
        if not file_path.is_file():
            results.append({"module": name, "passed": False, "error": "required render test module missing"})
            continue
        try:
            result = _run_recorder_module(name)
            report = result["report"]
            rows = report.get("tests", report.get("results", [])) if isinstance(report, dict) else []
            row_passed = all(row.get("passed", False) for row in rows if isinstance(row, dict))
            status_passed = report.get("status") in (None, "PASS") if isinstance(report, dict) else False
            result["passed"] = row_passed and status_passed
            result["testFailures"] = [row for row in rows if isinstance(row, dict) and not row.get("passed", False)]
            results.append(result)
        except Exception as error:
            results.append({"module": name, "passed": False, "error": str(error)})
    return {"checks": results, "passed": all(result.get("passed", False) for result in results)}


def performance_sample(source_root: Path, seed: int, steps: int, getter_loops: int) -> dict[str, Any]:
    lua = _lua(source_root)
    run = lua.eval(BENCHMARK_LUA)
    result = _lua_value(run(seed, steps, getter_loops))
    digest_text = result.pop("digestText")
    result["trajectoryDigest"] = hashlib.sha256(digest_text.encode("utf-8")).hexdigest()
    signal_text = result.pop("signalDigestText")
    result["signalDigest"] = hashlib.sha256(signal_text.encode("utf-8")).hexdigest()
    return result


def benchmark(source_root: Path, label: str) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    start = perf_counter()
    for seed in SEEDS:
        # One warm-up has the same workload and is excluded from the samples.
        performance_sample(source_root, seed, UPDATE_STEPS, GETTER_LOOPS)
        for repetition in range(REPETITIONS):
            sample = performance_sample(source_root, seed, UPDATE_STEPS, GETTER_LOOPS)
            sample["repetition"] = repetition + 1
            samples.append(sample)
    metrics = ("initCpuSec", "updateCpuSec", "signalGetterCpuSec",
               "signalCheckpointGetterCpuSec", "memoryDeltaKiB")
    summary = {
        metric: statistics.median(float(sample[metric]) for sample in samples)
        for metric in metrics
    }
    digest_by_seed = {
        str(seed): sorted({sample["trajectoryDigest"] for sample in samples if sample["seed"] == seed})
        for seed in SEEDS
    }
    signal_digest_by_seed = {
        str(seed): sorted({sample["signalDigest"] for sample in samples if sample["seed"] == seed})
        for seed in SEEDS
    }
    consistency = all(len(digests) == 1 for digests in digest_by_seed.values())
    signal_consistency = all(len(digests) == 1 for digests in signal_digest_by_seed.values())
    return {
        "label": label,
        "sourceRoot": str(source_root.relative_to(ROOT)).replace("\\", "/"),
        "scenario": {
            "seeds": list(SEEDS), "stepsPerSample": UPDATE_STEPS, "timeStepSec": 0.05,
            "repetitionsPerSeed": REPETITIONS, "warmupsPerSeed": 1,
            "getBirdsCallsPerSample": GETTER_LOOPS,
            "getSplashesCallsPerSample": GETTER_LOOPS,
            "surfaceCueSnapshots": "at steps 60, 120, 180, 240; records include source IDs, positions, headings, dive progress, splash remaining/lifetime/trail",
            "route": "deterministic 8-vector route changes every 30 updates",
            "activityRangeAndFishPopulation": "unchanged project Config and generated fish table",
        },
        "summaryMedian": summary,
        "trajectoryDigestBySeed": digest_by_seed,
        "signalDigestBySeed": signal_digest_by_seed,
        "signalRecordCountsBySeed": {
            str(seed): {
                "birdsSeenMedian": statistics.median(sample["birdsSeen"] for sample in samples if sample["seed"] == seed),
                "splashesSeenMedian": statistics.median(sample["splashesSeen"] for sample in samples if sample["seed"] == seed),
            }
            for seed in SEEDS
        },
        "repeatDigestStable": consistency,
        "repeatSignalDigestStable": signal_consistency,
        "samples": samples,
        "wallTimeSec": perf_counter() - start,
    }


def _median_comparison(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    metrics = ("initCpuSec", "updateCpuSec", "signalGetterCpuSec",
               "signalCheckpointGetterCpuSec", "memoryDeltaKiB")
    timing = {}
    for metric in metrics:
        a, b = before["summaryMedian"][metric], after["summaryMedian"][metric]
        timing[metric] = {
            "beforeMedian": a, "afterMedian": b,
            "delta": b - a,
            "percentChange": ((b - a) / a * 100) if a else None,
        }
    seed_match = {
        seed: before["trajectoryDigestBySeed"].get(seed) == after["trajectoryDigestBySeed"].get(seed)
        for seed in before["trajectoryDigestBySeed"]
    }
    signal_match = {
        seed: before.get("signalDigestBySeed", {}).get(seed) == after.get("signalDigestBySeed", {}).get(seed)
        for seed in before.get("trajectoryDigestBySeed", {})
    }
    signal_counts = {
        seed: {
            "before": before.get("signalRecordCountsBySeed", {}).get(seed),
            "after": after.get("signalRecordCountsBySeed", {}).get(seed),
            "unchanged": before.get("signalRecordCountsBySeed", {}).get(seed)
                == after.get("signalRecordCountsBySeed", {}).get(seed),
        }
        for seed in before.get("trajectoryDigestBySeed", {})
    }
    return {"timingAndAllocation": timing, "trajectoryMatchesBySeed": seed_match,
            "behaviorEquivalent": all(seed_match.values()),
            "signalSnapshotMatchesBySeed": signal_match,
            "signalRecordCountsBySeed": signal_counts,
            "drawCallEvidence": after.get("drawCallEvidence", []),
            "note": "Microbenchmark timings are diagnostic medians; trajectory equivalence is exact for this fixed scene."}


def _draw_call_evidence() -> list[dict[str, Any]]:
    path = OUT / "draw-equivalence.json"
    if not path.is_file():
        return []
    rows = json.loads(path.read_text(encoding="utf-8"))
    evidence = []
    for row in rows:
        captures = {capture.get("version"): capture for capture in row.get("captures", [])}
        before = captures.get("before", {})
        after = captures.get("after", {})
        evidence.append({
            "scene": row.get("scene"), "pixelsIdentical": row.get("pixelsIdentical"),
            "beforeNvgCalls": before.get("nvgCalls"), "afterNvgCalls": after.get("nvgCalls"),
            "nvgCallDelta": ((after.get("nvgCalls") or 0) - (before.get("nvgCalls") or 0)),
            "beforeSha256": before.get("sha256"), "afterSha256": after.get("sha256"),
        })
    return evidence


def performance(source_kind: str) -> dict[str, Any]:
    if source_kind == "baseline":
        if not BASELINE.is_dir():
            raise FileNotFoundError(f"baseline sources missing: {BASELINE}")
        result = benchmark(BASELINE, "before")
        result["drawCallEvidence"] = _draw_call_evidence()
        target = OUT / "performance-before.json"
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"mode": source_kind, "repeatDigestStable": result["repeatDigestStable"],
                          "summaryMedian": result["summaryMedian"], "output": str(target)}, ensure_ascii=False))
        return {"before": result, "after": None, "comparison": None,
                "passed": result["repeatDigestStable"] and result["repeatSignalDigestStable"]}
    if source_kind == "current":
        result = benchmark(ROOT / "scripts", "after")
        result["drawCallEvidence"] = _draw_call_evidence()
        target = OUT / "performance-after.json"
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        before_path = OUT / "performance-before.json"
        comparison = None
        if before_path.is_file():
            before = json.loads(before_path.read_text(encoding="utf-8"))
            comparison = _median_comparison(before, result)
            (OUT / "performance-comparison.json").write_text(
                json.dumps(comparison, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"mode": source_kind, "repeatDigestStable": result["repeatDigestStable"],
                          "summaryMedian": result["summaryMedian"], "comparison": comparison,
                          "drawCallEvidence": result["drawCallEvidence"],
                          "output": str(target)}, ensure_ascii=False))
        return {"before": None, "after": result, "comparison": comparison,
                "passed": result["repeatDigestStable"] and result["repeatSignalDigestStable"]
                    and (comparison is None or comparison["behaviorEquivalent"])}
    raise ValueError(source_kind)


def lsp_check() -> dict[str, Any]:
    checker_path = ROOT / "tests" / "check_sea_lsp.py"
    package = LSP_PACKAGE
    if not (package / "bin" / "emmylua_ls.exe").is_file():
        return {"passed": False, "error": f"installed EmmyLua binary missing under {package}"}
    source = checker_path.read_text(encoding="utf-8-sig")
    source, package_count = re.subn(
        r"^PACKAGE = .*$", lambda _: "PACKAGE = Path(" + repr(str(package)) + ")",
        source, count=1, flags=re.MULTILINE)
    source, output_count = re.subn(
        r"ROOT / 'screenshots' / 'sea-v1-lsp\.json'",
        "ROOT / 'outputs' / 'circle1-a2' / 'lsp.json'", source, count=1)
    if package_count != 1 or output_count != 1:
        return {"passed": False, "error": "could not safely redirect the existing LSP checker"}
    start = perf_counter()
    checker_exit = None
    try:
        exec(compile(source, str(checker_path), "exec"),
             {"__file__": str(checker_path), "__name__": "__main__"})
    except SystemExit as error:
        # The existing checker exits nonzero when it sees any raw diagnostic;
        # keep the report it wrote so this runner can compare only new errors.
        checker_exit = error.code
    except Exception as error:
        return {"passed": False, "error": f"installed LSP checker failed: {error}"}
    if not (OUT / "lsp.json").is_file():
        return {"passed": False, "error": f"LSP checker produced no report (exit={checker_exit})"}
    current = json.loads((OUT / "lsp.json").read_text(encoding="utf-8"))
    prior_path = ROOT / "outputs" / "circle1-a" / "lsp.json"
    prior = json.loads(prior_path.read_text(encoding="utf-8-sig")) if prior_path.is_file() else None

    def raw_errors(report: dict[str, Any]) -> Counter:
        return Counter((uri.split("/scripts/", 1)[-1], item.get("code"), item.get("message"))
                       for uri, items in report.get("diagnostics", {}).items()
                       for item in items if item.get("severity") == 1)

    current_raw = raw_errors(current)
    prior_raw = raw_errors(prior) if prior else Counter()
    new = [{"file": file, "code": code, "message": message, "count": count}
           for (file, code, message), count in (current_raw - prior_raw).items()]
    result = {
        "initialized": current.get("initialized", False),
        "missingDiagnostics": current.get("missingDiagnostics", []),
        "configuredErrorCount": len(current.get("errors", [])),
        "rawErrorCount": sum(current_raw.values()),
        "priorRawErrorCount": sum(prior_raw.values()),
        "priorReport": str(prior_path.relative_to(ROOT)).replace("\\", "/") if prior else None,
        "newRawErrors": new,
        "elapsedSec": perf_counter() - start,
        "checkerExitCode": checker_exit,
        "passed": bool(current.get("initialized")) and not current.get("missingDiagnostics") and not new,
        "note": "Uses the installed Maker EmmyLua server and existing diagnostic filters; the prior A1 report is the comparison baseline.",
    }
    (OUT / "lsp-summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return result


def boundary_check() -> dict[str, Any]:
    before_path = OUT / "before.json"
    if not before_path.is_file():
        return {"passed": False, "error": "outputs/circle1-a2/before.json missing"}
    before = json.loads(before_path.read_text(encoding="utf-8"))
    changed = [name for name, digest in before.items()
               if not (ROOT / name).is_file()
               or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
    changed_violations = [name for name in changed if name not in ALLOWED_CHANGED]
    added: list[str] = []
    scan_folders = ("scripts", "tests", "data", "docs", "engine-docs", "urhox-libs", "screenshots")
    for folder in scan_folders:
        root = ROOT / folder
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            name = path.relative_to(ROOT).as_posix()
            if name not in before and name not in ALLOWED_NEW:
                added.append(name)
    # The supplied hash inventory covers only selected old output evidence.
    # Compare non-A2 output timestamps to the inventory creation time so older
    # task evidence is not mistaken for this task's new files.
    baseline_time = before_path.stat().st_mtime
    outputs_root = ROOT / "outputs"
    if outputs_root.exists():
        for top in outputs_root.iterdir():
            if top.name in ("remote-review-20261002", "circle1-a2"):
                continue
            for path in top.rglob("*") if top.is_dir() else (top,):
                if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                    continue
                name = path.relative_to(ROOT).as_posix()
                if path.stat().st_mtime > baseline_time:
                    added.append(name)
    for path in OUT.rglob("*"):
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc":
            name = path.relative_to(ROOT).as_posix()
            if name not in before and not name.startswith("outputs/circle1-a2/"):
                added.append(name)
    violations = sorted(set(changed_violations + added))
    delivered = {}
    for name in sorted(set(changed + [f"scripts/tests/{p.name}" for p in (ROOT / "scripts/tests").glob("Circle1A2*.lua")]
                           + ["tests/run_circle1_a2.py"])):
        path = ROOT / name
        if path.is_file():
            delivered[name] = {"beforeSha256": before.get(name),
                               "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    report = {"changed": changed, "added": sorted(set(added)), "violations": violations,
              "deliveryManifest": delivered, "passed": not violations}
    (OUT / "boundary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "delivery-manifest.json").write_text(json.dumps(delivered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("all", "performance-before", "performance-after"), default="all")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.mode.startswith("performance-"):
        source_kind = "baseline" if args.mode == "performance-before" else "current"
        result = performance(source_kind)
        return 0 if result["passed"] else 1

    start = perf_counter()
    syntax = syntax_check()
    regressions = regression_checks()
    rendering = render_checks()
    perf_result = performance("current")
    lsp = lsp_check()
    boundary = boundary_check()
    passed = all((syntax["passed"], regressions["passed"], rendering["passed"],
                  perf_result["passed"], lsp["passed"], boundary["passed"]))
    report = {
        "python": sys.version,
        "pythonExecutable": sys.executable,
        "luaSyntax": syntax,
        "marineRegressions": regressions,
        "offlineRenderContracts": rendering,
        "performance": perf_result,
        "lsp": lsp,
        "boundary": {"passed": boundary["passed"], "violations": boundary.get("violations", [])},
        "elapsedSec": perf_counter() - start,
        "nativeEnginePreviewVerified": False,
        "realBGameplayConnectionVerified": False,
        "passed": passed,
    }
    target = OUT / "validation.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "passed": passed, "luaSyntaxCount": len(syntax["files"]),
        "syntaxFailures": [row for row in syntax["files"] if not row["passed"]],
        "regressions": [{"module": row.get("module"), "passed": row.get("passed"),
                         "failures": row.get("testFailures", [r for r in row.get("tests", []) if not r.get("passed", False)]),
                         "error": row.get("error")} for row in regressions["checks"]],
        "missingModules": regressions["missingModules"],
        "rendering": [{"module": row.get("module"), "passed": row.get("passed"),
                       "failures": row.get("testFailures", []), "error": row.get("error")}
                      for row in rendering["checks"]],
        "lspPassed": lsp.get("passed"), "lspNewErrors": lsp.get("newRawErrors"),
        "boundary": {"passed": boundary["passed"], "violations": boundary.get("violations", [])},
        "elapsedSec": report["elapsedSec"], "output": str(target),
    }, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
