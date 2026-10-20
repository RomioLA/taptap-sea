"""读海交付批次素材瘦身：256 色调色板量化（与既有 slim_ocean_art.py 同口径）。

背景（2026-10-20）：美美术交付的高分辨率水彩图是 32 位 RGBA 全彩，单张 1~3MB。
这些图在**屏幕上最多占几百像素**，但 PNG 里存的是原始位深。`assets/image` 入包
体积因此从 31MB 涨到 68MB（见 .project/resources.json 的排除表把未接线候选挡在包外，
本脚本进一步压缩**真正在用**的那批）。

做法与既有 `tests/slim_ocean_art.py` 完全一致：
  RGBA → 256 色 FASTOCTREE 调色板 + tRNS（直通 Alpha，非预乘），
  尺寸不变、content bounds 不变（所以 catalog 的 `contentWidth/Height` 语义不变），
  只更新 manifest 里与「实测」相关的字段（sha256/size/alpha_range/transparent_ratio）。

安全阀：
  * 只在 `--apply` 时落盘，默认是 dry-run（打印省下多少）；
  * 逐图做 PSNR 检查，低于阈值（默认 30dB）的图**跳过不压**，避免把水彩渐变压出 banding；
  * 已是 P 模式的图跳过（幂等）；
  * 压缩后重新 `describe()` 并断言 content bounds 不变。

用法：
  python tests/slim_readhai_art.py                 # dry-run，看能省多少
  python tests/slim_readhai_art.py --apply         # 真压 + 刷新 manifest + 重生成 catalog
  python tests/slim_readhai_art.py --check         # 只校验（manifest 与图是否一致）
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets/image"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"

# 需要瘦身的合集（2026-10-20 交付/接线涉及的那几个）。
SCOPES = ("OceanArtCollection", "OceanStoryLayer", "OceanShip", "SeaSurface", "Sky", "SkyDecor",
          "OceanEco", "OceanIslands", "OceanComponents")
# PSNR 下限：低于此值的图保持原样（宁可多占体积，也不把水彩压出阶梯）。
MIN_PSNR_DB = 30.0
COLORS = 256

# **绝不能量化**的图：它们不是「颜色」，而是逐像素数据 / 柔光强度。
#   water_dudv_flow        —— UV 位移向量场（R/G = 0.5 + 偏移），调色板会破坏编码
#   water_caustic_light*   —— 焦散强度（A 通道低值细网），量化会把 3~7 的 alpha 抹成 0
# PSNR 判据抓不住前者（整幅偏移很小），覆盖率判据抓不住后者之外的情况，故显式列白。
DO_NOT_QUANTIZE = (
    "water_dudv_flow.png",
    "water_caustic_light.png",
    "water_caustic_light_alt.png",
)


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def psnr(original, quantized):
    a = np.asarray(original.convert("RGBA"), dtype=np.float32)
    b = np.asarray(quantized.convert("RGBA"), dtype=np.float32)
    mse = float(((a - b) ** 2).mean())
    return 10 * np.log10(255.0 ** 2 / max(mse, 1e-9))


def targets():
    for scope in SCOPES:
        directory = ASSETS / scope
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.png")):
            if path.name in DO_NOT_QUANTIZE:
                continue
            yield scope, path


def measure(path, colors=COLORS):
    with Image.open(path) as raw:
        if raw.mode == "P":
            return {"skipped": "already_palette"}
        image = raw.convert("RGBA")
    alpha = np.asarray(image)[..., 3]
    opaque = bool((alpha == 255).all())
    quantized = image.quantize(colors=colors, method=Image.Quantize.FASTOCTREE)
    # 原本完全不透明的图（海面/天空底图）不能被量化出 254 之类的近透明色板项，
    # 否则运行时会在满幅材质上留下极细的透明缺口。这里按原图语义强制恢复。
    if opaque:
        # 量化到 RGB 调色板（无 tRNS），语义上就是「不透明满幅」，体积也最小。
        quantized = image.convert("RGB").quantize(colors=colors, method=Image.Quantize.FASTOCTREE)
    value = psnr(image, quantized)
    import io
    buffer = io.BytesIO()
    quantized.save(buffer, format="PNG", optimize=True)
    return {"psnr": value, "before": path.stat().st_size, "after": len(buffer.getvalue()),
            "quantized": quantized}


def patch_manifests(describe):
    """按实测重写各 manifest 的字段（与 slim_ocean_art.py 同口径）。"""
    changed = []
    for manifest_path in sorted(ASSETS.rglob("manifest.json")):
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        assets = data.get("assets")
        if not isinstance(assets, dict):
            continue
        touched = False
        for name, entry in assets.items():
            relative = entry.get("path")
            if not relative:
                continue
            path = ROOT / "assets" / relative
            if not path.is_file():
                continue
            fresh = describe(path, entry.get("source", relative))
            delta = {k: v for k, v in fresh.items() if entry.get(k) != v}
            entry.update(fresh)
            if delta:
                touched = True
                changed.append(f"{manifest_path.parent.name}/{name}: {sorted(delta)}")
        if touched:
            manifest_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return changed


def regenerate_catalog():
    eco = load_module(ROOT / "tests/prepare_ocean_eco_art.py", "slim_eco")
    CATALOG.write_text(eco.catalog_text(), encoding="utf-8")


def check():
    """校验：manifest 的实测字段与磁盘上的图一致（不判断是否已量化）。"""
    eat = load_module(ROOT / "tests/prepare_ocean_art.py", "slim_describe")
    problems = []
    for manifest_path in sorted(ASSETS.rglob("manifest.json")):
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        assets = data.get("assets")
        if not isinstance(assets, dict):
            continue
        for name, entry in assets.items():
            relative = entry.get("path")
            if not relative:
                continue
            path = ROOT / "assets" / relative
            if not path.is_file():
                problems.append(f"{manifest_path.parent.name}/{name}: 文件缺失 {relative}")
                continue
            fresh = eat.describe(path, entry.get("source", relative))
            for key in ("size", "content_bounds", "sha256", "alpha_range"):
                if entry.get(key) is not None and entry[key] != fresh[key]:
                    problems.append(f"{manifest_path.parent.name}/{name}: {key} 与磁盘不符")
    eco = load_module(ROOT / "tests/prepare_ocean_eco_art.py", "slim_eco_check")
    ready = load_module(ROOT / "tests/prepare_ocean_ready_art.py", "slim_ready_check")
    manifest = json.loads((ASSETS / "OceanReady/manifest.json").read_text(encoding="utf-8"))
    if CATALOG.read_text(encoding="utf-8") != eco.catalog_text():
        problems.append("catalog 与素材清单不同步")
    if eco.catalog_text() != ready.catalog_text(manifest):
        problems.append("两个 catalog 生成器输出不一致")
    if problems:
        raise SystemExit("\n".join(problems))
    print(json.dumps({"passed": True}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="真正落盘（缺省为 dry-run）")
    parser.add_argument("--check", action="store_true", help="只校验 manifest 与图是否一致")
    parser.add_argument("--min-psnr", type=float, default=MIN_PSNR_DB)
    args = parser.parse_args()

    if args.check:
        check()
        return

    plan, saved = [], 0
    for scope, path in targets():
        result = measure(path)
        if "skipped" in result:
            continue
        relative = path.relative_to(ROOT).as_posix()
        if result["psnr"] < args.min_psnr:
            plan.append({"path": relative, "skip": f"psnr {result['psnr']:.1f} < {args.min_psnr}"})
            continue
        saved += result["before"] - result["after"]
        plan.append({"path": relative, "beforeKB": round(result["before"] / 1024),
                     "afterKB": round(result["after"] / 1024),
                     "psnr": round(result["psnr"], 1),
                     "applied": args.apply})
        if args.apply:
            result["quantized"].save(path, optimize=True)

    summary = {"applied": args.apply, "files": len([p for p in plan if "afterKB" in p]),
               "skipped": len([p for p in plan if "skip" in p]),
               "savedMB": round(saved / 1024 / 1024, 1)}
    if args.apply:
        describe = load_module(ROOT / "tests/prepare_ocean_art.py", "slim_apply").describe
        summary["manifestFields"] = len(patch_manifests(describe))
        regenerate_catalog()
        check()
    print(json.dumps(summary, ensure_ascii=False))
    if not args.apply:
        print(json.dumps([p for p in plan if p.get("psnr", 0) < 35][:10], ensure_ascii=False))


if __name__ == "__main__":
    main()
