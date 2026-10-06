"""批1（2026-10-06）：生成 OceanStoryLayer manifest——OceanStory 重绘版 + ocean_tile 备选材质。

- 6 条目全部 preload=false（ArtVariants 开启后按需加载）；
- 溯源 source=文件自身（本层素材即 B 侧交付原图，经 slim 量化后原样引用）；
- 产出后由 prepare_ocean_ready_art.py --check 做 describe 同步校验。
"""
import hashlib
import importlib.util
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/OceanStoryLayer"

SOURCES = {
    "island_story": "OceanStory_island_20261005114948.png",
    "boat_story": "OceanStory_boat_20261005114947.png",
    "barrel_story": "OceanStory_barrel_20261005115009.png",
    "gull_story": "OceanStory_gull_20261005114946.png",
    "waterpaper_story": "OceanStory_waterpaper_20261005114940.png",
    "ocean_tile": "reading_sea_watercolor_ocean_tile_20261005115327.png",
}


def load_describe():
    spec = importlib.util.spec_from_file_location("ocean_art_import", ROOT / "tests/prepare_ocean_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.describe


def load_ready():
    spec = importlib.util.spec_from_file_location("ocean_ready_import", ROOT / "tests/prepare_ocean_ready_art.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    describe = load_describe()
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for name, filename in SOURCES.items():
        source = ROOT / "assets/image" / filename
        if not source.exists():
            raise FileNotFoundError(source)
        with Image.open(source) as image:
            assert image.mode in ("RGBA", "P"), f"{filename} 非 RGBA/调色板"
        entry = describe(source, "image/" + filename)
        entry["source_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        entry["anchor"] = [0.5, 0.5]
        entry["layer"] = "story"
        entry["status"] = "variant_not_wired_default_off"
        entries[name] = entry
    manifest = {"schema_version": 1, "style": "OceanStory 重绘版 + reading_sea ocean_tile 备选",
                "format": "调色板 P（tRNS 直通 Alpha）或 RGBA PNG，经 slim_ocean_art 量化",
                "placement": "仅素材库候选；ArtVariants 开关解析 *_story 变体，默认关闭",
                "references": ["tests/slim_ocean_art.py", "scripts/Ocean/ArtVariants.lua"],
                "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ready = load_ready()
    catalog_text = ready.catalog_text(json.loads((ROOT / "assets/image/OceanReady/manifest.json").read_text(encoding="utf-8")))
    (ROOT / "scripts/GeneratedData/OceanImageCatalog.lua").write_text(catalog_text, encoding="utf-8")
    print(json.dumps({"passed": True, "assets": len(entries), "catalog": "scripts/GeneratedData/OceanImageCatalog.lua"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
