"""Capture six real SeaDraw.Scene clock states as offline visual evidence."""
from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
for dependency in (ROOT / ".tmp/game-loop-test-runtime", ROOT / "outputs/seven-days-cycle/deps"):
    sys.path.insert(0, str(dependency))

spec = importlib.util.spec_from_file_location("sea_fusion_capture", ROOT / "tests/render_sea_fusion.py")
if spec is None or spec.loader is None:
    raise RuntimeError("could not load the existing NanoVG capture helpers")
capture_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = capture_module
spec.loader.exec_module(capture_module)

from lupa.lua54 import LuaRuntime
from PIL import Image, ImageDraw, ImageFont


def main() -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence_root = ROOT / "outputs/seven-days-cycle/evidence"
    output = evidence_root / f"day-night-cycle-{stamp}-{time.time_ns()}"
    output.mkdir(parents=True, exist_ok=False)

    width, height = 640, 360
    capture = capture_module.NVGCapture()
    lua = capture_module._new_lua()
    recorder = capture.bind(lua)
    lua.globals().__nvgRecorder = recorder
    ctx = lua.table()
    clock_module = capture_module._module(lua, "Gameplay.GameClock")
    sea_draw = capture_module._module(lua, "Ocean.SeaDraw")
    preview_tests = capture_module._module(lua, "tests.SeaFusionRenderTests")
    clock = clock_module.New()
    set_phase = lua.eval("function(clock, phase, elapsed) clock:Seek(phase, elapsed); return clock:GetState() end")

    panels: list[tuple[str, Image.Image]] = []
    frame_rows = []
    for phase in ("day", "night"):
        duration = float(clock.daySec if phase == "day" else clock.nightSec)
        for progress in (0.12, 0.5, 0.88):
            state = set_phase(clock, phase, duration * progress)
            runtime = preview_tests.CreatePreviewRuntime(width, height)
            capture.reset()
            sea_draw.Scene(ctx, width, height, runtime, state)
            stem = f"{phase}-{round(progress * 100):02d}pct"
            image_path = output / f"{stem}.png"
            capture.render_png(width, height, image_path, supersample=2)
            panels.append((f"{phase.upper()}  {progress:.0%}", Image.open(image_path).convert("RGB")))
            frame_rows.append({
                "name": stem,
                "phase": phase,
                "progress": float(state["progress"]),
                "duration": float(state["duration"]),
                "png": image_path.name,
                "recordedElements": len(capture.elements),
                "nanoVGCalls": int(sum(capture.counts.values())),
            })

    padding, label_height = 10, 28
    columns, rows = 3, 2
    sheet = Image.new("RGB", (columns * width, rows * (height + label_height)), (18, 30, 42))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    for index, (label, panel) in enumerate(panels):
        x = (index % columns) * width
        y = (index // columns) * (height + label_height)
        draw.text((x + padding, y + 5), label, fill=(236, 242, 246), font=font)
        sheet.paste(panel, (x, y + label_height))

    contact_path = output / "day-night-cycle-contact-sheet.png"
    sheet.save(contact_path, format="PNG", optimize=True)
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps({
        "evidenceKind": "offline_lua54_nanovg_capture",
        "engineScreenshot": False,
        "scene": "SeaDraw.Scene",
        "panelSize": {"width": width, "height": height},
        "contactSheetSize": {"width": sheet.width, "height": sheet.height},
        "frames": frame_rows,
        "contactSheet": contact_path.name,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"contactSheet": str(contact_path), "manifest": str(manifest_path),
                      "frames": frame_rows}, ensure_ascii=False))


if __name__ == "__main__":
    main()
