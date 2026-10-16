"""Verify data wiring, compatibility, stale artifacts and existing Lua regressions."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
from sync_runtime_data import ROOT, TABLES, synchronize

sys.path.insert(0, str(ROOT / '.tmp/sea-test-deps'))
from lupa.lua54 import LuaRuntime, lua_type

OUT = ROOT / '.tmp/data-migration-preparation'

def runtime(extra: Path | None = None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    roots = ([extra / 'scripts'] if extra else []) + [ROOT / 'scripts']
    lua.globals().package.path = ';'.join((p / '?.lua').as_posix() for p in roots) + ';' + lua.globals().package.path
    return lua

def require(lua, name):
    return lua.eval('function(name) return (require(name)) end')(name)

def convert(value):
    if lua_type(value) == 'table':
        keys = list(value.keys())
        if keys and set(keys) == set(range(1, len(keys) + 1)):
            return [convert(value[i]) for i in range(1, len(keys) + 1)]
        return {str(k): convert(value[k]) for k in keys}
    return value

def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})

checks = []
synchronize(check=True)
lua = runtime()
inventory = {name: convert(require(lua, name)) for name in ('Ocean.Config', 'Ocean.FishData', 'config.gameplay')}
items = require(lua, 'data.items')
inventory['data.items'] = {name: convert(items.GetDefinition(name)) for name in ('apple', 'bait', 'sardine', 'tuna')}
original = json.loads((OUT / 'runtime-data-inventory.json').read_text(encoding='utf-8'))
for name in original:
    check('all original keys/values: ' + name, inventory[name] == original[name])
check('unknown item remains nil', items.GetDefinition('missing') is None)
copy = items.GetDefinition('apple')
copy['buyPrice'] = 999
check('item query returns isolated copies', items.GetDefinition('apple')['buyPrice'] == 30)
fish = require(lua, 'Ocean.FishData')
config = require(lua, 'Ocean.Config')
check('fish color retains Config table identity', lua.eval('function(a,b) return a==b end')(fish['sardine']['color'], config['fish'][2]['color']))
check('derived speed and map unchanged', (config['ship']['speed'], config['ship']['maxSpeed'], config['world']['mapSize'], config['world']['halfSize']) == (6, 10, 1800, 900))

# Exercise real file -> generator -> require pipeline only in an isolated test fixture.
with tempfile.TemporaryDirectory(prefix='data-fixture-', dir=OUT) as directory:
    fixture = Path(directory)
    (fixture / 'data').mkdir()
    for source in TABLES:
        (fixture / 'data' / source).write_bytes((ROOT / 'data' / source).read_bytes())
    synchronize(fixture)
    check('generation is idempotent', synchronize(fixture) == [])
    source = fixture / 'data/items.lua'
    source.write_text(source.read_text(encoding='utf-8').replace('buy = 30,', 'buy = 31,').replace('shopStockPerDay = 2,', 'shopStockPerDay = 3,'), encoding='utf-8')
    try:
        synchronize(fixture, check=True)
        stale_rejected = False
    except ValueError:
        stale_rejected = True
    check('stale output is rejected before preview/build', stale_rejected)
    source = fixture / 'data/fish.lua'
    source.write_text(source.read_text(encoding='utf-8').replace('wander = 4,', 'wander = 4.25,').replace('fullRange = 120, freezeRange = 150', 'fullRange = 121, freezeRange = 151'), encoding='utf-8')
    synchronize(fixture)
    edited = runtime(fixture)
    check('source price reaches existing item interface', require(edited, 'data.items').GetDefinition('apple')['buyPrice'] == 31)
    check('source stock reaches existing gameplay interface', require(edited, 'config.gameplay')['shop']['dailyStock']['apple'] == 3)
    check('source fish speed reaches existing fish interface', require(edited, 'Ocean.FishData')['sardine']['wanderSpeed'] == 4.25)
    edited_config = require(edited, 'Ocean.Config')
    check('source ranges reach existing world interface', (edited_config['world']['activateRadius'], edited_config['world']['freezeRadius']) == (121, 151))
    source.write_text(source.read_text(encoding='utf-8').replace('fullRange = 121', 'fullRange = 122', 1), encoding='utf-8')
    synchronize(fixture)
    try:
        require(runtime(fixture), 'Ocean.Config')
        divergent_rejected = False
    except Exception as error:
        divergent_rejected = 'shared world activity range' in str(error)
    check('unsupported per-species range divergence fails clearly', divergent_rejected)

syntax = []
compile_source = lua.eval('function(source,name) local fn,err=load(source,name); return fn~=nil,err end')
for folder in ('scripts', 'data'):
    for path in sorted((ROOT / folder).rglob('*.lua')):
        ok, error = compile_source(path.read_text(encoding='utf-8-sig'), '@' + path.relative_to(ROOT).as_posix())
        syntax.append({'file': path.relative_to(ROOT).as_posix(), 'passed': bool(ok), 'error': error})

suites = []
for module in ('tests.SeaRuntimeTests', 'tests.SeaStabilityTests', 'tests.SeaFusedSceneTests', 'tests.ABIntegrationTests'):
    try:
        report = require(runtime(), module).Run()
        rows = convert(report['results'])
        suites.append({'module': module, 'passed': all(row['passed'] for row in rows), 'count': len(rows), 'failures': [row for row in rows if not row['passed']]})
    except Exception as error:
        suites.append({'module': module, 'passed': False, 'error': str(error)})

game = runtime()
for name in ('GameLoopSpec', 'GameLoopUISpec', 'PersistenceRegressionSpec', 'NumericEconomySpec', 'ShopStockSpec'):
    try:
        game.execute((ROOT / f'scripts/Tests/{name}.lua').read_text(encoding='utf-8-sig'))
        suites.append({'module': name, 'passed': True})
    except Exception as error:
        suites.append({'module': name, 'passed': False, 'error': str(error)})

source_hashes = {name: hashlib.sha256((ROOT / 'data' / name).read_bytes()).hexdigest() for name in TABLES}
result = {'checks': checks, 'syntax': syntax, 'suites': suites, 'sourceHashes': source_hashes, 'nativeRuntimeVerified': False}
result['passed'] = all(x['passed'] for x in checks + syntax + suites)
(OUT / 'migration-validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'passed': result['passed'], 'checks': len(checks), 'syntaxFiles': len(syntax), 'suites': suites, 'failedChecks': [x for x in checks + syntax if not x['passed']]}, ensure_ascii=False))
raise SystemExit(0 if result['passed'] else 1)
