#!/usr/bin/env python3
"""Execute SeaDraw.Scene in Lua 5.4 with a NanoVG recorder and export offline evidence.

The PNG renderer consumes the recorded vector paths directly. It uses Pillow and
NumPy when available; it does not open the Maker engine or download assets.
"""
from __future__ import annotations

import hashlib
import json
import math
import sys
import traceback
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "screenshots"
DEPENDENCY_DIR = ROOT / ".tmp" / "sea-test-deps"
if str(DEPENDENCY_DIR) not in sys.path:
    sys.path.insert(0, str(DEPENDENCY_DIR))


@dataclass(frozen=True)
class Color:
    r: float
    g: float
    b: float
    a: float


@dataclass(frozen=True)
class LinearGradient:
    x1: float
    y1: float
    x2: float
    y2: float
    start: Color
    end: Color


def _finite(value: Any, fallback: float = 0.0) -> float:
    try:
        result = float(value)
        return result if math.isfinite(result) else fallback
    except (TypeError, ValueError):
        return fallback


def _as_color(value: Any) -> Color:
    if isinstance(value, Color):
        return value
    try:
        return Color(*(_finite(value[index], 255 if index == 4 else 0) for index in range(1, 5)))
    except (TypeError, KeyError, IndexError):
        return Color(0, 0, 0, 255)


def _copy_clip(clip: tuple[float, float, float, float] | None):
    return tuple(clip) if clip is not None else None


class NVGCapture:
    """Small NanoVG recorder for the path, paint, transform, and scissor APIs used here."""

    IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    CURVE_K = 0.5522847498307936

    def __init__(self):
        self.reset()

    def reset(self):
        self.elements: list[dict[str, Any]] = []
        self.calls: list[tuple[str, tuple[Any, ...]]] = []
        self.counts: Counter[str] = Counter()
        self.path: list[tuple[str, tuple[float, ...]]] = []
        self.fill_color = Color(0, 0, 0, 255)
        self.fill_paint: LinearGradient | None = None
        self.stroke_color = Color(0, 0, 0, 255)
        self.stroke_width = 1.0
        self.transform = self.IDENTITY
        self.clip: tuple[float, float, float, float] | None = None
        self.stack: list[dict[str, Any]] = []

    def bind(self, lua):
        globals_ = lua.globals()
        globals_.nvgRGBA = lambda r, g, b, a=255: Color(_finite(r), _finite(g), _finite(b), _finite(a))
        globals_.nvgRGBAf = lambda r, g, b, a=1: Color(
            _finite(r) * 255, _finite(g) * 255, _finite(b) * 255, _finite(a) * 255
        )
        globals_.nvgBeginPath = self.begin_path
        globals_.nvgMoveTo = self.move_to
        globals_.nvgLineTo = self.line_to
        globals_.nvgQuadTo = self.quad_to
        globals_.nvgBezierTo = self.bezier_to
        globals_.nvgClosePath = self.close_path
        globals_.nvgRect = self.rect
        globals_.nvgRoundedRect = self.rounded_rect
        globals_.nvgCircle = self.circle
        globals_.nvgEllipse = self.ellipse
        globals_.nvgFillColor = self.set_fill_color
        globals_.nvgFillPaint = self.set_fill_paint
        globals_.nvgLinearGradient = self.linear_gradient
        globals_.nvgStrokeColor = self.set_stroke_color
        globals_.nvgStrokeWidth = self.set_stroke_width
        globals_.nvgFill = self.fill
        globals_.nvgStroke = self.stroke
        globals_.nvgSave = self.save
        globals_.nvgRestore = self.restore
        globals_.nvgTranslate = self.translate
        globals_.nvgScale = self.scale
        globals_.nvgRotate = self.rotate
        globals_.nvgScissor = self.scissor
        globals_.nvgResetScissor = self.reset_scissor
        return lua.table_from(
            {
                "reset": self.reset,
                "countFillColor": self.count_fill_color,
                "callCount": self.call_count,
                "hasEllipseArgs": self.has_ellipse_args,
                "countEllipseArgs": self.count_ellipse_args,
                "scissorMatches": self.scissor_matches,
            }
        )

    def _call(self, name: str, *args: Any):
        self.counts[name] += 1
        raw = tuple(_finite(v) if isinstance(v, (float, int)) else v for v in args[1:])
        self.calls.append((name, raw))

    @staticmethod
    def _point(matrix, x, y):
        a, b, c, d, e, f = matrix
        return a * x + c * y + e, b * x + d * y + f

    def _push(self, command: str, *coords: float):
        transformed: list[float] = []
        for index in range(0, len(coords), 2):
            x, y = self._point(self.transform, coords[index], coords[index + 1])
            transformed.extend((x, y))
        self.path.append((command, tuple(transformed)))

    def _multiply(self, rhs):
        a, b, c, d, e, f = self.transform
        g, h, i, j, k, l = rhs
        self.transform = (
            a * g + c * h,
            b * g + d * h,
            a * i + c * j,
            b * i + d * j,
            a * k + c * l + e,
            b * k + d * l + f,
        )

    def _append_ellipse(self, x, y, rx, ry):
        k = self.CURVE_K
        self._push("M", x + rx, y)
        self._push("C", x + rx, y + k * ry, x + k * rx, y + ry, x, y + ry)
        self._push("C", x - k * rx, y + ry, x - rx, y + k * ry, x - rx, y)
        self._push("C", x - rx, y - k * ry, x - k * rx, y - ry, x, y - ry)
        self._push("C", x + k * rx, y - ry, x + rx, y - k * ry, x + rx, y)
        self._push("Z")

    def begin_path(self, ctx):
        self._call("nvgBeginPath", ctx)
        self.path = []

    def move_to(self, ctx, x, y):
        self._call("nvgMoveTo", ctx, x, y)
        self._push("M", _finite(x), _finite(y))

    def line_to(self, ctx, x, y):
        self._call("nvgLineTo", ctx, x, y)
        self._push("L", _finite(x), _finite(y))

    def quad_to(self, ctx, cx, cy, x, y):
        self._call("nvgQuadTo", ctx, cx, cy, x, y)
        self._push("Q", _finite(cx), _finite(cy), _finite(x), _finite(y))

    def bezier_to(self, ctx, c1x, c1y, c2x, c2y, x, y):
        self._call("nvgBezierTo", ctx, c1x, c1y, c2x, c2y, x, y)
        self._push("C", _finite(c1x), _finite(c1y), _finite(c2x), _finite(c2y), _finite(x), _finite(y))

    def close_path(self, ctx):
        self._call("nvgClosePath", ctx)
        self.path.append(("Z", ()))

    def rect(self, ctx, x, y, w, h):
        self._call("nvgRect", ctx, x, y, w, h)
        x, y, w, h = map(_finite, (x, y, w, h))
        self._push("M", x, y)
        self._push("L", x + w, y)
        self._push("L", x + w, y + h)
        self._push("L", x, y + h)
        self._push("Z")

    def rounded_rect(self, ctx, x, y, w, h, radius):
        self._call("nvgRoundedRect", ctx, x, y, w, h, radius)
        x, y, w, h, radius = map(_finite, (x, y, w, h, radius))
        left, right = min(x, x + w), max(x, x + w)
        top, bottom = min(y, y + h), max(y, y + h)
        r = max(0.0, min(abs(radius), (right - left) * 0.5, (bottom - top) * 0.5))
        k = self.CURVE_K
        self._push("M", left + r, top)
        self._push("L", right - r, top)
        self._push("C", right - r + k * r, top, right, top + r - k * r, right, top + r)
        self._push("L", right, bottom - r)
        self._push("C", right, bottom - r + k * r, right - r + k * r, bottom, right - r, bottom)
        self._push("L", left + r, bottom)
        self._push("C", left + r - k * r, bottom, left, bottom - r + k * r, left, bottom - r)
        self._push("L", left, top + r)
        self._push("C", left, top + r - k * r, left + r - k * r, top, left + r, top)
        self._push("Z")

    def circle(self, ctx, x, y, radius):
        self._call("nvgCircle", ctx, x, y, radius)
        self._append_ellipse(_finite(x), _finite(y), abs(_finite(radius)), abs(_finite(radius)))

    def ellipse(self, ctx, x, y, rx, ry):
        self._call("nvgEllipse", ctx, x, y, rx, ry)
        self._append_ellipse(_finite(x), _finite(y), abs(_finite(rx)), abs(_finite(ry)))

    def set_fill_color(self, ctx, color):
        self._call("nvgFillColor", ctx, color)
        self.fill_color = _as_color(color)
        self.fill_paint = None

    def set_fill_paint(self, ctx, paint):
        self._call("nvgFillPaint", ctx, paint)
        self.fill_paint = paint if isinstance(paint, LinearGradient) else None

    def linear_gradient(self, ctx, x1, y1, x2, y2, start, end):
        self._call("nvgLinearGradient", ctx, x1, y1, x2, y2)
        p1 = self._point(self.transform, _finite(x1), _finite(y1))
        p2 = self._point(self.transform, _finite(x2), _finite(y2))
        return LinearGradient(*p1, *p2, _as_color(start), _as_color(end))

    def set_stroke_color(self, ctx, color):
        self._call("nvgStrokeColor", ctx, color)
        self.stroke_color = _as_color(color)

    def set_stroke_width(self, ctx, width):
        self._call("nvgStrokeWidth", ctx, width)
        self.stroke_width = max(0.0, _finite(width))

    def _element(self, *, fill_color=None, fill_paint=None, stroke_color=None, stroke_width=None):
        if not self.path:
            return
        a, b, c, d, _, _ = self.transform
        self.elements.append(
            {
                "path": list(self.path),
                "fill_color": fill_color,
                "fill_paint": fill_paint,
                "stroke_color": stroke_color,
                "stroke_width": stroke_width,
                "stroke_scale": math.sqrt(abs(a * d - b * c)),
                "clip": _copy_clip(self.clip),
            }
        )

    def fill(self, ctx):
        self._call("nvgFill", ctx)
        self._element(fill_color=None if self.fill_paint else self.fill_color, fill_paint=self.fill_paint)

    def stroke(self, ctx):
        self._call("nvgStroke", ctx)
        self._element(stroke_color=self.stroke_color, stroke_width=self.stroke_width * math.sqrt(
            abs(self.transform[0] * self.transform[3] - self.transform[1] * self.transform[2])
        ))

    def save(self, ctx):
        self._call("nvgSave", ctx)
        self.stack.append(
            {
                "fill_color": self.fill_color,
                "fill_paint": self.fill_paint,
                "stroke_color": self.stroke_color,
                "stroke_width": self.stroke_width,
                "transform": self.transform,
                "clip": _copy_clip(self.clip),
            }
        )

    def restore(self, ctx):
        self._call("nvgRestore", ctx)
        if not self.stack:
            raise RuntimeError("nvgRestore called without nvgSave")
        state = self.stack.pop()
        self.fill_color = state["fill_color"]
        self.fill_paint = state["fill_paint"]
        self.stroke_color = state["stroke_color"]
        self.stroke_width = state["stroke_width"]
        self.transform = state["transform"]
        self.clip = state["clip"]

    def translate(self, ctx, x, y):
        self._call("nvgTranslate", ctx, x, y)
        self._multiply((1, 0, 0, 1, _finite(x), _finite(y)))

    def scale(self, ctx, x, y):
        self._call("nvgScale", ctx, x, y)
        self._multiply((_finite(x, 1), 0, 0, _finite(y, 1), 0, 0))

    def rotate(self, ctx, angle):
        self._call("nvgRotate", ctx, angle)
        angle = _finite(angle)
        cosine, sine = math.cos(angle), math.sin(angle)
        self._multiply((cosine, sine, -sine, cosine, 0, 0))

    def scissor(self, ctx, x, y, w, h):
        self._call("nvgScissor", ctx, x, y, w, h)
        x, y, w, h = map(_finite, (x, y, w, h))
        points = [
            self._point(self.transform, x, y),
            self._point(self.transform, x + w, y),
            self._point(self.transform, x + w, y + h),
            self._point(self.transform, x, y + h),
        ]
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        new_clip = (min(xs), min(ys), max(xs), max(ys))
        if self.clip:
            old = self.clip
            new_clip = (max(old[0], new_clip[0]), max(old[1], new_clip[1]),
                        min(old[2], new_clip[2]), min(old[3], new_clip[3]))
        self.clip = new_clip

    def reset_scissor(self, ctx):
        self._call("nvgResetScissor", ctx)
        self.clip = None

    def count_fill_color(self, r, g, b, a=255):
        target = tuple(round(_finite(v)) for v in (r, g, b, a))
        return sum(
            1 for element in self.elements
            if element["fill_color"] is not None
            and tuple(round(v) for v in self._rgba(element["fill_color"])) == target
        )

    def call_count(self, name):
        return int(self.counts[str(name)])

    def has_ellipse_args(self, x, y, rx=0, ry=0, tolerance=0.001):
        return any(
            name == "nvgEllipse"
            and len(args) >= 4
            and abs(args[0] - _finite(x)) <= _finite(tolerance)
            and abs(args[1] - _finite(y)) <= _finite(tolerance)
            and (not rx or abs(args[2] - _finite(rx)) <= _finite(tolerance))
            and (not ry or abs(args[3] - _finite(ry)) <= _finite(tolerance))
            for name, args in self.calls
        )

    def count_ellipse_args(self, x, y, rx, ry, tolerance=0.001):
        return sum(
            1 for name, args in self.calls
            if name == "nvgEllipse" and len(args) >= 4
            and all(abs(args[index] - _finite(value)) <= _finite(tolerance)
                    for index, value in enumerate((x, y, rx, ry)))
        )

    def scissor_matches(self, x, y, w, h, tolerance=0.01):
        return any(
            name == "nvgScissor" and len(args) >= 4
            and all(abs(args[index] - _finite(value)) <= _finite(tolerance)
                    for index, value in enumerate((x, y, w, h)))
            for name, args in self.calls
        )

    @staticmethod
    def _rgba(color):
        values = (color.r, color.g, color.b, color.a)
        return tuple(max(0, min(255, _finite(value))) for value in values)

    @staticmethod
    def _fmt(value):
        return f"{value:.4f}".rstrip("0").rstrip(".") or "0"

    @classmethod
    def _svg_path(cls, path):
        parts = []
        for command, values in path:
            parts.append(command)
            if values:
                parts.append(" ".join(cls._fmt(v) for v in values))
        return " ".join(parts)

    def to_svg(self, width: int, height: int, title: str):
        defs: list[str] = []
        body: list[str] = []
        for index, element in enumerate(self.elements, start=1):
            attrs = [f'd="{self._svg_path(element["path"])}"']
            paint = element["fill_paint"]
            color = element["fill_color"]
            if paint is not None:
                gradient_id = f"gradient-{index}"
                defs.append(
                    f'<linearGradient id="{gradient_id}" gradientUnits="userSpaceOnUse" '
                    f'x1="{self._fmt(paint.x1)}" y1="{self._fmt(paint.y1)}" '
                    f'x2="{self._fmt(paint.x2)}" y2="{self._fmt(paint.y2)}">'
                    f'{self._svg_stop(0, paint.start)}{self._svg_stop(1, paint.end)}</linearGradient>'
                )
                attrs.append(f'fill="url(#{gradient_id})"')
                attrs.append('stroke="none"')
            elif color is not None:
                r, g, b, a = (round(v) for v in self._rgba(color))
                attrs.extend((f'fill="#{r:02x}{g:02x}{b:02x}"', f'fill-opacity="{a / 255:.4f}"'))
            else:
                attrs.append('fill="none"')
            stroke = element["stroke_color"]
            if stroke is not None:
                r, g, b, a = (round(v) for v in self._rgba(stroke))
                attrs.extend((f'stroke="#{r:02x}{g:02x}{b:02x}"', f'stroke-opacity="{a / 255:.4f}"'))
                attrs.append(f'stroke-width="{self._fmt(element["stroke_width"])}"')
                attrs.append('stroke-linecap="butt" stroke-linejoin="round"')
            clip = element["clip"]
            if clip:
                clip_id = f"clip-{index}"
                x0, y0, x1, y1 = clip
                defs.append(
                    f'<clipPath id="{clip_id}" clipPathUnits="userSpaceOnUse">'
                    f'<rect x="{self._fmt(x0)}" y="{self._fmt(y0)}" '
                    f'width="{self._fmt(max(0, x1 - x0))}" height="{self._fmt(max(0, y1 - y0))}" />'
                    f'</clipPath>'
                )
                attrs.append(f'clip-path="url(#{clip_id})"')
            body.append(f'<path {" ".join(attrs)} />')
        defs_markup = f'<defs>{"".join(defs)}</defs>' if defs else ""
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{title}">'
            f'<title>{title}</title>{defs_markup}{"".join(body)}</svg>'
        )

    @classmethod
    def _svg_stop(cls, offset, color):
        r, g, b, a = (round(v) for v in cls._rgba(color))
        return f'<stop offset="{offset * 100:.1f}%" stop-color="#{r:02x}{g:02x}{b:02x}" stop-opacity="{a / 255:.4f}" />'

    def render_png(self, width: int, height: int, destination: Path, supersample=2):
        from PIL import Image, ImageChops, ImageDraw
        try:
            import numpy as np
        except ImportError:
            np = None

        scale = max(1, int(supersample))
        canvas = Image.new("RGBA", (width * scale, height * scale), (0, 0, 0, 0))
        for element in self.elements:
            subpaths = _flatten_path(element["path"])
            all_points = [point for path, _closed in subpaths for point in path]
            if not all_points:
                continue
            stroke_margin = (element["stroke_width"] or 0) * 0.5 + 2
            min_x = min(point[0] for point in all_points) - stroke_margin
            min_y = min(point[1] for point in all_points) - stroke_margin
            max_x = max(point[0] for point in all_points) + stroke_margin
            max_y = max(point[1] for point in all_points) + stroke_margin
            clip = element["clip"]
            if clip:
                min_x, min_y = max(min_x, clip[0]), max(min_y, clip[1])
                max_x, max_y = min(max_x, clip[2]), min(max_y, clip[3])
            min_x, min_y = max(0, min_x), max(0, min_y)
            max_x, max_y = min(width, max_x), min(height, max_y)
            x0, y0 = max(0, math.floor(min_x * scale)), max(0, math.floor(min_y * scale))
            x1, y1 = min(width * scale, math.ceil(max_x * scale)), min(height * scale, math.ceil(max_y * scale))
            if x1 <= x0 or y1 <= y0:
                continue
            patch_size = (x1 - x0, y1 - y0)
            mask = Image.new("L", patch_size, 0)
            draw_mask = ImageDraw.Draw(mask)
            for points, closed in subpaths:
                if len(points) < 3:
                    continue
                mapped = [((x * scale) - x0, (y * scale) - y0) for x, y in points]
                if not closed and mapped[-1] != mapped[0]:
                    mapped.append(mapped[0])
                draw_mask.polygon(mapped, fill=255)
            if clip:
                clip_mask = Image.new("L", patch_size, 0)
                clip_draw = ImageDraw.Draw(clip_mask)
                clip_draw.rectangle(
                    ((clip[0] * scale - x0, clip[1] * scale - y0),
                     (clip[2] * scale - x0, clip[3] * scale - y0)), fill=255
                )
                mask = ImageChops.multiply(mask, clip_mask)

            if element["fill_color"] is not None or element["fill_paint"] is not None:
                if element["fill_paint"] is not None:
                    source = _linear_gradient_image(
                        element["fill_paint"], patch_size, x0, y0, scale, np, Image, ImageDraw
                    )
                else:
                    rgba = tuple(round(v) for v in self._rgba(element["fill_color"]))
                    source = Image.new("RGBA", patch_size, rgba)
                _composite_masked(canvas, source, mask, x0, y0, Image, ImageChops)

            if element["stroke_color"] is not None and element["stroke_width"] > 0:
                stroke_mask = Image.new("L", patch_size, 0)
                stroke_draw = ImageDraw.Draw(stroke_mask)
                line_width = max(1, round(element["stroke_width"] * scale))
                for points, closed in subpaths:
                    if len(points) < 2:
                        continue
                    mapped = [((x * scale) - x0, (y * scale) - y0) for x, y in points]
                    if closed and mapped[-1] != mapped[0]:
                        mapped.append(mapped[0])
                    stroke_draw.line(mapped, fill=255, width=line_width, joint="curve")
                if clip:
                    clip_mask = Image.new("L", patch_size, 0)
                    ImageDraw.Draw(clip_mask).rectangle(
                        ((clip[0] * scale - x0, clip[1] * scale - y0),
                         (clip[2] * scale - x0, clip[3] * scale - y0)), fill=255
                    )
                    stroke_mask = ImageChops.multiply(stroke_mask, clip_mask)
                stroke_rgba = tuple(round(v) for v in self._rgba(element["stroke_color"]))
                source = Image.new("RGBA", patch_size, stroke_rgba)
                _composite_masked(canvas, source, stroke_mask, x0, y0, Image, ImageChops)

        if scale != 1:
            canvas = canvas.resize((width, height), Image.Resampling.LANCZOS)
        destination.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(destination, format="PNG", optimize=True)


def _flatten_path(commands: Iterable[tuple[str, tuple[float, ...]]], curve_steps=16):
    result: list[tuple[list[tuple[float, float]], bool]] = []
    points: list[tuple[float, float]] = []
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    closed = False

    def finish():
        nonlocal points, closed
        if points:
            result.append((points, closed))
        points, closed = [], False

    for command, values in commands:
        values = tuple(values)
        if command == "M":
            finish()
            current = (values[0], values[1])
            start = current
            points = [current]
        elif command == "L":
            current = (values[0], values[1])
            points.append(current)
        elif command == "Q":
            control, end = (values[0], values[1]), (values[2], values[3])
            origin = current
            for index in range(1, curve_steps + 1):
                t = index / curve_steps
                u = 1 - t
                points.append((u * u * origin[0] + 2 * u * t * control[0] + t * t * end[0],
                               u * u * origin[1] + 2 * u * t * control[1] + t * t * end[1]))
            current = end
        elif command == "C":
            c1, c2, end = (values[0], values[1]), (values[2], values[3]), (values[4], values[5])
            origin = current
            for index in range(1, curve_steps + 1):
                t = index / curve_steps
                u = 1 - t
                points.append((u ** 3 * origin[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * end[0],
                               u ** 3 * origin[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * end[1]))
            current = end
        elif command == "Z":
            if points and points[-1] != start:
                points.append(start)
            current = start
            closed = True
    finish()
    return result


def _linear_gradient_image(gradient, size, x0, y0, scale, np, Image, ImageDraw):
    width, height = size
    x1, y1 = gradient.x1 * scale - x0, gradient.y1 * scale - y0
    x2, y2 = gradient.x2 * scale - x0, gradient.y2 * scale - y0
    vx, vy = x2 - x1, y2 - y1
    denominator = vx * vx + vy * vy
    start = tuple(max(0, min(255, v)) for v in NVGCapture._rgba(gradient.start))
    end = tuple(max(0, min(255, v)) for v in NVGCapture._rgba(gradient.end))
    if denominator <= 1e-9:
        return Image.new("RGBA", size, start)
    if np is not None:
        yy, xx = np.ogrid[:height, :width]
        t = ((xx - x1) * vx + (yy - y1) * vy) / denominator
        t = np.clip(t, 0.0, 1.0)
        arr = np.empty((height, width, 4), dtype=np.uint8)
        for channel in range(4):
            arr[:, :, channel] = np.rint(start[channel] + t * (end[channel] - start[channel])).astype(np.uint8)
        return Image.fromarray(arr, "RGBA")
    image = Image.new("RGBA", size)
    draw = ImageDraw.Draw(image)
    if abs(vx) < 1e-9:
        for py in range(height):
            t = max(0.0, min(1.0, ((py - y1) * vy) / denominator))
            draw.line((0, py, width, py), fill=tuple(round(a + t * (b - a)) for a, b in zip(start, end)))
    elif abs(vy) < 1e-9:
        for px in range(width):
            t = max(0.0, min(1.0, ((px - x1) * vx) / denominator))
            draw.line((px, 0, px, height), fill=tuple(round(a + t * (b - a)) for a, b in zip(start, end)))
    else:
        pixels = image.load()
        for py in range(height):
            for px in range(width):
                t = max(0.0, min(1.0, (((px - x1) * vx + (py - y1) * vy) / denominator)))
                pixels[px, py] = tuple(round(a + t * (b - a)) for a, b in zip(start, end))
    return image


def _composite_masked(canvas, source, mask, x0, y0, Image, ImageChops):
    alpha = ImageChops.multiply(source.getchannel("A"), mask)
    source.putalpha(alpha)
    canvas.alpha_composite(source, (x0, y0))


def _lua_to_python(value):
    if not callable(getattr(value, "keys", None)):
        return value
    keys = list(value.keys())
    if not keys:
        return {}
    if all(isinstance(key, (int, float)) and int(key) == key and key > 0 for key in keys):
        max_key = int(max(keys))
        if len(keys) == max_key:
            return [_lua_to_python(value[index]) for index in range(1, max_key + 1)]
    return {str(key): _lua_to_python(value[key]) for key in keys}


def _module(lua, name):
    return lua.eval("function(module_name) local module = require(module_name); return module end")(name)


def _new_lua():
    try:
        from lupa.lua54 import LuaRuntime
    except ImportError as exc:
        raise RuntimeError("Lupa Lua 5.4 runtime is unavailable; no dependency was installed") from exc
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().PROJECT_ROOT = str(ROOT).replace("\\", "/")
    lua.execute(
        'package.path = PROJECT_ROOT .. "/scripts/?.lua;" .. PROJECT_ROOT .. "/scripts/?/init.lua;" .. package.path'
    )
    return lua


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    capture = NVGCapture()
    lua = _new_lua()
    recorder = capture.bind(lua)
    lua.globals().__nvgRecorder = recorder
    ctx = lua.table()
    lua.globals().__nvgContext = ctx
    sea_draw = _module(lua, "Ocean.SeaDraw")
    tests = _module(lua, "tests.SeaFusionRenderTests")

    tests_result = _lua_to_python(tests.Run(recorder))
    if tests_result.get("status") != "PASS":
        raise AssertionError(f"render contract tests did not pass: {tests_result!r}")

    screenshots = []
    capture_scenes = [
        ("landscape", 1920, 1080, False),
        ("portrait", 1200, 1150, False),
        ("reveal", 1920, 1080, True),
    ]
    for name, width, height, reveal in capture_scenes:
        runtime = tests.CreatePreviewRuntime(width, height)
        if reveal:
            runtime.setDebugFlag(runtime, "showUnderwater", True)
        capture.reset()
        sea_draw.Scene(ctx, width, height, runtime)
        svg_path = OUT_DIR / f"sea-fusion-{name}.svg"
        png_path = OUT_DIR / f"sea-fusion-{name}.png"
        svg_path.write_text(capture.to_svg(width, height, f"Sea fusion offline render: {name}"), encoding="utf-8")
        capture.render_png(width, height, png_path, supersample=2)
        svg_bytes, png_bytes = svg_path.read_bytes(), png_path.read_bytes()
        screenshots.append(
            {
                "name": name,
                "width": width,
                "height": height,
                "fish_visibility": "debug_reveal" if reveal else "default_hidden",
                "svg": str(svg_path.relative_to(ROOT)).replace("\\", "/"),
                "png": str(png_path.relative_to(ROOT)).replace("\\", "/"),
                "svg_bytes": len(svg_bytes),
                "png_bytes": len(png_bytes),
                "svg_sha256": hashlib.sha256(svg_bytes).hexdigest(),
                "png_sha256": hashlib.sha256(png_bytes).hexdigest(),
                "recorded_elements": len(capture.elements),
                "recorded_nvg_calls": sum(capture.counts.values()),
                "nvg_call_counts": dict(sorted(capture.counts.items())),
                "clipped_elements": sum(1 for element in capture.elements if element["clip"] is not None),
                "linear_gradient_elements": sum(1 for element in capture.elements if element["fill_paint"] is not None),
            }
        )

    qa = {
        "status": "PASS",
        "evidence_kind": "offline_lua54_nanovg_capture",
        "engine_screenshot": False,
        "hud_included": False,
        "hud_note": "This capture executes SeaDraw.Scene and does not render UrhoX UI widgets or the native HUD.",
        "network_used": False,
        "dependencies_installed": False,
        "png_renderer": {
            "backend": "Pillow",
            "linear_gradients": "per-pixel linear interpolation",
            "curve_rasterization": "quadratic and cubic paths flattened to 16 segments",
            "supersampling": 2,
            "svg_preserves_recorded_vector_paths": True,
        },
        "runtime": {
            "lupa": "2.6",
            "python": sys.executable,
            "pillow": __import__("PIL").__version__,
        },
        "tests": tests_result["tests"],
        "metrics": tests_result["metrics"],
        "screenshots": screenshots,
    }
    qa_path = OUT_DIR / "sea-fusion-render-qa.json"
    qa_path.write_text(json.dumps(qa, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "qa": str(qa_path), "screenshots": screenshots}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        failure = {
            "status": "FAIL",
            "error": str(exc),
            "traceback": traceback.format_exc(),
            "evidence_kind": "offline_lua54_nanovg_capture",
        }
        failure_path = OUT_DIR / "sea-fusion-render-qa.json"
        try:
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            failure_path.write_text(json.dumps(failure, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        except OSError:
            pass
        print(json.dumps(failure, ensure_ascii=False, indent=2), file=sys.stderr)
        raise
