"""日月云贴图（SkyDecor）入库：水彩太阳/月亮/日夜云 → assets/image/SkyDecor/ + manifest + catalog 重生成。

素材来源：E:/workbath/Fishing/_gen_sky_decor/{sky_sun,sky_moon,sky_cloud_dark,sky_cloud_light}_v1.png
（用户剪贴板 JPG 棋盘格去底 + 径向光晕重建，处理脚本 .tmp/sky_decor_process.py）。

日月云为屏幕空间装饰层（ImageArt.ScreenSprite：居中 imagePattern，非世界平面），
替换 Draw.Background 的矢量日/月/云（加载失败回退矢量，零回归）。因此：
- RGBA 直通 Alpha（水彩软边），content_bounds 为不透明包围盒；
- repeatTexture=false（单件精灵，不循环）；
- preload=false：装饰贴图懒加载（首个 Backdrop 帧按需加载一次）。

catalog 由 tests/prepare_ocean_eco_art.py 的 catalog_text() 统一重生成（含既有各合集），
本脚本只负责 SkyDecor 素材与清单，避免两份 catalog 生成器漂移。

用法：
  python3 tests/prepare_ocean_sky_decor_art.py          # 入库并重生成 catalog
  python3 tests/prepare_ocean_sky_decor_art.py --check   # 只读校验（含源图 sha256）
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/SkyDecor"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
SOURCE_DIR = Path("E:/workbath/Fishing/_gen_sky_decor")
SOURCES = {
    "sky_sun": "sky_sun_v1.png",
    "sky_moon": "sky_moon_v1.png",
    "sky_cloud_dark": "sky_cloud_dark_v1.png",
    "sky_cloud_light": "sky_cloud_light_v1.png",
}
PIXEL_SIZES = {
    "sky_sun": (512, 511),
    "sky_moon": (512, 512),
    "sky_cloud_dark": (512, 234),
    "sky_cloud_light": (512, 224),
}
PRELOAD = {name: False for name in SOURCES}
PERIODS = {
    "sky_sun": "day",
    "sky_moon": "night",
    "sky_cloud_dark": "night",
    "sky_cloud_light": "day",
}


def importer():
    spec = importlib.util.spec_from_file_location("ocean_art_import", ROOT / "tests/prepare_ocean_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def eco_importer():
    spec = importlib.util.spec_from_file_location("ocean_eco_art", ROOT / "tests/prepare_ocean_eco_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare():
    module = importer()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, filename in SOURCES.items():
        source = SOURCE_DIR / filename
        image = Image.open(source).convert("RGBA")
        assert image.size == PIXEL_SIZES[name], f"{name} 源图尺寸 {image.size} != {PIXEL_SIZES[name]}"
        path = OUT / (name + ".png")
        image.save(path, optimize=True)
        entry = module.describe(path, source.as_posix())
        entry.update({"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "preload": PRELOAD[name], "anchor": [0.5, 0.5], "layer": "sky",
                      "status": "ready_wired", "period": PERIODS[name]})
        entries[name] = entry
    manifest = {"schema_version": 1,
                "style": "读海日系水彩绘本风，日月单件水彩（含光晕）+ 日/夜两态积云，棋盘格去底 + 径向光晕重建",
                "format": "RGBA PNG 直通 Alpha；水彩软边保留；单件精灵不循环",
                "projection": "屏幕空间装饰层（ImageArt.ScreenSprite）：居中 imagePattern，非世界平面",
                "placement": "Draw.Background 日/月/云贴图优先（day=sky_sun+sky_cloud_light、night=sky_moon+sky_cloud_dark、day 末段交叉淡入），加载失败回退矢量（零回归）",
                "references": ["scripts/Ocean/Draw.lua", "scripts/Ocean/ImageArt.lua",
                               "scripts/Ocean/Config.lua", "scripts/Ocean/SeaViewArt.lua"],
                "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    CATALOG.write_text(eco_importer().catalog_text(), encoding="utf-8")


def check():
    module = importer()
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    assert set(manifest["assets"]) == set(SOURCES), "SkyDecor 清单与预期不一致"
    for name, entry in manifest["assets"].items():
        path = ROOT / "assets" / entry["path"]
        assert path.is_file(), f"{name} 运行目录缺失"
        with Image.open(path) as image:
            assert image.mode == "RGBA", f"{name} 应为 RGBA 直通 Alpha"
            assert image.size == PIXEL_SIZES[name], f"{name} 尺寸不符（{PIXEL_SIZES[name]} 契约）"
            assert image.size == tuple(entry["size"]), f"{name} 清单尺寸不符"
        source = Path(entry["source"])
        if source.is_file():
            assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["source_sha256"], f"{name} 源图变化，需重新导入"
        else:
            print(f"[warn] {name} 源图缺失，跳过溯源校验：{source}")
        actual = module.describe(path, entry["source"])
        for key in ("size", "content_bounds", "alpha_range", "sha256"):
            assert actual[key] == entry[key], f"{name} 的 {key} 与清单不一致"
        assert entry["preload"] == PRELOAD[name], f"{name} preload 与方案不符"
    text = CATALOG.read_text(encoding="utf-8")
    assert text == eco_importer().catalog_text(), "运行目录与素材清单不同步（catalog 需重生成）"
    for name in SOURCES:
        assert f"    {name} = {{" in text, f"catalog 缺少 {name}"
    print(json.dumps({"passed": True, "sky_decor_assets": len(manifest["assets"]),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读校验清单、PNG、源图与 catalog 一致性")
    args = parser.parse_args()
    if not args.check:
        prepare()
    check()
