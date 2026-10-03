"""Compare frozen/current real Lua update and recorded drawing; no native FPS claim."""
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'outputs/circle1-b5'
sys.path.insert(0, str(ROOT / '.tmp/sea-test-deps'))
from lupa.lua54 import LuaRuntime
spec = importlib.util.spec_from_file_location('b5_perf_recorder', ROOT / 'tests/render_sea_fusion.py')
render = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = render
spec.loader.exec_module(render)

PROBE = '''function(seed)
    local runtime = require('Ocean.SeaRuntime').New({daySeed=seed})
    local bridge = require('Integration.Bridge').New(runtime, {store={
        Save=function(_,_,done) done(true) end, Load=function(_,done) done(true,nil) end}})
    assert(bridge.loop:Depart())
    local started = os.clock()
    for i=1,900 do assert(bridge:Update(1/60, math.floor((i-1)/150)%3-1, 0)) end
    local elapsed=os.clock()-started
    local rows={string.format('time=%.12f|clock=%.12f|ship=%.12f,%.12f|stamina=%s|day=%s|paused=%s',
        runtime.time,bridge.loop.clock.elapsed,runtime.ship.position.x,runtime.ship.position.y,
        bridge.loop.player.stamina,bridge.loop.player.day,tostring(runtime.paused))}
    for _,e in ipairs(runtime.world.entities) do
        rows[#rows+1]=string.format('%s|%s|%.12f|%.12f|%s|%s|%s',e.id,e.kind,
            e.position.x,e.position.y,tostring(e.removed),tostring(e.state),tostring(e.active))
    end
    table.sort(rows)
    return runtime, elapsed, table.concat(rows,'\\n')
end'''


def sample(source, seed):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = (source / '?.lua').as_posix() + ';' + (source / '?/init.lua').as_posix() + ';' + lua.globals().package.path
    printed = {'count': 0}
    def count_log(*_values):
        printed['count'] += 1
    lua.globals().print = count_log
    recorder = render.NVGCapture()
    recorder.bind(lua)
    runtime, seconds, state = lua.eval(PROBE)(seed)
    draw = lua.eval("function(r) r.movement:SetViewport(1280,720); require('Ocean.SeaDraw').Scene({},1280,720,r) end")
    # At sea, then at authored port, using fixture camera/position solely for the draw probe.
    draw(runtime)
    away_calls = sum(recorder.counts.values())
    lua.eval('function(r) r.movement:ResetAtPosition(r:GetPortPosition()) end')(runtime)
    durations = []
    for _ in range(30):
        recorder.reset()
        started = time.perf_counter()
        draw(runtime)
        durations.append(time.perf_counter() - started)
    return {'updateSeconds': seconds, 'stateHash': hashlib.sha256(state.encode()).hexdigest(),
            'recordedDrawMedianSeconds': statistics.median(durations),
            'portVisibleNvgCalls': sum(recorder.counts.values()), 'awayNvgCalls': away_calls,
            'operationLogCountDuring900Updates': printed['count']}


def main():
    baseline = sorted(OUT.glob('source-before-*/scripts'))[0]
    records = []
    for seed in (271828, 314159):
        before = [sample(baseline, seed) for _ in range(5)]
        after = [sample(ROOT / 'scripts', seed) for _ in range(5)]
        records.append({'seed': seed, 'before': before, 'after': after,
            'identicalBusinessState': all(b['stateHash'] == a['stateHash'] for b, a in zip(before, after)),
            'updateMedianBeforeSeconds': statistics.median(r['updateSeconds'] for r in before),
            'updateMedianAfterSeconds': statistics.median(r['updateSeconds'] for r in after),
            'drawMedianBeforeSeconds': statistics.median(r['recordedDrawMedianSeconds'] for r in before),
            'drawMedianAfterSeconds': statistics.median(r['recordedDrawMedianSeconds'] for r in after),
            'extraPortVisibleNvgCalls': after[0]['portVisibleNvgCalls']-before[0]['portVisibleNvgCalls']})
    result = {'records': records, 'passed': all(r['identicalBusinessState'] for r in records),
        'nativePerformanceVerified': False,
        'limitations': 'Lua 5.4 CPU and Python NanoVG recorder only; no real GPU, UI refresh or Maker print sink performance. Finite offline capture; runtime has no log buffer.'}
    path = OUT / f'performance-{time.time_ns()}.json'
    with path.open('x', encoding='utf-8') as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
    print(json.dumps({'report': str(path), 'passed': result['passed'],
        'samples': [{k:v for k,v in r.items() if k not in ('before','after')} for r in records]}, ensure_ascii=False)[:3000])
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
