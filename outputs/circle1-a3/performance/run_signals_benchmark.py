"""A3 read-only benchmark for the Ocean signal getter and scalar visitor paths.

The Lua sources under outputs/circle1-a3/baseline/Ocean are loaded as the
before state; current scripts/Ocean is the after state. The harness helper is
imported read-only from tests/run_circle1_a2.py. No game source or older A2
evidence is overwritten.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import statistics
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
BASELINE_OCEAN = ROOT / "outputs" / "circle1-a3" / "baseline"
SEEDS = (271828, 314159)
STEPS = 2400
GETTER_LOOPS = 1200
REPETITIONS = 3
SIGNAL_SAMPLE_INTERVAL = 5

spec = importlib.util.spec_from_file_location("circle1_a2_helpers", ROOT / "tests" / "run_circle1_a2.py")
assert spec and spec.loader
helpers = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helpers
spec.loader.exec_module(helpers)

BENCHMARK_LUA = r"""
function(seed, steps, getterLoops)
    local Runtime = require("Ocean.SeaRuntime")
    collectgarbage("collect")
    local heapBeforeRun = collectgarbage("count")
    local initStart = os.clock()
    local runtime = Runtime.New({ daySeed = seed, departure = { x = 0, y = 0 } })
    local initCpuSec = os.clock() - initStart
    local updateStart = os.clock()
    local updateCpuSec, checkpointCpuSec = 0, 0
    local signalRows = {}
    for step = 1, steps do
        -- Normal movement input on a stable open-water route. No test fish,
        -- modified population, injected signal, or tuning override is used.
        runtime:Update(0.05, 0, 1)
        if step % 5 == 0 then
            updateCpuSec = updateCpuSec + os.clock() - updateStart
            local checkpointStart = os.clock()
            local birds = runtime.surfaceSignals:GetBirds()
            local splashes = runtime.surfaceSignals:GetSplashes()
            for _, bird in ipairs(birds) do
                signalRows[#signalRows + 1] = string.format(
                    "step=%d|bird|%s|%s|%.6f|%.6f|%.6f|%.6f",
                    step, tostring(bird.id), tostring(bird.sourceId), bird.position.x, bird.position.y,
                    bird.heading or 0, bird.diveProgress or 0)
            end
            for _, splash in ipairs(splashes) do
                signalRows[#signalRows + 1] = string.format(
                    "step=%d|splash|%s|%.6f|%.6f|%.6f|%.6f|%.6f|%.6f",
                    step, tostring(splash.sourceId), splash.position.x, splash.position.y,
                    splash.heading or 0, splash.remaining or 0, splash.lifetime or 0,
                    splash.trailLength or 0)
            end
            checkpointCpuSec = checkpointCpuSec + os.clock() - checkpointStart
            updateStart = os.clock()
        end
    end
    updateCpuSec = updateCpuSec + os.clock() - updateStart

    local rows = {}
    for _, entity in ipairs(runtime.world.entities) do
        if not entity.removed then
            rows[#rows + 1] = string.format(
                "%s|%s|%s|%s|%s|%s|%.6f|%.6f|%.6f|%.6f|%.6f",
                tostring(entity.id), tostring(entity.entityType), tostring(entity.species or ""),
                tostring(entity.active), tostring(entity.frozen), tostring(entity.state),
                entity.position.x, entity.position.y, entity.rotation or 0,
                entity.surfaceDepth or 0, entity.riseRemaining or 0)
        end
    end
    table.sort(rows)

    local ship = runtime.ship.position
    local worldText = table.concat({
        string.format("seed=%d;time=%.6f;worldtime=%.6f;ship=%.6f,%.6f",
            seed, runtime.time, runtime.world.time, ship.x, ship.y),
        table.concat(rows, "\n"),
    }, "\n")
    table.sort(signalRows)
    local signalDigestText = table.concat(signalRows, "\n")
    local counts = runtime.world:getCounts()
    local finalBirds = runtime.surfaceSignals:GetBirds()
    local finalSplashes = runtime.surfaceSignals:GetSplashes()
    local entityCount = #rows

    -- Update/init memory is measured as net heap growth before/after a full
    -- collection. It is not mislabeled as total allocation traffic.
    local runPreGcKiB = collectgarbage("count")
    collectgarbage("collect")
    local runPostGcKiB = collectgarbage("count")

    local function getterSample()
        collectgarbage("collect")
        local startKiB = collectgarbage("count")
        collectgarbage("stop")
        local startCpu = os.clock()
        local birdCount, splashCount = 0, 0
        local lastBirds, lastSplashes = {}, {}
        for _ = 1, getterLoops do
            lastBirds = runtime.surfaceSignals:GetBirds()
            lastSplashes = runtime.surfaceSignals:GetSplashes()
            birdCount = birdCount + #lastBirds
            splashCount = splashCount + #lastSplashes
        end
        local cpuSec = os.clock() - startCpu
        local preGcKiB = collectgarbage("count")
        collectgarbage("collect")
        local postGcKiB = collectgarbage("count")
        collectgarbage("restart")
        return {
            cpuSec = cpuSec,
            birdsVisited = birdCount,
            splashesVisited = splashCount,
            preGcAllocationDeltaKiB = preGcKiB - startKiB,
            postGcRetainedDeltaKiB = postGcKiB - startKiB,
            collectedDeltaKiB = preGcKiB - postGcKiB,
        }
    end

    local function visitorSample()
        collectgarbage("collect")
        local startKiB = collectgarbage("count")
        local birdCount, splashCount, checksum = 0, 0, 0
        local function visitBird(x, y, heading, diveProgress)
            birdCount = birdCount + 1
            checksum = checksum + x * 0.000001 + y * 0.000002 + heading * 0.000003 + diveProgress * 0.000004
        end
        local function visitSplash(x, y, remaining, lifetime, heading, trailLength)
            splashCount = splashCount + 1
            checksum = checksum + x * 0.000001 + y * 0.000002 + remaining * 0.000003
                + lifetime * 0.000004 + heading * 0.000005 + trailLength * 0.000006
        end
        -- Allocate callbacks before stopping GC so this measures the per-read
        -- surface path rather than the harness closure setup.
        collectgarbage("collect")
        startKiB = collectgarbage("count")
        collectgarbage("stop")
        local startCpu = os.clock()
        local birdsSeen, splashesSeen = 0, 0
        for _ = 1, getterLoops do
            birdsSeen = birdsSeen + runtime.surfaceSignals:VisitBirds(visitBird)
            splashesSeen = splashesSeen + runtime.surfaceSignals:VisitSplashes(visitSplash)
        end
        local cpuSec = os.clock() - startCpu
        local preGcKiB = collectgarbage("count")
        collectgarbage("collect")
        local postGcKiB = collectgarbage("count")
        collectgarbage("restart")
        return {
            cpuSec = cpuSec,
            birdsVisited = birdsSeen,
            splashesVisited = splashesSeen,
            checksum = checksum,
            preGcAllocationDeltaKiB = preGcKiB - startKiB,
            postGcRetainedDeltaKiB = postGcKiB - startKiB,
            collectedDeltaKiB = preGcKiB - postGcKiB,
        }
    end

    local getter = getterSample()
    local visitorAvailable = type(runtime.surfaceSignals.VisitBirds) == "function"
        and type(runtime.surfaceSignals.VisitSplashes) == "function"
    local visitor = visitorAvailable and visitorSample() or nil
    return {
        seed = seed,
        steps = steps,
        route = "normal-runtime, level-1 straight north, dt=0.05s, signals sampled every 0.25s; no injected fish/signals",
        getterLoops = getterLoops,
        initCpuSec = initCpuSec,
        updateCpuSec = updateCpuSec,
        checkpointGetterCpuSec = checkpointCpuSec,
        runPreGcHeapKiB = runPreGcKiB,
        runPostGcRetainedHeapKiB = runPostGcKiB,
        runRetainedDeltaKiB = runPostGcKiB - heapBeforeRun,
        entityCount = entityCount,
        activeFish = counts.active,
        frozenFish = counts.frozen,
        sardineCount = counts.sardine,
        tunaCount = counts.tuna,
        finalBirds = #finalBirds,
        finalSplashes = #finalSplashes,
        getter = getter,
        visitorAvailable = visitorAvailable,
        visitor = visitor,
        worldDigestText = worldText,
        signalDigestText = signalDigestText,
    }
end
"""


def load_lua(source_root: Path):
    lua = helpers._lua(source_root)
    # The A3 baseline only contains Ocean modules; non-Ocean shared modules
    # continue to come from the workspace's scripts tree via helpers._lua.
    lua.execute("package.path = " + json.dumps(source_root.as_posix() + "/?.lua;" + source_root.as_posix() + "/?/init.lua;") + " .. package.path")
    return lua


def as_py(table: Any) -> dict[str, Any]:
    return helpers._lua_value(table)


def run_sample(source_root: Path, seed: int) -> dict[str, Any]:
    lua = load_lua(source_root)
    result = lua.eval(BENCHMARK_LUA)(seed, STEPS, GETTER_LOOPS)
    return as_py(result)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    numeric_paths = [
        ("initCpuSec",), ("updateCpuSec",), ("checkpointGetterCpuSec",),
        ("getter", "cpuSec"),
        ("getter", "preGcAllocationDeltaKiB"), ("getter", "postGcRetainedDeltaKiB"),
        ("runRetainedDeltaKiB",),
    ]
    if samples[0].get("visitor") is not None:
        numeric_paths.extend((
            ("visitor", "cpuSec"),
            ("visitor", "preGcAllocationDeltaKiB"),
            ("visitor", "postGcRetainedDeltaKiB"),
        ))
    result: dict[str, Any] = {"repetitions": len(samples)}
    for path in numeric_paths:
        values = [sample[path[0]] if len(path) == 1 else sample[path[0]][path[1]] for sample in samples]
        result[".".join(path)] = {
            "median": statistics.median(values),
            "min": min(values),
            "max": max(values),
        }
    return result


def main() -> None:
    if not BASELINE_OCEAN.is_dir():
        raise SystemExit(f"A3 baseline missing: {BASELINE_OCEAN}")
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "purpose": "same-seed fixed-route A3 Lua signals before/after benchmark",
        "environment": {
            "nativeFrameRateMeasured": False,
            "engine": "Lupa Lua 5.4 helper from tests/run_circle1_a2.py",
            "route": "normal runtime initialization, departure (0,0), level 1 straight north 120s; signals sampled every 0.25s",
            "steps": STEPS,
            "dtSeconds": 0.05,
            "signalSampleIntervalSteps": SIGNAL_SAMPLE_INTERVAL,
            "getterAndVisitorLoops": GETTER_LOOPS,
            "repetitions": REPETITIONS,
            "sampleOrder": [
                {"repetition": 1, "sources": ["before", "after"]},
                {"repetition": 2, "sources": ["after", "before"]},
                {"repetition": 3, "sources": ["before", "after"]},
            ],
            "seeds": list(SEEDS),
            "population": "normal Config, generated regional population, no signal/fish fixture",
            "memoryMetricNote": "getter/visitor pre-GC delta measures allocation while Lua GC is stopped; post-GC delta is retained heap after full collect; run pre/post values are net heap, not total traffic",
        },
        "baselineRoot": str(BASELINE_OCEAN.relative_to(ROOT)).replace("\\", "/"),
        "sources": {},
    }
    comparisons = {}
    for seed in SEEDS:
        source_roots = {"before": BASELINE_OCEAN, "after": ROOT / "scripts"}
        samples_by_source: dict[str, list[dict[str, Any]]] = {"before": [], "after": []}
        runs_by_source: dict[str, list[dict[str, Any]]] = {"before": [], "after": []}
        sample_order = []
        run_sequence = 0
        for repetition, order in enumerate((
            ("before", "after"),
            ("after", "before"),
            ("before", "after"),
        ), start=1):
            sample_order.append({"repetition": repetition, "sources": list(order)})
            for source_order_index, label in enumerate(order, start=1):
                run_sequence += 1
                sample = run_sample(source_roots[label], seed)
                samples_by_source[label].append(sample)
                runs_by_source[label].append({
                    "repetition": repetition,
                    "sourceOrderIndex": source_order_index,
                    "sequence": run_sequence,
                    "timingsAndMemory": {
                        key: value for key, value in sample.items()
                        if key not in ("worldDigestText", "signalDigestText", "seed", "steps", "route")
                    },
                    "worldSha256": digest(sample["worldDigestText"]),
                    "signalSha256": digest(sample["signalDigestText"]),
                })

        for label in ("before", "after"):
            samples = samples_by_source[label]
            reference = samples[0]
            for repetition, sample in enumerate(samples[1:], start=2):
                if sample["worldDigestText"] != reference["worldDigestText"]:
                    raise AssertionError(f"unstable world digest in {label} seed {seed} repetition {repetition}")
                if sample["signalDigestText"] != reference["signalDigestText"]:
                    raise AssertionError(f"unstable signal digest in {label} seed {seed} repetition {repetition}")
            if reference.get("visitor") is not None:
                if reference["getter"]["birdsVisited"] != reference["visitor"]["birdsVisited"]:
                    raise AssertionError(f"getter/visitor bird counts differ in {label} seed {seed}")
                if reference["getter"]["splashesVisited"] != reference["visitor"]["splashesVisited"]:
                    raise AssertionError(f"getter/visitor splash counts differ in {label} seed {seed}")
            report["sources"].setdefault(label, {})[str(seed)] = {
                "summary": summarize(samples),
                "sampleOrder": sample_order,
                "runs": runs_by_source[label],
                "sample": {
                    key: value for key, value in reference.items()
                    if key not in ("worldDigestText", "signalDigestText")
                },
                "digests": {
                    "worldSha256": digest(reference["worldDigestText"]),
                    "signalSha256": digest(reference["signalDigestText"]),
                },
            }

        before = report["sources"]["before"][str(seed)]
        after = report["sources"]["after"][str(seed)]
        comparisons[str(seed)] = {
            "worldDigestEqual": before["digests"]["worldSha256"] == after["digests"]["worldSha256"],
            "signalDigestEqual": before["digests"]["signalSha256"] == after["digests"]["signalSha256"],
            "beforeFinalSignals": {
                "birds": before["sample"]["finalBirds"], "splashes": before["sample"]["finalSplashes"],
                "sardines": before["sample"]["sardineCount"], "tuna": before["sample"]["tunaCount"],
            },
            "afterFinalSignals": {
                "birds": after["sample"]["finalBirds"], "splashes": after["sample"]["finalSplashes"],
                "sardines": after["sample"]["sardineCount"], "tuna": after["sample"]["tunaCount"],
            },
        }
    report["comparisons"] = comparisons
    report["allWorldDigestsEqual"] = all(item["worldDigestEqual"] for item in comparisons.values())
    report["allSignalDigestsEqual"] = all(item["signalDigestEqual"] for item in comparisons.values())
    report["naturalSplashObserved"] = any(
        item["beforeFinalSignals"]["splashes"] > 0 and item["afterFinalSignals"]["splashes"] > 0
        for item in comparisons.values()
    )
    out_path = OUTPUT / "signals-benchmark.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "report": str(out_path),
        "allWorldDigestsEqual": report["allWorldDigestsEqual"],
        "allSignalDigestsEqual": report["allSignalDigestsEqual"],
        "naturalSplashObserved": report["naturalSplashObserved"],
        "comparisons": report["comparisons"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
