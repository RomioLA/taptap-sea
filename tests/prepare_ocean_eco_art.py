"""生态层组件 v2（OceanEco）入库：去底量化成稿 → assets/image/OceanEco/ + manifest + catalog 重生成。

素材来源：E:/workbath/Fishing/_gen_eco_v2/final/（miora 生成 + .tmp/eco_v2_process.py 去底量化）。
鱼/海鸟水平翻转：生成侧头朝左，翻转为头朝右（+X），与 ImageArt.Plane 的 heading 语义对齐
（u=1 边缘映射到 +heading 方向）；木桶俯视径向对称，不翻转。
帧对齐契约：保持 1024x1024 画布不裁剪，f1/f2/f3 同坐标系，动画不抖动。

用法：
  python3 tests/prepare_ocean_eco_art.py          # 入库并重生成 catalog
  python3 tests/prepare_ocean_eco_art.py --check   # 只读校验（含源图 sha256）
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/OceanEco"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
SELECTION = ROOT / "docs/art-runtime-selection.json"
WAVE2_OUT = ROOT / "assets/image/OceanWave2"
SOURCE_DIR = Path("E:/workbath/Fishing/_gen_eco_v2/final")
# 基础名 -> 是否需要水平翻转（头朝左 -> 头朝右）
FRAMES = {
    "eco_fish_small": True,
    "eco_fish_big": True,
    "eco_bird": True,
    "eco_barrel": False,
}
FRAME_COUNT = 3


def importer():
    spec = importlib.util.spec_from_file_location("ocean_art_import", ROOT / "tests/prepare_ocean_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def catalog_text():
    loop = json.loads((ROOT / "assets/image/OceanLoop/manifest.json").read_text(encoding="utf-8"))
    ready = json.loads((ROOT / "assets/image/OceanReady/manifest.json").read_text(encoding="utf-8"))
    story = json.loads((ROOT / "assets/image/OceanStoryLayer/manifest.json").read_text(encoding="utf-8"))
    decor = json.loads((ROOT / "assets/image/OceanDecor/manifest.json").read_text(encoding="utf-8"))
    components = json.loads((ROOT / "assets/image/OceanComponents/manifest.json").read_text(encoding="utf-8"))
    islands = json.loads((ROOT / "assets/image/OceanIslands/manifest.json").read_text(encoding="utf-8"))
    eco = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    # SeaSurface（纯海面 v2，2026-10-17）：屏幕空间材质层，由 tests/prepare_ocean_sea_art.py 入库；
    # 清单缺失时按空合集处理（尚未入库的旧工作区可直接跑本脚本的 eco 部分）。
    sea_manifest = ROOT / "assets/image/SeaSurface/manifest.json"
    sea = json.loads(sea_manifest.read_text(encoding="utf-8")) if sea_manifest.exists() else {"assets": {}}
    # Sky（2026-10-18 读海美术接入）：屏幕空间满幅天空贴图；清单缺失时按空合集处理。
    sky_manifest = ROOT / "assets/image/Sky/manifest.json"
    sky = json.loads(sky_manifest.read_text(encoding="utf-8")) if sky_manifest.exists() else {"assets": {}}
    # SkyDecor（2026-10-19 日月云贴图）：屏幕空间装饰层；清单缺失时按空合集处理。
    skydecor_manifest = ROOT / "assets/image/SkyDecor/manifest.json"
    skydecor = json.loads(skydecor_manifest.read_text(encoding="utf-8")) if skydecor_manifest.exists() else {"assets": {}}
    # OceanArtCollection（2026-10-20 用户供的 V2.8 美术合集）：V2.8 固定海上节点从
    # 矢量占位升级为正式素材（debris/shipwreck/bones/vortex/bottle）+ 物品图标。
    # 规格由 tests/prepare_ocean_art_collection.py 生成 manifest；清单缺失时按空合集处理。
    art_manifest = ROOT / "assets/image/OceanArtCollection/manifest.json"
    art = json.loads(art_manifest.read_text(encoding="utf-8")) if art_manifest.exists() else {"assets": {}}
    entries = {}
    # eco/SeaSurface 合集按条目自带 preload（per-entry，如 sea_surface_day/dusk=true、
    # night=false），其余合集沿用既有默认；与 prepare_ocean_ready_art.py 的 catalog_text
    # 保持同构（单一生成器原则：两处输出必须字节一致，任一 --check 才能互证）。
    # OceanIslands（2026-10-18 六座新岛）：世界内走矢量变体绘制，贴图 preload=false 备用。
    for collection, preload, per_entry in ((loop["assets"], True, False), (ready["assets"], False, False),
                                           (story["assets"], False, False), (decor["assets"], False, False),
                                           (components["assets"], False, False), (islands["assets"], False, False),
                                           (eco["assets"], False, True),
                                           (sea["assets"], False, True),
                                           (sky["assets"], False, True),
                                           (skydecor["assets"], False, True),
                                           (art["assets"], False, False)):
        for name, entry in collection.items():
            entries[name] = {**entry, "preload": entry.get("preload", preload) if per_entry else preload}
    selected = json.loads((WAVE2_OUT / "manifest.json").read_text(encoding="utf-8"))["assets"] \
        if SELECTION.exists() else {}
    # Keep the current main-branch art decisions: the boat is vector-drawn, and
    # the island remains a layered base/decor composition. W2 files stay in the
    # candidate manifest and are still validated, but these two do not replace
    # their runtime catalog entries.
    for name, entry in selected.items():
        if name not in ("boat", "island"):
            entries[name] = entry
    repeat_names = ("waterpaper", "waterpaper_story", "ocean_tile",
                    "sea_surface_day", "sea_surface_dusk", "sea_surface_night",
                    "sea_ripple_overlay", "sky_day", "sky_dusk")
    lines = ["-- 自动生成：python3 tests/prepare_ocean_eco_art.py；禁止手工编辑。",
             "-- 只含图片规格，不含实体、玩法数值或更新逻辑。", "return {"]
    for name, entry in sorted(entries.items()):
        size, bounds = entry["size"], entry["content_bounds"]
        lines.extend([
            "    " + name + " = {",
            "        path = " + json.dumps(entry["path"]) + ",",
            f"        pixelWidth = {size[0]}, pixelHeight = {size[1]},",
            f"        contentWidth = {bounds[2] - bounds[0]}, contentHeight = {bounds[3] - bounds[1]},",
            "        anchorX = 0.5, anchorY = 0.5,",
            "        preload = " + str(entry["preload"]).lower() + ",",
            "        repeatTexture = " + str(name in repeat_names).lower() + ",",
            "        completeIsland = " + str(entry.get("complete_island", False)).lower() + ",",
            "    },",
        ])
    lines.append("}")
    return "\n".join(lines) + "\n"


def prepare():
    module = importer()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for base, flip in FRAMES.items():
        for index in range(1, FRAME_COUNT + 1):
            name = f"{base}_f{index}"
            # 源目录命名为 fish_small_f1（无 eco_ 前缀）
            source = SOURCE_DIR / f"{base[4:]}_f{index}.png"
            image = Image.open(source).convert("RGBA")
            if flip:
                image = image.transpose(Image.FLIP_LEFT_RIGHT)
            path = OUT / (name + ".png")
            image.save(path, optimize=True)
            entry = module.describe(path, source.as_posix())
            entry.update({"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                          "anchor": [0.5, 0.5], "layer": "component",
                          "status": "ready_not_placed", "frame": index})
            entries[name] = entry
    manifest = {"schema_version": 1,
                "style": "读海日系水彩绘本风，生态层组件（小鱼/大鱼/海鸟/木桶），锚点链派生自主场景昼夜套件",
                "format": "RGBA PNG 直通 Alpha（256 色量化 P 模式等价语义）；帧间同画布坐标系不裁剪",
                "projection": "Ocean.Projection 世界平面分片投影（ImageArt.Plane），鱼/鸟 heading 沿世界朝向，木桶 heading=0",
                "placement": "SeaDraw 渲染接入：鱼（sardine→eco_fish_small / tuna→eco_fish_big）、海鸟、木桶三帧循环；加载失败保持矢量兜底",
                "references": ["assets/image/OceanComponents/manifest.json",
                               "scripts/Ocean/SeaDraw.lua", "scripts/Ocean/ImageArt.lua"],
                "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(catalog_text(), encoding="utf-8")


def check():
    module = importer()
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    for name, entry in manifest["assets"].items():
        path = ROOT / "assets" / entry["path"]
        assert path.is_file(), f"{name} 运行目录缺失"
        with Image.open(path) as image:
            assert image.mode in ("RGBA", "P"), f"{name} 非 RGBA/调色板直通 Alpha"
            assert image.size == tuple(entry["size"]), f"{name} 尺寸不符（帧对齐契约）"
        source = Path(entry["source"])
        assert source.is_file(), f"{name} 源图缺失：{source}"
        assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["source_sha256"], f"{name} 源图变化，需重新导入"
        actual = module.describe(path, entry["source"])
        for key in ("size", "content_bounds", "alpha_range", "sha256"):
            assert actual[key] == entry[key], f"{name} 的 {key} 与清单不一致"
        assert actual["alpha_range"][0] == 0 and actual["transparent_ratio"] > 0.1, f"{name} 缺少透明留边"
    assert CATALOG.read_text(encoding="utf-8") == catalog_text(), "运行目录与素材清单不同步"
    print(json.dumps({"passed": True, "eco_assets": len(manifest["assets"]),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读校验清单、PNG、源图与运行目录一致性")
    args = parser.parse_args()
    if not args.check:
        prepare()
    check()
