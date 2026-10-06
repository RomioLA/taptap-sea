"""P2+P3 素材瘦身（2026-10-06，技美美）：waterpaper 降采样 512² + 全量 PNG 调色板量化。

- 量化等效 pngquant（RGBA→256 色调色板 + tRNS），预期包体 17MB→约 6MB；
- 溯源源图（OceanReady_*_top_*.png）不动，保证 prepare 流水线可复跑；
- 完成后用 describe() 重写 OceanLoop/OceanReady 两个 manifest 的实测字段，
  再生 OceanImageCatalog，保证 --check 全绿；
- 运行前置：tests/prepare_ocean_ready_art.py 曾运行过（manifest 存在）。
  若之后任何人重跑 prepare（非 check 模式），需再跑一次本脚本。
"""
import importlib.util
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets/image"
CATALOG = ROOT / "scripts/GeneratedData/OceanImageCatalog.lua"
MANIFESTS = [ASSETS / "OceanLoop/manifest.json", ASSETS / "OceanReady/manifest.json"]
WATERPAPER = ASSETS / "OceanLoop/waterpaper.png"


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def collect_targets():
    targets = []
    for path in sorted(ASSETS.rglob("*.png")):
        if path.name.startswith("OceanReady_") and "_top_" in path.name:
            continue  # 溯源源图不动
        targets.append(path)
    return targets


def downscale_waterpaper():
    image = Image.open(WATERPAPER).convert("RGBA")
    if image.width <= 512:
        return "already<=512"
    image = image.resize((512, 512), Image.Resampling.LANCZOS)
    image.save(WATERPAPER, optimize=True)
    return "resized 1024->512"


def quantize(path):
    image = Image.open(path)
    if image.mode == "P":
        return 0  # 已是调色板模式
    before = path.stat().st_size
    source = image.convert("RGBA")
    quantized = source.quantize(colors=256, method=Image.Quantize.FASTOCTREE)
    quantized.save(path, optimize=True)
    after = path.stat().st_size
    check = Image.open(path).convert("RGBA")
    assert check.size == source.size, f"{path.name} 尺寸变化"
    return before - after


def patch_manifests(describe):
    for manifest_path in MANIFESTS:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        for name, entry in data["assets"].items():
            path = ROOT / "assets" / entry["path"]
            fresh = describe(path, entry["source"])
            entry.update(fresh)
        manifest_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def regenerate_catalog(ready_module):
    ready_manifest = json.loads((ASSETS / "OceanReady/manifest.json").read_text(encoding="utf-8"))
    CATALOG.write_text(ready_module.catalog_text(ready_manifest), encoding="utf-8")


def main():
    ocean_art = load_module(ROOT / "tests/prepare_ocean_art.py", "ocean_art_import")
    ready_art = load_module(ROOT / "tests/prepare_ocean_ready_art.py", "ocean_ready_import")

    report = {"waterpaper": downscale_waterpaper(), "files": [], "savedKB": 0}
    for path in collect_targets():
        before = path.stat().st_size
        delta = quantize(path)
        report["files"].append({"name": path.relative_to(ASSETS).as_posix(),
                                "beforeKB": round(before / 1024), "afterKB": round((before - delta) / 1024)})
        report["savedKB"] += round(delta / 1024)

    patch_manifests(ocean_art.describe)
    regenerate_catalog(ready_art)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
