"""导入本轮海面平面素材，保留生成源图并记录 Alpha、锚点与溯源。"""
from pathlib import Path
import hashlib
import json
from collections import deque
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets/image/OceanLoop"
SOURCES = {
    "boat": ("OceanLoop_boat_topdown_20261005103106.png", (1024, 512), True),
    "island": ("OceanLoop_island_topdown_20261005103049.png", (1024, 1024), False),
    "gull": ("OceanLoop_gull_topdown_20261005103040.png", (512, 512), True),
    "barrel": ("OceanLoop_barrel_topdown_20261005103221.png", (512, 512), False),
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
    return result


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
            image = image.resize((round(content_size[1] * image.width / image.height), content_size[1]), Image.Resampling.LANCZOS)
        else:
            image = image.resize(content_size, Image.Resampling.LANCZOS)
        target.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
        path = OUT / (key + ".png")
        target.save(path, optimize=True)
        entries[key] = describe(path, source.relative_to(ROOT).as_posix())
    # 波纹为独立可缩放 PNG；透明内区确保不会遮住船或木桶。
    scale = 4
    ripple = Image.new("RGBA", (512 * scale, 512 * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(ripple)
    draw.arc((30 * scale, 30 * scale, 482 * scale, 482 * scale), 8, 165,
             fill=(223, 245, 236, 210), width=7 * scale)
    draw.arc((30 * scale, 30 * scale, 482 * scale, 482 * scale), 186, 345,
             fill=(223, 245, 236, 210), width=7 * scale)
    draw.arc((58 * scale, 58 * scale, 454 * scale, 454 * scale), 25, 140,
             fill=(244, 252, 240, 120), width=3 * scale)
    ripple = ripple.resize((512, 512), Image.Resampling.LANCZOS)
    path = OUT / "ripple.png"
    ripple.save(path, optimize=True)
    entries["ripple"] = describe(path, "tests/prepare_ocean_art.py:程序化透明弧环")
    manifest = {"task": "Ocean 主航海画面最小美术闭环", "date": "2026-10-05",
                "format": "RGBA PNG，直通 Alpha；船和海鸥船头/鸟喙朝 +X",
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
