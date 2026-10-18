"""Paired CPU/allocation comparison against saved pre-fix code, without a window."""
import importlib.util
import json
import statistics
import sys
import time as clock
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
spec = importlib.util.spec_from_file_location('paired_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()


def runtime(version):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().processClock = clock.process_time
    lua.globals().elapsedClock = clock.perf_counter
    lua.globals().package.path = f'{(ROOT / "scripts").as_posix()}/?.lua;' + lua.globals().package.path
    if version == 'before':
        for name in ('ProjectedGeometry', 'SeaViewArt', 'Projection'):
            lua.execute(f"package.preload['Ocean.{name}']=function() return assert(loadfile('{(OUT / 'before-fix' / (name + '.lua')).as_posix()}'))() end")
    rec = capture.NVGCapture()
    host.bind_recorder(lua, rec, rec.bind(lua), capture)
    lua.globals().probeNames = lua.table_from([key for key in lua.globals().keys() if isinstance(key, str) and key.startswith('nvg')])
    lua.globals().print = lambda *_: None
    return lua, lua.execute('''
        local value,calls={},0
        for _,name in ipairs(probeNames) do _G[name]=function()calls=calls+1;return value end end
        local Runtime=require('Ocean.SeaRuntime')
        local Draw=require('Ocean.SeaDraw')
        return function(width,height,x,y,time,drift)
            local r=Runtime.New({daySeed=271828});r.movement:SetViewport(width,height)
            r.movement:ResetAtPosition({x=x,y=y});r.time=time
            local function draw()
                if drift then
                    r.time=r.time+1/60
                    r.movement.camera.x=r.movement.camera.x+.02
                    r.movement.camera.y=r.movement.camera.y+.02
                    r.ship.position.x=r.ship.position.x+.02
                    r.ship.position.y=r.ship.position.y+.02
                end
                Draw.Scene({},width,height,r)
            end
            draw();collectgarbage('collect');calls=0
            local start=processClock();local elapsedStart=elapsedClock()
            for _=1,36 do draw()end
            local cpu=(processClock()-start)*1000/36
            local elapsed=(elapsedClock()-elapsedStart)*1000/36
            local nvg=calls/36
            collectgarbage('collect');collectgarbage('stop')
            local heap=collectgarbage('count');draw()
            local allocated=collectgarbage('count')-heap
            collectgarbage('restart');collectgarbage('collect')
            return {processCpuMs=cpu,elapsedMs=elapsed,nvgCallsPerFrame=nvg,allocatedKiBPerFrame=allocated}
        end
    ''')


probes = {version: runtime(version) for version in ('before', 'after')}
records = []
drift_only = '--drift-only' in sys.argv
scenarios = ((1920,1080,0,0,9,True),) if drift_only else (
    (1280,720,0,0,0,False),(1920,1080,0,0,0,False),(1920,1080,0,0,9,False),
    (1920,1080,400,400,9,False),(600,900,-80,-20,9,False))
for width, height, x, y, time, drift in scenarios:
    samples = {version: [] for version in probes}
    for run in range(3):
        for version in (('before','after') if run % 2 == 0 else ('after','before')):
            _, probe = probes[version]
            samples[version].append(host.to_json_value(probe(width,height,x,y,time,drift),lua_type))
    row = {'dimensions':[width,height], 'position':[x,y], 'time':time, 'cameraDriftsEveryFrame':drift, 'samples':samples}
    for version in probes:
        row[version] = {key: statistics.median(sample[key] for sample in samples[version]) for key in samples[version][0]}
    row['cpuReductionPercent'] = (1-row['after']['processCpuMs']/row['before']['processCpuMs'])*100
    row['elapsedReductionPercent'] = (1-row['after']['elapsedMs']/row['before']['elapsedMs'])*100
    records.append(row)
    print(json.dumps({key:value for key,value in row.items() if key != 'samples'},ensure_ascii=False),flush=True)
result = {'nativeFpsVerified':False, 'gpuMeasured':False, 'method':'Paired isolated Lua5.4 runtimes, alternating before/after order, 3x36 frames per scenario. Python process_time for process CPU and perf_counter for elapsed. Same config/seed271828. Pre-fix geometry/art/projection loaded from saved files. Counting no-op NanoVG; excludes GPU, binding cost, UI, real logs. Allocation measured over one frame with GC stopped, then restarted.', 'records':records}
if drift_only:
    result['method'] += ' Synthetic drift: camera/ship X and Y each advance .02m and time advances 1/60s per render. Forces plane-cache invalidation every frame, without world simulation.'
destination = OUT / ('moving-paired-fix-process-clock.json' if drift_only else 'paired-fix-process-clock.json')
destination.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
