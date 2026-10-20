"""Rebuild an island base plate so a watercolour wash stops reading as a box.

Why this exists
---------------
island_01 renders `coast_base_v3` through ImageArt.Plane as a 2r plate. The
authored artwork is painted edge to edge (alpha bbox x = 0..1024) and its body
sits below the canvas centre, so on the sea it shows up as a hard-edged white
rectangle hanging under the island (2026-10-20 real-device report).

What it does
------------
Keeps every brushstroke and re-samples the painting in polar coordinates: each
direction is stretched onto one shared near-circular silhouette, so over-long
directions (the wide flanks, the shoal spilling to the bottom edge) are
compressed instead of leaking out as a slab. Pale foam is thinned before the
resample, the lower rim skirt is bleached, the plate fades to zero alpha inside
the canvas (transparent corners by construction) and is cropped tight to a
square so the plane never shows a transparent margin as a shape.

Output contract
---------------
Square RGBA PNG, content = whole canvas, alpha reaches 0 before the canvas edge.
Set the catalog entry to pixelWidth/contentWidth = 800 / 704 after a rebuild
(704 = 2 * 400 * BODY_RATIO, the painted body diameter), which makes the island
body line up with the world radius r instead of overshooting it with foam.

Usage
-----
    python tests/prepare_island_base.py <src.png> <dst.png> [--report r.json]

Fold the shipped file:
    python tests/prepare_island_base.py \\
        assets/image/OceanComponents/coast_base_v3.png \\
        assets/image/OceanComponents/coast_base_v3.png
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

CANVAS = 1024            # working canvas, downsampled to OUT_SIZE at the end
OUT_SIZE = 800           # shipped size (power-of-two friendly, <= source)
BODY_RATIO = 0.88        # painted body radius / half canvas
FADE = 0.12              # outer alpha fade band, share of the body radius
ANGLES = 2048            # angular resolution of the outline trace
ALPHA_FLOOR = 0.82       # alpha treated as "painted body" when tracing the outline
PALE_MIN_RGB = 0.88      # pale wash kept but thinned (this is what paints the box)
PALE_KEEP = 0.34
LOWER_SKIRT_KILL = 0.55  # extra bleaching of the pale skirt along the lower rim


def smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    e0 = np.asarray(edge0, dtype=np.float32)
    e1 = np.asarray(edge1, dtype=np.float32)
    denom = np.where(np.abs(e1 - e0) < 1e-6, 1e-6, e1 - e0)
    t = np.clip((np.asarray(x, dtype=np.float32) - e0) / denom, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def bilinear(img: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    h, w = img.shape[:2]
    xs = np.clip(xs, 0, w - 1.001)
    ys = np.clip(ys, 0, h - 1.001)
    x0 = np.floor(xs).astype(np.int32)
    y0 = np.floor(ys).astype(np.int32)
    x1, y1 = x0 + 1, y0 + 1
    fx = (xs - x0)[..., None]
    fy = (ys - y0)[..., None]
    top = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
    bot = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
    return top * (1 - fy) + bot * fy


def trace_outline(src: np.ndarray) -> tuple[float, float, np.ndarray]:
    """Locate the painted body centre and a near-circular target silhouette.

    A least-squares ellipse over the traced radii keeps the slab shape (pale
    foam and shoal dominate the extents), so the silhouette is anchored on the
    median traced radius plus a small multi-lobe modulation instead.
    """
    alpha = src[:, :, 3]
    mask = alpha > ALPHA_FLOOR
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        raise SystemExit("no painted body found in source")
    cx, cy = float(xs.mean()), float(ys.mean())

    thetas = np.linspace(-np.pi, np.pi, ANGLES, endpoint=False)
    steps = 900
    radii = np.zeros(ANGLES, dtype=np.float64)
    for i, t in enumerate(thetas):
        rr = np.linspace(4.0, 620.0, steps)
        px = cx + np.cos(t) * rr
        py = cy + np.sin(t) * rr
        inside = (px >= 0) & (px < alpha.shape[1] - 1) & (py >= 0) & (py < alpha.shape[0] - 1)
        vals = np.zeros(steps)
        vals[inside] = bilinear(alpha[:, :, None], px[inside], py[inside])[:, 0]
        hit = np.nonzero(vals > ALPHA_FLOOR)[0]
        radii[i] = rr[hit[-1]] if len(hit) else 0.0

    live = radii[radii > 0]
    if len(live) == 0:
        raise SystemExit("empty outline")
    med = float(np.median(live))
    silhouette = med * (1.0
                        + 0.045 * np.sin(3 * thetas + 0.8)
                        + 0.025 * np.sin(5 * thetas + 2.3)
                        + 0.015 * np.sin(7 * thetas + 4.1))
    return cx, cy, silhouette


def rebuild(src_path: Path, dst_path: Path) -> dict:
    src = np.asarray(Image.open(src_path).convert("RGBA"), dtype=np.float32) / 255.0

    pale = (src[:, :, :3].min(axis=2) > PALE_MIN_RGB) & (src[:, :, 3] < 0.96)
    src[:, :, 3] = np.where(pale, src[:, :, 3] * PALE_KEEP, src[:, :, 3])

    cx, cy, silhouette = trace_outline(src)

    half = CANVAS / 2.0
    body_r = half * BODY_RATIO
    apron_r = body_r * (1.0 + FADE)

    grid = np.arange(CANVAS, dtype=np.float32) - half
    gx, gy = np.meshgrid(grid, grid)
    rho = np.sqrt(gx * gx + gy * gy)
    theta = np.arctan2(gy, gx)

    idx = ((theta + np.pi) / (2 * np.pi) * ANGLES) % ANGLES
    src_r = np.interp(idx, np.arange(ANGLES), silhouette)
    scale = src_r / body_r
    xs = cx + np.cos(theta) * rho * scale
    ys = cy + np.sin(theta) * rho * scale
    out = bilinear(src, xs, ys)

    fade = smoothstep(apron_r, body_r, rho)
    out[:, :, 3] *= fade

    lower = np.clip(gy / (body_r * 0.75), 0.0, 1.0)
    whiteish = out[:, :, :3].min(axis=2) > 0.88
    out[:, :, 3] *= 1.0 - LOWER_SKIRT_KILL * lower * whiteish

    img = Image.fromarray((np.clip(out, 0, 1) * 255).round().astype(np.uint8), "RGBA")
    img = img.filter(ImageFilter.GaussianBlur(0.4))

    bb = img.getchannel("A").getbbox()
    pad = 3
    bb = (max(0, bb[0] - pad), max(0, bb[1] - pad),
          min(img.width, bb[2] + pad), min(img.height, bb[3] + pad))
    img = img.crop(bb)
    w, h = img.size
    square = Image.new("RGBA", (max(w, h), max(w, h)), (0, 0, 0, 0))
    square.alpha_composite(img, ((max(w, h) - w) // 2, (max(w, h) - h) // 2))
    square = square.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    square.save(dst_path)

    bb2 = square.getchannel("A").getbbox()
    alpha_px = np.asarray(square.getchannel("A"))
    return {
        "dst": str(dst_path),
        "size": list(square.size),
        "content_bounds": list(bb2),
        "content_size": [bb2[2] - bb2[0], bb2[3] - bb2[1]],
        "transparent_ratio": round(float((alpha_px <= 8).mean()), 4),
        "edge_touch": int((bb2[0] < 3) + (bb2[1] < 3)
                          + (bb2[2] > OUT_SIZE - 3) + (bb2[3] > OUT_SIZE - 3)),
        "catalog": {"pixelWidth": OUT_SIZE, "pixelHeight": OUT_SIZE,
                    "contentWidth": round(OUT_SIZE * BODY_RATIO),
                    "contentHeight": round(OUT_SIZE * BODY_RATIO)},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("src", type=Path)
    parser.add_argument("dst", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = rebuild(args.src, args.dst)
    text = json.dumps(report, indent=2, ensure_ascii=False)
    print(text)
    if args.report:
        args.report.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
