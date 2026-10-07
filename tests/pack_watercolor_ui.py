"""批2：WatercolorUI 切片精灵 → 分类别图集 + PixiJS spritesheet JSON。

输入：assets/image/WatercolorUI/manifest.json（slice_watercolor_sheets.py 产物，42 精灵）
输出：assets/image/WatercolorUI/<sheet>.json + atlas/<sheet>.png（256 色量化）
消费：urhox-libs UI.Sprite({src=..., frame=...})（HUD 水彩图标条）

语义命名由人工对 contact sheet 标定（2026-10-07）；新增精灵时在 SEMANTIC 补名。
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
UI_DIR = ROOT / "assets/image/WatercolorUI"
MANIFEST = UI_DIR / "manifest.json"

# sheet → [语义名]，顺序与 manifest 中同名序号一一对应（_000, _001, ...）。
SEMANTIC = {
    "resource_icons": [
        "chest", "plank", "shell", "fish", "anchor", "bottle_message",
        "seaweed", "rope", "clay_pot", "orb_teal", "apple", "coins_pile",
        "coin_single", "coin_small", "scroll", "compass", "map", "orb_crystal",
    ],
    "navigation": [
        "compass", "treasure_map", "logbook", "spyglass", "anchor", "helm",
        "fishing_net", "coins_pile",
    ],
    "button_states": [
        "circle_cream", "pill_cream", "circle_gold", "pill_gold",
        "circle_gray", "pill_gray",
    ],
    "marine_life": [
        "shark", "dolphin", "tuna", "mackerel", "ray", "octopus",
        "turtle", "jellyfish",
    ],
    "characters": ["fisherman_elder", "fisherman_young"],
}


def pack_sheet(sheet: str, entries: list[dict]) -> dict:
    """shelf packing：按高降序逐个放入，返回 PixiJS JSON 数据并落盘图集。"""
    items = sorted(entries, key=lambda e: -e["size"][1])
    pads = 2
    x, y, row_h, width = pads, pads, 0, 0
    placed = []
    for entry in items:
        w, h = entry["size"]
        if x + w + pads > 1024:  # 换行（行高由本行最高精灵决定）
            width = max(width, x)
            x, y = pads, y + row_h + pads
            row_h = 0
        placed.append((entry, x, y))
        x += w + pads
        row_h = max(row_h, h)
    width = max(width, x) + pads
    height = y + row_h + pads

    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    frames = {}
    for entry, px, py in placed:
        img = Image.open(ROOT / "assets" / entry["file"]).convert("RGBA")
        atlas.paste(img, (px, py), img)
        frames[entry["semantic"]] = {
            "frame": {"x": px, "y": py, "w": entry["size"][0], "h": entry["size"][1]},
            "sourceSize": {"w": entry["size"][0], "h": entry["size"][1]},
            "pivot": {"x": 0.5, "y": 0.5},
        }

    atlas_path = UI_DIR / "atlas" / f"{sheet}.png"
    atlas_path.parent.mkdir(parents=True, exist_ok=True)
    quantized = atlas.quantize(colors=256, method=Image.Quantize.FASTOCTREE)
    quantized.save(atlas_path, optimize=True)

    data = {
        "frames": frames,
        "meta": {"image": f"atlas/{sheet}.png", "size": {"w": width, "h": height}},
    }
    json_path = UI_DIR / f"{sheet}.json"
    json_path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return {
        "sheet": sheet,
        "frames": len(frames),
        "atlas": os.path.relpath(atlas_path, ROOT).replace(os.sep, "/"),
        "atlasSize": f"{width}x{height}",
        "atlasKB": atlas_path.stat().st_size // 1024,
        "sha256": hashlib.sha256(atlas_path.read_bytes()).hexdigest()[:16],
    }


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))["assets"]
    groups: dict[str, list[dict]] = {}
    for name, entry in manifest.items():
        sheet, _, index = name.rpartition("_")
        semantic_list = SEMANTIC.get(sheet)
        assert semantic_list, f"SEMANTIC 缺少 sheet：{sheet}"
        semantic = semantic_list[int(index)]
        groups.setdefault(sheet, []).append({**entry, "semantic": semantic})

    report = [pack_sheet(sheet, items) for sheet, items in sorted(groups.items())]
    total_kb = sum(r["atlasKB"] for r in report)
    print(json.dumps({"passed": True, "sheets": report, "totalKB": total_kb}, ensure_ascii=False))


if __name__ == "__main__":
    sys.exit(main())
