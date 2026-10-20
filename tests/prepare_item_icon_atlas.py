"""把 OceanArtCollection 的物品图标并进 WatercolorUI 图集链（UI.Sprite 可直接消费）。

背景（2026-10-20）：用户供的 V2.8 美术合集里，4 张是**物品图标**
（航海残页 / 深海珍珠 / 珊瑚枝 / 沉船珠宝），不是海上节点占位符。
HUD 物品行原本没有任何图标绘制入口，而现有 UI 体系里唯一可直接消费图片的
控件是 `UI.Sprite`——它读 PixiJS 图集 JSON，不读单张 PNG。

因此本脚本把这 4 张图缩到 UI 图标尺寸、写成 WatercolorUI 的切片格式，
让 `tests/pack_watercolor_ui.py` 像处理其它 UI 图标一样打进图集：

  1) 运行本脚本     -> 生成 assets/image/WatercolorUI/item_icons/*.png + 更新 manifest
  2) 运行 pack_watercolor_ui.py -> 生成 item_icons.json + atlas/item_icons.png
  3) HUD 用 UI.Sprite({ src = "image/WatercolorUI/item_icons.json", frame = ... })

约束（docs/ART_PIPELINE.md）：
- 只做 UI 表现素材整理，不碰玩法、世界实体或存档；
- 不新建第二套图标目录体系：产物直接落在既有 WatercolorUI 目录与既有打包器输入里；
- 图标尺寸按 UI 行高（物品行约 22-28px）留 2-3 倍余量，不做超大图。

用法：
  python tests/prepare_item_icon_atlas.py           # 生成切片 + 更新 manifest
  python tests/prepare_item_icon_atlas.py --check   # 只校验
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets/image/OceanArtCollection"
UI_DIR = ROOT / "assets/image/WatercolorUI"
OUT = UI_DIR / "item_icons"
MANIFEST = UI_DIR / "manifest.json"

SHEET = "item_icons"
# 图标边长（像素）。物品行 icon 画 24px 左右，96 在 3x DPR 下仍有余量。
ICON_SIZE = 96
# 与 HUD 的 frame 名一一对应（itemId 见 scripts/data/items.lua）
ICONS = {
    "sea_note": "dacdad07-sea_note_01_v2_1024.png",       # 航海残页 01/02
    "abyss_pearl": "3dc43067-abyss_pearl.png",            # 深海珍珠
    "coral_branch": "157da5af-coral_branch_01.png",        # 珊瑚枝
    "jewelry": "e5b77519-jewelry_01.png",                  # 沉船珠宝
}


def image_module():
    from PIL import Image
    return Image


def build(check_only):
    Image = image_module()
    missing = [f for f in ICONS.values() if not (SRC / f).is_file()]
    if missing:
        raise SystemExit("缺少素材：" + ", ".join(sorted(missing)))

    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for semantic, filename in ICONS.items():
        source = SRC / filename
        with Image.open(source) as raw:
            image = raw.convert("RGBA")
            bounds = image.getchannel("A").getbbox()
            if not bounds:
                raise SystemExit(f"{filename} 无可见主体")
            image = image.crop(bounds)
            # 等比缩放到留 8% 透明边，避免图标贴边被圆角/描边切掉
            inner = max(1, round(ICON_SIZE * 0.92))
            ratio = min(inner / image.width, inner / image.height)
            size = (max(1, round(image.width * ratio)), max(1, round(image.height * ratio)))
            image = image.resize(size, Image.Resampling.LANCZOS)
            canvas = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
            canvas.paste(image, ((ICON_SIZE - size[0]) // 2, (ICON_SIZE - size[1]) // 2))
            target = OUT / (semantic + ".png")
            if not check_only:
                canvas.save(target, optimize=True)
            entries[semantic] = {
                "file": target.relative_to(ROOT / "assets").as_posix(),
                "source": source.relative_to(ROOT).as_posix(),
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            }

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assets = manifest["assets"]
    # 先清掉本 sheet 的旧条目，保证重跑幂等
    for key in [k for k in assets if k.startswith(SHEET + "_")]:
        del assets[key]
    for index, (semantic, entry) in enumerate(sorted(entries.items())):
        assets[f"{SHEET}_{index:03d}"] = {
            "file": entry["file"],
            "sheet": SHEET,
            "bboxInSheet": [0, 0, ICON_SIZE, ICON_SIZE],
            "size": [ICON_SIZE, ICON_SIZE],
            "anchor": [0.5, 0.5],
        }
    text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    if check_only:
        if not all((OUT / (s + ".png")).is_file() for s in ICONS):
            raise SystemExit("图标切片缺失，请先运行生成")
    else:
        MANIFEST.write_text(text, encoding="utf-8")

    print(json.dumps({
        "ok": True,
        "sheet": SHEET,
        "icons": sorted(ICONS),
        "iconSize": ICON_SIZE,
        "manifestEntries": len([k for k in assets if k.startswith(SHEET + "_")]),
        "note": "下一步运行 tests/pack_watercolor_ui.py 生成图集 JSON",
    }, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验，不写文件")
    args = parser.parse_args()
    build(args.check)


if __name__ == "__main__":
    main()
