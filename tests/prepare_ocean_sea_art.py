"""纯海面 v2（SeaSurface）入库：三张时段海面 + 波纹平铺层 → assets/image/SeaSurface/ + manifest + catalog 重生成。

素材来源（2026-10-20 换装）：
- day/dusk：E:/workbath/Fishing/_gen_pure_sea/watercolor_sea_{day,dusk}_v2.png
  （用户 miora 再创作「读海_水彩海面纹理_v2」水彩海面：保留水彩底色、上浅下深明暗
  层次、远景低对比低细节、近景清晰较疏波纹；1728×972 精确 16:9，裁角去平台水印。
  复制为 ASCII 文件名入库；左右边缘非严格无缝，底图默认 scroll=false 固定，
  repeatTexture 横拼标志保留备用）。
- night：E:/workbath/Fishing/_gen_pure_sea/pure_sea_night_v2.png（miora 锚点链派生
  v2，1920×1080；方案 A 夜图不进自动映射，留作 SeaDebug/后续方案）。
- 波纹：E:/workbath/Fishing/_gen_pure_sea/sea_ripple_overlay_gamma_v2.png
  （2026-10-19 真机修复后的权威产物快照：去白底提 alpha + 伽马 0.55 重提取，
  RGBA 512×288 双向无缝瓦片。原 sea_ripple_serene_v1.png 为 RGB 白底原始素材，
  直接重入库会静默回退真机修复，故改以修复版为源）。

海面为屏幕空间材质层（ImageArt.SeaSurface：地平线裁剪 + imagePattern + 相机横向滚动），
不是世界实体，因此与生态层组件的契约不同：
- 不透明满幅（无透明留边）：content_bounds = 全画布，alpha_range 为 (255,255)；
- repeatTexture=true：左右边缘无缝，横向循环拼接；
- preload：day/dusk=true（场景启动即需，昼相末段交叉淡入），night=false
  （方案 A 夜罩不动：夜间=昼图过夜罩，夜图不接入自动映射，留作 SeaDebug 切换与后续方案储备）。

catalog 由 tests/prepare_ocean_eco_art.py 的 catalog_text() 统一重生成（含既有各合集），
本脚本只负责 SeaSurface 素材与清单，避免两份 catalog 生成器漂移。

用法：
  python3 tests/prepare_ocean_sea_art.py          # 入库并重生成 catalog
  python3 tests/prepare_ocean_sea_art.py --check   # 只读校验（含源图 sha256）
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/SeaSurface"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
SOURCE_DIR = Path("E:/workbath/Fishing/_gen_pure_sea")
# 目录名 -> 源文件（时段顺序即交付顺序）
SOURCES = {
    "sea_surface_day": "watercolor_sea_day_v2.png",
    "sea_surface_dusk": "watercolor_sea_dusk_v2.png",
    "sea_surface_night": "pure_sea_night_v2.png",
    "sea_ripple_overlay": "sea_ripple_overlay_gamma_v2.png",
}
# 各素材目标像素尺寸：昼/黄昏为用户水彩纹理原生 1728×972（精确 16:9）；
# 夜图沿用锚点链 v2 满幅 1920×1080；波纹平铺瓦片 512×288
PIXEL_SIZES = {
    "sea_surface_day": (1728, 972),
    "sea_surface_dusk": (1728, 972),
    "sea_surface_night": (1920, 1080),
    "sea_ripple_overlay": (512, 288),
}
# day/dusk 随场景启动预载（首帧即需 / 昼相末段淡入目标）；night 懒载（方案 A 不自动映射）
# ripple 预载（每帧叠加于海面之上，替换程序 crest marks）
PRELOAD = {
    "sea_surface_day": True,
    "sea_surface_dusk": True,
    "sea_surface_night": False,
    "sea_ripple_overlay": True,
}
PERIODS = {
    "sea_surface_day": "day",
    "sea_surface_dusk": "dusk",
    "sea_surface_night": "night",
    "sea_ripple_overlay": "all",
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


def manifest_text():
    return json.loads((OUT / "manifest.json").read_text(encoding="utf-8"))


def prepare():
    module = importer()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, filename in SOURCES.items():
        source = SOURCE_DIR / filename
        image = Image.open(source).convert("RGB")
        assert image.size == PIXEL_SIZES[name], f"{name} 源图尺寸 {image.size} != {PIXEL_SIZES[name]}"
        path = OUT / (name + ".png")
        image.save(path, optimize=True)
        entry = module.describe(path, source.as_posix())
        entry.update({"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "preload": PRELOAD[name], "anchor": [0.5, 0.5], "layer": "sea_surface",
                      "status": "ready_wired", "period": PERIODS[name]})
        entries[name] = entry
    manifest = {"schema_version": 1,
                "style": "读海日系水彩绘本风：昼/黄昏为 2026-10-20 用户提供水彩海面纹理 v2"
                         "（宁静，纯海面满幅，上浅下深明暗层次），夜晚为 miora 锚点链派生 v2；"
                         "波纹平铺层为 2026-10-18 用户提供水彩波纹纹理",
                "format": "不透明 RGB 满幅/瓦片；昼/黄昏 1728×972 精确 16:9、夜 1920×1080；"
                          "上浅下深纵深过渡；昼/黄昏左右边缘非严格无缝（底图默认 scroll=false 固定，"
                          "repeatTexture 标志保留备用），波纹瓦片双向无缝可 REPEATX|REPEATY 平铺",
                "projection": "屏幕空间材质层（ImageArt.SeaSurface）：地平线裁剪 + imagePattern + 相机横向滚动，非世界平面",
                "placement": "SeaViewArt.Surface 相位映射（方案 A 夜罩不动）：day 承载日间与夜间（夜间=昼图过夜罩），"
                             "dusk 用于昼相 progress≥0.8 交叉淡入，night 留 SeaDebug/后续方案",
                "references": ["scripts/Ocean/SeaViewArt.lua", "scripts/Ocean/ImageArt.lua",
                               "scripts/Ocean/SeaDraw.lua"],
                "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # catalog 统一走 eco 脚本的生成器（已扩展纳入 SeaSurface 合集）
    CATALOG.write_text(eco_importer().catalog_text(), encoding="utf-8")


def check():
    module = importer()
    manifest = manifest_text()
    # 2026-10-20：SeaSurface 合集新增近景动态层（焦散/dudv，由
    # prepare_ocean_water_fx_art.py 入库）。本脚本只校验自己负责的那三件套，
    # 其余条目不得出现在 SOURCES 之外的同名冲突里。
    water_fx_names = {"water_caustic_light", "water_caustic_light_alt", "water_dudv_flow"}
    present = set(manifest["assets"])
    assert set(SOURCES).issubset(present), "SeaSurface 清单缺少本脚本负责的海面三件套"
    assert present <= set(SOURCES) | water_fx_names, "SeaSurface 清单出现未登记条目"
    for name, entry in manifest["assets"].items():
        if name in water_fx_names:
            continue  # 由 prepare_ocean_water_fx_art.py 的 --check 负责
        path = ROOT / "assets" / entry["path"]
        assert path.is_file(), f"{name} 运行目录缺失"
        with Image.open(path) as image:
            if name == "sea_ripple_overlay":
                # 波纹层 2026-10-19 起为 RGBA（去白底提 alpha + 伽马重提取），
                # 自持透明度叠加于海面之上；其余海面三图为不透明 RGB 满幅。
                assert image.mode == "RGBA", f"{name} 应为 RGBA（自持 alpha 波纹）"
            else:
                assert image.mode == "RGB", f"{name} 应为不透明 RGB 满幅"
            assert image.size == PIXEL_SIZES[name], f"{name} 尺寸不符（{PIXEL_SIZES[name]} 契约）"
            assert image.size == tuple(entry["size"]), f"{name} 清单尺寸不符"
        source = Path(entry["source"])
        if source.is_file():
            assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["source_sha256"], f"{name} 源图变化，需重新导入"
        else:
            # 源图在工作区（非 git），清理后仅跳过溯源校验；运行目录与清单校验仍然有效
            # （eco 批次的 --check 因源图被删整体硬失败，此处不复刻该脆弱点）。
            print(f"[warn] {name} 源图缺失，跳过溯源校验：{source}")
        actual = module.describe(path, entry["source"])
        for key in ("size", "content_bounds", "alpha_range", "sha256"):
            assert actual[key] == entry[key], f"{name} 的 {key} 与清单不一致"
        # 海面契约：三张海面满幅不透明（与组件类的透明留边相反）；
        # 波纹层为 RGBA 自持 alpha（叠加层），不适用该断言
        if name != "sea_ripple_overlay":
            assert entry["alpha_range"] == [255, 255], f"{name} 应完全不透明"
            assert entry["content_bounds"] == [0, 0, *PIXEL_SIZES[name]], f"{name} 应满幅无留边"
        assert entry["preload"] == PRELOAD[name], f"{name} preload 与方案 A 契约不符"
    text = CATALOG.read_text(encoding="utf-8")
    assert text == eco_importer().catalog_text(), "运行目录与素材清单不同步（catalog 需重生成）"
    for name in SOURCES:
        assert f"    {name} = {{" in text, f"catalog 缺少 {name}"
    assert "repeatTexture = true" in text, "catalog 缺少海面无缝循环标记"
    print(json.dumps({"passed": True, "sea_assets": len(manifest["assets"]),
                      "catalog": CATALOG.relative_to(ROOT).as_posix()}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读校验清单、PNG、源图与 catalog 一致性")
    args = parser.parse_args()
    if not args.check:
        prepare()
    check()
