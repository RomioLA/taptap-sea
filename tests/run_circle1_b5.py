"""B5 headless checks; evidence is append-only under outputs/circle1-b5.

Uses the already installed Lua 5.4 dependency. Never launches the engine or cloud,
and never invokes historical runners that overwrite their original evidence.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tmp/sea-test-deps'))
from lupa.lua54 import LuaRuntime

# Reuse the established NanoVG recorder without executing its artifact-writing main.
_spec = importlib.util.spec_from_file_location('b5_render_recorder', ROOT / 'tests/render_sea_fusion.py')
_render = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _render
_spec.loader.exec_module(_render)


def plain(value):
    if hasattr(value, 'items'):
        pairs = list(value.items())
        if pairs and all(isinstance(k, int) for k, _ in pairs):
            return [plain(value[k]) for k in sorted(k for k, _ in pairs)]
        return {str(k): plain(v) for k, v in pairs}
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'scripts')
    parser.add_argument('--phase', choices=('baseline', 'final', 'new'), default='final')
    args = parser.parse_args()
    source = args.source.resolve()
    captured = []
    def log(*values):
        if len(captured) < 600:
            captured.append(' '.join(str(v) for v in values)[:9000])
    def runtime():
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().package.path = (source / '?.lua').as_posix() + ';' + (source / '?/init.lua').as_posix() + ';' + lua.globals().package.path
        lua.globals().print = log
        return lua

    lua = runtime()
    compile_lua = lua.eval('function(s,n) local f,e=load(s,n); return f~=nil,e end')
    syntax = []
    for path in sorted(source.rglob('*.lua')):
        ok, error = compile_lua(path.read_text(encoding='utf-8-sig'), '@' + path.as_posix())
        syntax.append({'file': path.relative_to(source).as_posix(), 'passed': bool(ok), 'error': error})

    test_dir = source / 'tests'
    # Run all established Circle1 protocols, real Ocean suites and A/B seams.
    modules = sorted({p.stem for p in test_dir.glob('Circle1*Tests.lua')})
    modules += ['ABIntegrationTests', 'ArchitectureIntegrationTests', 'SeaFusedSceneTests',
                'SeaFusionRenderTests', 'SeaRuntimeTests', 'SeaStabilityTests',
                'SurfaceRiseTests', 'SurfaceSignalsTests']
    if args.phase == 'new':
        modules = [name for name in modules if name.startswith('Circle1B5')]
    suites = []
    for name in modules:
        captured.clear()
        started = time.perf_counter()
        row = {'name': name, 'evidence': 'offline Lua modules; engine/UI/cloud bindings are test doubles'}
        try:
            lua = runtime()
            recorder = _render.NVGCapture()
            recorder_table = recorder.bind(lua)
            module = lua.eval(f'require("tests.{name}")')
            if isinstance(module, tuple):
                module = module[0]
            render_suites = {'Circle1A2BarrelRenderTests', 'Circle1A2FishingTests',
                             'Circle1A3RecognitionTests', 'SeaFusionRenderTests', 'Circle1B5PortDrawTests'}
            report = plain(module.Run(recorder_table) if name in render_suites else module.Run())
            checks = report.get('results', report.get('checks', report.get('tests', []))) if isinstance(report, dict) else []
            if isinstance(checks, dict):
                checks = list(checks.values())
            aggregate = str(report.get('status', '')).lower() in ('pass', 'passed', 'ok') if isinstance(report, dict) else False
            checks = [{'name': c, 'passed': aggregate, 'evidence': 'aggregate assertion suite returned PASS'} if isinstance(c, str) else c for c in checks]
            row.update(report=report, tests=checks, passed=all(c.get('passed') for c in checks if not c.get('skipped')) if checks else aggregate or bool(report.get('passed', False)), skippedCount=sum(bool(c.get('skipped')) for c in checks), nvgCalls=sum(recorder.counts.values()))
        except Exception as error:
            row.update(passed=False, error=str(error), tests=[], skippedCount=0)
        row.update(elapsedSeconds=time.perf_counter() - started, log='\n'.join(captured)[:24000])
        suites.append(row)
    if args.phase != 'new':
        for name in ('GameLoopSpec.lua', 'GameLoopUISpec.lua', 'PersistenceRegressionSpec.lua', 'NumericEconomySpec.lua', 'ShopStockSpec.lua'):
            captured.clear()
            row = {'name': name, 'evidence': 'existing offline regression, unchanged source'}
            try:
                runtime().execute((test_dir / name).read_text(encoding='utf-8-sig'))
                row.update(passed=True, skippedCount=0)
            except Exception as error:
                row.update(passed=False, error=str(error), skippedCount=0)
            row['log'] = '\n'.join(captured)[:24000]
            suites.append(row)

    failures = [r for r in syntax if not r['passed']] + [r for r in suites if not r['passed']]
    skipped = sum(r.get('skippedCount', 0) for r in suites)
    result = {'phase': args.phase, 'source': str(source), 'luaVersion': str(lua.eval('_VERSION')),
              'syntax': syntax, 'suites': suites, 'failureCount': len(failures),
              'skippedCount': skipped, 'allExecutedPassed': not failures,
              'allRequestedVerified': not failures and not skipped,
              'nativeEngineVerified': False, 'nativeUIVerified': False, 'realCloudVerified': False,
              'sourceHashes': {p.relative_to(source).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.rglob('*.lua'))}}
    out = ROOT / 'outputs/circle1-b5' / f'{args.phase}-regression-{time.time_ns()}.json'
    with out.open('x', encoding='utf-8') as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
    print(json.dumps({'report': str(out), 'phase': args.phase, 'syntaxFiles': len(syntax),
                      'suites': len(suites), 'tests': sum(len(r.get('tests', [])) for r in suites),
                      'failureCount': len(failures), 'skippedCount': skipped,
                      'failures': [{'name': r.get('name', r.get('file')), 'error': r.get('error', ''), 'checks': [c for c in r.get('tests', []) if not c.get('passed')][:4]} for r in failures[:6]]}, ensure_ascii=False)[:4500])
    return 0 if not failures and not skipped else 1


if __name__ == '__main__':
    raise SystemExit(main())
