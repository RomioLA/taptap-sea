"""OceanArtCollection（V2.8 海上节点 / 物品图标美术合集）规格生成与校验。

用途（2026-10-20 用户提供的美术合集接入）：
- `assets/image/OceanArtCollection/` 下是本批正式候选素材（水彩绘本风，RGBA PNG）；
- 本脚本把它们整理成运行时规格，写进现有唯一目录生成链
  `scripts/GeneratedData/OceanImageCatalog.lua`（**不手工编辑该文件**，见
  docs/ART_PIPELINE.md §2.13）；
- 生成 `assets/image/OceanArtCollection/manifest.json`，供
  `tests/prepare_ocean_ready_art.py` 的 catalog_text 汇总。

约束（docs/ART_PIPELINE.md）：
- 只处理表现规格，不写实体、玩法数值或更新逻辑；
- 不为素材新增第二套图片目录 / ImageArt / 投影；
- 素材替换失败必须保留矢量 fallback，因此本脚本只登记 catalog 条目，
  绘制侧的贴图优先 + 矢量兜底由 SeaDraw 自己决定。

用法：
  python tests/prepare_ocean_art_collection.py            # 整理 + 生成 manifest
  python tests/prepare_ocean_art_collection.py --check    # 只校验，不写文件
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets/image/OceanArtCollection"

# 素材文件名 -> (catalog 名, 用途分类, 说明)
#
# 分类：
#   sea_node  = V2.8 固定海上节点的海上占位符替换（走 SeaDraw 世界平面/立牌绘制）
#   item_icon = 背包 / 独立道具栏 / 结算里的物品图标（不走世界绘制）
#
# 同一素材的多分辨率版本只登记一个运行时条目（取像素更充足的那份），
# 另一份保留在合集里作为源料，不重复进 catalog。
ASSETS = {
    # ---- V2.8 海上节点 ----
    "23d6254c-debris_01.png": (
        "debris_01", "sea_node", "漂浮木板带（05-A）"),
    "d6ebaee5-shipwreck_01.png": (
        "shipwreck_01", "sea_node", "水下旧木船残骸（05-B，探海镜可见）"),
    "30a5a944-leviathan_bones_01_2048x1024.png": (
        "leviathan_bones_01", "sea_node", "巨兽骸骨（03，水下）"),
    "f18b358c-sea_eye_vortex_01_v2_normal.png": (
        "sea_eye_vortex_01", "sea_node", "海眼漩涡常态（10）"),
    "d437af41-sea_eye_vortex_01_v2_boost.png": (
        "sea_eye_vortex_01_boost", "sea_node", "海眼漩涡投放增强态（10）"),
    "7e0e0194-drift_bottle_01_v2_1024.png": (
        "bottle_note_01", "sea_node", "漂流瓶（08-A/B，1024 运行时版）"),
    # ---- 物品图标 ----
    "dacdad07-sea_note_01_v2_1024.png": (
        "sea_note_01", "item_icon", "航海残页图标（1024 运行时版）"),
    "3dc43067-abyss_pearl.png": (
        "abyss_pearl", "item_icon", "深海珍珠图标"),
    "157da5af-coral_branch_01.png": (
        "coral_branch", "item_icon", "珊瑚枝图标"),
    "e5b77519-jewelry_01.png": (
        "jewelry_01", "item_icon", "沉船珠宝图标"),
}

# 只作源料、不进 catalog 的分辨率变体（同素材的备用尺寸）。
SOURCE_ONLY = {
    "f7da323f-drift_bottle_01_v2_512.png": "bottle_note_01 的 512 备用版",
    "deb68261-sea_note_01_v2_512.png": "sea_note_01 的 512 备用版",
}

MANIFEST = SRC / "manifest.json"


def image_module():
    from PIL import Image
    return Image


def describe(path, name, kind, note):
    """与 tests/prepare_ocean_art.py 的 describe 同口径，另加分类字段。"""
    Image = image_module()
    with Image.open(path) as image:
        image = image.convert("RGBA")
        size = image.size
        bounds = image.getchannel("A").getbbox()
        if not bounds:
            raise ValueError(f"素材无可见主体：{path}")
        alpha = image.getchannel("A")
        values = list(alpha.get_flattened_data()) if hasattr(alpha, "get_flattened_data") \
            else list(alpha.getdata())
        transparent = sum(1 for v in values if v == 0)
        return {
            "path": path.relative_to(ROOT / "assets").as_posix().replace("assets/", "", 1)
            if path.relative_to(ROOT / "assets").as_posix().startswith("assets/")
            else path.relative_to(ROOT / "assets").as_posix(),
            "name": name,
            "kind": kind,
            "note": note,
            "size": [size[0], size[1]],
            "content_bounds": list(bounds),
            "alpha_range": [min(values), max(values)],
            "transparent_ratio": round(transparent / max(1, len(values)), 6),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "anchor": [0.5, 0.5],
            "preload": False,
        }


def build(check_only):
    Image = image_module()
    missing = [f for f in list(ASSETS) + list(SOURCE_ONLY) if not (SRC / f).is_file()]
    if missing:
        raise SystemExit("缺少素材：" + ", ".join(sorted(missing)))

    assets = {}
    for filename, (name, kind, note) in ASSETS.items():
        entry = describe(SRC / filename, name, kind, note)
        entry["source_file"] = filename
        assets[name] = entry
    sources = {}
    for filename, note in SOURCE_ONLY.items():
        entry = describe(SRC / filename, filename, "source_only", note)
        sources[filename] = entry

    manifest = {
        "schema_version": 1,
        "status": "RUNTIME_CANDIDATE",
        "style": "读海日系水彩绘本风（与 OceanStory/OceanEco 同源）",
        "format": "RGBA PNG 直通 Alpha；中心锚点；世界尺寸由实体 radius 决定，不由像素推导",
        "projection": "Ocean.Projection 世界平面分片投影（ImageArt.Plane/Upright）；本批不外挂第二套投影",
        "placement": "catalog 规格由此 manifest 汇总生成；绘制接入在 SeaDraw，贴图失败回退既有矢量占位",
        "references": [
            "docs/ART_PIPELINE.md",
            "scripts/Ocean/SeaDraw.lua",
            "scripts/Ocean/ImageArt.lua",
        ],
        "note": (
            "sea_node 条目是 V2.8 固定海上节点从矢量占位升级为正式素材；"
            "item_icon 条目是物品图标（不进世界绘制）。"
            "两份 512 变体只作源料保留，不进 catalog。"
        ),
        "assets": assets,
        "source_only": sources,
    }
    text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    if check_only:
        if not MANIFEST.is_file():
            raise SystemExit("缺少 manifest，请先运行生成")
        if MANIFEST.read_text(encoding="utf-8") != text:
            raise SystemExit("manifest 与素材不一致，请重新运行生成")
    else:
        MANIFEST.write_text(text, encoding="utf-8")

    # 一致性：每份素材画布与 content bounds 必须在画布内。
    for name, entry in list(assets.items()) + list(sources.items()):
        w, h = entry["size"]
        x0, y0, x1, y1 = entry["content_bounds"]
        if not (0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h):
            raise SystemExit(f"{name} 的 content bounds 越界：{entry['content_bounds']} in {w}x{h}")
    print(json.dumps({
        "ok": True,
        "seaNode": sum(1 for e in assets.values() if e["kind"] == "sea_node"),
        "itemIcon": sum(1 for e in assets.values() if e["kind"] == "item_icon"),
        "sourceOnly": len(sources),
        "manifest": str(MANIFEST.relative_to(ROOT)),
    }, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验，不写文件")
    args = parser.parse_args()
    build(args.check)


if __name__ == "__main__":
    main()
