"""One-frame allocation attribution and inclusive elapsed time; no GUI or GPU."""
import importlib.util
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('hotspot_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path = f'{(ROOT / "scripts").as_posix()}/?.lua;' + lua.globals().package.path
rec = capture.NVGCapture()
host.bind_recorder(lua, rec, rec.bind(lua), capture)
lua.globals().names = lua.table_from([key for key in lua.globals().keys() if isinstance(key, str) and key.startswith('nvg')])
lua.globals().print = lambda *_: None
result = lua.execute('''
local value={}; for _,name in ipairs(names) do _G[name]=function() return value end end
local Runtime=require('Ocean.SeaRuntime')
local Draw=require('Ocean.SeaDraw')
local Art=require('Ocean.SeaViewArt')
local G=require('Ocean.ProjectedGeometry')
local P=require('Ocean.Projection')
local r=Runtime.New({daySeed=271828});r.movement:SetViewport(1920,1080)
Draw.Scene({},1920,1080,r)
local rows={}
for _,m in ipairs({{Art,{'Island','Surface'}},{G,{'ProjectPolygon','ClipPolygon','ClipLine','StrokeWorldLine','ClipScreenPolygon'}},
    {P,{'Project','Horizon','Visibility','VisibleDepth','ViewPolygon'}}}) do
    for _,name in ipairs(m[2]) do
        local original=m[1][name];local row={calls=0,ms=0,allocKiB=0};rows[name]=row
        m[1][name]=function(...)
            local before=collectgarbage('count');local start=os.clock()
            local result=table.pack(original(...))
            row.ms=row.ms+(os.clock()-start)*1000
            row.allocKiB=row.allocKiB+collectgarbage('count')-before
            row.calls=row.calls+1
            return table.unpack(result,1,result.n)
        end
    end
end
collectgarbage('collect');collectgarbage('stop')
Draw.Scene({},1920,1080,r)
collectgarbage('restart')
return rows
''')
rows = host.to_json_value(result, lua_type)
print(json.dumps(rows, ensure_ascii=False, indent=2))
Path(__file__).with_name('hotspots.json').write_text(json.dumps(rows, indent=2) + '\n', encoding='utf-8')
