#!/usr/bin/env python3
"""Mechanical ART-W2-01 PNG staging; no source files are modified or removed."""
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parent
W1 = ROOT / "outputs" / "art-wave1"
HIGH = ROOT / "assets" / "generated" / "highspec"
IMAGE = ROOT / "assets" / "image"

def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

def alpha_info(im):
    a = im.getchannel("A")
    hist = a.histogram()
    bbox = a.getbbox()
    return {"alpha_bbox": list(bbox) if bbox else None,
            "alpha_pixels": sum(hist[1:]), "partial_alpha_pixels": sum(hist[1:255]),
            "transparent_pixels": hist[0], "opaque_pixels": hist[255]}

def sizing(src):
    n = src.name.lower()
    if "island" in n or "岛" in n:
        return [(768, 768, "island768"), (1024, 1024, "island1024")]
    if "ship_" in n or "船" in n:
        return [(640, 427, "ship640")]
    if "bottom" in n or "底部操作栏" in n:
        return [(640, 360, "panel640")]
    if "ui" in n or any(k in n for k in ("icon", "marker", "target", "apple", "lens", "sardine_inventory", "tuna_")):
        return [(192 if "button" in n or "按钮" in n else 256,
                 192 if "button" in n or "按钮" in n else 256, "ui")]
    if any(k in n for k in ("bird", "gull", "splash", "ripple", "bubble", "wake", "disturbance", "breach", "feedback", "impact")):
        edge = 256 if "small" in n or "roaming" in n or "bubble" in n else 384
        return [(edge, edge, "effect")]
    if any(k in n for k in ("rocks", "shrub", "礁", "岩", "灌木")):
        return [(384, 384, "world384")]
    if src.parent.name == "ART-W1-04" and "世界" in n:
        return [(384, 384, "world384")]
    if "world" in n or "世界" in n or "driftwood" in n or "net" in n or "barrel" in n or "boat" in n:
        return [(384, 384, "world384")]
    return [(384, 384, "default384")]

def stage(src, tag):
    with Image.open(src) as opened:
        im = opened.convert("RGBA")
    original = {"dimensions": list(im.size), **alpha_info(im)}
    bbox = im.getchannel("A").getbbox()
    cw, ch = (int(x) for x in tag.split("x"))
    if bbox:
        content = im.crop(bbox)
    else:
        content = im
    maxw, maxh = max(1, round(cw * .88)), max(1, round(ch * .88))
    scale = min(maxw / content.width, maxh / content.height)
    rw, rh = max(1, round(content.width * scale)), max(1, round(content.height * scale))
    # Pillow RGBa stores premultiplied channels, avoiding dark fringes at alpha edges.
    resized = content.convert("RGBa").resize((rw, rh), Image.Resampling.LANCZOS).convert("RGBA")
    canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    xy = ((cw-rw)//2, (ch-rh)//2)
    canvas.alpha_composite(resized, xy)
    dest = OUT / f"{src.stem}__{tag}.png"
    canvas.save(dest, format="PNG", optimize=True, compress_level=9)
    staged = {"dimensions": [cw, ch], **alpha_info(canvas)}
    n = src.name.lower()
    if "island" in n or "岛" in n:
        budget = 500000
    elif "ship_" in n or "船" in n or "env_" in n or "world" in n or "世界" in n or "driftwood" in n or "barrel" in n or "boat" in n or "rocks" in n or "shrub" in n or "礁" in n or "岩" in n or "灌木" in n:
        budget = 300000
    elif "bottom" in n or "底部操作栏" in n:
        budget = 400000
    else:
        budget = 250000
    return {"path": str(src.relative_to(ROOT)).replace("\\", "/"),
            "staging": str(dest.relative_to(ROOT)).replace("\\", "/"),
            "sha256": sha(src), "staging_sha256": sha(dest),
            "source_bytes": src.stat().st_size, "staging_bytes": dest.stat().st_size,
            "saving_bytes": src.stat().st_size-dest.stat().st_size,
            "saving_percent": round((1-dest.stat().st_size/src.stat().st_size)*100, 2),
            "soft_budget_bytes": budget, "soft_overbudget": dest.stat().st_size > budget,
            "content_bounds": original["alpha_bbox"], "original": original,
            "staged": staged, "fit": "visible-alpha bbox centered; 88% max canvas; premultiplied RGBa Lanczos"}

def main():
    sources = []
    for i in range(1, 6):
        folder = HIGH / f"ART-W1-{i:02}"
        high_files = sorted(folder.glob("*.png"))
        candidate = W1 / f"ART-W1-{i:02}" / "candidates"
        # W1-05 generated-only candidates are confirmed sources; other candidate files
        # are the script's already-verified archive copies of the highspec originals.
        if i == 5:
            # Reused W1-05 assets are staged from their already-archived candidate
            # paths below; keep the highspec originals in the copy/hash plan.
            cfiles = {p.name: p for p in candidate.glob("*.png")}
            high_files = [p for p in high_files if not (
                p.name in cfiles and sha(p) == sha(cfiles[p.name]))]
            sources += sorted(candidate.glob("*.png"))
        sources += high_files
    sources += sorted(IMAGE.glob("ART-W1-02_*.png"))
    unique = {}
    for p in sources:
        unique[str(p.resolve()).lower()] = p
    records = []
    for src in unique.values():
        # One staging candidate per input PNG, except the four W1-01 islands retain 768/1024 variants.
        dims = sizing(src)
        if "island" in src.name.lower() and "ART-W1-01" in str(src):
            staged_rows = [stage(src, f"{w}x{h}") for w,h,_ in dims]
        else:
            w,h,_ = dims[0]
            staged_rows = [stage(src, f"{w}x{h}")]
        group = next((f"ART-W1-{i:02}" for i in range(1,6) if f"ART-W1-{i:02}" in str(src)), "ART-W1-02")
        target = W1 / group / "candidates" / src.name
        for row in staged_rows:
            row["candidate_input"] = str(target.relative_to(ROOT)).replace("\\", "/")
        records.extend(staged_rows)
    # Archive plan covers only original source files under assets/. Output candidates
    # already there are staging inputs, never relocation blockers.
    asset_sources = []
    for i in range(1, 6):
        folder = HIGH / f"ART-W1-{i:02}"
        asset_sources += sorted(folder.glob("*.png"))
        if i == 5:
            asset_sources += sorted(folder.glob("*.meta"))
    asset_sources += sorted(IMAGE.glob("ART-W1-02_*.png"))
    copies = []
    for source_file in asset_sources:
        group = next((f"ART-W1-{i:02}" for i in range(1,6) if f"ART-W1-{i:02}" in str(source_file)), "ART-W1-02")
        dest = W1 / group / "candidates" / source_file.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists() and sha(dest) != sha(source_file):
            raise RuntimeError(f"destination collision with different SHA256: {dest}")
        if not dest.exists():
            dest.write_bytes(source_file.read_bytes())
        if sha(dest) != sha(source_file):
            raise RuntimeError(f"copy SHA256 mismatch: {dest}")
        copies.append({"original": str(source_file.relative_to(ROOT)).replace("\\", "/"),
                       "copy": str(dest.relative_to(ROOT)).replace("\\", "/"),
                       "sha256": sha(source_file), "bytes": source_file.stat().st_size})
    copy_by_dest = {x["copy"]: x["original"] for x in copies}
    for row in records:
        if row["candidate_input"] in copy_by_dest:
            row["asset_original"] = copy_by_dest[row["candidate_input"]]
    staging_paths = [x["staging"] for x in records]
    if len(staging_paths) != len(set(staging_paths)):
        from collections import Counter
        dup = [x for x,n in Counter(staging_paths).items() if n > 1]
        raise RuntimeError("staging filename collision detected: " + ", ".join(dup[:6]))
    (OUT / "staging-map.json").write_text(json.dumps({"input_png_count":len(unique),"staging_count":len(records),"records":records},ensure_ascii=False,indent=2),encoding="utf-8")
    blockers = [x["original"] for x in copies if x["original"].startswith(("assets/generated/highspec/", "assets/image/"))]
    (OUT / "relocation-plan.json").write_text(json.dumps({"status":"PARTIAL","asset_png_original_count":sum(x["original"].endswith(".png") for x in copies),
        "asset_meta_original_count":sum(x["original"].endswith(".meta") for x in copies),"copies":copies,
        "blocking_originals_remaining":blockers,"actual_removal":False},ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps({"inputs":len(unique),"staged":len(records),"copies":len(copies),
        "blocking_originals":len(blockers),"output_bytes":sum(x["staging_bytes"] for x in records)},ensure_ascii=False))

if __name__ == "__main__": main()
