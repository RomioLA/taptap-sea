"""天空图（Sky）入库：日间/黄昏两张天空贴图 → assets/image/Sky/ + manifest + catalog 重生成。

素材来源：E:/workbath/Fishing/_gen_pure_sea/pure_sky_{day,dusk}_v1.png
（miora 锚点链生成 + .tmp/sky_postprocess_v1.py 去右下角水印 / 1920×1080 校正 /
左右 96px 无缝融合 / 底边 alpha 渐隐）。

天空为屏幕空间满幅材质层（ImageArt.Sky：满幅 imagePattern + 相机横向视差），
不是世界实体，与海面（SeaSurface）契约相近但保留 Alpha 透明（地平线以下渐隐为 0，
交由海面底图覆盖）。因此：
- RGBA 直通 Alpha（与海面不透明 RGB 相反）：content_bounds 为不透明包围盒，alpha_range 含 0；
- repeatTexture=true：左右边缘无缝，横向循环拼接；
- preload=false：画面贴图类保持懒加载（与 sardine/reef 同口径），避免场景启动解码尖峰；
  首个 Backdrop 帧按需加载一次，句柄缓存。

catalog 由 tests/prepare_ocean_eco_art.py 的 catalog_text() 统一重生成（含既有各合集），
本脚本只负责 Sky 素材与清单，避免两份 catalog 生成器漂移。

用法：
  python3 tests/prepare_ocean_sky_art.py          # 入库并重生成 catalog
  python3 tests/prepare_ocean_sky_art.py --check   # 只读校验（含源图 sha256）
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/Sky"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
SOURCE_DIR = Path("E:/workbath/Fishing/_gen_pure_sea")
SOURCES = {
    "sky_day": "pure_sky_day_v1.png",
    "sky_dusk": "pure_sky_dusk_v1.png",
}
PIXEL_SIZES = {
    "sky_day": (1920, 1080),
    "sky_dusk": (1920, 1080),
}
PRELOAD = {
    "sky_day": False,
    "sky_dusk": False,
}
PERIODS = {
    "sky_day": "day",
    "sky_dusk": "dusk",
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
                "style": "读海日系水彩绘本风，天空图满幅（上蓝下白近海雾、底边 alpha 渐隐），锚点链派生：风格参考图→日间锚点→黄昏",
                "format": "RGBA PNG 直通 Alpha；上 26% 实天空、26%→40% 渐隐为 0；左右边缘无缝可横向循环拼接",
                "projection": "屏幕空间材质层（ImageArt.Sky）：满幅 imagePattern + 相机横向视差，非世界平面",
                "placement": "SeaViewArt.Sky 相位映射（委托 SeaSurfaceFrame，键名 sky_day/sky_dusk）：昼夜与海面同步交叉淡入；夜间沿用昼天图过夜罩（方案 A 夜罩不动）",
                "references": ["scripts/Ocean/SeaViewArt.lua", "scripts/Ocean/ImageArt.lua",
                               "scripts/Ocean/Draw.lua", "scripts/Ocean/SeaDraw.lua"],
                "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    CATALOG.write_text(eco_importer().catalog_text(), encoding="utf-8")


def check():
    module = importer()
    manifest = json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))
    assert set(manifest["assets"]) == set(SOURCES), "Sky 清单与预期不一致"
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
        # 天空契约：底边 alpha 渐隐为 0（与海面不透明相反），透明率应显著大于 0
        assert entry["alpha_range"][0] == 0, f"{name} 底边应渐隐到完全透明（alpha 下限 0）"
        assert entry["transparent_ratio"] > 0.1, f"{name} 应保留可观透明留边"
        assert entry["preload"] == PRELOAD[name], f"{name} preload 与方案不符"
    text = CATALOG.read_text(encoding="utf-8")
    assert text == eco_importer().catalog_text(), "运行目录与素材清单不同步（catalog 需重生成）"
    for name in SOURCES:
        assert f"    {name} = {{" in text, f"catalog 缺少 {name}"
        assert "repeatTexture = true" in text, "catalog 缺少天空无缝循环标记"
    print(json.dumps({"passed": True, "sky_assets": len(manifest["assets"]),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读校验清单、PNG、源图与 catalog 一致性")
    args = parser.parse_args()
    if not args.check:
        prepare()
    check()
