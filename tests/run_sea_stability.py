"""Long simulated voyages, separate from native rendering/hardware acceptance."""
import json
from pathlib import Path
import sys
from time import perf_counter

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tmp' / 'sea-test-deps'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = str(ROOT / 'scripts' / '?.lua').replace('\\', '/') + ';' + lua.globals().package.path
start = perf_counter()
report = lua.eval('require("tests.SeaStabilityTests").Run')()
results = [dict(report['results'][i]) for i in range(1, len(report['results']) + 1)]
result = {'luaVersion': lua.eval('_VERSION'), 'tests': results,
          'metrics': dict(report['metrics']), 'wallTimeSec': perf_counter()-start,
          'nativeRenderingPerformanceMeasured': False,
          'passed': all(t['passed'] for t in results)}
out = ROOT / 'screenshots' / 'sea-v1-stability-tests.json'
out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False))
sys.exit(0 if result['passed'] else 1)
