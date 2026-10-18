"""Island component attribution in isolated Lua, without production edits or GUI."""
import importlib.util
import json
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
spec = importlib.util.spec_from_file_location('island_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()


def create(width, height, cx, cy, radius):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().processClock = time.process_time
    lua.globals().elapsedClock = time.perf_counter
    lua.globals().package.path = f'{(ROOT / "scripts").as_posix()}/?.lua;' + lua.globals().package.path
    rec = capture.NVGCapture()
    host.bind_recorder(lua, rec, rec.bind(lua), capture)
    lua.globals().nvgNames = lua.table_from([key for key in lua.globals().keys() if isinstance(key,str) and key.startswith('nvg')])
    lua.globals().print = lambda *_: None
    factory = lua.execute('''
        local Config=require('Ocean.Config')
        local Art=require('Ocean.SeaViewArt')
        local Geometry=require('Ocean.ProjectedGeometry')
        local Projection=require('Ocean.Projection')
        local Presentation=require('Ocean.SeaPresentation')
        local Runtime=require('Ocean.SeaRuntime')
        local Scene=require('Ocean.SeaDraw')
        local value,calls,active,trace={},0,nil,false
        local owners={}
        local function owner()return owners[active]end
        local function bump(name)
            if trace and active then
                local row=owner();row.calls[name]=(row.calls[name] or 0)+1
            end
        end
        for _,name in ipairs(nvgNames)do
            _G[name]=function()
                calls=calls+1
                if name=='nvgFill' or name=='nvgClosePath' or name=='nvgLineTo' then bump(name) end
                return value
            end
        end
        return function(w,h,cx,cy,radius)
            local runtime=Runtime.New({initializeRegions=false})
            local movement=runtime.movement
            movement:SetViewport(w,h);movement.camera.x=cx;movement.camera.y=cy
            local island={position={x=0,y=0},radius=radius,entityType='island',layer='surface',id='profile-island'}
            local function islandDraw()Art.Island({},movement,island,9,0)end
            local function measure(fn)
                fn();collectgarbage('collect');calls=0
                local start=processClock();local elapsedStart=elapsedClock()
                for _=1,72 do fn()end
                local ms=(processClock()-start)*1000/72
                local elapsedMs=(elapsedClock()-elapsedStart)*1000/72
                local count=calls/72
                collectgarbage('collect');collectgarbage('stop')
                local heap=collectgarbage('count');fn()
                local allocated=collectgarbage('count')-heap
                collectgarbage('restart');collectgarbage('collect')
                return {processCpuMs=ms,elapsedMs=elapsedMs,nvgApiCalls=count,allocatedKiBPerFrame=allocated}
            end
            local seen=Presentation.State(movement,island.position,radius,5.4)~=nil
            local full={}
            for _=1,3 do full[#full+1]=measure(islandDraw)end
            local indices,available={},{}
            for index=1,100 do
                local name,fn=debug.getupvalue(Art.Island,index)
                if not name then break end
                available[#available+1]=name
                if type(fn)=='function' then indices[name]={index=index,original=fn}end
            end
            local groups={circlePoints='ring_construction',fillWorldPolygon='body_fill',strokeWorldPolygon='outlines',
                drawShoreFoam='foam',drawHill='hills',drawTree='trees'}
            for name,tag in pairs(groups)do assert(indices[name],'missing actual island upvalue: '..name)end
            local removed={}
            for _,name in ipairs({'drawShoreFoam','drawHill','drawTree','strokeWorldPolygon'})do
                local record=indices[name]
                local samples={}
                for _=1,3 do
                    local before=measure(islandDraw)
                    debug.setupvalue(Art.Island,record.index,function()end)
                    local disabled=measure(islandDraw)
                    debug.setupvalue(Art.Island,record.index,record.original)
                    local after=measure(islandDraw)
                    samples[#samples+1]={before=before,disabled=disabled,after=after,
                        cpuDeltaMs=(before.processCpuMs+after.processCpuMs)/2-disabled.processCpuMs}
                end
                removed[name]=samples
            end
            for name,tag in pairs(groups)do
                local record=indices[name]
                owners[tag]={traceElapsedMs=0,invocations=0,calls={}}
                debug.setupvalue(Art.Island,record.index,function(...)
                    if active then return record.original(...)end
                    active=tag
                    local row=owner();local start=elapsedClock()
                    local results=table.pack(record.original(...))
                    row.traceElapsedMs=row.traceElapsedMs+(elapsedClock()-start)*1000
                    row.invocations=row.invocations+1
                    active=nil
                    return table.unpack(results,1,results.n)
                end)
            end
            for _,pair in ipairs({{Geometry,'StrokeWorldLine'},{Geometry,'ClipLine'},{Geometry,'ClipScreenPolygon'},
                {Geometry,'ProjectPolygon'},{Projection,'Project'},{Projection,'Visibility'}})do
                local module,name=pair[1],pair[2];local fn=module[name]
                module[name]=function(...)bump(name);return fn(...)end
            end
            trace=true
            for _=1,36 do islandDraw()end
            trace=false
            for _,row in pairs(owners)do
                row.traceElapsedMs=row.traceElapsedMs/36;row.invocations=row.invocations/36
                for key,n in pairs(row.calls)do row.calls[key]=n/36 end
            end
            return {visibleByPresentation=seen,full=full,withoutComponent=removed,components=owners,
                actualUpvalues=available}
        end
    ''')
    result = host.to_json_value(factory(width,height,cx,cy,radius),lua_type)
    result['medianFull'] = {key:statistics.median(s[key]for s in result['full'])for key in result['full'][0]}
    result['medianComponentCpuDeltaMs'] = {name:statistics.median(s['cpuDeltaMs']for s in samples)for name,samples in result['withoutComponent'].items()}
    return result


records=[]
scenarios=(("near_full",1920,1080,0,-35,20),("left_edge",1920,1080,90,-35,20),
           ("left_offscreen",1920,1080,160,-35,20),("horizon_crossing",1920,1080,0,-108,20),
           ("small_island_near",1920,1080,0,-35,12))
for name,w,h,cx,cy,radius in scenarios:
    row={'scenario':name,'dimensions':[w,h],'camera':[cx,cy],'radius':radius,**create(w,h,cx,cy,radius)}
    records.append(row)
    print(json.dumps({'scenario':name,'visible':row['visibleByPresentation'],'full':row['medianFull'],
        'componentCpuDeltaMs':row['medianComponentCpuDeltaMs'],'components':row['components']},ensure_ascii=False),flush=True)
report={'method':'Current production Lua5.4 modules in isolated instances. No-op NanoVG, no GUI/GPU. Python time.process_time measures process CPU; perf_counter measures elapsed. Whole island timings: 3x72 frames. Ablations: 3 adjacent baseline/disabled/baseline pairs, 72 frames each; CPU delta uses mean adjacent baselines minus disabled. One-frame allocation with GC stopped then restarted. Local island upvalues discovered via debug.getupvalue; diagnostic replacements affect only this runtime. Component traces have extra instrumentation and measure elapsed, not CPU; do not add trace timings to production timings. Direct island calls are measured even offscreen to expose work that broad-phase normally skips. Synthetic radius/camera scenarios, not an exact reproduction of screenshot position.',
    'nativeFpsVerified':False,'productionFilesModified':False,'records':records}
(OUT/'island-components.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
