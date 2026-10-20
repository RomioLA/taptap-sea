"""环境声床降采样（2026-10-20 包体预算收紧）。

背景：包体一度到 104.7MB，超过 TapTap 60MB 红线。逐项核对后最大单块是
`assets/audio/sfx/` 的 8 个环境声床（35.1MB），它们是 44.1/48kHz 立体声未压缩 WAV。

为什么不转 mp3：`AudioDirector.SPECS` 全部走 `.wav` 路径，转 mp3 要动 SPECS 与
`candidatePaths` 的自愈逻辑，在没有真机验证的前提下风险高于收益。

为什么降到 22.05kHz 而不是更低：先做了频谱实测——这 8 条素材 >11kHz 的能量占比
全部 <0.5%（海洋/风声/人声床，本质是低频噪声），所以 22.05kHz（奈奎斯特 11.025kHz）
已经覆盖全部有效内容，听感不可辨；再往下降到 16kHz 才可能损失空气感。

本脚本可重跑（幂等：已是 22050Hz 的文件直接跳过），并做三项验收：

  1. 时长必须与源文件一致（误差 < 0.05s）——防止循环点被裁剪或补静音；
  2. RMS 电平与源文件一致（差 < 1dB）——防止增益被改动；
  3. 首尾样本差不得明显变大——保证 loop 接缝没有跳变。

用法：
  python tests/downsample_ambience.py                # 执行（源文件先备份到 .tmp/audio-orig）
  python tests/downsample_ambience.py --check        # 只校验现状（CI / 推送前）
  python tests/downsample_ambience.py --restore      # 从备份还原
"""
import argparse
import json
import math
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SFX = ROOT / "assets" / "audio" / "sfx"
BACKUP = ROOT / ".tmp" / "audio-orig"

TARGET_RATE = 22050
TARGET_CHANNELS = 2

# 环境声床白名单（短音效不动：它们是 0.1~2.8s，本来就小，且降采样会损失瞬态）。
BEDS = (
    "amb_deep_ruins_ai",
    "amb_elder_npc_ai",
    "amb_rare_fish_ai",
    "amb_storm_premonition_ai",
    "amb_morning_sea_ai",
    "amb_overcast_sea_ai",
    "ambience_night_ocean_loop",
    "ambience_calm_sea_loop",
)

# 验收阈值
DURATION_TOLERANCE_SEC = 0.05
LEVEL_TOLERANCE_DB = 1.0
EDGE_JUMP_LIMIT = 1500          # 16bit 满量程 ±32768；首尾差超过此值说明接缝有跳变


def info(path):
    with wave.open(str(path)) as handle:
        return {"rate": handle.getframerate(), "channels": handle.getnchannels(),
                "frames": handle.getnframes(),
                "duration": handle.getnframes() / handle.getframerate()}


def samples(path):
    with wave.open(str(path)) as handle:
        channels = handle.getnchannels()
        raw = handle.readframes(handle.getnframes())
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    if channels == 2:
        data = data.reshape(-1, 2).mean(axis=1)
    return data


def rms_db(data):
    value = float(np.sqrt((data.astype(np.float64) ** 2).mean()))
    return 20 * math.log10(max(value, 1e-9) / 32768.0)


def check_pair(source, target):
    """比对源与产物；返回问题列表（空=通过）。"""
    problems = []
    src_info, dst_info = info(source), info(target)
    if abs(src_info["duration"] - dst_info["duration"]) > DURATION_TOLERANCE_SEC:
        problems.append(
            f"{target.name}: 时长变化 {src_info['duration']:.2f}s → {dst_info['duration']:.2f}s"
            "（循环点会被破坏）")
    src, dst = samples(source), samples(target)
    level_delta = abs(rms_db(src) - rms_db(dst))
    if level_delta > LEVEL_TOLERANCE_DB:
        problems.append(f"{target.name}: 电平变化 {level_delta:.2f}dB（增益被改动）")
    edge_src = abs(float(src[0]) - float(src[-1]))
    edge_dst = abs(float(dst[0]) - float(dst[-1]))
    if edge_dst > EDGE_JUMP_LIMIT and edge_dst > edge_src + 200:
        problems.append(f"{target.name}: 首尾差 {edge_src:.0f} → {edge_dst:.0f}（loop 接缝跳变）")
    return problems


def ffmpeg_available():
    return shutil.which("ffmpeg") is not None


def downsample_one(name):
    path = SFX / (name + ".wav")
    if not path.is_file():
        return f"{name}: 文件缺失", 0
    current = info(path)
    if current["rate"] <= TARGET_RATE:
        return f"{name}: 已是 {current['rate']}Hz，跳过", 0
    BACKUP.mkdir(parents=True, exist_ok=True)
    backup = BACKUP / path.name
    if not backup.is_file():
        shutil.copy2(path, backup)
    before = path.stat().st_size
    with tempfile.TemporaryDirectory() as tmp:
        produced = Path(tmp) / path.name
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(path),
             "-ar", str(TARGET_RATE), "-ac", str(TARGET_CHANNELS),
             "-c:a", "pcm_s16le", str(produced)],
            capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if result.returncode != 0:
            return f"{name}: ffmpeg 失败 {result.stderr.strip()[:200]}", 0
        problems = check_pair(backup, produced)
        if problems:
            return f"{name}: 验收未通过 {problems}", 0
        shutil.move(str(produced), str(path))
    after = path.stat().st_size
    return f"{name}: {current['rate']}Hz {before // 1024}KB → {TARGET_RATE}Hz {after // 1024}KB", before - after


def run(check_only):
    if not BEDS:
        return 0
    if not check_only and not ffmpeg_available():
        raise SystemExit("需要 ffmpeg（PATH 中不可用）")
    problems, saved, changed = [], 0, 0
    for name in BEDS:
        path = SFX / (name + ".wav")
        if not path.is_file():
            problems.append(f"{name}: 文件缺失")
            continue
        if check_only:
            current = info(path)
            if current["rate"] > TARGET_RATE:
                problems.append(f"{name}: 仍是 {current['rate']}Hz（应降到 {TARGET_RATE}Hz）")
            backup = BACKUP / path.name
            if backup.is_file():
                problems.extend(check_pair(backup, path))
            continue
        message, delta = downsample_one(name)
        print(message)
        if delta:
            saved += delta
            changed += 1
        elif "跳过" not in message:
            problems.append(message)
    if problems:
        raise SystemExit("\n".join(problems))
    report = {"passed": True, "beds": len(BEDS), "changed": changed,
              "savedMB": round(saved / 1024 / 1024, 1) if saved else 0,
              "targetRate": TARGET_RATE}
    print(json.dumps(report, ensure_ascii=False))


def restore():
    if not BACKUP.is_dir():
        raise SystemExit(f"没有备份目录：{BACKUP}")
    restored = 0
    for path in sorted(BACKUP.glob("*.wav")):
        shutil.copy2(path, SFX / path.name)
        restored += 1
    print(json.dumps({"restored": restored, "from": str(BACKUP.relative_to(ROOT))}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验现状，不改文件")
    parser.add_argument("--restore", action="store_true", help="从 .tmp/audio-orig 还原原始 WAV")
    args = parser.parse_args()
    if args.restore:
        restore()
        return
    run(args.check)


if __name__ == "__main__":
    main()
