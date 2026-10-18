"""Assemble delivery statistics from completed checks, preserving intermediate evidence."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
OUT = Path(__file__).resolve().parent

def read(name):
    return json.loads((OUT/name).read_text(encoding='utf-8-sig'))

validation = read('validation-all.json')
lsp = read('lsp-summary.json')
boundary = read('boundary.json')
assert validation['tests']['passed'] and validation['drawEquivalence']['passed']
assert lsp['passed'] and boundary['passed'] and boundary['priorEvidencePreserved']
benchmark = read('performance/signals-benchmark.json')
assert benchmark['allWorldDigestsEqual'] and benchmark['allSignalDigestsEqual']
assert benchmark['naturalSplashObserved']
regressions = read('regressions.json')
renders = read('render-contracts.json')
syntax = read('syntax.json')
logic_count = sum(len(row['tests']) for row in regressions['checks'])
render_count = sum(len(row['report'].get('results', row['report'].get('tests', []))) for row in renders['checks'])

def median(data, side, seed, key):
    return data['sources'][side][str(seed)]['summary'][key]['median']

lines = [
    '\n## 性能对比与实际限制\n',
    '基线为本轮开始时的Ocean快照。所有采样使用正常生成、相同两个种子、(0,0)出航、默认6米/秒连续北航120模拟秒、2400次0.05秒更新、每0.25秒读取信号、1200对getter/visitor读取、每版本每种子重复3次。没有改鱼数、范围、信号阈值或输入。下表为Lua os.clock耗时中位数，**不是原生帧率**。\n',
    '| 轮次/种子 | 初始化，前→后(ms) | 世界更新，前→后(ms) | 1200对getter，前→后(ms) | 后版本visitor(ms) |',
    '|---|---:|---:|---:|---:|',
]
for label, file in (
    ('单遍前/分块', 'performance/pre-single-membership-pass.json'),
    ('单遍后/分块', 'performance/single-pass-blocked-order.json'),
    ('最终/交错', 'performance/signals-benchmark.json'),
):
    data = read(file)
    for seed in (271828, 314159):
        values = [f'{median(data,"before",seed,key)*1000:.0f}→{median(data,"after",seed,key)*1000:.0f}'
            for key in ('initCpuSec','updateCpuSec','getter.cpuSec')]
        visitor = median(data,'after',seed,'visitor.cpuSec')*1000
        lines.append(f'| {label} / {seed} | {values[0]} | {values[1]} | {values[2]} | {visitor:.0f} |')
lines.extend([
    '\n三轮都保留原始结果。第二轮基线本身也显著变慢，不能把跨轮变化归因到单遍成员检查。为检查顺序影响，最后一轮仅将运行顺序改为before/after、after/before、before/after，其余方法不变；完整重复计时、配对与顺序均保存。交错成对更新差异分别为(+64.5%,-13.4%,+0.5%)、(+3.0%,+8.3%,-1.2%)，getter差异分别为(+43.3%,-24.9%,-30.3%)、(+19.8%,+7.3%,-11.3%)。**CPU结果波动且有退步，未证明可靠收益，getter/update耗时仍待解决；不能以分配收益宣布性能问题全部修复。**\n',
    '可重复的分配收益：两个种子1200对快照getter的GC停止期间增量分别20,907.92→20,382.95KiB、17,495.42→16,970.45KiB，均少约525KiB；完全GC后保留量18.42→17.36KiB、15.58→14.52KiB，各少约1.06KiB。新visitor没有旧版本接口，报告为after-only：1200对分配0.25KiB，GC后保留0.125KiB；最终计时样本135–250ms，绘制自身的回调/路径开销不包含在该读取数字中。\n',
    '完整正常初始化+120秒扩区运行，GC后增量分别4,750.00→4,750.86KiB、4,145.64→4,146.49KiB，后版约多0.85KiB，明确报告为保留工作区成本。正常同日区域鱼群存量增长与快照临时分配不同；前轮未GC增量不能当作泄漏证据。真实旧World调度/引用问题由重建回归证实并修复，未用该采样推断原生内存泄漏已消除。\n',
    '定位依据：快照getter要为每条线索及位置生成副本，旧水域快照每次分配表/闭包，成员map和排序曾反复重建。本轮减少这些重复工作并让Draw用标量读取；每次读取仍刷新阻挡对象并做当前资格检查，历史水花合法性增加了必要成本。剩余getter副本和扫描成本未消除。两种子所有世界/完整信号摘要一致，末态分别42鸟/4水花、32鸟/7水花，鱼群156/28、152/28，天然水花均存在。\n',
    '详表、范围和各轮解释见 `performance/signals-performance-report.md`。原生FPS、真实Draw帧时和原生内存仍未测。\n',
    '\n## 最终验证汇总\n',
    f'- {len(regressions["checks"])}个逻辑模块、{logic_count}项检查通过；{len(renders["checks"])}个绘图模块、{render_count}项检查通过。新增A3共26项，包含真实PlayerState/Persistence的离线识别回归。',
    f'- Lua5.4加载{len(syntax["files"])}个脚本，全部语法通过。',
    f'- LSP初始化完成，无缺失诊断；配置后错误{lsp["configuredErrorCount"]}；原始severity1为{lsp["rawErrorCount"]}（前轮{lsp["priorRawErrorCount"]}），新增0。既有诊断未越界修改，不宣称全项目clean。',
    '- 四个正常生成绘图场景前后SVG哈希、鸟/水花数量一致；正常体验重复摘要一致；天然海面水花PNG已实际打开检查。',
    '- 文件边界违规0；六个Ocean改动、六个A3测试新增；A1/A2证据保留，受保护目录内容哈希未变。',
    '- 待验收/未完成边界：B正式接线、原生控制与画面/长运行/性能、CPU收益确认、所列设计缺口。',
    '\n阅读依据：本地AGENTS、现有架构/共同接口边界、完整Lua开发指南、01 NanoVG/03 Flappy/13 Yoga等相关示例、输入/UI文档、2D脚手架与已安装taptap-maker-local技能。项目指定nvg-resolution-mode专项技能资源未在本机发现路径中找到；保留既有Mode B并按本地指南/示例核对，未改引擎或安装替代。\n',
    '取证索引：`evidence-manifest.json`列出本目录文件SHA256（不包含自身），`delivery-manifest.json`列出代码；复跑入口 `run_validation.py --mode all`。本交付状态保持**待验收**。\n',
])
path = OUT/'交付说明.md'
base = path.read_text(encoding='utf-8').split('\n## 性能对比与实际限制\n',1)[0]
path.write_text(base+'\n'.join(lines),encoding='utf-8')
final = {
    'status':'待验收', 'generatedAtUTC':datetime.now(timezone.utc).isoformat(),
    'logicChecks':logic_count, 'renderChecks':render_count, 'syntaxFiles':len(syntax['files']),
    'newA3Checks':26, 'newRawLspErrors':lsp['newRawErrors'],
    'oceanValidationPassed':True, 'boundaryPassed':True,
    'benchmarkDigestsMatch':True, 'allocationBenefitObserved':True,
    'cpuBenefitProven':False, 'nativeGameplayMeasured':False,
    'bFormalWiringVerified':False, 'wholeProjectCleanClaimed':False,
}
(OUT/'final-summary.json').write_text(json.dumps(final,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
manifest = {}
for file in sorted(OUT.rglob('*')):
    if file.is_file() and file.name != 'evidence-manifest.json' and '__pycache__' not in file.parts:
        manifest[file.relative_to(OUT).as_posix()] = {'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'bytes':file.stat().st_size}
(OUT/'evidence-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(final,ensure_ascii=False))
