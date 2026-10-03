"""Run focused shared-registry, scheduling and coordinator integration checks."""
from pathlib import Path
import json
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tmp/sea-test-deps'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = (ROOT / 'scripts/?.lua').as_posix() + ';' + lua.globals().package.path
report = lua.eval('require("tests.ArchitectureIntegrationTests").Run()')
checks = [dict(row.items()) for row in report['results'].values()]
result = {'passed': all(row['passed'] for row in checks), 'checks': checks,
          'nativeRuntimeVerified': False}
out = ROOT / '.tmp/architecture-integration'
out.mkdir(parents=True, exist_ok=True)
(out / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False))
raise SystemExit(0 if result['passed'] else 1)
