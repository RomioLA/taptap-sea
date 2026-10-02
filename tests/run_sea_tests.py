"""Run real pure Lua 5.4 tests; engine UI/visual acceptance is recorded separately."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tmp' / 'sea-test-deps'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = str(ROOT / 'scripts' / '?.lua').replace('\\', '/') + ';' + lua.globals().package.path
syntax = []
compile_lua = lua.eval('function(source,name) local f,e=load(source,name); return f~=nil,e end')
for path in sorted((ROOT / 'scripts').rglob('*.lua')):
    ok, error = compile_lua(path.read_text(encoding='utf-8-sig'), str(path))
    syntax.append({'file': str(path.relative_to(ROOT)), 'passed': ok, 'error': error})
report = lua.eval('require("tests.SeaRuntimeTests").Run')()
results = [dict(report['results'][i]) for i in range(1, len(report['results']) + 1)]
result = {'luaVersion': lua.eval('_VERSION'), 'syntax': syntax, 'tests': results,
          'metrics': dict(report['metrics']), 'passed': all(t['passed'] for t in results) and all(t['passed'] for t in syntax)}
out = ROOT / 'screenshots' / 'sea-v1-logic-tests.json'
out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps({'passed': result['passed'], 'testCount': len(results), 'metrics': result['metrics'],
                  'failures': [t for t in results if not t['passed']], 'output': str(out)}, ensure_ascii=False))
sys.exit(0 if result['passed'] else 1)
