"""Validate the accepted remote changes without engine, network or cloud writes."""
from pathlib import Path
import json
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'outputs/selective-merge-20261003'
for path in (ROOT / '.tmp/sea-test-deps', ROOT / 'outputs/remote-review-20261002/test-runtime'):
    sys.path.insert(0, str(path))
from lupa.lua54 import LuaRuntime
from render_sea_fusion import NVGCapture
from sync_runtime_data import synchronize


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (ROOT / 'scripts/?.lua').as_posix() + ';' + lua.globals().package.path
    return lua


def color_tuple(value):
    return None if value is None else (value.r, value.g, value.b, value.a)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    checks = []
    lua = runtime()
    compile_source = lua.eval('function(s,n) local f,e=load(s,n); return f ~= nil,e end')
    sources = list((ROOT / 'scripts').rglob('*.lua'))
    errors = []
    for path in sources:
        ok, error = compile_source(path.read_text(encoding='utf-8-sig'), '@' + path.as_posix())
        if not ok:
            errors.append({'file': str(path.relative_to(ROOT)), 'error': error})
    checks.append({'name': 'Lua54 syntax', 'count': len(sources), 'passed': not errors, 'errors': errors})
    for module in ('tests.ArchitectureIntegrationTests', 'tests.ABIntegrationTests', 'tests.SeaFusedSceneTests'):
        report = runtime().eval('require(...).Run()', module)
        rows = [dict(row.items()) for row in report['results'].values()]
        checks.append({'name': module, 'count': len(rows), 'passed': all(row['passed'] for row in rows),
                       'failures': [row for row in rows if not row['passed']]})
    synchronize(check=True)
    checks.append({'name': 'GeneratedData matches editable data', 'passed': True})

    lua = runtime()
    capture = NVGCapture()
    recorder = capture.bind(lua)
    lua.globals().recorder = recorder
    report = lua.eval('require("tests.SeaFusionRenderTests").Run(recorder)')
    checks.append({'name': 'render contracts including live clock and layer order',
                   'count': len(report['tests']), 'passed': report['status'] == 'PASS'})
    ctx = lua.table()
    fixtures = lua.eval('require("tests.SeaFusionRenderTests")')
    draw = lua.eval('require("Ocean.SeaDraw")')
    previews = []
    for width, height, aspect in ((1920, 1080, 'landscape'), (900, 1200, 'portrait')):
        scene = fixtures.CreatePreviewRuntime(width, height)
        clock = lua.eval('require("Gameplay.GameClock").New()')
        for phase in ('day', 'night'):
            clock.Seek(clock, phase, 10)
            capture.reset()
            draw.Scene(ctx, width, height, scene, clock)
            overlays = [index for index, element in enumerate(capture.elements)
                        if color_tuple(element['fill_color']) == (10, 22, 48, 190)]
            assert len(overlays) == (1 if phase == 'night' else 0)
            assert not capture.stack, 'NanoVG state leaked between frames'
            if phase == 'night':
                overlay = capture.elements[overlays[0]]
                assert overlay['clip'] is None, 'Night tint must cover the full background'
                assert overlays[0] < len(capture.elements) - 1, 'Boat/marks must be drawn above tint'
            name = f'{aspect}-{phase}'
            svg = OUT / f'{name}.svg'
            png = OUT / f'{name}.png'
            svg.write_text(capture.to_svg(width, height, name), encoding='utf-8')
            capture.render_png(width, height, png, supersample=1)
            previews.append(str(png.relative_to(ROOT)))
    checks.append({'name': 'day/night in both aspects, full tint and restored clipping', 'passed': True})
    result = {'passed': all(row['passed'] for row in checks), 'checks': checks,
              'previews': previews, 'evidence_kind': 'offline Lua54 NanoVG capture',
              'native_runtime_verified': False, 'hud_rendered': False}
    (OUT / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
