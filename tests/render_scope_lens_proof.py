"""Offline visual proof for the scope-lens water layer (2026-10-19).

Renders SeaDraw.Scene with the scope enabled and fish inside the 90-degree sector,
at 1920x1080, twice: water layer ON (locked A-pack) and OFF (legacy look), so the
two PNGs can be compared side by side. Uses the established NVG recorder from
render_sea_fusion.py; no engine, no network, no package installs.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tmp/sea-test-deps"))
sys.path.insert(0, str(ROOT / "tests"))

from lupa.lua54 import LuaRuntime

_spec = importlib.util.spec_from_file_location("b5_render_recorder", ROOT / "tests/render_sea_fusion.py")
_render = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _render
_spec.loader.exec_module(_render)

OUT_DIR = ROOT / "outputs" / "scope-lens"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def build_runtime(lua, sea_draw):
    return lua.eval(
        """
        function(width, height)
            local Runtime = require('Ocean.SeaRuntime')
            local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
            runtime.time = 8
            runtime.movement:SetViewport(width, height)
            runtime:SetScopeEnabled(true)
            runtime:spawnFish('tuna', { x = 8, y = 6 }, 0)
            runtime:spawnFish('sardine', { x = 10, y = 8 }, 0)
            runtime:spawnFish('sardine', { x = 12, y = 12 }, 0)
            runtime:spawnFish('sardine', { x = 4, y = 3 }, 0)
            return runtime
        end
        """
    )(1920, 1080)


def _module(lua, name):
    # lupa unpack_returned_tuples=True 下 require 返回 tuple，需取首元素
    value = lua.eval('require("%s")' % name)
    return value[0] if isinstance(value, tuple) else value


def main() -> None:
    capture = _render.NVGCapture()
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (
        (ROOT / "scripts/?.lua").as_posix() + ";" + (ROOT / "scripts/?/init.lua").as_posix() + ";"
        + lua.globals().package.path
    )
    recorder = capture.bind(lua)
    ctx = lua.table()
    sea_draw = _module(lua, "Ocean.SeaDraw")
    config = _module(lua, "Ocean.Config")

    runtime = build_runtime(lua, sea_draw)

    for name, enabled in (("on", True), ("off", False)):
        config.visual.scopeLens.enabled = enabled
        capture.reset()
        sea_draw.Scene(ctx, 1920, 1080, runtime)
        png_path = OUT_DIR / f"scope-lens-{name}.png"
        capture.render_png(1920, 1080, png_path, supersample=2)
        print(name, png_path, png_path.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
