"""整理新增航海绘本素材并生成只读运行目录；--check 仅校验，不覆盖文件。

注意（2026-10-15）：OUT（assets/image/OceanReady）当前是 tests/slim_ocean_art.py
量化后的 256 色 P 模式瘦身产物；直接运行 prepare() 会以 RGBA 全彩重写这四张图、
回退 P3 瘦身（体积约 5 倍）。新增素材（如 OceanDecor）只应：
  1) 用 catalog_text(manifest) 重写 scripts/GeneratedData/OceanImageCatalog.lua；
  2) 运行 --check 校验清单、PNG、源图与运行目录一致性。
除非明确要重新导入 OceanReady 源图，否则不要运行 prepare()。
"""
import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/OceanReady"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
SELECTION = ROOT / "docs/art-runtime-selection.json"
WAVE2_OUT = ROOT / "assets/image/OceanWave2"
SOURCES = {
    "reef": ("OceanReady_reef_top_20261005123026.png", (512, 512)),
    "shrub": ("OceanReady_shrub_top_20261005123049.png", (512, 512)),
    "driftwood": ("OceanReady_driftwood_top_20261005123027.png", (768, 512)),
    "sardine": ("OceanReady_sardine_top_20261005123025.png", (768, 512)),
}


def importer():
    spec = importlib.util.spec_from_file_location("ocean_art_import", ROOT / "tests/prepare_ocean_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def image_module():
    from PIL import Image
    return Image


def catalog_text(manifest):
    existing = json.loads((ROOT / "assets/image/OceanLoop/manifest.json").read_text(encoding="utf-8"))
    story = json.loads((ROOT / "assets/image/OceanStoryLayer/manifest.json").read_text(encoding="utf-8"))
    decor = json.loads((ROOT / "assets/image/OceanDecor/manifest.json").read_text(encoding="utf-8"))
    components = json.loads((ROOT / "assets/image/OceanComponents/manifest.json").read_text(encoding="utf-8"))
    islands = json.loads((ROOT / "assets/image/OceanIslands/manifest.json").read_text(encoding="utf-8"))
    eco = json.loads((ROOT / "assets/image/OceanEco/manifest.json").read_text(encoding="utf-8"))
    # SeaSurface（纯海面 v2）：与 prepare_ocean_eco_art.py 同口径，清单缺失时按空合集处理。
    sea_manifest = ROOT / "assets/image/SeaSurface/manifest.json"
    sea = json.loads(sea_manifest.read_text(encoding="utf-8")) if sea_manifest.exists() else {"assets": {}}
    entries = {}
    # eco 合集按条目自带 preload（per-entry，如 sea_surface_day/dusk=true、
    # night=false），其余合集沿用既有默认；W2 selected 覆盖保留（boat/island
    # 保持向量绘制，W2 候选仍进 catalog 并被校验）。
    # OceanIslands（2026-10-18 六座新岛）：世界内走矢量变体绘制，贴图 preload=false 备用。
    for collection, preload, per_entry in ((existing["assets"], True, False), (manifest["assets"], False, False),
                                           (story["assets"], False, False), (decor["assets"], False, False),
                                           (components["assets"], False, False), (islands["assets"], False, False),
                                           (eco["assets"], False, True), (sea["assets"], False, True)):
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
            "        repeatTexture = " + str(name in ("waterpaper", "waterpaper_story", "ocean_tile",
                                                       "sea_surface_day", "sea_surface_dusk", "sea_surface_night")).lower() + ",",
            "        completeIsland = " + str(entry.get("complete_island", False)).lower() + ",",
            "    },",
        ])
    lines.append("}")
    return "\n".join(lines) + "\n"


def prepare_selected():
    """W2 selection is import input, not an art finalisation or gameplay source."""
    if not SELECTION.exists():
        return
    Image = image_module()
    module = importer()
    selection = json.loads(SELECTION.read_text(encoding="utf-8"))
    assert selection["status"] == "CURRENT_RUNTIME_CANDIDATE"
    WAVE2_OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, spec in selection["assets"].items():
        source = (ROOT / spec["source"]).resolve()
        assert source.is_relative_to((ROOT / "outputs/art-wave1").resolve())
        assert hashlib.sha256(source.read_bytes()).hexdigest() == spec["source_sha256"]
        image = Image.open(source).convert("RGBA")
        bounds = image.getchannel("A").getbbox()
        if not bounds:
            raise ValueError(f"No alpha content: {source}")
        image = image.crop(bounds)
        size = tuple(spec["size"])
        ratio = min(1.0, size[0] * .88 / image.width, size[1] * .88 / image.height)
        content_size = (max(1, round(image.width * ratio)), max(1, round(image.height * ratio)))
        image = image.convert("RGBa").resize(content_size, Image.Resampling.LANCZOS).convert("RGBA")
        canvas = Image.new("RGBA", size)
        canvas.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
        # Do not erode alpha or change watercolour colours to hit a byte target.
        path = WAVE2_OUT / (name + ".png")
        canvas.save(path, optimize=True)
        entry = module.describe(path, spec["source"])
        entry.update({"source_sha256": spec["source_sha256"], "preload": spec["preload"],
                      "complete_island": spec.get("complete_island", False),
                      "status": selection["status"], "task": spec["task"],
                      "source_bytes": source.stat().st_size, "runtime_bytes": path.stat().st_size})
        entries[name] = entry
    (WAVE2_OUT / "manifest.json").write_text(json.dumps({"schema_version": 1,
        "status": selection["status"], "assets": entries}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def generate_catalog():
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    CATALOG.write_text(catalog_text(manifest), encoding="utf-8")


def extend_transparent_rgb(image):
    """保留可见的细描边，只修复高饱和彩点并向零 Alpha 留边扩展 RGB。"""
    Image = image_module()
    import numpy as np
    from scipy.ndimage import distance_transform_edt
    values = np.array(image.convert("RGBA"))
    visible = values[:, :, 3] > 0
    rgb = values[:, :, :3].astype(float)
    maximum, minimum = rgb.max(axis=2), rgb.min(axis=2)
    saturation = (maximum - minimum) / np.maximum(maximum, 1)
    polluted = (saturation > 0.65) & (rgb[:, :, 0] > 210) & (
        (rgb[:, :, 1] > 190) | (rgb[:, :, 2] > 100))
    safe = (values[:, :, 3] >= 240) & ~polluted
    if safe.any() and (polluted & visible).any():
        _, indices = distance_transform_edt(~safe, return_indices=True)
        nearest = values[indices[0], indices[1], :3]
        values[polluted & visible, :3] = nearest[polluted & visible]
    if visible.any():
        _, indices = distance_transform_edt(~visible, return_indices=True)
        nearest = values[indices[0], indices[1], :3]
        values[~visible, :3] = nearest[~visible]
    return Image.fromarray(values, "RGBA")


def prepare():
    Image = image_module()
    module = importer()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, (filename, size) in SOURCES.items():
        source = ROOT / "assets/image" / filename
        original = Image.open(source).convert("RGBA")
        # 复用既有连通域 Alpha 清理，但不复用其会侵蚀细描边的可见 RGB 修复。
        cleaned = module.clean_alpha(original)
        image = original.copy()
        image.putalpha(cleaned.getchannel("A"))
        image = extend_transparent_rgb(image)
        bounds = image.getchannel("A").getbbox()
        if not bounds:
            raise ValueError(f"素材无可见主体：{source}")
        image = image.crop(bounds)
        # 保持主体长宽比，不把细长鱼/木板拉伸为画布比例；四边至少留 6%。
        ratio = min(size[0] * 0.88 / image.width, size[1] * 0.88 / image.height)
        content_size = (max(1, round(image.width * ratio)), max(1, round(image.height * ratio)))
        image = image.convert("RGBa").resize(content_size, Image.Resampling.LANCZOS).convert("RGBA")
        image = extend_transparent_rgb(image)
        canvas = Image.new("RGBA", size)
        canvas.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
        canvas = extend_transparent_rgb(canvas)
        path = OUT / (name + ".png")
        canvas.save(path, optimize=True)
        entry = module.describe(path, source.relative_to(ROOT).as_posix())
        entry.update({"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "anchor": [0.5, 0.5], "view": "top_down", "status": "ready_not_placed",
                      "heading": "+X" if name in ("driftwood", "sardine") else "none"})
        entries[name] = entry
    manifest = {"schema_version": 1, "style": "暖赭细描边、简化色块、轻水彩纸感",
            "format": "RGBA PNG，直通 Alpha、透明边 RGB 扩边、主体保持比例",
            "projection": "Ocean.Projection 世界平面分片投影；不作屏幕旋转",
            "placement": "仅素材库候选，不创建实体、不修改生成或玩法",
            "references": ["assets/image/OceanStory_island_20261005114948.png",
                               "assets/image/OceanStory_boat_20261005114947.png",
                               "assets/image/OceanStory_gull_20261005114946.png"],
            "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(catalog_text(manifest), encoding="utf-8")


def check():
    Image = image_module()
    module = importer()
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    existing = json.loads((ROOT / "assets/image/OceanLoop/manifest.json").read_text(encoding="utf-8"))
    story = json.loads((ROOT / "assets/image/OceanStoryLayer/manifest.json").read_text(encoding="utf-8"))
    decor = json.loads((ROOT / "assets/image/OceanDecor/manifest.json").read_text(encoding="utf-8"))
    components = json.loads((ROOT / "assets/image/OceanComponents/manifest.json").read_text(encoding="utf-8"))
    islands = json.loads((ROOT / "assets/image/OceanIslands/manifest.json").read_text(encoding="utf-8"))
    eco = json.loads((ROOT / "assets/image/OceanEco/manifest.json").read_text(encoding="utf-8"))
    full_bleed = ("waterpaper", "waterpaper_story", "ocean_tile")  # 整幅材质，无透明留边契约
    selected = json.loads((WAVE2_OUT / "manifest.json").read_text(encoding="utf-8"))["assets"] if SELECTION.exists() else {}
    # Check legacy files too: overriding a catalog entry never deletes its fallback asset.
    all_assets = list(existing["assets"].items()) + list(manifest["assets"].items()) \
        + list(story["assets"].items()) + list(decor["assets"].items()) \
        + list(components["assets"].items()) + list(islands["assets"].items()) \
        + list(eco["assets"].items()) \
        + list(selected.items())
    for name, entry in all_assets:
        path = ROOT / "assets" / entry["path"]
        if not path.resolve().is_relative_to((ROOT / "assets").resolve()):
            raise ValueError("素材路径越界")
        with Image.open(path) as image:
            # P3 瘦身（tests/slim_ocean_art.py）产出 256 色调色板 PNG + tRNS，
            # 语义仍为直通 Alpha（非预乘），与 RGBA 同一契约，允许两种模式。
            assert image.mode in ("RGBA", "P"), f"{name} 非 RGBA/调色板直通 Alpha"
        actual = module.describe(path, entry["source"])
        for key in ("size", "content_bounds", "alpha_range", "sha256"):
            assert actual[key] == entry[key], f"{name} 的 {key} 与清单不一致"
        if name not in full_bleed:
            assert actual["alpha_range"][0] == 0 and actual["transparent_ratio"] > 0.1, f"{name} 缺少透明留边"
        if "source_sha256" in entry:
            source = ROOT / entry["source"]
            assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["source_sha256"], f"{name} 源图变化，需重新导入"
            image = Image.open(path)
            bounds = entry["content_bounds"]
            assert bounds[0] > 0 and bounds[1] > 0 and bounds[2] < image.width and bounds[3] < image.height
    assert CATALOG.read_text(encoding="utf-8") == catalog_text(manifest), "运行目录与素材清单不同步"
    if SELECTION.exists():
        selection = json.loads(SELECTION.read_text(encoding="utf-8"))
        assert selection["status"] == "CURRENT_RUNTIME_CANDIDATE"
        assert set(selection["assets"]) == set(selected)
        for name, spec in selection["assets"].items():
            entry = selected[name]
            assert entry["source"] == spec["source"] and entry["source_sha256"] == spec["source_sha256"]
            assert entry["size"] == spec["size"] and entry["preload"] == spec["preload"]
            assert entry["complete_island"] == spec.get("complete_island", False)
            assert entry["runtime_bytes"] == (ROOT / "assets" / entry["path"]).stat().st_size
    print(json.dumps({"passed": True, "existing_assets": len(existing["assets"]),
                      "new_assets": len(manifest["assets"]), "story_assets": len(story["assets"]),
                      "decor_assets": len(decor["assets"]), "component_assets": len(components["assets"]),
                      "selected_assets": len(selected),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读检查清单、PNG、源图与运行目录一致性")
    parser.add_argument("--wave2", action="store_true", help="只导入 W2 选择并生成目录，保留旧运行资源")
    args = parser.parse_args()
    if not args.check:
        if args.wave2:
            prepare_selected()
            generate_catalog()
        else:
            prepare_selected()
            prepare()
    check()
