"""Real Lua tests for scene composition; native visuals require separate acceptance."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tmp' / 'sea-test-deps'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = str(ROOT / 'scripts' / '?.lua').replace('\\', '/') + ';' + lua.globals().package.path
report = lua.eval('require("tests.SeaFusedSceneTests").Run')()
tests = [dict(report['results'][i]) for i in range(1, len(report['results']) + 1)]
result = {'luaVersion': lua.eval('_VERSION'), 'tests': tests,
          'nativeRuntimeVerified': False, 'passed': all(t['passed'] for t in tests)}
out = ROOT / 'screenshots' / 'sea-fusion-adapter-tests.json'
out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False))
sys.exit(0 if result['passed'] else 1)
