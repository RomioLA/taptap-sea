"""导入本轮海面平面素材，保留生成源图并记录 Alpha、锚点与溯源。"""
from pathlib import Path
import hashlib
import json
from collections import deque
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/OceanLoop"
SOURCES = {
    "boat": ("OceanStory_boat_20261005114947.png", (1024, 512), True),
    "island": ("OceanStory_island_20261005114948.png", (1024, 1024), False),
    "gull": ("OceanStory_gull_20261005114946.png", (512, 512), True),
    "barrel": ("OceanStory_barrel_20261005115009.png", (512, 512), False),
}


def clean_alpha(image):
    alpha = image.getchannel("A")
    width, height = image.size
    pixels = alpha.tobytes()
    visited = bytearray(len(pixels))
    largest = []
    for start, value in enumerate(pixels):
        if value < 32 or visited[start]:
            continue
        group, queue = [], deque([start])
        visited[start] = 1
        while queue:
            index = queue.popleft()
            group.append(index)
            x, y = index % width, index // width
            for adjacent in (index - 1 if x else -1, index + 1 if x + 1 < width else -1,
                             index - width if y else -1, index + width if y + 1 < height else -1):
                if adjacent >= 0 and not visited[adjacent] and pixels[adjacent] >= 32:
                    visited[adjacent] = 1
                    queue.append(adjacent)
        if len(group) > len(largest):
            largest = group
    mask_data = bytearray(len(pixels))
    for index in largest:
        mask_data[index] = 255
    mask = Image.frombytes("L", image.size, bytes(mask_data)).filter(ImageFilter.MaxFilter(5))
    result = image.copy()
    from PIL import ImageChops
    result.putalpha(ImageChops.multiply(alpha, mask))
    # Alpha 为零的 RGB 清零，不把黑底或白底混入边缘。
    result.paste((0, 0, 0, 0), mask=ImageChops.invert(result.getchannel("A").point(lambda a: 255 if a else 0)))
    return repair_edge_rgb(result)


def repair_edge_rgb(image):
    """半透明边缘与透明留边继承最近的主体颜色，避免缩小后出现暗圈/彩点。"""
    import numpy as np
    from scipy.ndimage import binary_erosion, distance_transform_edt
    values = np.array(image.convert("RGBA"))
    opaque = values[:, :, 3] >= 240
    # 生成抠图偶有不透明黄/洋红碎点，不能只修Alpha：先从干净主体恢复RGB。
    rgb = values[:, :, :3].astype(float)
    maximum, minimum = rgb.max(axis=2), rgb.min(axis=2)
    saturation = (maximum - minimum) / np.maximum(maximum, 1)
    contaminated = (saturation > 0.65) & (rgb[:, :, 0] > 210) & (
        (rgb[:, :, 1] > 190) | (rgb[:, :, 2] > 100))
    safe = opaque & ~contaminated
    if safe.any() and contaminated.any():
        _, clean_indices = distance_transform_edt(~safe, return_indices=True)
        clean_rgb = values[clean_indices[0], clean_indices[1], :3]
        values[contaminated, :3] = clean_rgb[contaminated]
    interior = binary_erosion(safe, iterations=6)
    if interior.any():
        _, indices = distance_transform_edt(~interior, return_indices=True)
        nearest = values[indices[0], indices[1], :3]
        border = ~interior
        values[border, :3] = nearest[border]
    return Image.fromarray(values, "RGBA")


def resize_rgba(image, size):
    # 预乘空间缩放避免透明RGB参与插值，保存时恢复直通Alpha。
    resized = image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
    return repair_edge_rgb(resized)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    entries = {}
    for key, (name, size, rotate) in SOURCES.items():
        source = ROOT / "assets/image" / name
        image = clean_alpha(Image.open(source).convert("RGBA"))
        image = image.crop(image.getchannel("A").getbbox())
        if rotate:
            image = image.transpose(Image.Transpose.ROTATE_270)
        # 画布留边固定为 6%；世界尺寸对应整个画布，锚点保持正中心。
        target = Image.new("RGBA", size, (0, 0, 0, 0))
        content_size = (round(size[0] * 0.88), round(size[1] * 0.88))
        if key == "gull":
            image = resize_rgba(image, (round(content_size[1] * image.width / image.height), content_size[1]))
        else:
            image = resize_rgba(image, content_size)
        target.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
        target = repair_edge_rgb(target)
        path = OUT / (key + ".png")
        target.save(path, optimize=True)
        entries[key] = describe(path, source.relative_to(ROOT).as_posix())
    # 波纹为独立可缩放 PNG；透明内区确保不会遮住船或木桶。
    scale = 4
    ripple = Image.new("RGBA", (512 * scale, 512 * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(ripple)
    draw.arc((30 * scale, 30 * scale, 482 * scale, 482 * scale), 8, 148,
             fill=(247, 242, 216, 210), width=6 * scale)
    draw.arc((34 * scale, 25 * scale, 478 * scale, 480 * scale), 195, 337,
             fill=(247, 242, 216, 185), width=5 * scale)
    draw.arc((58 * scale, 58 * scale, 454 * scale, 454 * scale), 30, 125,
             fill=(173, 222, 209, 120), width=3 * scale)
    ripple = resize_rgba(ripple, (512, 512))
    path = OUT / "ripple.png"
    ripple.save(path, optimize=True)
    entries["ripple"] = describe(path, "tests/prepare_ocean_art.py:绘本透明弧环")
    source = ROOT / "assets/image/OceanStory_waterpaper_20261005114940.png"
    paper = Image.open(source).convert("RGBA").resize((512, 512), Image.Resampling.LANCZOS)
    # 镜像成周期纹理；四边连续。这里只是纸感材质，不含可交互世界对象。
    tile = Image.new("RGBA", (1024, 1024))
    tile.paste(paper, (0, 0))
    tile.paste(paper.transpose(Image.Transpose.FLIP_LEFT_RIGHT), (512, 0))
    tile.paste(paper.transpose(Image.Transpose.FLIP_TOP_BOTTOM), (0, 512))
    tile.paste(paper.transpose(Image.Transpose.ROTATE_180), (512, 512))
    path = OUT / "waterpaper.png"
    tile.save(path, optimize=True)
    entries["waterpaper"] = describe(path, source.relative_to(ROOT).as_posix())
    manifest = {"task": "Ocean 航海绘本美术替换闭环", "date": "2026-10-05",
                "reference": "_uploads/c3fb8b9b0834ca6c098bcb452e23f0c1a899c2747c3b9787e317156cb7abd5b8.png",
                "style": "暖赭细描边、简化色块、轻水彩纸感",
                "format": "RGBA PNG，直通 Alpha；透明边RGB扩边；船和海鸥船头/鸟喙朝 +X",
                "projection": "现有 Ocean.Projection；贴图在世界平面先旋转，再分片投影",
                "anchor": [0.5, 0.5], "assets": entries}
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


def describe(path, source):
    image = Image.open(path).convert("RGBA")
    alpha = image.getchannel("A")
    histogram = alpha.histogram()
    return {"path": path.relative_to(ROOT / "assets").as_posix(), "source": source,
            "size": list(image.size), "content_bounds": list(alpha.getbbox()),
            "alpha_range": list(alpha.getextrema()), "transparent_ratio": histogram[0] / (image.width * image.height),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


if __name__ == "__main__":
    main()
