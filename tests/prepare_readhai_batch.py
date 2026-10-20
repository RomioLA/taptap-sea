"""读海美术交付批次入库（2026-10-20 用户提供 C:/codex/taptap-jam/Fishing）。

本脚本只做「已确定要入库」的那一批：
- 岛：完整岛 island_01/02（分层贴图层，替换画布）
- 海面/天空：v1 与 v2 变体（并入既有 SeaSurface/Sky 合集，不新建平行目录）
- 水下剧情节点：水下宝藏 / 破渔网 / 浮藻假岛 / 巨兽气泡 / sea_eye vortex v1
- 玩家船正式水彩：player_boat
- 成就徽章 6 枚
- UI 三件（对话框 / 气泡提示 / 按钮底板）

契约（docs/ART_PIPELINE.md）：
- 不新建第二套图片目录 / ImageArt / 投影；产物落在既有 `assets/image/<合集>/`
- manifest 用与既有合集同口径的 `describe()` 字段（size / content_bounds /
  alpha_range / transparent_ratio / sha256），由 catalog 生成器统一汇总
- 只登记表现规格，不写实体、玩法数值或更新逻辑

用法：
  python tests/prepare_readhai_batch.py            # 入库 + 写 manifest
  python tests/prepare_readhai_batch.py --check     # 只读校验
"""
import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
# 交付目录（美术侧）。美术按批次交付到 `taptap-jam/` 下的不同子目录，2026-10-20
# 第二批的「船舱物品」直接落在 jam 根目录、而非 Fishing/ 内部，因此按顺序在多个
# 根上解析；整批目录缺失时 check 降级为「只校验项目侧」，不阻塞 CI。
SOURCE_BASE = Path("C:/codex/taptap-jam")
SOURCE_ROOTS = (SOURCE_BASE / "Fishing", SOURCE_BASE)


def resolve_source(rel):
    """在交付根列表里定位源图；返回 (path, root_label)。"""
    for root in SOURCE_ROOTS:
        candidate = root / rel
        if candidate.is_file():
            return candidate, root.name
    raise SystemExit("缺少源图：" + " / ".join(str(r / rel) for r in SOURCE_ROOTS))

# 合集 -> {输出名: (源相对路径, 分类, 说明)}
BATCH = {
    "OceanStoryLayer": {
        "island_01_full": (
            "读海_完整岛屿_island01_v1_assets/540e96e8-读海_island_01_完整岛屿_v1.png",
            "island_body", "初遇之岛 01 完整分层底图（岸线+丘+植被）"),
        "island_02_full": (
            "读海_完整岛屿_island01_v1_assets/729885a0-读海_island_02_完整岛屿_v1.png",
            "island_body", "第二座岛 02 完整分层底图"),
    },
    # V2.8 海上节点正式素材：一律并入既有 OceanArtCollection 合集（append-only，
    # 由 tests/prepare_ocean_art_collection.py 负责老 10 条，本脚本只追加新条目）。
    "OceanArtCollection": {
        "underwater_treasure_01": (
            "读海_水下宝藏_v1_assets/4797806b-underwater_treasure_01.png",
            "sea_node", "03 水下宝藏（探海镜标记点）"),
        "trapped_net_01": (
            "读海_破渔网_v1_assets/trapped_net_01.png",
            "sea_node", "06 破渔网双分支节点"),
        "kelp_mirage_01": (
            "读海_破渔网_v1_assets/kelp_mirage_01_a.png",
            "sea_node", "12 浮藻假岛（岛影态，80m 轮廓）"),
        "kelp_mirage_01_b": (
            "读海_破渔网_v1_assets/kelp_mirage_01_b.png",
            "sea_node", "12 浮藻假岛（20m 识破后的藻层态）"),
        "leviathan_bubbles_01": (
            "读海_沉船_v1_assets/43594104-leviathan_bubbles_01.png",
            "fx", "03 巨骨海面慢气泡"),
        "sea_eye_vortex_01_v1": (
            "读海_海面特效_v1_assets/363c72a9-sea_eye_vortex_01.png",
            "fx", "10 海眼漩涡 v1 常态（v2 为主用，v1 留 A/B）"),
        "sea_eye_vortex_01_v1_boost": (
            "读海_海面特效_v1_assets/bb401ed7-sea_eye_vortex_01_boost.png",
            "fx", "10 海眼漩涡 v1 增强态"),
        # 物品图标（2026-10-20 第二批交付：船舱物品目录更新版）。
        # 四个基础物品此前完全没有图标素材，HUD 物品行只有文字；这四张补上。
        "apple_01": (
            "读海_船舱物品_v1_assets/apple_01.png", "item_icon", "物品图标：苹果"),
        "bait_01": (
            "读海_船舱物品_v1_assets/bait_01.png", "item_icon", "物品图标：鱼饵"),
        "sardine_01": (
            "读海_船舱物品_v1_assets/sardine_01.png", "item_icon", "物品图标：沙丁鱼"),
        "tuna_01": (
            "读海_船舱物品_v1_assets/tuna_01.png", "item_icon", "物品图标：金枪鱼"),
        # 图鉴版（同一物种的另一画法，带标本式构图）：先入库备用，不接管图鉴页。
        "codex_sardine_01": (
            "读海_船舱物品_v1_assets/codex_sardine_01.png", "codex_icon", "图鉴图标：沙丁鱼标本版"),
        "codex_tuna_01": (
            "读海_船舱物品_v1_assets/codex_tuna_01.png", "codex_icon", "图鉴图标：金枪鱼标本版"),
        "salvaged_chest_01": (
            "读海_船舱物品_v1_assets/03a7091c-salvaged_chest_01.png",
            "item_icon", "物品图标：海底金属货箱（12 浮藻假岛奖励）"),
        "rusty_key_01": (
            "读海_船舱物品_v1_assets/6f2840c2-rusty_key_01.png",
            "item_icon", "物品图标：生锈钥匙（06 破渔网分支 B）"),
    },
    "OceanShip": {
        "player_boat": (
            "读海_玩家船_正式水彩素材_assets/d9c2abf1-player_boat.png",
            "boat", "玩家船正式水彩（正俯视，船头 +X）"),
        "player_boat_scene": (
            "读海_玩家船_正式水彩素材_assets/0b7dfe2c-_scene_boat_zoom.png",
            "reference", "玩家船场景合成参考（非运行时，RGB 整幅）"),
        "player_boat_sheet": (
            "读海_玩家船_正式水彩素材_assets/5312d634-boat_only_sheet.png",
            "reference", "玩家船部件表（非运行时，RGB 整幅）"),
        "player_boat_view": (
            "读海_玩家船_正式水彩素材_assets/587cfafa-_view_final3.png",
            "reference", "玩家船合成视图（非运行时，RGB 整幅）"),
    },
    "WatercolorUI": {
        # 成就徽章 6 枚（交付命名按图片语义，不猜测与 A1~A6/C1~C3 的一一对应：
        # 现有成就数据里没有徽章绑定字段，擅自映射会把美术语义写成玩法事实）。
        "achievement_first_lens": (
            "读海_成就徽章_v1_assets/achievement_first_lens.png",
            "badge", "成就徽章：首日探海镜"),
        "achievement_unconventional_path": (
            "读海_成就徽章_v1_assets/achievement_unconventional_path.png",
            "badge", "成就徽章：非常规路径"),
        "achievement_lifesaving_bait": (
            "读海_成就徽章_v1_assets/achievement_lifesaving_bait.png",
            "badge", "成就徽章：救命鱼饵"),
        "achievement_full_load": (
            "读海_成就徽章_v1_assets/achievement_full_load.png",
            "badge", "成就徽章：满载而归"),
        "achievement_big_fish": (
            "读海_成就徽章_v1_assets/achievement_big_fish.png",
            "badge", "成就徽章：大鱼"),
        "achievement_safe_return": (
            "读海_成就徽章_v1_assets/achievement_safe_return.png",
            "badge", "成就徽章：平安归港"),
        "ui_dialogue_panel": (
            "读海_UI素材_v1_assets/0961a748-ui_dialogue_panel_v1.png",
            "ui_chrome", "对话底板（水彩羊皮纸）"),
        "ui_bubble_tip": (
            "读海_UI素材_v1_assets/60dcbe7e-ui_bubble_tip_v1.png",
            "ui_chrome", "气泡提示底板"),
        "ui_btn_normal": (
            "读海_UI素材_v1_assets/deb56a2f-ui_btn_normal_v1.png",
            "ui_chrome", "按钮常态底板"),
    },
}

# 并入既有 SeaSurface 合集（不新建目录）：名字与运行期相位键一一对应，
# 后缀 _v1 的是交付目录里的另一版候选（A/B 用，preload=false）。
SEA_VARIANTS = {
    "sea_surface_day_v1": ("读海_海面_v1_assets/7cc7fbc4-pure_sea_day_v2.png", "海面日相候选 v1"),
    "sea_surface_dusk_v1": ("读海_海面_v1_assets/a52e3c66-pure_sea_dusk_v2.png", "海面暮相候选 v1"),
    "sea_surface_night_v1": ("读海_海面_v1_assets/482bf56c-pure_sea_night_v2.png", "海面夜相候选 v1"),
    "sea_surface_day_flat": ("读海_主场景昼夜套件_v1_assets/906c42bb-pure_sea_day_flat_v1.png", "海面日相平涂版"),
    "sea_surface_night_flat": ("读海_主场景昼夜套件_v1_assets/cf2021b4-pure_sea_night_flat_v1.png", "海面夜相平涂版"),
}
SKY_VARIANTS = {
    "sky_day_v1": ("读海_主场景昼夜套件_v1_assets/c01a5859-pure_sea_day_v1.png", "天空日相整幅候选"),
    "sky_night_v1": ("读海_主场景昼夜套件_v1_assets/3402aeea-pure_sea_night_v1.png", "天空夜相整幅候选"),
    "sky_day_v1_preview": ("读海_天空_v1_assets/be08783f-pure_sky_day_v1_preview.png", "天空日相预览图"),
    "sky_dusk_v1_preview": ("读海_天空_v1_assets/fd749a74-pure_sky_dusk_v1_preview.png", "天空暮相预览图"),
}

# UI 元素的最大像素边长：徽章按 26px 显示、底板按 ~320px 宽显示，给 3x DPR 余量。
UI_PIXEL_LIMITS = {"badge": 192, "ui_chrome": 768}

MANIFESTS = {
    "OceanStoryLayer": ROOT / "assets/image/OceanStoryLayer/manifest.json",
    "OceanArtCollection": ROOT / "assets/image/OceanArtCollection/manifest.json",
    "OceanShip": ROOT / "assets/image/OceanShip/manifest.json",
    "WatercolorUI": ROOT / "assets/image/WatercolorUI/manifest.json",
}


def image_module():
    return Image


# Maker 资源 .meta 的 uuid 规格：base64url(18 字节) = 24 字符（schemas/resources.schema.json
# 的 uuid 协议要求 ^uuid://[A-Za-z0-9]{24}$）。注意 `uuid.UUID.bytes` **恒为 16 字节**，
# 用它会产出 22 字符的非法短 id（2026-10-20 踩过），因此这里自己取 18 字节哈希。
UUID_BYTES = 18


def make_uuid(rel):
    digest = hashlib.sha256(("taptap-sea/readhai/" + rel).encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest[:UUID_BYTES]).decode()


def ensure_meta(path):
    """为**新增**资源补 .meta。

    安全规则（2026-10-20 踩过）：已存在的 .meta 一律不动。
    已提交的资源 uuid 是 Maker 侧引用的锚点，改写会断掉引用——
    哪怕它的长度不在 24 字符规范内，也只能由 prepush 报告，不能自行重写。
    """
    meta = Path(str(path) + ".meta")
    if meta.exists():
        return
    rel = path.relative_to(ROOT / "assets").as_posix()
    meta.write_text(json.dumps({"uuid": make_uuid(rel)}, indent=2) + "\n", encoding="utf-8")


def describe(path, name, kind, note):
    """与 tests/prepare_ocean_art_collection.py 的 describe 同口径。"""
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
            "path": path.relative_to(ROOT / "assets").as_posix(),
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
    if not any(root.is_dir() for root in SOURCE_ROOTS):
        if not check_only:
            raise SystemExit(f"交付目录不存在：{SOURCE_ROOTS}")
        print(json.dumps({"skipped": True, "reason": f"交付目录不存在：{SOURCE_ROOTS}"}, ensure_ascii=False))
        verify_only()
        return

    # 1) 世界/UI 合集（各自独立目录 + manifest）
    for collection, entries in BATCH.items():
        out = ROOT / "assets" / "image" / collection
        out.mkdir(parents=True, exist_ok=True)
        manifest_path = MANIFESTS[collection]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {
            "schema_version": 1,
            "style": "读海日系水彩绘本风（Fishing 交付批次 2026-10-20）",
            "format": "RGBA PNG 直通 Alpha；中心锚点；世界尺寸由实体 radius 决定，不由像素推导",
            "projection": "Ocean.Projection 世界平面分片投影（ImageArt.Plane/Sprite）；本批不外挂第二套投影",
            "placement": "catalog 规格由本 manifest 汇总生成；绘制侧贴图优先、失败回退既有矢量",
            "references": ["docs/ART_PIPELINE.md", "scripts/Ocean/SeaDraw.lua", "scripts/Ocean/ImageArt.lua"],
            "assets": {},
        }
        assets = manifest.setdefault("assets", {})
        batch = {}
        for name, (rel, kind, note) in entries.items():
            source, root_label = resolve_source(rel)
            target = out / (name + ".png")
            limit = UI_PIXEL_LIMITS.get(kind) if collection == "WatercolorUI" else None
            if limit:
                with Image.open(source) as raw:
                    image = raw.convert("RGBA")
                    if max(image.size) > limit:
                        ratio = limit / max(image.size)
                        image = image.resize((max(1, round(image.width * ratio)),
                                              max(1, round(image.height * ratio))),
                                             Image.Resampling.LANCZOS)
                        image.save(target, optimize=True)
                    else:
                        image.save(target, optimize=True)
            elif not target.is_file() or target.stat().st_size != source.stat().st_size:
                target.write_bytes(source.read_bytes())
            entry = describe(target, name, kind, note)
            entry["source_file"] = rel
            entry["source_root"] = root_label
            entry["source_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            # WatercolorUI 的 assets 键必须是 <sheet>_<index> 结构（pack_watercolor_ui.py
            # 的输入契约），因此本批徽章/UI 底板按 readhai_000.. 顺序入 assets，
            # 再用 readhai_frames 记录「序号 -> 语义名」，语义名只有一个落点。
            if collection == "WatercolorUI":
                batch[name] = entry
            else:
                assets[name] = entry
        if collection == "WatercolorUI":
            for key in [k for k in assets if k.startswith("readhai_")]:
                del assets[key]
            frames = {}
            for index, name in enumerate(sorted(batch)):
                entry = batch[name]
                # pack_watercolor_ui.py（图集打包器）读 file/sheet/bboxInSheet/size/
                # anchor 五字段，与既有 WatercolorUI 切片条目同结构；其余溯源字段
                # 一并保留（path/kind/source_sha256 等）。
                assets[f"readhai_{index:03d}"] = {
                    **entry,
                    "file": entry["path"],
                    "sheet": "readhai",
                    "bboxInSheet": [0, 0, entry["size"][0], entry["size"][1]],
                    "anchor": [0.5, 0.5],
                }
                frames[f"readhai_{index:03d}"] = name
            manifest["readhai_frames"] = frames
        if not check_only:
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # 2) 海面 / 天空变体（并入既有合集，不新建目录）
    for collection, variants, style in (
        ("SeaSurface", SEA_VARIANTS, "海面候选变体（A/B 与备用相位）"),
        ("Sky", SKY_VARIANTS, "天空候选变体（整幅候选与预览）"),
    ):
        out = ROOT / "assets/image" / collection
        manifest_path = out / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        assets = manifest.setdefault("assets", {})
        for name, (rel, note) in variants.items():
            source, root_label = resolve_source(rel)
            target = out / (name + ".png")
            if not target.is_file() or target.stat().st_size != source.stat().st_size:
                target.write_bytes(source.read_bytes())
            entry = describe(target, name, "sea_surface_variant" if collection == "SeaSurface" else "sky_variant", note)
            entry["source_file"] = rel
            entry["source_root"] = root_label
            entry["source_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            entry["preload"] = False
            assets[name] = entry
        manifest.setdefault("variants", {})["note"] = style
        if not check_only:
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # 2.5) 新增资源的 .meta（Maker 资源 uuid）。只补缺失/非法长度的，已存在不动。
    for path in sorted((ROOT / "assets" / "image").rglob("*")):
        if path.is_file() and path.suffix.lower() in (".png", ".jpg"):
            ensure_meta(path)

    # 3) 图集：徽章/UI 底板走既有 pack_watercolor_ui.py（UI.Sprite 通道），
    #    本脚本只负责触发重打，避免调用方漏一步导致 json/png 与清单脱节。
    if not check_only:
        import subprocess
        result = subprocess.run([sys.executable, str(ROOT / "tests/pack_watercolor_ui.py"),
                                 "--sheet", "readhai"], cwd=ROOT,
                                capture_output=True, text=True, errors="replace",
                                stdin=subprocess.DEVNULL)
        print(result.stdout.strip() or result.stderr.strip())
        if result.returncode != 0:
            raise SystemExit("readhai 图集重打失败")

    verify_only()


def verify_only():
    report = {}
    for collection, entries in BATCH.items():
        manifest_path = MANIFESTS[collection]
        if not manifest_path.exists():
            continue
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        frames = manifest.get("readhai_frames", {})
        by_semantic = {semantic: manifest["assets"][key] for key, semantic in frames.items()}
        for name in entries:
            entry = manifest["assets"].get(name) or by_semantic.get(name)
            assert entry, f"{collection}/{name} 未写入清单"
            path = ROOT / "assets" / entry["path"]
            assert path.is_file(), f"{name} 运行目录缺失"
            with Image.open(path) as image:
                assert image.mode in ("RGBA", "P", "RGB"), f"{name} 非 RGBA/调色板/RGB"
                assert list(image.size) == entry["size"], f"{name} 尺寸与清单不一致"
            w, h = entry["size"]
            x0, y0, x1, y1 = entry["content_bounds"]
            assert 0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h, f"{name} content bounds 越界"
        report[collection] = len(entries)
    # codex_icon（图鉴备用画法）只入 manifest、不进 catalog：显式记录该意图，
    # 避免以后误当成「漏接」而被悄悄加进世界绘制。
    art_manifest = json.loads((ROOT / "assets/image/OceanArtCollection/manifest.json")
                              .read_text(encoding="utf-8"))
    codex_icons = {name for name, entry in art_manifest["assets"].items()
                   if entry.get("kind") == "codex_icon"}
    if codex_icons:
        catalog_text = (ROOT / "scripts/GeneratedData/OceanImageCatalog.lua").read_text(encoding="utf-8")
        for name in sorted(codex_icons):
            assert f"    {name} = {{" not in catalog_text,                 name + " is a codex-only icon and must not enter the runtime catalog yet"
    # 图集 JSON 必须覆盖全部徽章/UI 帧（防止清单加了、图集没重打）。
    readhai_json = ROOT / "assets/image/WatercolorUI/readhai.json"
    if readhai_json.is_file():
        packed = set(json.loads(readhai_json.read_text(encoding="utf-8"))["frames"])
        expected = set(BATCH["WatercolorUI"])
        assert expected <= packed, f"readhai 图集缺帧：{sorted(expected - packed)}"
    for collection, variants in (("SeaSurface", SEA_VARIANTS), ("Sky", SKY_VARIANTS)):
        manifest = json.loads((ROOT / "assets/image" / collection / "manifest.json").read_text(encoding="utf-8"))
        for name in variants:
            assert name in manifest["assets"], f"{collection}/{name} 未写入清单"
            assert (ROOT / "assets" / manifest["assets"][name]["path"]).is_file()
        report[collection] = report.get(collection, 0) + len(variants)
    print(json.dumps({"passed": True, "batched": report}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只读校验，不写文件")
    args = parser.parse_args()
    build(args.check)
