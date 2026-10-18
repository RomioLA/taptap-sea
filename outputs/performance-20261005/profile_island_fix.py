"""Paired island/scene process CPU and allocation, no GUI/native rendering."""
import importlib.util
import json
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
spec = importlib.util.spec_from_file_location('island_fix_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()


def make(version, width, height, cx, cy, radius, scene=False, drift=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = f'{(ROOT / "scripts").as_posix()}/?.lua;' + lua.globals().package.path
    if version == 'before':
        for name in ('ProjectedGeometry', 'SeaViewArt', 'Projection'):
            lua.execute(f"package.preload['Ocean.{name}']=function() return assert(loadfile('{(OUT / 'before-island-fix' / (name + '.lua')).as_posix()}'))() end")
    rec = capture.NVGCapture()
    host.bind_recorder(lua, rec, rec.bind(lua), capture)
    lua.globals().nvgNames = lua.table_from([key for key in lua.globals().keys() if isinstance(key, str) and key.startswith('nvg')])
    lua.globals().processClock = time.process_time
    lua.globals().elapsedClock = time.perf_counter
    lua.globals().print = lambda *_: None
    setup = lua.execute('''
        local value,calls={},0
        for _,name in ipairs(nvgNames) do _G[name]=function()calls=calls+1;return value end end
        local Runtime=require('Ocean.SeaRuntime')
        local Scene=require('Ocean.SeaDraw')
        local Art=require('Ocean.SeaViewArt')
        return function(w,h,cx,cy,radius,scene,drift)
            local r=Runtime.New({initializeRegions=scene,daySeed=271828})
            r.movement:SetViewport(w,h);r.movement:ResetAtPosition({x=cx,y=cy});r.time=9
            local island={position={x=0,y=0},radius=radius,entityType='island',layer='surface'}
            local function draw()
                if drift then
                    r.time=r.time+1/60
                    r.movement.camera.x=r.movement.camera.x+.02
                    r.movement.camera.y=r.movement.camera.y+.02
                    r.ship.position.x=r.ship.position.x+.02
                    r.ship.position.y=r.ship.position.y+.02
                end
                if scene then Scene.Scene({},w,h,r)
                else Art.Island({},r.movement,island,r.time,0) end
            end
            draw()
            return function()
                collectgarbage('collect');collectgarbage('stop');calls=0
                local start=processClock();local elapsedStart=elapsedClock()
                for _=1,32 do draw()end
                local cpu=(processClock()-start)*1000/32
                local elapsed=(elapsedClock()-elapsedStart)*1000/32
                local apiCalls=calls/32
                collectgarbage('restart');collectgarbage('collect');collectgarbage('stop')
                local heap=collectgarbage('count');draw()
                local allocated=collectgarbage('count')-heap
                collectgarbage('restart');collectgarbage('collect')
                return {processCpuMs=cpu,elapsedMs=elapsed,nvgApiCalls=apiCalls,allocatedKiBPerFrame=allocated}
            end
        end
    ''')
    return lua, setup(width,height,cx,cy,radius,scene,drift)


records = []
cases = [('near_full',1920,1080,0,-35,20,False,False),
         ('left_edge',1920,1080,90,-35,20,False,False),
         ('horizon_crossing',1920,1080,0,-108,20,False,False),
         ('small_island',1920,1080,0,-35,12,False,False),
         ('port_scene',1920,1080,0,0,20,True,False),
         ('port_scene_drift',1920,1080,0,0,20,True,True)]
for label,w,h,cx,cy,radius,scene,drift in cases:
    engines={version:make(version,w,h,cx,cy,radius,scene,drift) for version in ('before','after')}
    samples={version:[] for version in engines}
    for run in range(4):
        for version in (('before','after') if run%2==0 else ('after','before')):
            _,probe=engines[version]
            samples[version].append(host.to_json_value(probe(),lua_type))
    row={'scenario':label,'dimensions':[w,h],'camera':[cx,cy],'radius':radius,'scene':scene,'drift':drift,'samples':samples}
    for version in engines:
        row[version]={key:statistics.median(s[key] for s in samples[version]) for key in samples[version][0]}
    row['cpuReductionPercent']=(1-row['after']['processCpuMs']/row['before']['processCpuMs'])*100
    row['allocationReductionPercent']=(1-row['after']['allocatedKiBPerFrame']/row['before']['allocatedKiBPerFrame'])*100
    records.append(row)
    print(json.dumps({k:v for k,v in row.items() if k!='samples'},ensure_ascii=False),flush=True)
report={'method':'Isolated Lua5.4, saved pre-island-fix modules versus current modules; same configuration, seed271828, time9. Alternating 4x32 frames, warmed static world-geometry cache. GC stopped during timed batches to isolate algorithm process CPU, then restarted/collected; timings exclude GC pauses. Python process_time for CPU, perf_counter for elapsed. Counting no-op NanoVG, excludes native binding, tessellation, GPU/UI and FPS. One-frame allocation measured with GC stopped. Drift advances camera/ship .02m and time1/60 per draw; world simulation not executed. Direct isolated Island samples differ from actual Scene broad-phase.',
        'nativeFpsVerified':False,'records':records}
(OUT/'island-fix-paired.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
