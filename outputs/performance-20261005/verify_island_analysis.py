"""Check diagnostic consistency, production hashes, syntax, and clock behavior."""
import hashlib
import importlib.util
import json
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
report_path = OUT / 'island-components.json'
report = json.loads(report_path.read_text(encoding='utf-8'))
rows = {row['scenario']: row for row in report['records']}
assert len(rows) == 5
near, edge = rows['near_full'], rows['left_edge']
assert near['components']['outlines']['calls']['StrokeWorldLine'] == 96
assert near['components']['outlines']['calls']['nvgClosePath'] == 402
assert near['components']['foam']['calls']['StrokeWorldLine'] == 128
assert near['medianFull']['nvgApiCalls'] == 4964
assert edge['components']['outlines']['calls']['StrokeWorldLine'] == 96
assert edge['components']['foam']['calls']['StrokeWorldLine'] == 128
assert edge['medianFull']['nvgApiCalls'] == 1955
assert near['visibleByPresentation'] and edge['visibleByPresentation']
assert not rows['left_offscreen']['visibleByPresentation']
prior = json.loads((OUT / 'verification-followup.json').read_text(encoding='utf-8'))
verified_files = []
for row in prior['sourceFiles']:
    actual = hashlib.sha256((ROOT / row['path']).read_bytes()).hexdigest().upper()
    assert actual == row['sha256'], row['path']
    verified_files.append(row['path'])
assert hashlib.sha256((ROOT / 'scripts/Ocean/Config.lua').read_bytes()).hexdigest().upper() == prior['contentConfigSha256']
for name in ('profile_islands.py', 'compare_fix.py', 'profile_hotspots.py', 'verify_island_analysis.py'):
    compile((OUT / name).read_text(encoding='utf-8'), name, 'exec')
spec = importlib.util.spec_from_file_location('clock_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, _, _ = host.prepare_runtime()
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().pause = lambda: time.sleep(.25)
start_cpu, start_elapsed = time.process_time(), time.perf_counter()
lua_clock = lua.execute('local start=os.clock();pause();return os.clock()-start')
clock_evidence = {'luaOsClockSeconds': lua_clock, 'processCpuSeconds': time.process_time()-start_cpu,
    'elapsedSeconds': time.perf_counter()-start_elapsed}
report['timingQuality'] = {
    'accurateComponentPercentagesVerified': False,
    'reason': 'Large cross-sample variation, negative ablation deltas, instrumentation overhead, and shared outline upvalues. Use calls/allocations for this analysis.',
    'legacyTimerValidation': clock_evidence}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
result = {'consistentScenarios': len(rows), 'productionSourceHashesUnchanged': verified_files,
    'contentConfigUnchanged': True, 'diagnosticSyntaxFiles': 4, 'clockEvidence': clock_evidence,
    'gameRegressionRerun': False, 'nativeFpsVerified': False}
(OUT / 'island-analysis-verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result, ensure_ascii=False))
