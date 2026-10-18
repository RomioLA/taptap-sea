"""Offline Lua CPU attribution; no window, screenshot, GPU or native FPS claim."""
import importlib.util
import json
import statistics
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('review_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()
lua = LuaRuntime(unpack_returned_tuples=True)
scripts = (ROOT / 'scripts').as_posix()
lua.globals().package.path = f'{scripts}/?.lua;{scripts}/?/init.lua;' + lua.globals().package.path
rec = capture.NVGCapture()
host.bind_recorder(lua, rec, rec.bind(lua), capture)
names = [key for key in lua.globals().keys() if isinstance(key, str) and key.startswith('nvg')]
lua.globals().probeNvgNames = lua.table_from(names)
lua.execute('''
local calls, value = {}, {}
for _, name in ipairs(probeNvgNames) do
    _G[name] = function(...) calls[name]=(calls[name] or 0)+1; return value end
end
function ResetCalls() for key in pairs(calls) do calls[key]=nil end end
function ReadCalls() return calls end
''')
lua.globals().print = lambda *_: None
probe = lua.execute('''
local Config = require('Ocean.Config')
local Art = require('Ocean.SeaViewArt')
local Atmos = require('Ocean.SeaAtmosphere')
local Draw = require('Ocean.SeaDraw')
local Runtime = require('Ocean.SeaRuntime')
local Bridge = require('Integration.Bridge')
local ctx = {}
local function measure(fn, frames)
    fn(); collectgarbage('collect'); ResetCalls()
    local memory = collectgarbage('count')
    local start=os.clock()
    for _=1,frames do fn() end
    local ms=(os.clock()-start)*1000/frames
    local growth=(collectgarbage('count')-memory)/frames
    local counts={}; for key,value in pairs(ReadCalls()) do counts[key]=value/frames end
    return {luaCpuMs=ms,nvgCalls=counts,netHeapKiBPerFrame=growth}
end
return function(width,height,x,y,frames)
    local r=Runtime.New({daySeed=271828})
    r.movement:SetViewport(width,height)
    r.movement:ResetAtPosition({x=x,y=y})
    local result={width=width,height=height,position={x=x,y=y},entities=#r.world.entities}
    result.full=measure(function() Draw.Scene(ctx,width,height,r) end,frames)
    result.surface=measure(function() Art.Surface(ctx,r.movement,r.time) end,frames)
    result.backdrop=measure(function() Art.Backdrop(ctx,width,height,r.time) end,frames)
    result.cloud=measure(function() Atmos.CloudShadows(ctx,r.movement,r.time,r.daySeed) end,frames)
    result.fog=measure(function() Atmos.Fog(ctx,r.movement,r.time,r.daySeed) end,frames)
    local origSurface=Art.Surface
    Art.Surface=function()end
    result.withoutSurface=measure(function() Draw.Scene(ctx,width,height,r) end,frames)
    Art.Surface=origSurface
    local oldNear,oldFar=Config.visual.surface.nearSpacingMeters,Config.visual.surface.farSpacingMeters
    Config.visual.surface.nearSpacingMeters=24
    Config.visual.surface.farSpacingMeters=12
    result.halfDensityEachAxis=measure(function() Draw.Scene(ctx,width,height,r) end,frames)
    Config.visual.surface.nearSpacingMeters,Config.visual.surface.farSpacingMeters=oldNear,oldFar
    local Geometry=require('Ocean.ProjectedGeometry')
    local oldLine=Geometry.StrokeWorldLine
    Geometry.StrokeWorldLine=function()return true end
    result.withoutProjectedStrokes=measure(function() Draw.Scene(ctx,width,height,r) end,frames)
    Geometry.StrokeWorldLine=oldLine
    local b=Bridge.New(r,{store={Save=function(_,_,done)done(true)end,Load=function(_,done)done(true,nil)end}})
    result.portUpdate=measure(function()b:Update(1/60,0,0);b:Sync()end,300)
    b.loop:Depart()
    result.seaUpdate=measure(function()b:Update(1/60,0,0);b:Sync()end,300)
    return result
end
''')
records = []
for dims, pos in [((1280,720),(0,0)), ((1920,1080),(0,0)), ((1920,1080),(400,400))]:
    samples=[]
    for _ in range(3):
        samples.append(host.to_json_value(probe(*dims,*pos,24),lua_type))
    row=samples[0]
    for key in ('full','surface','backdrop','cloud','fog','withoutSurface','halfDensityEachAxis','withoutProjectedStrokes','portUpdate','seaUpdate'):
        row[key]['luaCpuMs']=statistics.median(s[key]['luaCpuMs'] for s in samples)
        counts=row[key]['nvgCalls']
        row[key]['nvgCallTotal']=sum(counts.values()) if isinstance(counts,dict) else 0
    records.append(row)
    print(json.dumps({'dimensions':dims,'position':pos,'luaCpuMs':{key:round(row[key]['luaCpuMs'],3) for key in ('full','surface','withoutSurface','withoutProjectedStrokes','portUpdate','seaUpdate')},'nvgCalls':row['full']['nvgCallTotal']},ensure_ascii=False),flush=True)
result={'createdAt':time.time(),'nativeFpsVerified':False,'gpuMeasured':False,'method':'Lua 5.4 with counting no-op NanoVG bindings, 3 runs x 24 render frames. Ablations affect only this isolated runtime. No production config edits. CPU attribution excludes native tessellation, GPU, UI and actual logging costs.','records':records}
out=Path(__file__).with_name('frame-profile.json')
out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('REPORT',out)
