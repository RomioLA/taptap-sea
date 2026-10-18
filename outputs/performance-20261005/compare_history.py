"""Compare archived render implementations in isolated Lua runtimes, no GUI."""
import importlib.util
import json
import statistics
import sys
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
spec = importlib.util.spec_from_file_location('review_history_host', ROOT/'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()

sources=[]
for name in ('before-oblique-ef6dea0','first-oblique-949d7ca'):
    dest=OUT/name
    with zipfile.ZipFile(OUT/f'{name}.zip') as archive:
        for info in archive.infolist():
            if not (dest/info.filename).resolve().is_relative_to(dest.resolve()):
                raise ValueError('archive path outside evidence directory')
        archive.extractall(dest)
    sources.append((name,dest/'scripts'))
sources.append(('current',ROOT/'scripts'))
rows=[]
for name,source in sources:
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path=f'{source.as_posix()}/?.lua;{source.as_posix()}/?/init.lua;'+lua.globals().package.path
    rec=capture.NVGCapture()
    host.bind_recorder(lua,rec,rec.bind(lua),capture)
    names=[key for key in lua.globals().keys() if isinstance(key,str) and key.startswith('nvg')]
    lua.globals().probeNames=lua.table_from(names)
    lua.globals().print=lambda *_:None
    lua.execute('''
    local counts, value = {}, {}
    for _,name in ipairs(probeNames) do _G[name]=function(...) counts[name]=(counts[name]or 0)+1;return value end end
    function ResetCounts()for k in pairs(counts)do counts[k]=nil end end
    function Counts()return counts end
    ''')
    probe=lua.execute('''
    local Runtime=require('Ocean.SeaRuntime')
    local Draw=require('Ocean.SeaDraw')
    local r=Runtime.New({daySeed=271828})
    r.movement:SetViewport(1920,1080)
    local ctx={}
    local frameCache
    local function draw()
        if frameCache then frameCache={} end
        Draw.Scene(ctx,1920,1080,r)
    end
    local function measure()
        draw();collectgarbage('collect');ResetCounts()
        local started=os.clock()
        for _=1,36 do draw()end
        local elapsed=(os.clock()-started)*1000/36
        local n=0;for _,v in pairs(Counts())do n=n+v end
        collectgarbage('collect');collectgarbage('stop')
        local startHeap=collectgarbage('count');draw()
        local alloc=collectgarbage('count')-startHeap
        collectgarbage('restart');collectgarbage('collect')
        return {luaCpuMs=elapsed,nvgCallsPerFrame=n/36,allocatedKiBPerFrame=alloc}
    end
    return function()
        local result={full=measure()}
        local ok,Art=pcall(require,'Ocean.SeaViewArt')
        if ok then
            local orig=Art.Island;Art.Island=function()end
            result.withoutIsland=measure();Art.Island=orig
            orig=Art.Boat;Art.Boat=function()end
            result.withoutBoat=measure();Art.Boat=orig
            local Config=require('Ocean.Config')
            if Config.visual.shoreFoam then
                local enabled=Config.visual.shoreFoam.enabled
                Config.visual.shoreFoam.enabled=false
                result.withoutShoreFoam=measure()
                Config.visual.shoreFoam.enabled=enabled
            end
            local Projection=require('Ocean.Projection')
            local viewPolygon=Projection.ViewPolygon
            frameCache={}
            Projection.ViewPolygon=function(movement,padding,extension)
                local key=tostring(padding)..'|'..tostring(extension)
                if not frameCache[key] then frameCache[key]=viewPolygon(movement,padding,extension)end
                return frameCache[key]
            end
            result.reuseViewPolygonWithinFrame=measure()
            Projection.ViewPolygon=viewPolygon;frameCache=nil
            local Geometry=require('Ocean.ProjectedGeometry')
            local counts={}
            local originals={}
            for _,record in ipairs({{Geometry,'ClipLine'},{Geometry,'StrokeWorldLine'},
                {Projection,'ViewPolygon'},{Projection,'Unproject'},{Projection,'Project'}}) do
                local module,name=record[1],record[2]
                if module[name] then
                    local original=module[name]
                    originals[#originals+1]={module,name,original}
                    module[name]=function(...) counts[name]=(counts[name]or 0)+1;return original(...)end
                end
            end
            draw()
            result.geometryCallsPerFrame=counts
            for _,record in ipairs(originals)do record[1][record[2]]=record[3]end
        end
        return result
    end
    ''')
    samples=[host.to_json_value(probe(),lua_type)for _ in range(3)]
    result={'version':name,'samples':samples,'medianLuaCpuMs':{key:statistics.median(s[key]['luaCpuMs']for s in samples)for key in samples[0] if 'luaCpuMs' in samples[0][key]}}
    rows.append(result)
    print(json.dumps({'version':name,'medianLuaCpuMs':result['medianLuaCpuMs'],'calls':samples[0]['full']['nvgCallsPerFrame'],'allocKiB':samples[0]['full']['allocatedKiBPerFrame']},ensure_ascii=False),flush=True)
(OUT/'history-profile.json').write_text(json.dumps({'nativeFpsVerified':False,'method':'Same 1920x1080, seed271828, initial ship/camera; Lua5.4 counting no-op NanoVG; each archive uses its own historical config. 3x36 frames; isolated diagnostic ablations only. Allocations measured with GC stopped for one frame. Historical commits are comparison points, not confirmed good versions.','versions':rows},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
