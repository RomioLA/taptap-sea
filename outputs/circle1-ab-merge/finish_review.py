"""Finalize review documents and syntax evidence; never run gameplay or write scripts."""
import hashlib
import importlib.util
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
def read(name):
    return json.loads((OUT / name).read_text(encoding='utf-8-sig'))
def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def textwrite(name, value):
    (OUT / name).write_text(value, encoding='utf-8')

spec = importlib.util.spec_from_file_location('final_runner', OUT / 'run_final_checks.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
lua = runner._lua_runtime()
compile_only = lua.eval('function(src, name) local f, err = load(src, name); return f ~= nil, err end')
syntax = []
for path in sorted((ROOT / 'scripts').rglob('*.lua')):
    ok, error = compile_only(path.read_text(encoding='utf-8-sig'), '@' + path.as_posix())
    syntax.append({'file': path.relative_to(ROOT).as_posix(), 'sha256': sha(path), 'passed': bool(ok), 'error': error})
write('syntax-final.json', {'luaVersion': lua.eval('_VERSION'), 'compileOnly': True,
    'files': len(syntax), 'passed': all(row['passed'] for row in syntax), 'results': syntax})
whitespace = subprocess.run(['git', 'diff', '--check'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace')
write('whitespace-final.json', {'command': 'git diff --check', 'exitCode': whitespace.returncode,
    'stdout': whitespace.stdout, 'stderr': whitespace.stderr, 'scope': 'Tracked working-tree diff only; CRLF conversion notices are retained.'})

contract = read('contract-inventory.json')
contract['purpose'] = '圈1 A/B 当前组合接口清单；离线验收结果见合并复查与交付.md，原生及真实云待验收'
contract['source_context']['b4_state'] = 'B4 已交付；当前组合完成修复并冻结86份Lua源码'
contract['compatibility_check'].update({
    'existing_path': 'Bridge preparation receipt uses Runtime:GetFishingGeneration(); Game:GetWorld() separately ensures composition World/system registration.',
    'facade_fixture': 'Construct Bridge.New with a real Runtime, then replace only bridge.runtime with a method-only proxy rejecting world/ship/movement reads. Keep bridge.game.runtime real. Execute the actual NewRun/preparation path; receipt obtains generation through GetFishingGeneration(). Architecture suite passes.',
    'scope_limit': 'Post-construction Bridge public-method compatibility only, not arbitrary facade injection during Bridge.New. Game:GetWorld lifecycle/deduplicated registration is tested separately. Formal NewRun preserves World; independent Runtime.Reset replaces it.',
    'known_absence': 'SeaRuntime has no generic public GetWorld/GetWorldIdentity. Prepared receipts need only the provided GetFishingGeneration method; Game:GetWorld is the composition current-World getter with deduplicated registration.'})
contract['deferred_acceptance'] = [
    'Native GUI/input/resize/DPR and real cloud cross-launch restore remain untested.',
    'Local run/session guards reject stale local callback application; remote same-key write ordering requires real-service evidence.',
    'No preview start, real-cloud operation, build, submit, commit or push was performed by this final review.']
write('contract-inventory.json', contract)

matrix_path = OUT / '接口验收矩阵.md'
matrix = matrix_path.read_text(encoding='utf-8-sig')
matrix = matrix.replace('状态：A 接口静态核对完成；这是 B4 交付后的执行清单，不是组合验收结果。B4 仍在开发，本轮没有把当前变动中的 B 代码或旧 D 盘副本当作最终版本，也没有运行组合测试、启动原生/云环境、构建或提交。', '状态：B4 已交付，当前 C 工程已完成组合修复与离线回归。执行结果、源码冻结和未测边界见[合并复查与交付](合并复查与交付.md)。本矩阵保留合同及原生/真实云后续验收清单。')
start = matrix.index('10. **公开 Runtime façade')
matrix = matrix[:start] + '''10. **公开 Runtime façade 兼容性**：正常构造 Bridge.New(realRuntime, options) 后，仅替换 bridge.runtime 为公开方法代理，对 world/ship/movement 等非方法字段读取报错；bridge.game.runtime 保持真实 Runtime。真实 NewRun/新日准备收据通过公开 GetFishingGeneration() 获取代次，不需读取 World。当前 Architecture 测试已通过这一路径；Game:GetWorld() 的 World 读取、GameplaySystem 去重及独立 Runtime:Reset() 生命周期由其余架构用例单独验证。此夹具只证明构造后 Bridge 的公开方法调用兼容，不声称任意 façade 可注入 Bridge.New，也不声称 A 有 Runtime:GetWorld()。原准备矩阵要求准备收据经 game:GetWorld() 的写法过度约束，现按实际所需语义修正。

上述离线检查已经执行，不能据此推断原生输入、截图、真实云或帧率通过。预览状态为 stopped/process_alive=false，按项目规则未启动；没有构建、提交或推送。
'''
textwrite('接口验收矩阵.md', matrix)

textwrite('验证执行说明.md', '''# A+B 当前工作树回归入口

最终执行结果见[合并复查与交付](合并复查与交付.md)。`run_final_checks.py` 默认仅检查 readiness；`--stage all` 运行冻结后的当前 C 工程。每套使用独立 Lua 5.4 runtime，Lua 搜索路径只有本工程 scripts，移除原生模块 searcher。D 盘仅只读提供既有 Lupa wheel，不提供 Lua 业务源码。

```powershell
& 'C:/Users/80739/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' `
  'C:/codex/taptap-sea/outputs/circle1-ab-merge/run_final_checks.py' --stage all
```

组合门禁要求 B4交付说明.md、完整 final-source-ready.json（status=ready，覆盖全部86份 scripts Lua、哈希一致）及有效 B4 测试发现结果。启动首套测试前再次检查；整批前后比对源码，任何变化均非零退出。`--force-b4` 不绕过门禁，runner 不写 ready 标记。

阶段包含 a1/a2/a3、legacy、b1/b2/b3/b4、players、merge。A 绘制测试使用现有 NVGCapture recorder，识别测试按其实际签名传 recorder。B1/2/3 动态发现当前测试。

B4 没有新增 B4 命名的 Lua suite，实际更新了既有 B2/B3 suites 和玩家脚本。根任务逐文件审阅后生成 b4-final-suite-manifest.json，记录五套实际更新测试的当前路径与 SHA256；无 B4 命名模块时，runner 只接受完整有效的该清单，否则 not_ready。玩家阶段另执行全部五份顶层 Spec，以实际断言计数或唯一 PASS 输出计数判定，异常即失败；不假设它们有 Run()。模块 require 用括号限制 Lua5.4 多返回值，Run() 结果逐用例转换，不能因无返回值而假设通过。

merge 阶段运行新建 Circle1ABMergeFrameBudgetTests 的五项实际 Runtime/Bridge/Loop 回归。B4 阶段的五套与 B2/B3 重复，因此最终45次套件执行对应40套唯一测试，不能计成45套新增测试。逐套结果记录 failed/skipped/load_error/not_ready/not_tested，任一非通过则非零退出。

报告在 final-checks 下按 UTC 时间戳新增，不覆盖历史 A/B 报告。早期 runner 返回值解析问题、旧测试夹具失败、B2替身时长预期修正及新测试 LSP 参数错误的中间记录均保留，最终以 run-20261003T043853914928Z.json 为准。原 A 共享测试两项哈希差异保留并独立登记审阅结论，不改保护基线来掩盖差异。

纯 Lua、内存 Store、UI 控件树、NVG recorder 只证明脚本与绘制合同。nativeGuiPreviewVerified/nativeFrameRateVerified/realCloudSdkVerified 均为 false，不记录为原生表现或真实云成功。工具不启动 preview/build、不切换服务环境、不写真实云、不提交推送。

原生验收还需记录设备、窗口尺寸、DPR、Maker版本、实际输入、截图/日志及结果；覆盖 UI 点击消费、窗口变化、固定桶航路、透镜捕鱼、昼夜/背包暂停。真实云需覆盖新局初始保存、失败重试/明确跳过、读档跨启动、迟到回调、同 key 写入顺序。未执行项目保持未测。
''')

note = '''

## 最终修复追记（根任务）

本报告及 b4-logic-evidence/results.json 保留修复前事实。上述两个产品问题已通过 Game.lua、GameClock.lua、Circle1B2Barrel.lua 的最小修改处理；同场景新回归修复前3/5、修复后5/5，最终组合45次套件执行全部通过。准备收据采用公开 GetFishingGeneration() 满足所需语义，接口矩阵原要求经 game:GetWorld() 已修正；Architecture 实际代理兼容用例也通过。详见[合并复查与交付](合并复查与交付.md)，不将旧报告的待修复状态视为当前状态。原生及真实云仍未测。
'''
with (OUT / 'B4逻辑复查.md').open('a', encoding='utf-8') as stream:
    stream.write(note)
with (OUT / '准备交付.md').open('a', encoding='utf-8') as stream:
    stream.write('\n\n## 最终阶段更新\n\n以上保留准备期事实。B4 已交付，当前 C 工程组合与离线回归结果以[合并复查与交付](合并复查与交付.md)为准；共享测试差异已逐项审阅，原保护哈希不改。\n')
print(json.dumps({'syntaxFiles': len(syntax), 'syntaxPassed': all(row['passed'] for row in syntax), 'whitespaceExit': whitespace.returncode}))
