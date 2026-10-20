"""推送前硬闸门：版本一致性 + 资产预算 + 回归基线。

背景（2026-10-16 真机事故）：Codex 推送后真机卡顿、PC/手机版本不一致。
根因链：① 音效 43MB WAV 被 ensureInit 一次性同步解码（已修：懒加载）；
② 测试码未随云构建重生成 → 手机跑旧构建；③ 真机无调试面板，性能埋点读不到；
④ 无任何推送前检查，坏版本直接上真机。

本脚本把 SOP 固化为闸门。用法：

    python tests/prepush_check.py            # 全量检查（含 b5 回归，约数分钟）
    python tests/prepush_check.py --skip-b5  # 跳过回归（本地快速预检）

通过（退出码 0）才允许 push。任何一项失败都会给出具体修复指令。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_INFO = ROOT / "scripts" / "GeneratedData" / "BuildInfo.lua"
PROJECT_JSON = ROOT / ".project" / "project.json"
CONFIG_LUA = ROOT / "scripts" / "Ocean" / "Config.lua"

# 2026-10-20 结构调整：8 个环境声床（amb_*/ambience_*）降采样到 22.05kHz。
# 实测这些素材 >11kHz 的能量占比 <0.5%（几乎全在低频），降采样听感不可辨，
# 但把 audio 从 35.1MB 压到 18.6MB，让出包体余量给美术。
# 预算随之收紧：40MB 时总量已顶到 60MB 红线，现在按 22MB 守。
AUDIO_BUDGET_MB = 22.0
# 单资产上限：环境声床降采样后最大 2.53MB（30s/22.05kHz/立体声），故设 3MB。
# 更长的未降采样 WAV（>3MB）会被拦下，提示降采样或转码。
SINGLE_FILE_MB = 3.0
# 已知环境声床（AudioDirector.SPECS 中 loop=true 的 8 条）：已按 key 懒加载，
# 只在首次启床时同步解码单条，运行时风险有界；仅作提醒不拦截。
# 若真机开老人卡/暂停仍出现可感 Hitch，再按方案文档把这些床转 mp3/降采样。
# 空：8 个环境声床已于 2026-10-20 降采样到 22.05kHz，单文件均 ≤2.6MB 且走懒加载，
# 不再需要「超限白名单」。若将来重新导入未降采样的声床，应重新降采样而不是加白名单。
BED_WAV_WHITELIST = set()

problems: list[str] = []
warnings: list[str] = []


def run(args: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    # stdin=DEVNULL：Windows ConPTY 下 stdin=pipe 会必现 EBUSY（项目铁律 9）
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                          timeout=timeout, stdin=subprocess.DEVNULL)


def git(*args: str) -> str:
    result = run(["git", *args])
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def check_clean_tree() -> None:
    status = git("status", "--porcelain")
    if status:
        problems.append(
            "工作区有未提交改动，先 commit 再跑本检查（版本戳只对已提交代码有意义）：\n"
            + "\n".join("  " + line for line in status.splitlines()[:20]))


def check_remote_alignment() -> None:
    """Maker 云端 HEAD 必须是本地 HEAD 的祖先（推送安全条件）。

    注意：commit 后、push 前本地必然领先云端 1~2 笔（含 stamp 提交），属正常，
    不得要求相等；真正要防的是本地落后/分叉（云端提交未进本地历史）。
    """
    try:
        remote = run(["git", "ls-remote", "origin", "refs/heads/main"]).stdout.split()
        remote_head = remote[0] if remote else ""
    except Exception as error:  # noqa: BLE001 - 网络/代理波动只作提醒
        warnings.append(f"无法连接 Maker 云端核对 HEAD（{error}）；推送后务必用 ls-remote 复核")
        return
    if remote_head:
        result = run(["git", "merge-base", "--is-ancestor", remote_head, "HEAD"])
        if result.returncode != 0:
            problems.append(
                f"Maker 云端 {remote_head[:7]} 不是本地 HEAD 的祖先（本地落后或已分叉）。\n"
                "  先 git fetch origin +refs/heads/main:refs/remotes/origin/main\n"
                "  再 git rebase origin/main，确认云端提交全部进入本地历史后再推送")
    # GitHub 镜像只做对账提醒（凭证/网络异常不影响主流程）
    try:
        github = run(["git", "ls-remote", "github", "refs/heads/main"], timeout=60).stdout.split()
        if github and github[0] != git("rev-parse", "HEAD"):
            warnings.append(
                f"GitHub 镜像落后（{github[0][:7]} vs 本地 HEAD）；"
                "恢复推送后执行 git push github main")
    except Exception:  # noqa: BLE001
        warnings.append("GitHub 镜像无法核对（PAT 可能过期/代理不通）；不影响 Maker 主线")


def read_build_info() -> dict[str, str]:
    """解析 Lua 表字面量（仅支持 key = "value" 扁平结构，够用且零依赖）。"""
    info: dict[str, str] = {}
    for match in re.finditer(r'(\w+)\s*=\s*"([^"]*)"', BUILD_INFO.read_text(encoding="utf-8")):
        info[match.group(1)] = match.group(2)
    return info


def write_build_info(version: str, commit: str, date: str) -> None:
    BUILD_INFO.write_text(
        "-- 构建身份戳（勿手改）：由 tests/prepush_check.py 在每次推送前自动重写。\n"
        "-- 用途：真机与 PC 预览同屏显示，双端版本核对（PC/手机版本不一致类事故的判读依据）。\n"
        "-- 权威身份是 commit（云构建取 Maker 远端 HEAD）；version 为 .project/project.json 快照。\n"
        "return {\n"
        f'    version = "{version}",\n'
        f'    commit = "{commit}",\n'
        f'    commitDate = "{date}",\n'
        '    note = "auto-stamped by prepush_check",\n'
        "}\n",
        encoding="utf-8")


def check_build_stamp() -> None:
    """BuildInfo.commit 必须指向本次构建的代码内容。

    时间性困境：commit 后才知道 hash，把 hash 写进 BuildInfo 后提交又改变 HEAD hash。
    约定（2026-10-16）：stamp 用**新起一笔提交**（两笔式：代码提交 + stamp 提交），
    不用 amend——amend 会替换父提交，之前 stamp 的 hash 从历史中消失，永远对不上。
    通过条件：BuildInfo.commit == HEAD~1（代码提交），且 HEAD 相对 HEAD~1 的 diff
    仅含 BuildInfo.lua（stamp 提交）。两者代码内容等价，戳指向的代码即构建代码。
    SeaDebug 展示的是代码提交的 hash，语义上代表同一份代码。
    """
    if not BUILD_INFO.exists():
        problems.append("缺少 scripts/GeneratedData/BuildInfo.lua（版本戳文件）")
        return
    head = git("rev-parse", "--short=7", "HEAD")
    parent = git("rev-parse", "--short=7", "HEAD~1")
    date = git("log", "-1", "--format=%ad", "--date=format:%Y-%m-%d")
    info = read_build_info()
    stamp = info.get("commit")
    if stamp == head:
        return
    if stamp == parent:
        names = run(["git", "diff", "--name-only", "HEAD~1", "HEAD"])
        changed = [n for n in names.stdout.split() if n]
        if changed == [BUILD_INFO.relative_to(ROOT).as_posix()]:
            return
        # HEAD 是普通代码提交而戳指向父提交：重写 stamp 指向 HEAD，
        # 新起一笔 stamp 提交后 HEAD~1 即代码提交，重跑即通过
        version = "0.0.0"
        try:
            version = json.loads(PROJECT_JSON.read_text(encoding="utf-8")).get("version", version)
        except Exception:  # noqa: BLE001
            pass
        write_build_info(version, head, date)
        problems.append(
            f"BuildInfo 版本戳指向 HEAD~1（{stamp}）但 HEAD 含代码改动，已自动重写为 {head}。\n"
            f"  执行 git add {BUILD_INFO.relative_to(ROOT).as_posix()} && "
            "git commit -m 'chore: stamp build info'（新起一笔，勿 amend），然后重跑本检查")
        return
    version = "0.0.0"
    try:
        version = json.loads(PROJECT_JSON.read_text(encoding="utf-8")).get("version", version)
    except Exception:  # noqa: BLE001
        pass
    write_build_info(version, head, date)
    problems.append(
        f"BuildInfo 版本戳过期（{stamp} != HEAD {head}），已自动重写。\n"
        f"  执行 git add {BUILD_INFO.relative_to(ROOT).as_posix()} && "
        "git commit -m 'chore: stamp build info'（新起一笔，勿 amend——amend 会替换父提交，戳永远对不上），\n"
        "  然后重跑本检查（戳指向 HEAD~1 且 HEAD 仅含 BuildInfo 时视为通过）")


RESOURCES_JSON = ROOT / ".project" / "resources.json"
IMAGE_BUDGET_MB = 40.0   # assets/image 入包上限（与 60MB 红线内 audio 预算配套）


def check_asset_meta() -> None:
    """资源 .meta 的 uuid 规格：base64url(18B) = 24 字符。

    schemas/resources.schema.json 的 uuid 协议是 `^uuid://[A-Za-z0-9]{24}$`。
    2026-10-20 踩过：用 `uuid.UUID.bytes[:18]` 生成（该属性恒 16 字节）得到 22 字符的
    非法短 id，Maker 侧无法按 uuid 引用这些资源。
    只检查新增/未提交的可疑项，既有 21~23 字符的历史文件只作提醒（不阻塞推送）。
    """
    import base64
    legacy = []
    broken = []
    for meta in sorted((ROOT / "assets").rglob("*.meta")):
        try:
            uuid_value = json.loads(meta.read_text(encoding="utf-8")).get("uuid", "")
        except Exception:  # noqa: BLE001
            broken.append(meta)
            continue
        if len(uuid_value) == 24:
            try:
                if len(base64.urlsafe_b64decode(uuid_value + "=" * (-len(uuid_value) % 4))) == 18:
                    continue
            except Exception:  # noqa: BLE001
                pass
        broken.append(meta)
    # 只把「本次改动涉及的」当阻断项：已提交进 HEAD 的历史文件不阻塞推送。
    try:
        committed = set(
            line.strip() for line in run(["git", "ls-files", "assets"]).stdout.splitlines())
    except Exception:  # noqa: BLE001
        committed = set()
    fresh = [m for m in broken if m.relative_to(ROOT).as_posix() not in committed]
    if fresh:
        listing = "\n".join(f"    {m.relative_to(ROOT).as_posix()}" for m in fresh[:10])
        problems.append(
            f"{len(fresh)} 个资源 .meta 的 uuid 不是 24 字符 base64url(18B)，Maker 无法按 uuid 引用：\n"
            + listing)
    else:
        legacy = broken
    if legacy:
        warnings.append(f"{len(legacy)} 个历史 .meta 的 uuid 长度非 24（多为音频，既有问题，不阻塞）")


def check_image_budget() -> None:
    """assets/image 的**入包**体积闸门（按 resources.json 的 groups 规则实算）。

    背景（2026-10-20）：一次美术入库把 image 从 31MB 推到 68MB，而 resources.json
    是 `**` 全量引用、构建不做引用裁剪，于是「已入库但未接线」的候选图全部进了包体。
    本检查把入包体积算清楚：候选图要么被代码真正引用、要么进 resources.json 的排除表。
    """
    import fnmatch
    try:
        rules = json.loads(RESOURCES_JSON.read_text(encoding="utf-8"))["groups"]["default"]
    except Exception as error:  # noqa: BLE001
        warnings.append(f"无法解析 resources.json（{error}），跳过 image 预算检查")
        return

    def packed(rel: str) -> bool:
        keep = False
        for rule in rules:
            negative = rule.startswith("!")
            pattern = rule[1:] if negative else rule
            if fnmatch.fnmatch(rel, pattern) or (
                    pattern.endswith("/**") and rel.startswith(pattern[:-3] + "/")):
                keep = not negative
        return keep

    image_dir = ROOT / "assets" / "image"
    if not image_dir.exists():
        return
    total = 0
    for path in image_dir.rglob("*"):
        if path.is_file() and packed(path.relative_to(ROOT).as_posix()):
            total += path.stat().st_size
    total_mb = total / 1024 / 1024
    if total_mb > IMAGE_BUDGET_MB:
        largest = sorted((p for p in image_dir.rglob("*") if p.is_file()
                          and packed(p.relative_to(ROOT).as_posix())),
                         key=lambda p: -p.stat().st_size)[:10]
        listing = "\n".join(f"    {p.stat().st_size / 1024 / 1024:6.2f}MB  {p.relative_to(ROOT).as_posix()}"
                            for p in largest)
        problems.append(
            f"assets/image 入包体积超预算：{total_mb:.1f}MB > {IMAGE_BUDGET_MB:.0f}MB。"
            "要么让代码真正引用这些图，要么把「入库但未接线」的候选加进 "
            ".project/resources.json 的排除表。最大的 10 个：\n" + listing)


def check_asset_budget() -> None:
    audio_dir = ROOT / "assets" / "audio"
    if not audio_dir.exists():
        return
    total = sum(f.stat().st_size for f in audio_dir.rglob("*") if f.is_file())
    total_mb = total / 1024 / 1024
    if total_mb > AUDIO_BUDGET_MB:
        top = sorted((f for f in audio_dir.rglob("*") if f.is_file()),
                     key=lambda f: -f.stat().st_size)[:10]
        listing = "\n".join(f"    {f.stat().st_size / 1024 / 1024:6.2f}MB  {f.relative_to(ROOT).as_posix()}"
                            for f in top)
        problems.append(f"assets/audio 超预算：{total_mb:.1f}MB > {AUDIO_BUDGET_MB:.0f}MB。最大的 10 个：\n{listing}")
    oversize = [f for f in audio_dir.rglob("*") if f.is_file()
                and f.stat().st_size > SINGLE_FILE_MB * 1024 * 1024]
    blocked = [f for f in oversize if f.relative_to(ROOT).as_posix() not in BED_WAV_WHITELIST]
    if blocked:
        listing = "\n".join(f"    {f.stat().st_size / 1024 / 1024:6.2f}MB  {f.relative_to(ROOT).as_posix()}"
                            for f in sorted(blocked, key=lambda f: -f.stat().st_size))
        problems.append(
            f"存在超过 {SINGLE_FILE_MB:.0f}MB 的单音频文件（WAV 同步解码会造卡顿，须转 mp3 或降采样）：\n{listing}")
    beds = [f for f in oversize if f.relative_to(ROOT).as_posix() in BED_WAV_WHITELIST]
    if beds:
        warnings.append(
            f"{len(beds)} 个环境声床 WAV 超过 {SINGLE_FILE_MB:.0f}MB（白名单，懒加载已有缓解）；"
            "若真机启床时仍有可感 Hitch，按方案文档转 mp3/降采样")
    archives = [f for f in (ROOT / "assets").rglob("*.zip") if f.is_file()]
    if archives:
        listing = "\n".join(f"    {f.relative_to(ROOT).as_posix()}" for f in archives)
        problems.append(f"assets/ 内不允许放压缩包（只进包体、运行时不引用，源包应移出仓库）：\n{listing}")


def check_debug_switch() -> None:
    """防回流闸门：真机调试入口（forceEnabled）已于 2026-10-16 按用户决策删除，
    正式包体不得再带「海上调试」面板入口。PC 开发模式热键不受影响。"""
    text = CONFIG_LUA.read_text(encoding="utf-8")
    if "forceEnabled = true" in text:
        problems.append(
            "Ocean/Config.lua 出现 debug.forceEnabled=true：真机调试面板入口已于 2026-10-16 "
            "按用户决策删除，禁止回流（PC 开发模式热键开 SeaDebug 不受影响）")


def run_b5() -> None:
    print("[prepush] 运行 b5 全量回归（52 套件量级，约数分钟）...")
    started = time.time()
    result = run([sys.executable, "tests/run_circle1_b5.py", "--phase", "final"], timeout=1800)
    tail = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    try:
        report = json.loads(tail)
        failures = report.get("failureCount", -1)
        print(f"[prepush] b5: {failures} 红（{time.time() - started:.0f}s）")
        if failures:
            problems.append(f"b5 回归 {failures} 红，详见 {report.get('report')}")
    except Exception:  # noqa: BLE001
        problems.append("b5 回归输出无法解析：\n" + (result.stdout + result.stderr)[-2000:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-b5", action="store_true", help="跳过 b5 全量回归")
    args = parser.parse_args()

    print("[prepush] 1/5 工作区清洁检查")
    check_clean_tree()
    print("[prepush] 2/5 本地/云端 HEAD 对账")
    check_remote_alignment()
    print("[prepush] 3/5 构建版本戳")
    check_build_stamp()
    print("[prepush] 4/5 资产预算")
    check_asset_budget()
    check_image_budget()
    check_asset_meta()
    check_debug_switch()
    if not args.skip_b5:
        print("[prepush] 5/5 b5 回归")
        run_b5()
    else:
        print("[prepush] 5/5 b5 回归（--skip-b5 跳过）")

    for warning in warnings:
        print(f"[prepush][提醒] {warning}")
    if problems:
        print("\n[prepush] 未通过，禁止推送：")
        for index, problem in enumerate(problems, 1):
            print(f"  {index}. {problem}")
        return 1
    print("\n[prepush] 全部通过，可以推送。推送后必须：maker qrcode 重生成测试码 → 真机重新扫码 → 双端版本戳一致才开测")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
