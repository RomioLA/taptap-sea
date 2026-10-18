"""Compare recorded vector paths, without rasterization, GUI, screenshot or GPU."""
import importlib.util
import json
import math
import sys
from pathlib import Path

sys.dont_write_bytecode = True
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
spec = importlib.util.spec_from_file_location('vector_host', ROOT / 'tests/run_circle1_review.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
LuaRuntime, lua_type, capture = host.prepare_runtime()


def make(version):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = f'{(ROOT / "scripts").as_posix()}/?.lua;' + lua.globals().package.path
    if version == 'before':
        for name in ('ProjectedGeometry', 'SeaViewArt', 'Projection'):
            lua.execute(f"package.preload['Ocean.{name}']=function()return assert(loadfile('{(OUT / 'before-island-fix' / (name + '.lua')).as_posix()}'))()end")
    recorder = capture.NVGCapture()
    host.bind_recorder(lua, recorder, recorder.bind(lua), capture)
    lua.globals().print = lambda *_: None
    draw = lua.execute('''
        local Runtime=require('Ocean.SeaRuntime')
        local Draw=require('Ocean.SeaDraw')
        return function(w,h,x,y,time)
            local r=Runtime.New({daySeed=271828});r.movement:SetViewport(w,h)
            r.movement:ResetAtPosition({x=x,y=y});r.time=time
            Draw.Scene({},w,h,r)
        end
    ''')
    return recorder, draw


def on_segment(a, b, p):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = math.hypot(dx, dy)
    if length < 1e-12:
        return math.hypot(p[0]-a[0], p[1]-a[1]) < 1e-7
    distance = abs(dx*(p[1]-a[1])-dy*(p[0]-a[0]))/length
    dot = (p[0]-a[0])*dx+(p[1]-a[1])*dy
    return distance <= 1e-7 and -1e-7 <= dot <= length*length+1e-7


def normalize(commands):
    result = []
    start = 0
    for command, coords in commands:
        if command == 'M':
            start = len(result)
        if command == 'L':
            if result and result[-1][0] in ('M','L') and math.dist(result[-1][1],coords) <= 1e-7:
                continue
            while len(result) >= start+2 and result[-1][0] == 'L' and result[-2][0] in ('M','L') and on_segment(result[-2][1],coords,result[-1][1]):
                result.pop()
        if command == 'Z' and len(result) >= start+3:
            while len(result) >= start+3 and result[-1][0] == 'L' and result[-2][0] in ('M','L') and on_segment(result[-2][1],result[start][1],result[-1][1]):
                result.pop()
        result.append((command,coords))
    return result


engines = {version:make(version) for version in ('before','after')}
records = []
for w,h in ((1920,1080),(600,900)):
    for x,y in ((0,0),(400,400),(-80,-20)):
        for time in (0,9):
            elements = {}
            for version,(recorder,draw) in engines.items():
                recorder.reset();draw(w,h,x,y,time)
                elements[version] = list(recorder.elements)
            before,after = elements['before'],elements['after']
            assert len(before) == len(after), (w,h,x,y,time,'element-count',len(before),len(after))
            maximum = 0
            for index,(a,b) in enumerate(zip(before,after)):
                assert {k:v for k,v in a.items() if k != 'path'} == {k:v for k,v in b.items() if k != 'path'}, (index,'paint/state')
                ap,bp = normalize(a['path']),normalize(b['path'])
                assert len(ap) == len(bp), (w,h,x,y,time,index,'path-length',len(ap),len(bp))
                for (ac,av),(bc,bv) in zip(ap,bp):
                    assert ac == bc and len(av) == len(bv),(index,'commands')
                    for old,new in zip(av,bv):
                        maximum = max(maximum,abs(old-new))
                        assert abs(old-new) <= 1e-6,(index,'coordinates',old,new)
            row = {'dimensions':[w,h],'position':[x,y],'time':time,'elements':len(before),'maxCoordinateDifferencePx':maximum,'passed':True}
            records.append(row)
            print(json.dumps(row),flush=True)
(OUT/'island-fix-vector-equivalence.json').write_text(json.dumps({'method':'NanoVG command recorder, removes duplicate/collinear path points within 1e-7 px; paint, stroke widths, ordering and commands must match; remaining coordinates within 1e-6 px. No raster/native visual judgment.', 'records':records},indent=2)+'\n',encoding='utf-8')
