"""UI 套件重设计（v2.1 批B 前置）：ui_panels 整图离线切分 → 卡片水彩底板。

输入：assets/image/reading_sea_watercolor_ui_panels_clean_20261005115658.png
输出：assets/image/WatercolorUI/ui_panels/<NNN_cx-cy>.png + manifest.json
      （256 色量化，与 button_states 同契约；meta 由 Maker 云端 sync 自动生成）

语义命名（人工对 contact sheet 标定，接入时在 SEMANTIC 查）：
  1 = panel_parchment（羊皮纸粗边框 → 对白/结局/宝物等剧情卡）
  2 = panel_rounded（圆角茶棕卡 → 通用卡片：背包/港口/日结/捕鱼）
  3 = panel_scroll（卷轴 → 预留，本批不接入）
  4 = panel_plain（素面纸卡 → toast/气泡等轻量浮层）
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import label

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets/image/reading_sea_watercolor_ui_panels_clean_20261005115658.png"
OUT = ROOT / "assets/image/WatercolorUI/ui_panels"

SEMANTIC = {
    "001": "panel_parchment",
    "002": "panel_rounded",
    "003": "panel_scroll",
    "004": "panel_plain",
}
MIN_SIDE_PX = 120  # 面板都是大块；碎屑/噪点丢弃
PAD = 2            # 连通域 bbox 外扩，避免切掉水彩柔边

image = Image.open(SRC).convert("RGBA")
alpha = np.array(image.getchannel("A"))
mask = alpha > 8
labels, count = label(mask)
OUT.mkdir(parents=True, exist_ok=True)

entries = []
kept = 0
for index in range(1, count + 1):
    ys, xs = np.where(labels == index)
    x0, x1 = int(xs.min()) - PAD, int(xs.max()) + 1 + PAD
    y0, y1 = int(ys.min()) - PAD, int(ys.max()) + 1 + PAD
    if (x1 - x0) < MIN_SIDE_PX or (y1 - y0) < MIN_SIDE_PX:
        continue
    kept += 1
    region = image.crop((x0, y0, x1, y1))
    name = f"{kept:03d}_{(x0 + x1) // 2}-{(y0 + y1) // 2}.png"
    path = OUT / name
    quantized = region.quantize(colors=256, method=Image.Quantize.FASTOCTREE)
    quantized.save(path, optimize=True)
    entries.append({
        "file": f"image/WatercolorUI/ui_panels/{name}",
        "semantic": SEMANTIC.get(f"{kept:03d}", f"panel_{kept:03d}"),
        "bboxInSheet": [x0, y0, x1, y1],
        "size": [region.width, region.height],
    })

manifest = {
    "schema_version": 1,
    "style": "reading_sea_watercolor 离线切分（ui_panels）",
    "format": "256 色调色板 PNG（FASTOCTREE），九宫格消费（backgroundFit=sliced）",
    "assets": entries,
}
(OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"kept": kept, "assets": entries}, ensure_ascii=False, indent=2))
