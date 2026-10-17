"""A3 evidence only: reuse established Lua54/NVG/LSP helpers without overwriting A1/A2."""
from __future__ import annotations
from collections import Counter
import argparse
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('a3_existing_runner', ROOT / 'tests/run_circle1_a2.py')
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)

def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def tests():
    runner.REGRESSION_MODULES = (*runner.REGRESSION_MODULES, 'tests.Circle1A2BarrelTests',
        'tests.Circle1A3PortTests', 'tests.Circle1A3InputTests', 'tests.Circle1A3SignalsTests',
        'tests.Circle1A3StabilityTests', 'tests.Circle1A3ExperienceTests')
    result = runner.regression_checks()
    write('regressions.json', result)
    syntax = runner.syntax_check()
    write('syntax.json', syntax)
    renders = runner.render_checks()
    for module in ('tests.Circle1A2BarrelRenderTests', 'tests.Circle1A3RecognitionTests'):
        try:
            row = runner._run_recorder_module(module)
            checks = row['report'].get('results', row['report'].get('tests', []))
            row['passed'] = bool(checks) and all(c['passed'] for c in checks)
        except Exception as error:
            row = {'module': module, 'passed': False, 'error': str(error)}
        renders['checks'].append(row)
    renders['passed'] = all(row['passed'] for row in renders['checks'])
    write('render-contracts.json', renders)
    return {'regressions': result, 'syntax': syntax, 'renders': renders,
            'passed': result['passed'] and syntax['passed'] and renders['passed']}

def lsp():
    checker = ROOT / 'tests/check_sea_lsp.py'
    source = checker.read_text(encoding='utf-8-sig')
    old = "ROOT / 'screenshots' / 'sea-v1-lsp.json'"
    assert source.count(old) == 1
    source = source.replace(old, "ROOT / 'outputs' / 'circle1-a3' / 'lsp.json'")
    try:
        exec(compile(source, str(checker), 'exec'), {'__file__': str(checker), '__name__': '__main__'})
    except SystemExit:
        pass
    current = json.loads((OUT / 'lsp.json').read_text(encoding='utf-8-sig'))
    previous = json.loads((ROOT / 'outputs/circle1-a2/barrel-addon/lsp.json').read_text(encoding='utf-8-sig'))
    def errors(report):
        return Counter((uri.split('/scripts/', 1)[-1], row.get('code'), row.get('message'))
            for uri, rows in report['diagnostics'].items() for row in rows if row.get('severity') == 1)
    raw, prior = errors(current), errors(previous)
    new = [{'file': f, 'code': c, 'message': m, 'count': n} for (f, c, m), n in (raw-prior).items()]
    report = {'initialized': current.get('initialized'), 'missingDiagnostics': current.get('missingDiagnostics'),
        'configuredErrorCount': len(current.get('errors', [])), 'rawErrorCount': sum(raw.values()),
        'priorRawErrorCount': sum(prior.values()), 'newRawErrors': new,
        'passed': bool(current.get('initialized')) and not current.get('missingDiagnostics')
            and not current.get('errors') and not new}
    write('lsp-summary.json', report)
    return report

def boundary():
    before = json.loads((OUT / 'before.json').read_text(encoding='utf-8-sig'))
    changed = [name for name, sha in before.items() if not (ROOT/name).is_file()
        or hashlib.sha256((ROOT/name).read_bytes()).hexdigest().upper() != sha.upper()]
    allowed = lambda name: name.startswith('scripts/Ocean/') or name == 'scripts/Systems/EntityStateSystem.lua'
    added = []
    for folder in ('scripts','tests','data','docs','.project','engine-docs','urhox-libs','examples','templates','assets','screenshots'):
        for path in (ROOT/folder).rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                name = path.relative_to(ROOT).as_posix()
                if name not in before:
                    added.append(name)
    violations = [name for name in changed if not allowed(name)] + [name for name in added
        if not re.fullmatch(r'scripts/tests/Circle1A3\w+\.lua',name)]
    manifest = {name: {'beforeSha256': before.get(name),
        'sha256': hashlib.sha256((ROOT/name).read_bytes()).hexdigest()}
        for name in sorted(set(changed+added)) if (ROOT/name).is_file()}
    report = {'changed': changed, 'added': added, 'violations': violations,
        'priorEvidencePreserved': not any(n.startswith('outputs/circle1-a') for n in changed),
        'passed': not violations, 'baseline': 'start-of-A3 working files, not git HEAD'}
    write('boundary.json', report)
    write('delivery-manifest.json', manifest)
    patches = []
    for name in sorted(changed):
        if name.startswith('scripts/Ocean/'):
            old = OUT/'baseline'/'Ocean'/Path(name).name
            new = ROOT/name
            if old.is_file() and new.is_file():
                patches.extend(difflib.unified_diff(old.read_text(encoding='utf-8-sig').splitlines(True),
                    new.read_text(encoding='utf-8-sig').splitlines(True),fromfile='a/'+name,tofile='b/'+name))
    (OUT/'ocean-changes.patch').write_text(''.join(patches),encoding='utf-8')
    return report

def pictures():
    rows = []
    for recognized in (False, True):
        lua = runner._lua(ROOT/'scripts')
        capture = runner._capture_type()()
        capture.bind(lua)
        runtime = lua.eval('function() local r=require("Ocean.SeaRuntime").New({initializeRegions=false}); '
            'r.ship.position={x=85,y=25};r.movement:SetViewport(1920,1080);'
            'r.movement:_AnchorCameraToShip();return r end')()
        query = lua.eval('function(value) return function(id) assert(id=="driftwood_barrel"); return value end end')(recognized)
        lua.eval('require("Ocean.SeaDraw").Scene')(lua.table(),1920,1080,runtime,None,None,query)
        name = 'barrel-25m-' + ('remembered' if recognized else 'unknown')
        capture.render_png(1920,1080,OUT/(name+'.png'))
        (OUT/(name+'.svg')).write_text(capture.to_svg(1920,1080,name),encoding='utf-8')
        rows.append({'name':name,'recognized':recognized,'distanceMeters':25,'engineScreenshot':False,
            'kind':'NanoVG render fixture','png':name+'.png'})
    write('offline-images.json',rows)

def draw_equivalence():
    rows = []
    for seed in (271828, 314159):
        for departure in (0, 400):
            captures = []
            for version, source in (('before',OUT/'baseline'), ('after',ROOT/'scripts')):
                lua = runner._lua(source)
                capture = runner._capture_type()()
                capture.bind(lua)
                make = lua.eval('function(seed,departure) '
                    'local r=require("Ocean.SeaRuntime").New({daySeed=seed,departure={x=departure,y=departure}});'
                    'r.movement:SetViewport(1920,1080);'
                    'for i=1,1000 do r:Update(0.05,1,0) end;return r end')
                runtime = make(seed,departure)
                before_time = runtime.time
                birds = len(runtime.surfaceSignals.GetBirds(runtime.surfaceSignals))
                splashes = len(runtime.surfaceSignals.GetSplashes(runtime.surfaceSignals))
                lua.eval('require("Ocean.SeaDraw").Scene')(lua.table(),1920,1080,runtime)
                assert runtime.time == before_time
                svg = capture.to_svg(1920,1080,'equivalence')
                digest = hashlib.sha256(svg.encode('utf-8')).hexdigest()
                captures.append({'version':version,'svgSha256':digest,'nvgCalls':sum(capture.counts.values()),
                    'birds':birds,'splashes':splashes,'entityCount':len(runtime.world.entities)})
                if seed == 271828 and departure == 0:
                    name='signals-draw-'+version
                    (OUT/(name+'.svg')).write_text(svg,encoding='utf-8')
                    capture.render_png(1920,1080,OUT/(name+'.png'))
            rows.append({'seed':seed,'departure':departure,'normalPopulation':True,
                'sameInput':'1000*0.05 sec, keyboard (1,0)', 'captures':captures,
                'equivalent': captures[0]['svgSha256']==captures[1]['svgSha256']
                    and captures[0]['birds']==captures[1]['birds'] and captures[0]['splashes']==captures[1]['splashes']})
    result={'scenes':rows,'passed':all(row['equivalent'] for row in rows),
        'kind':'offline NanoVG recorder with normal seeded Runtime, not native screenshot/FPS'}
    write('draw-equivalence.json',result)
    return result

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--mode',choices=('tests','lsp','pictures','boundary','draw','all'),default='all')
    mode=parser.parse_args().mode
    report={}
    if mode in ('tests','all'): report['tests']=tests()
    if mode in ('lsp','all'): report['lsp']=lsp()
    if mode in ('pictures','all'): pictures()
    if mode in ('draw','all'): report['drawEquivalence']=draw_equivalence()
    if mode in ('boundary','all'): report['boundary']=boundary()
    report['nativeGameplayMeasured']=False
    report['passed']=all(v.get('passed',True) for v in report.values() if isinstance(v,dict))
    write('validation-'+mode+'.json',report)
    print(json.dumps({'mode':mode,'passed':report['passed'], 'summary':{
        k: (v.get('passed') if isinstance(v,dict) else v) for k,v in report.items()}},ensure_ascii=False))
    return 0 if report['passed'] else 1

if __name__=='__main__': sys.exit(main())
