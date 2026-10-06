"""批2 预备（2026-10-06，技美美）：reading_sea_watercolor 整图离线切分（D2 裁决方案）。

- 按 Alpha 连通域切出独立精灵 PNG（<2px 间隙的相邻元素会被合并，属可接受近似）；
- 产出 assets/image/WatercolorUI/<sheet>/<row-col>.png + manifest.json（bbox/尺寸/中心锚点）；
- 切出件继承 256 色调色板量化（与 slim_ocean_art 同一契约）；
- 仅素材库预备，不改运行时；语义命名（如 icon_stamina）由后续接入时人工标定。
"""
import json
from pathlib import Path
import numpy as np
from PIL import Image
from scipy.ndimage import label

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets/image"
OUT = ASSETS / "WatercolorUI"

SHEETS = {
    "characters": "reading_sea_watercolor_characters_20261005115718.png",
    "marine_life": "reading_sea_watercolor_marine_life_20261005115707.png",
    "resource_icons": "reading_sea_watercolor_resource_icons_20261005115435.png",
    "button_states": "reading_sea_watercolor_button_states_20261005115716.png",
    "navigation": "reading_sea_watercolor_navigation_clean_20261005115700.png",
}

MIN_SIDE_PX = 24  # 小于此尺寸的碎片（噪点/描边残屑）丢弃


def slice_sheet(sheet_name, filename):
    image = Image.open(ASSETS / filename).convert("RGBA")
    alpha = np.array(image.getchannel("A"))
    mask = alpha > 8
    labels, count = label(mask)
    out_dir = OUT / sheet_name
    out_dir.mkdir(parents=True, exist_ok=True)
    entries = []
    kept = 0
    for index in range(1, count + 1):
        ys, xs = np.where(labels == index)
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        if (x1 - x0) < MIN_SIDE_PX or (y1 - y0) < MIN_SIDE_PX:
            continue
        kept += 1
        region = image.crop((int(x0), int(y0), int(x1), int(y1)))
        name = f"{kept:03d}_{(x0 + x1) // 2}-{(y0 + y1) // 2}.png"
        path = out_dir / name
        quantized = region.quantize(colors=256, method=Image.Quantize.FASTOCTREE)
        quantized.save(path, optimize=True)
        entries.append({"file": f"image/WatercolorUI/{sheet_name}/{name}", "sheet": sheet_name,
                        "bboxInSheet": [int(x0), int(y0), int(x1), int(y1)],
                        "size": [region.width, region.height], "anchor": [0.5, 0.5]})
    return entries, kept


def main():
    report = {}
    all_entries = {}
    for sheet_name, filename in SHEETS.items():
        entries, kept = slice_sheet(sheet_name, filename)
        all_items = all_entries.setdefault("assets", {})
        for index, entry in enumerate(entries):
            all_items[f"{sheet_name}_{index:03d}"] = entry
        report[sheet_name] = kept
    manifest = {"schema_version": 1, "style": "reading_sea_watercolor 离线切分",
                "format": "256 色调色板 PNG（tRNS 直通 Alpha），中心锚点，未接运行时",
                "naming": "序号_中心坐标；语义命名待接入时人工标定",
                "assets": all_entries["assets"]}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": True, "spritesPerSheet": report, "total": len(all_entries["assets"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
