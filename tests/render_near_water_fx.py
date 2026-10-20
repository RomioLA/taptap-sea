"""近景海面动态层离线渲染证据（不是引擎截图）。

做法：用真实 Lua 模块（Ocean.WaterFX / Ocean.Projection / Ocean.Config）跑一遍
WaterFX.Draw，录制每次 nvgTransform + 路径顶点 + imagePattern(image, alpha)，
然后在 Python 侧按「屏幕像素 → 逆变换 → 纹理 UV → 环绕采样 PNG」逐像素合成。
这与 NanoVG 图片填充的数学一致，因此可以用来判断焦散位置、尺度、边缘渐隐、
DuDv 位移是否真的作用在 UV 上。

输出：outputs/near-water-fx/preview-<name>.png（叠在真实海面底图上）
限制：offline math only；不代表 Maker 引擎 GPU 输出，也不代表真机观感/帧率。
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tmp" / "sea-test-deps"))
sys.dont_write_bytecode = True

from lupa.lua54 import LuaRuntime  # noqa: E402

OUT = ROOT / "outputs" / "near-water-fx"
ASSETS = ROOT / "assets"
WIDTH, HEIGHT = 960, 540


class Capture:
    """录制 WaterFX 的绘制调用。"""

    def __init__(self):
        self.image_paths = {}
        self.tiles = []
        self.path = []
        self.transform = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
        self.stack = []
        self.drawn = []

    # ---- NanoVG 子集 ----
    def nvgCreateImage(self, ctx, path, flags):
        handle = len(self.image_paths) + 1
        self.image_paths[handle] = path
        return handle

    def nvgDeleteImage(self, ctx, image):
        pass

    def nvgSave(self, ctx):
        self.stack.append(self.transform)

    def nvgRestore(self, ctx):
        self.transform = self.stack.pop()

    def nvgTransform(self, ctx, a, b, c, d, e, f):
        # 与 NanoVG 一致：新变换左乘（先应用自身，再应用已有）
        pa, pb, pc, pd, pe, pf = self.transform
        self.transform = (
            a * pa + b * pc, a * pb + b * pd,
            c * pa + d * pc, c * pb + d * pd,
            e * pa + f * pc + pe, e * pb + f * pd + pf,
        )

    def nvgBeginPath(self, ctx):
        self.path = []

    def _point(self, x, y):
        a, b, c, d, e, f = self.transform
        return a * x + c * y + e, b * x + d * y + f

    def nvgMoveTo(self, ctx, x, y):
        self.path.append(self._point(x, y))

    def nvgLineTo(self, ctx, x, y):
        self.path.append(self._point(x, y))

    def nvgClosePath(self, ctx):
        pass

    def nvgShapeAntiAlias(self, ctx, enabled):
        pass

    def nvgImagePattern(self, ctx, ox, oy, ex, ey, angle, image, alpha):
        return {"image": image, "alpha": alpha}

    def nvgFillPaint(self, ctx, paint):
        self.pending = paint

    def nvgFill(self, ctx):
        paint = getattr(self, "pending", None)
        if paint and self.path:
            self.drawn.append({
                "image": paint["image"],
                "alpha": float(paint["alpha"]),
                "matrix": tuple(float(v) for v in self.transform),
                "points": list(self.path),
            })
        self.path = []

    def bind(self, lua):
        g = lua.globals()
        # lupa 把 Python 可调用对象暴露为 userdata，而 ImageArt 用 type(f)=="function"
        # 做接口探测；因此在这里用 Lua 闭包重新包一层，让 harness 与被测代码的
        # 类型契约一致（引擎里这些本来就是 Lua function）。
        for name in ("nvgCreateImage", "nvgDeleteImage", "nvgSave", "nvgRestore",
                     "nvgTransform", "nvgBeginPath", "nvgMoveTo", "nvgLineTo",
                     "nvgClosePath", "nvgShapeAntiAlias", "nvgImagePattern",
                     "nvgFillPaint", "nvgFill"):
            g.__setitem__("__py_" + name, getattr(self, name))
            lua.execute(f"function {name}(...) return __py_{name}(...) end")
        g.__setitem__("NVG_IMAGE_GENERATE_MIPMAPS", 1)
        g.__setitem__("NVG_IMAGE_REPEATX", 2)
        g.__setitem__("NVG_IMAGE_REPEATY", 4)
        g.__setitem__("nvgRGBA", lambda r, gg, b, a=255: (r, gg, b, a))


class Sampler:
    """按 NanoVG 图片填充的逆映射采样（REPEAT 环绕）。"""

    def __init__(self, tiles, image_paths):
        self.tiles = tiles
        self.cache = {}
        self.image_paths = image_paths

    def texture(self, handle):
        if handle in self.cache:
            return self.cache[handle]
        path = ASSETS / self.image_paths[handle]
        image = Image.open(path).convert("RGBA")
        array = np.asarray(image, dtype=np.float32) / 255.0
        self.cache[handle] = array
        return array

    def render(self, size):
        width, height = size
        canvas = np.zeros((height, width, 4), dtype=np.float32)
        yy, xx = np.mgrid[0:height, 0:width].astype(np.float64)
        for tile in self.tiles:
            a, b, c, d, e, f = tile["matrix"]
            det = a * d - b * c
            if abs(det) < 1e-12:
                continue
            # 屏幕 → 纹理空间（逆变换）
            inv = (d / det, -b / det, -c / det, a / det,
                   (c * f - d * e) / det, (b * e - a * f) / det)
            u = inv[0] * xx + inv[2] * yy + inv[4]
            v = inv[1] * xx + inv[3] * yy + inv[5]
            # 覆盖判定：路径顶点已经是屏幕空间（move_to 已应用 nvgTransform），
            # 所以用屏幕坐标 (xx, yy) 做内点测试。屏幕 y 向下，三角形环绕方向
            # 随仿射符号变化，因此先按有符号面积定出内侧符号。
            # 共享对角线要做半开处理（首边严格 >0），否则相邻两个三角形各盖
            # 一次边界像素 → 预览里出现细斜线（引擎关 AA 时不会双盖，但预览
            # 必须与之一致才能用于判断接缝）。
            points = np.array(tile["points"], dtype=np.float64)
            count = len(points)
            area = 0.0
            for index in range(count):
                x0, y0 = points[index]
                x1, y1 = points[(index + 1) % count]
                area += x0 * y1 - x1 * y0
            sign = 1.0 if area >= 0 else -1.0
            inside = np.ones((height, width), dtype=bool)
            for index in range(count):
                x0, y0 = points[index]
                x1, y1 = points[(index + 1) % count]
                edge = sign * ((x1 - x0) * (yy - y0) - (y1 - y0) * (xx - x0))
                inside &= edge > 1e-9 if index == 0 else edge >= 0.0
            if not inside.any():
                continue
            texture = self.texture(tile["image"])
            th, tw = texture.shape[:2]
            # REPEAT 环绕
            tx = np.mod(u, 1.0) * (tw - 1)
            ty = np.mod(v, 1.0) * (th - 1)
            x0 = np.clip(tx.astype(np.int64), 0, tw - 1)
            y0 = np.clip(ty.astype(np.int64), 0, th - 1)
            sample = texture[y0, x0]
            alpha = sample[..., 3] * tile["alpha"] * inside
            source = sample[..., :3]
            # 直通 alpha 合成（source-over）：canvas 存的是非预乘颜色，
            # 不能直接 rgb*alpha 累加，否则最终合成时会被乘两次 alpha 变黑。
            dest_alpha = canvas[..., 3]
            out_alpha = alpha + dest_alpha * (1 - alpha)
            safe = np.where(out_alpha > 1e-6, out_alpha, 1.0)
            for channel in range(3):
                canvas[..., channel] = (
                    source[..., channel] * alpha
                    + canvas[..., channel] * dest_alpha * (1 - alpha)
                ) / safe
            canvas[..., 3] = out_alpha
        return canvas


def build_lua(capture: Capture) -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = str(ROOT / "scripts" / "?.lua") + ";" + lua.globals().package.path
    capture.bind(lua)
    lua.globals().print = lambda *args: None
    return lua


def lua_literal(value) -> str:
    """JSON → Lua 表字面量（JSON 的 quoted key 在 Lua 里是语法错误）。"""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, dict):
        return "{" + ",".join(f"[{json.dumps(str(k))}]={lua_literal(v)}" for k, v in value.items()) + "}"
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(lua_literal(v) for v in value) + "}"
    raise TypeError(type(value))


class ImageStub:
    """模拟引擎 Image 资源：提供 GetPixelBilinear 的 CPU 像素访问。

    真实环境里 WaterFX.ResolveSampler 走 cache:GetResource("Image", path)；
    headless 没有引擎，所以这里用同一张 PNG 真实像素搭一个等价对象，
    让预览的 DuDv 位移来自真数据而不是伪造值。
    """

    def __init__(self, path: Path):
        self.array = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255.0
        self.height, self.width = self.array.shape[:2]

    def GetWidth(self):
        return self.width

    def GetHeight(self):
        return self.height

    def GetPixelBilinear(self, x, y):
        px = int(round(float(x))) % self.width
        py = int(round(float(y))) % self.height
        r, g, b, a = self.array[py, px]
        return {"r": float(r), "g": float(g), "b": float(b), "a": float(a)}


def install_cache(lua):
    """装一个最小 cache 全局：GetResource("Image", path) → ImageStub。"""
    stubs = {}

    def stub_for(path):
        if path not in stubs:
            stubs[path] = ImageStub(ASSETS / path)
        return stubs[path]

    lua.globals()["__py_get_pixel"] = lambda path, x, y: stub_for(path).GetPixelBilinear(x, y)
    lua.globals()["__py_size"] = lambda path: (stub_for(path).GetWidth(), stub_for(path).GetHeight())
    lua.execute('''
        cache = {
            GetResource = function(self, kind, path)
                local width, height = __py_size(path)
                return {
                    GetWidth = function() return width end,
                    GetHeight = function() return height end,
                    GetPixelBilinear = function(_, x, y) return __py_get_pixel(path, x, y) end,
                }
            end,
        }
    ''')


def render(name: str, clock_phase: str, time: float, camera_x: float = 0.0,
           overrides: dict | None = None, size=(WIDTH, HEIGHT)):
    capture = Capture()
    lua = build_lua(capture)
    install_cache(lua)
    lua.globals()["__py_log"] = lambda *args: None
    lua.execute(f'''
        local Config = require("Ocean.Config")
        local WaterFX = require("Ocean.WaterFX")
        Config.visual.nearWaterFX.enabled = true
        local overrides = {lua_literal(overrides or {})}
        for key, value in pairs(overrides) do
            Config.visual.nearWaterFX[key] = value
        end
        local cameraX = {camera_x}
        local movement = {{
            viewportWidth = {size[0]}, viewportHeight = {size[1]},
            viewportReady = true,
            viewHeight = Config.camera.viewHeight,
            camera = {{ x = cameraX, y = 0 }},
            ship = {{ position = {{ x = cameraX, y = 0 }} }},
        }}
        function movement:WorldToScreen(position, altitude)
            return require("Ocean.Projection").Project(self, position, altitude)
        end
        function movement:GetHorizonY(x)
            return require("Ocean.Projection").Horizon(self, x)
        end
        result = {{}}
        local drew, stats = WaterFX.Draw({{}}, movement, nil, {time},
            {{ phase = "{clock_phase}", progress = 0.5 }})
        result.drew = drew
        result.tiles = stats and stats.tiles or 0
        result.alpha = stats and stats.alpha or 0
        result.dudv = stats and stats.dudv or false
        result.columns = stats and stats.columns or 0
    ''')
    result = lua.globals().result
    return capture, {
        "drew": bool(result["drew"]),
        "tiles": int(result["tiles"]),
        "alpha": float(result["alpha"]),
        "dudv": bool(result["dudv"]),
        "columns": int(result["columns"]),
    }, name


def composite(base_path: Path, layer: np.ndarray) -> Image.Image:
    base = Image.open(base_path).convert("RGBA").resize((layer.shape[1], layer.shape[0]))
    base_array = np.asarray(base, dtype=np.float32) / 255.0
    alpha = layer[..., 3:4]
    out = layer[..., :3] * alpha + base_array[..., :3] * (1 - alpha)
    return Image.fromarray(np.clip(out * 255, 0, 255).astype(np.uint8), "RGB")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sea = ASSETS / "image/SeaSurface/sea_surface_day.png"
    report = {"task": "near-water fx offline composite evidence",
              "engineVisualAcceptance": "NOT RUN",
              "note": "Lua math + NanoVG-equivalent rasterisation; not a device screenshot",
              "cases": []}
    cases = [
        ("day-ship-center", "day", 12.0, 0.0, {}),
        ("night-ship-center", "night", 12.0, 0.0, {}),
        ("day-two-layer", "day", 12.0, 0.0, {"secondLayer": True}),
        ("day-dudv-off", "day", 12.0, 0.0, {"dudvEnabled": False}),
        ("day-caustic-strong", "day", 12.0, 0.0, {"alpha": 0.3, "edgeJitter": 0.0}),
    ]
    for name, phase, time, camera_x, overrides in cases:
        capture, stats, _ = render(name, phase, time, camera_x, overrides)
        layer = Sampler(capture.drawn, capture.image_paths).render((WIDTH, HEIGHT))
        composite(sea, layer).save(OUT / f"preview-{name}.png")
        report["cases"].append({"case": name, **stats,
                                "fills": len(capture.drawn)})
        print(name, stats, "fills", len(capture.drawn))
    (OUT / "preview-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
