"""Run isolated pure Lua suites for Circle 1 review and preserve full evidence."""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
LUPA_ROOT = ROOT / ".tmp" / "circle1-review-runtime"
DEFAULT_OUTPUT_DIR = ROOT / "outputs" / "circle1-review-20261005"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("baseline", "final"), default="baseline")
    parser.add_argument(
        "--suite",
        action="append",
        default=[],
        metavar="PATTERN",
        help="suite filename/stem or wildcard; repeatable, commas also accepted",
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--list-suites", action="store_true")
    return parser.parse_args()


def discover_suites() -> list[dict[str, str]]:
    folder = ROOT / "scripts" / "Tests"
    suites: list[dict[str, str]] = []
    for path in sorted(folder.glob("*Tests.lua"), key=lambda p: p.name.casefold()):
        suites.append({"name": path.stem, "kind": "run", "file": str(path.relative_to(ROOT))})
    for path in sorted(folder.glob("*Spec.lua"), key=lambda p: p.name.casefold()):
        suites.append({"name": path.stem, "kind": "spec", "file": str(path.relative_to(ROOT))})
    return suites


def normalize_patterns(raw: list[str]) -> list[str]:
    patterns = [piece.strip() for value in raw for piece in value.split(",") if piece.strip()]
    return [pattern.casefold() for pattern in patterns]


def select_suites(suites: list[dict[str, str]], patterns: list[str]) -> list[dict[str, str]]:
    if not patterns:
        return suites
    selected = []
    unknown = []
    for pattern in patterns:
        normalized = pattern.removesuffix(".lua")
        matches = [
            suite
            for suite in suites
            if fnmatch.fnmatchcase(suite["name"].casefold(), normalized)
            or fnmatch.fnmatchcase(suite["file"].casefold(), pattern)
        ]
        if not matches:
            unknown.append(pattern)
        for suite in matches:
            if suite not in selected:
                selected.append(suite)
    if unknown:
        known = ", ".join(suite["name"] for suite in suites)
        raise ValueError(f"unknown suite selector(s): {', '.join(unknown)}; available: {known}")
    return sorted(selected, key=lambda suite: suite["name"].casefold())


def to_json_value(value: Any, lua_type: Any, seen: set[int] | None = None) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, tuple):
        return [to_json_value(item, lua_type, seen) for item in value]
    if lua_type(value) == "table":
        seen = seen or set()
        identity = id(value)
        if identity in seen:
            return "<cycle>"
        seen.add(identity)
        entries = list(value.items())
        if all(isinstance(key, int) and key >= 1 for key, _ in entries):
            entries.sort(key=lambda pair: pair[0])
            if [key for key, _ in entries] == list(range(1, len(entries) + 1)):
                result: Any = [to_json_value(item, lua_type, seen) for _, item in entries]
            else:
                result = {str(key): to_json_value(item, lua_type, seen) for key, item in entries}
        else:
            result = {str(key): to_json_value(item, lua_type, seen) for key, item in entries}
        seen.remove(identity)
        return result
    return f"<{lua_type(value) or type(value).__name__}: {str(value)[:300]}>"


def summarize_returned_result(value: Any) -> tuple[bool, int, list[Any]]:
    if isinstance(value, dict):
        raw_results = value.get("results", value.get("tests"))
        subtests = raw_results if isinstance(raw_results, list) else []
        failed = [item for item in subtests if isinstance(item, dict) and item.get("passed") is False]
        if value.get("passed") is False or value.get("status") in ("FAIL", "ERROR"):
            failed.append({
                "passed": False,
                "name": value.get("error") or "suite returned a failing status",
            })
        count = len(subtests)
        if not count and isinstance(value.get("total"), (int, float)):
            count = int(value["total"])
        return not failed, count, failed
    if value is False:
        return False, 0, [{"passed": False, "name": "suite returned false"}]
    return True, 0, []


def load_recorder_module():
    source = ROOT / "tests" / "render_sea_fusion.py"
    spec = importlib.util.spec_from_file_location("circle1_review_nvg_capture", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load NVGCapture from {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    return module


def prepare_runtime():
    sys.path.insert(0, str(LUPA_ROOT))
    try:
        from lupa.lua54 import LuaRuntime, lua_type  # type: ignore[import-not-found]
    except Exception as error:
        raise RuntimeError(
            f"Unable to load Lupa Lua 5.4 from {LUPA_ROOT}: "
            f"{type(error).__name__}: {error}"
        ) from error
    return LuaRuntime, lua_type, load_recorder_module()


def bind_recorder(lua: Any, recorder: Any, recorder_table: Any, capture_module: Any) -> None:
    alpha = [1.0]
    alpha_stack: list[float] = []

    def transform(ctx, a, b, c, d, e, f):
        matrix = tuple(float(value) for value in (a, b, c, d, e, f))
        recorder._call("nvgTransform", ctx, *matrix)
        recorder._multiply(matrix)

    def radial_gradient(ctx, x, y, inner_radius, outer_radius, inner_color, outer_color):
        recorder._call("nvgRadialGradient", ctx, x, y, inner_radius, outer_radius)
        center_x, center_y = recorder._point(recorder.transform, float(x), float(y))
        return capture_module.LinearGradient(
            center_x,
            center_y,
            center_x + float(outer_radius),
            center_y,
            capture_module._as_color(inner_color),
            capture_module._as_color(outer_color),
        )

    def intersect_scissor(ctx, x, y, width, height):
        recorder._call("nvgIntersectScissor", ctx, x, y, width, height)
        points = [
            recorder._point(recorder.transform, float(x), float(y)),
            recorder._point(recorder.transform, float(x + width), float(y)),
            recorder._point(recorder.transform, float(x + width), float(y + height)),
            recorder._point(recorder.transform, float(x), float(y + height)),
        ]
        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        new_clip = (min(xs), min(ys), max(xs), max(ys))
        if recorder.clip:
            old = recorder.clip
            new_clip = (
                max(old[0], new_clip[0]),
                max(old[1], new_clip[1]),
                min(old[2], new_clip[2]),
                min(old[3], new_clip[3]),
            )
        recorder.clip = new_clip

    def global_alpha(ctx, value):
        recorder._call("nvgGlobalAlpha", ctx, value)
        alpha[0] = max(0.0, min(1.0, float(value)))
        return alpha[0]

    def save(ctx):
        alpha_stack.append(alpha[0])
        recorder.save(ctx)

    def restore(ctx):
        recorder.restore(ctx)
        alpha[0] = alpha_stack.pop() if alpha_stack else 1.0

    def has_green_fill_above_y(limit):
        for element in recorder.elements:
            color = element["fill_color"]
            if color is None or not (color.g > color.r and color.g > color.b):
                continue
            for _, coordinates in element["path"]:
                if any(coordinates[index] < float(limit) for index in range(1, len(coordinates), 2)):
                    return True
        return False

    globals_ = lua.globals()
    globals_.__nvgRecorder = recorder_table
    globals_.__nvgContext = lua.table()
    globals_.nvgTransform = transform
    globals_.nvgRadialGradient = radial_gradient
    globals_.nvgIntersectScissor = intersect_scissor
    globals_.nvgGlobalAlpha = global_alpha
    globals_.nvgSave = save
    globals_.nvgRestore = restore
    recorder_table["globalAlpha"] = lambda: alpha[0]
    recorder_table["hasGreenFillAboveY"] = has_green_fill_above_y


def run_one(
    suite: dict[str, str], LuaRuntime: Any, lua_type: Any, capture_module: Any
) -> dict[str, Any]:
    started = time.perf_counter()
    captured: list[str] = []
    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
    lua.globals().print = lambda *args: captured.append("\t".join(str(arg) for arg in args))
    scripts = (ROOT / "scripts").as_posix()
    # 引擎库位于仓库根的 urhox-libs/（被 .gitignore 排除，不进 scripts/）；
    # Circle1HUDReviewTests 需要 require("urhox-libs/UI/Core/Transition")，
    # 模块名自带 urhox-libs 前缀，因此把仓库根加入搜索路径。
    lua.globals().package.path = (
        f"{scripts}/?.lua;{scripts}/?/init.lua;{ROOT.as_posix()}/?.lua;{ROOT.as_posix()}/?/init.lua;"
        + lua.globals().package.path
    )
    recorder_capture = capture_module.NVGCapture()
    recorder_table = recorder_capture.bind(lua)
    bind_recorder(lua, recorder_capture, recorder_table, capture_module)
    outcome: dict[str, Any] = {
        "name": suite["name"],
        "kind": suite["kind"],
        "file": suite["file"],
        "passed": False,
        "subtestCount": 0,
        "failures": [],
    }
    try:
        if suite["kind"] == "run":
            module_name = f"tests.{suite['name']}"
            module = lua.eval("function(name) local value = require(name); return value end")(
                module_name
            )
            run = module["Run"] if lua_type(module) == "table" else None
            if run is None:
                raise RuntimeError("required module did not expose a Run function")
            if suite["name"] == "Circle1B3CloudTests":
                returned = lua.eval(
                    'function(name) local m=require(name); '
                    'return m.Run(require("Gameplay.Persistence")) end'
                )(module_name)
            else:
                returned = run(recorder_table)
            converted = to_json_value(returned, lua_type)
            outcome["returned"] = converted
            passed, count, failures = summarize_returned_result(converted)
            outcome["passed"] = passed
            outcome["subtestCount"] = count
            outcome["failures"] = failures
        else:
            source = (ROOT / suite["file"]).read_text(encoding="utf-8-sig")
            lua.execute(source)
            outcome["passed"] = True
            outcome["subtestCount"] = sum(
                1 for line in captured if line.lstrip().startswith("PASS ")
            )
    except Exception as error:
        outcome["passed"] = False
        outcome["error"] = f"{type(error).__name__}: {error}"
        outcome["traceback"] = traceback.format_exc()
    outcome["stdout"] = "\n".join(captured)
    outcome["nvgCalls"] = dict(sorted(recorder_capture.counts.items()))
    outcome["nvgCallTotal"] = sum(recorder_capture.counts.values())
    outcome["durationMs"] = round((time.perf_counter() - started) * 1000, 3)
    return outcome


def render_report(result: dict[str, Any]) -> str:
    suites = result["suites"]
    passing = sum(1 for suite in suites if suite["passed"])
    subtests = sum(suite["subtestCount"] for suite in suites)
    lines = [
        f"# Circle 1 review {result['phase']}",
        "",
        f"- Lua: {result.get('luaVersion', 'unavailable')}",
        f"- Suites: {passing}/{len(suites)} passed; reported subtests: {subtests}",
        f"- Generated: {result['generatedAt']}",
    ]
    failed = [suite for suite in suites if not suite["passed"]]
    if failed:
        lines.extend(["", "## Failures"])
        for suite in failed:
            lines.append(f"- `{suite['name']}` ({suite['file']})")
            reason = suite.get("error")
            if not reason and suite.get("failures"):
                reason = json.dumps(suite["failures"], ensure_ascii=False)
            if reason:
                lines.append(f"  - {reason}")
    else:
        lines.extend(["", "All selected suites passed."])
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    suites = discover_suites()
    if args.list_suites:
        for suite in suites:
            print(f"{suite['name']}\t{suite['kind']}\t{suite['file']}")
        return 0
    try:
        suites = select_suites(suites, normalize_patterns(args.suite))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    result: dict[str, Any] = {
        "phase": args.phase,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "project": str(ROOT),
        "runtimePath": str(LUPA_ROOT),
        "suiteCount": len(suites),
        "suites": [],
    }
    try:
        LuaRuntime, lua_type, capture_module = prepare_runtime()
        probe = LuaRuntime(encoding="utf-8")
        result["luaVersion"] = probe.eval("_VERSION")
        for suite in suites:
            item = run_one(suite, LuaRuntime, lua_type, capture_module)
            result["suites"].append(item)
            state = "PASS" if item["passed"] else "FAIL"
            print(f"{state} {item['name']} ({item['subtestCount']} reported checks)")
    except Exception as error:
        result["setupError"] = f"{type(error).__name__}: {error}"
        result["setupTraceback"] = traceback.format_exc()
        print(result["setupError"], file=sys.stderr)
    result["passedSuiteCount"] = sum(1 for suite in result["suites"] if suite["passed"])
    result["failedSuiteCount"] = len(result["suites"]) - result["passedSuiteCount"]
    result["passed"] = (
        "setupError" not in result
        and result["suiteCount"] == len(result["suites"])
        and result["failedSuiteCount"] == 0
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.output_dir / f"{args.phase}.json"
    report_path = args.output_dir / f"{args.phase}.md"
    json_path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report_path.write_text(render_report(result), encoding="utf-8")
    print(f"RESULT {result['passedSuiteCount']}/{result['suiteCount']} suites passed; JSON {json_path}")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
