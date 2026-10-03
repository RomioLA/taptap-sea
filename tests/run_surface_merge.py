"""Regression and offline visual evidence for the user-approved sea signals."""
from pathlib import Path
import hashlib
import json
import sys

sys.dont_write_bytecode = True
from run_selective_merge import runtime, NVGCapture, synchronize, color_tuple

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'outputs/selective-merge-20261003-surface'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    results = []
    lua = runtime()
    compile_source = lua.eval('function(s,n) local f,e=load(s,n); return f ~= nil,e end')
    files = list((ROOT / 'scripts').rglob('*.lua'))
    errors = []
    for path in files:
        ok, error = compile_source(path.read_text(encoding='utf-8-sig'), '@' + path.as_posix())
        if not ok:
            errors.append({'file': str(path.relative_to(ROOT)), 'error': error})
    results.append({'name': 'Lua54 syntax', 'count': len(files), 'passed': not errors, 'errors': errors})
    for module in ('tests.ArchitectureIntegrationTests', 'tests.ABIntegrationTests',
                   'tests.SeaFusedSceneTests', 'tests.SeaRuntimeTests',
                   'tests.SurfaceRiseTests', 'tests.SurfaceSignalsTests', 'tests.SeaStabilityTests'):
        try:
            report = runtime().eval('require(...).Run()', module)
            rows = [dict(row.items()) for row in report['results'].values()]
            results.append({'name': module, 'count': len(rows), 'passed': all(row['passed'] for row in rows),
                            'failures': [row for row in rows if not row['passed']]})
        except Exception as error:
            results.append({'name': module, 'passed': False, 'error': str(error)})
    synchronize(check=True)
    results.append({'name': 'GeneratedData unchanged and synchronized', 'passed': True})

    lua = runtime()
    capture = NVGCapture()
    lua.globals().recorder = capture.bind(lua)
    render_report = lua.eval('require("tests.SeaFusionRenderTests").Run(recorder)')
    results.append({'name': 'existing render contracts', 'passed': render_report['status'] == 'PASS',
                    'count': len(render_report['tests'])})
    ctx = lua.table()
    lua.globals().ctx = ctx
    lua.execute('''
        R = require("Ocean.SeaRuntime")
        Draw = require("Ocean.SeaDraw")
        r = R.New({initializeRegions=false})
        sardine = r:spawnFish("sardine", {x=-8,y=-8}, 0)
        tuna = r:spawnFish("tuna", {x=-1,y=-8}, math.pi)
        r.world:Update(0.5)
        assert(sardine.surfaceDepth > 0 and sardine.surfaceDepth < 1)
        assert(#r.surfaceSignals:GetBirds() > 0)
        assert(#r.surfaceSignals:GetSplashes() > 0)
        clock = require("Gameplay.GameClock").New()
        beforeDepth = sardine.surfaceDepth
        beforeRemaining = sardine.riseRemaining
        beforeTime = r.time
        beforeWorldTime = r.world.time
        beforeEntityCount = #r.world.entities
    ''')
    snapshots = []
    for width, height, aspect in ((1920, 1080, 'landscape'), (900, 1200, 'portrait')):
        scene = lua.globals().r
        scene.movement.SetViewport(scene.movement, width, height)
        for phase in ('day', 'night'):
            clock = lua.globals().clock
            clock.Seek(clock, phase, 10)
            capture.reset()
            lua.globals().Draw.Scene(ctx, width, height, scene, clock)
            assert not capture.stack, 'Signal drawing leaked the NanoVG state stack'
            hints = [i for i, element in enumerate(capture.elements)
                     if color_tuple(element['fill_color']) in ((14, 34, 52, 63), (250, 250, 240, 238))
                     or color_tuple(element['stroke_color']) == (240, 252, 250, 230)]
            assert hints, 'Actual sea signal drawing was absent'
            assert all(capture.elements[i]['clip'] is not None for i in hints), 'Sea hints escaped the water clip'
            overlays = [i for i, element in enumerate(capture.elements)
                        if color_tuple(element['fill_color']) == (10, 22, 48, 190)]
            if phase == 'night':
                assert overlays and max(hints) < min(overlays), 'Sea hints escaped night shading'
            else:
                assert not overlays, 'Day scene retained the night mask'
            name = f'signals-{aspect}-{phase}'
            png = OUT / f'{name}.png'
            svg = OUT / f'{name}.svg'
            svg.write_text(capture.to_svg(width, height, name), encoding='utf-8')
            capture.render_png(width, height, png, supersample=1)
            snapshots.append(str(png.relative_to(ROOT)))
    lua.execute('''
        assert(sardine.surfaceDepth == beforeDepth and sardine.riseRemaining == beforeRemaining)
        assert(r.time == beforeTime and r.world.time == beforeWorldTime)
        assert(#r.world.entities == beforeEntityCount)
        r.paused = true
        r:Update(0.2)
        assert(sardine.riseRemaining == beforeRemaining and r.time == beforeTime)
        r.world:remove(sardine.id, "caught")
        assert(#r.surfaceSignals:GetBirds() == 0)
        r:Reset()
        assert(#r.surfaceSignals:GetBirds() == 0 and #r.surfaceSignals:GetSplashes() == 0)
    ''')
    results.append({'name': 'real Runtime signals render purely, pause, immediate removal and reset', 'passed': True})
    before = json.loads((OUT / 'before.json').read_text(encoding='utf-8-sig'))
    unchanged_planning = []
    for record in before:
        path = Path(record['path'])
        if not path.is_absolute():
            path = ROOT / path
        if path.suffix == '.xlsx' or 'docs/' in record['path']:
            unchanged_planning.append(hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256'])
    results.append({'name': 'planning workbook and planning-related docs unchanged',
                    'passed': all(unchanged_planning), 'count': len(unchanged_planning)})
    result = {'passed': all(row['passed'] for row in results), 'checks': results,
              'snapshots': snapshots, 'native_runtime_verified': False,
              'rise_seconds': 2, 'rise_status': 'USER_APPROVED_TEST_VALUE', 'seabirds_eat_fish': False}
    (OUT / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
