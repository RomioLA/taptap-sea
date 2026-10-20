"""近景海面动态效果资产入库：焦散水彩贴图 + DuDv 向量场 → assets/image/SeaSurface/。

本脚本生成两类素材（纯程序合成，不依赖任何外部源图，可完全重跑）：

1. **caustic（焦散）** —— `water_caustic_light` / `water_caustic_light_alt`
   - 256×256 或 512×512，RGBA，双向无缝（REPEATX|REPEATY 可平铺）；
   - 风格对齐《读海》手绘水彩：低饱和浅青/浅蓝白、柔和的不规则网状光斑、
     无规则圆斑、无硬边、无机械重复；
   - 振幅做成「灰度强度 + alpha」双通道：RGB 为浅青白色（乘法/正常混合都不出错），
     A 为光斑强度。这样无论绘制端用普通混合还是叠加，都只会在原海面上加一点
     浅青白，不会糊成一块白斑；
   - 生成方式是「周期性值噪声 + 脊线（ridge）+ 各向异性拉伸 + 双重平滑」，
     脊线取网，天然形成亮丝网而不是圆点。

2. **dudv（纹理坐标位移场）** —— `water_dudv_flow`
   - 256×256，RGB，双通道编码：`R/G = 0.5 + 偏移量`，中性值 0.5；
   - 采用「散度近似为零」的旋转/卷曲噪声（curl of a periodic potential），
     避免采样偏移把纹理整体推开（那会看起来像贴图在漂移，而不是被扰动）；
   - 编码约定写进 manifest，运行时按 `(rg - 0.5) * 2 * strength` 解码，
     不允许把 RGB 当位移直接使用。

无缝约束（重要）：所有噪声都以整数频率的周期函数合成，因此画面在 u/v 两个方向
天然首尾相接；生成后会做一次接缝一致性断言（首列 vs 末列、首行 vs 末行）。

用法：
  python3 tests/prepare_ocean_water_fx_art.py            # 入库 + 重生成 catalog
  python3 tests/prepare_ocean_water_fx_art.py --check     # 只读校验（尺寸/无缝/清单/catalog）
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/SeaSurface"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"

CAUSTIC_SIZE = 512
DUDV_SIZE = 256

# 名字 -> (尺寸, 生成参数)。两个焦散版本给双层叠加留出「不同节奏」的备选，
# 单层版本默认只用 water_caustic_light。
CAUSTICS = {
    # ridge_power 越大线芯越细；detail_base 越高网眼越小越「圆」。
    # 2026-10-20 离线预览实测：ridge_power 过高 + detail_base 过低会让等值线
    # 退化成又长又直的斜线（放大后像划痕）。现在这一组得到不规则闭合网眼。
    "water_caustic_light": {
        "size": CAUSTIC_SIZE,
        "seed": 11,
        "ridge_power": 16.0,
        "detail_base": 11,
        "warp": 0.30,
        "density_mix": 1.10,
        "gain": 2.6,
    },
    "water_caustic_light_alt": {
        "size": CAUSTIC_SIZE,
        "seed": 63,
        "ridge_power": 14.0,
        "detail_base": 13,
        "warp": 0.28,
        "density_mix": 1.10,
        "gain": 2.6,
    },
}
DUDV = {
    "water_dudv_flow": {
        "size": DUDV_SIZE,
        "seed": 2027,
        "base": 3,
        "curl": 1.0,
    },
}

# 运行期表现：焦散懒加载为 true 的代价是首帧解码尖峰，因此随场景启动预载；
# dudv 只在 ABC 路径使用，保持懒加载（AB 路径不读它）。
PRELOAD = {
    "water_caustic_light": True,
    "water_caustic_light_alt": False,
    "water_dudv_flow": False,
}
REPEAT = True


def importer():
    spec = importlib.util.spec_from_file_location(
        "ocean_art_import", ROOT / "tests/prepare_ocean_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def eco_importer():
    spec = importlib.util.spec_from_file_location(
        "ocean_eco_art", ROOT / "tests/prepare_ocean_eco_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _grid(size):
    """返回 [0,1) 的周期性采样网格（endpoint=False 保证首尾可接）。"""
    axis = np.arange(size, dtype=np.float64) / float(size)
    return np.meshgrid(axis, axis, indexing="xy")


def _box_blur(field, radius):
    """可分离盒式模糊（环绕边界），用于水彩柔边；半径按整数环绕＝保持无缝。"""
    if radius <= 0:
        return field
    out = field
    for axis in (0, 1):
        accumulated = np.zeros_like(out)
        for offset in range(-radius, radius + 1):
            accumulated += np.roll(out, offset, axis=axis)
        out = accumulated / float(radius * 2 + 1)
    return out


# ---------------------------------------------------------------------------
# 可平铺值噪声 / FBM
#
# 不能用「整数频率三角函数求和」：那是规则格纹，同屏会显成机械图案（已实测
# 被否）。这里的 value noise 在整数频率格点上采样、末格与首格共用同一随机值，
# 因此天然双向无缝，且格点随机值携带不规则信息。
# ---------------------------------------------------------------------------
def _value_noise(size, frequency, rng):
    grid = rng.random((frequency, frequency))
    t = np.arange(size, dtype=np.float64) / size * frequency
    index0 = np.floor(t).astype(np.int64) % frequency
    frac = t - np.floor(t)
    index1 = (index0 + 1) % frequency
    smooth = frac * frac * (3.0 - 2.0 * frac)
    a = grid[np.ix_(index0, index0)]
    b = grid[np.ix_(index0, index1)]
    c = grid[np.ix_(index1, index0)]
    d = grid[np.ix_(index1, index1)]
    sx, sy = smooth[None, :], smooth[:, None]
    return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy


def _fbm(size, base_frequency, octaves, rng, persistence=0.5):
    total = np.zeros((size, size), dtype=np.float64)
    amplitude, norm, frequency = 1.0, 0.0, base_frequency
    for _ in range(octaves):
        total += amplitude * _value_noise(size, frequency, rng)
        norm += amplitude
        amplitude *= persistence
        frequency *= 2
    return total / max(norm, 1e-9)


def _sample_wrap(field, u, v):
    """环绕双线性采样：用 UV 偏移重建场，同时保持首尾相接。"""
    size = field.shape[0]
    y = (v % 1.0) * size
    x = (u % 1.0) * size
    y0 = np.floor(y).astype(np.int64) % size
    x0 = np.floor(x).astype(np.int64) % size
    y1 = (y0 + 1) % size
    x1 = (x0 + 1) % size
    fy = y - np.floor(y)
    fx = x - np.floor(x)
    return ((field[y0, x0] * (1 - fx) + field[y0, x1] * fx) * (1 - fy)
            + (field[y1, x0] * (1 - fx) + field[y1, x1] * fx) * fy)


def define_caustic(spec):
    """域扭曲 FBM 的等值线抽取：得到不规则、闭合、可平铺的水彩亮丝网。

    为什么不用「谐波叠加 + 等值线」：那是规则格纹（实测肉眼可见机械重复，
    已被否）。域扭曲（domain warp）让等值线自然弯曲、粗细不一，网眼大小也不
    均匀，才接近手绘焦散；同时 warp 场本身也是可平铺 FBM，不破坏无缝。
    """
    size = spec["size"]
    seed = spec["seed"]
    grid = np.arange(size, dtype=np.float64) / size
    u, v = np.meshgrid(grid, grid)

    base = _fbm(size, 3, 5, np.random.default_rng(seed))
    detail = _fbm(size, spec.get("detail_base", 11), 4, np.random.default_rng(seed + 100))
    warp = spec.get("warp", 0.30)
    warp_u = (_fbm(size, 2, 3, np.random.default_rng(seed + 7)) - 0.5) * warp
    warp_v = (_fbm(size, 2, 3, np.random.default_rng(seed + 29)) - 0.5) * warp

    power = spec["ridge_power"]
    coarse = _sample_wrap(base, u + warp_u, v + warp_v)
    line_coarse = np.clip(1.0 - np.abs(coarse * 2.0 - 1.0), 0.0, 1.0) ** power
    fine = _sample_wrap(detail, u + warp_u * 1.7, v + warp_v * 1.7)
    line_fine = np.clip(1.0 - np.abs(fine * 2.0 - 1.0), 0.0, 1.0) ** (power * 1.7)
    net = line_coarse * 0.64 + line_fine * 0.36

    # 疏密调制：手绘焦散不会整幅一样密，留白本身也是笔触。
    density = _fbm(size, 2, 3, np.random.default_rng(seed + 77))
    net = net * (0.18 + spec["density_mix"] * density)
    net = np.clip(net * spec["gain"], 0.0, 1.0)
    # 水彩柔边：轻微模糊把线芯溶开，形成渗色感（环绕模糊保持无缝）。
    net = np.clip(_box_blur(net, max(1, size // 512)), 0.0, 1.0)
    return net


def build_caustic(spec):
    size = spec["size"]
    net = define_caustic(spec)
    # alpha 为光斑强度；RGB 恒定浅青白，避免 mipmap 采样到透明像素时产生色边。
    alpha = np.clip((net - 0.03) / 0.97, 0.0, 1.0) ** 1.2 * 255.0
    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[..., 0] = 228
    rgba[..., 1] = 245
    rgba[..., 2] = 246
    rgba[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def build_dudv(spec):
    """由可平铺势场的旋转梯度（curl）得到位移场，近似无散度。

    为什么不用直接噪声当位移：有散度的场会把整张焦散整体推开（看起来是贴图
    在漂，不是被扰动）。curl 场只旋转 UV，水滴感才是「局部扭曲」。
    """
    size = spec["size"]
    potential = _fbm(size, spec["base"], 3, np.random.default_rng(spec["seed"]))
    # 离散中心差分 + 环绕索引 → 位移场同样严格可平铺。
    step = 1.0
    dx = (np.roll(potential, -1, axis=1) - np.roll(potential, 1, axis=1)) / (2.0 * step)
    dy = -(np.roll(potential, -1, axis=0) - np.roll(potential, 1, axis=0)) / (2.0 * step)
    peak = max(np.abs(dx).max(), np.abs(dy).max(), 1e-9)
    # 归一化到 ±0.5：编码后正好覆盖 [0,1]，中性值 0.5（字节 128）。
    scale = 0.5 * spec["curl"] / peak
    dx = _box_blur(dx * scale, max(1, size // 64))
    dy = _box_blur(dy * scale, max(1, size // 64))

    red = np.clip((dx + 0.5) * 255.0, 0, 255)
    green = np.clip((dy + 0.5) * 255.0, 0, 255)
    blue = np.full_like(red, 128.0)
    rgb = np.stack([red, green, blue], axis=-1).astype(np.uint8)
    return Image.fromarray(rgb, "RGB")


def seam_step_error(array, axis):
    """接缝处的一步差异（末行/列 → 首行/列）。

    可平铺纹理在首尾之间本来就差一个采样步长，不能用「首尾相等」判定。
    回一个（接缝步长最大值, 内部相邻步长最大值）：接缝只是一条相邻步，
    它的最大跳变不应超过整张纹理内部相邻步长的最大跳变（后者样本量
    是前者的平方量级，是保守上界）。
    """
    values = array.astype(np.int16)
    if axis == 0:
        interior = np.abs(np.diff(values, axis=0))
        seam = np.abs(values[0] - values[-1])
    else:
        interior = np.abs(np.diff(values, axis=1))
        seam = np.abs(values[:, 0] - values[:, -1])
    return float(seam.max()), float(interior.max())


def assert_seamless(array, name):
    for axis, label in ((0, "纵向"), (1, "横向")):
        seam, reference = seam_step_error(array, axis)
        assert seam <= max(reference, 8.0), \
            f"{name} {label}接缝跳变超过内部相邻步长：seam={seam} interiorMax={reference}"


def build_all():
    module = importer()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, spec in CAUSTICS.items():
        image = build_caustic(spec)
        path = OUT / (name + ".png")
        image.save(path, optimize=True)
        entry = module.describe(path, "procedural:" + name)
        entry.update({"preload": PRELOAD[name], "anchor": [0.5, 0.5],
                      "layer": "sea_surface", "status": "ready_wired",
                      "kind": "caustic", "period": "all",
                      "generator": "tests/prepare_ocean_water_fx_art.py"})
        entries[name] = entry
    for name, spec in DUDV.items():
        image = build_dudv(spec)
        path = OUT / (name + ".png")
        image.save(path, optimize=True)
        entry = module.describe(path, "procedural:" + name)
        entry.update({"preload": PRELOAD[name], "anchor": [0.5, 0.5],
                      "layer": "sea_surface", "status": "ready_not_placed",
                      "kind": "dudv", "period": "all",
                      "encoding": {"neutral": 0.5, "channels": ["r", "g"],
                                   "decode": "(rgb - 0.5) * 2 * strength"},
                      "generator": "tests/prepare_ocean_water_fx_art.py"})
        entries[name] = entry
    return entries


def merge_manifest(entries):
    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assets = manifest.get("assets", {})
    for name, entry in entries.items():
        assets[name] = entry
    manifest["assets"] = assets
    # 既有的 sea_surface/ripple 条目保持不变，只补充近景动态层说明。
    manifest["near_water_fx"] = {
        "style": "焦散：低饱和浅青/浅蓝白水彩亮丝网（无圆斑、无硬边）；dudv：周期性卷曲位移场",
        "format": "caustic 为 RGBA（RGB 浅青白 + A 光斑强度，双向无缝可平铺）；"
                  "dudv 为 RGB 双通道位移（R/G = 0.5 + 偏移，中性 0.5）",
        "placement": "SeaViewArt.Surface 近景层（Lua + NanoVG 图片纹理），随船的世界锚点区域，"
                     "区域边缘径向渐隐；dudv 仅在启用 GPU 置换路径时读取",
        "generator": "tests/prepare_ocean_water_fx_art.py",
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
    return manifest


def prepare():
    entries = build_all()
    merge_manifest(entries)
    CATALOG.write_text(eco_importer().catalog_text(), encoding="utf-8")


def check():
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    assets = manifest["assets"]
    expected = set(CAUSTICS) | set(DUDV)
    for name in expected:
        assert name in assets, f"{name} 未写入清单"
        entry = assets[name]
        path = ROOT / "assets" / entry["path"]
        assert path.is_file(), f"{name} 运行目录缺失"
        with Image.open(path) as image:
            mode = "RGBA" if name in CAUSTICS else "RGB"
            assert image.mode == mode, f"{name} 应为 {mode}，实际 {image.mode}"
            array = np.array(image)
        if name in CAUSTICS:
            assert image.size == (CAUSTIC_SIZE, CAUSTIC_SIZE), f"{name} 尺寸不符"
            assert_seamless(array, name)
            alpha = array[..., 3]
            coverage = float((alpha > 8).mean())
            assert 0.02 <= coverage <= 0.75, f"{name} 覆盖度异常 {coverage}"
            rgb = array[..., :3].astype(np.int16)
            chroma = float((rgb.max(axis=-1) - rgb.min(axis=-1)).mean())
            assert chroma <= 48, f"{name} 饱和度过高（chroma={chroma:.1f}）"
        else:
            assert image.size == (DUDV_SIZE, DUDV_SIZE), f"{name} 尺寸不符"
            assert_seamless(array, name)
            red = array[..., 0].astype(float)
            green = array[..., 1].astype(float)
            assert abs(red.mean() - 127.5) < 12, f"{name} R 中性值偏移"
            assert abs(green.mean() - 127.5) < 12, f"{name} G 中性值偏移"
        assert entry["preload"] == PRELOAD[name]
    text = CATALOG.read_text(encoding="utf-8")
    assert text == eco_importer().catalog_text(), "catalog 与素材清单不同步"
    for name in expected:
        assert f"    {name} = {{" in text, f"catalog 缺少 {name}"
    print(json.dumps({"passed": True, "water_fx_assets": len(expected),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()},
                     ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="只读校验清单、PNG、无缝性与 catalog 一致性")
    arguments = parser.parse_args()
    if not arguments.check:
        prepare()
    check()
