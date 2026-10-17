import sys,json,hashlib
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd()
sys.path.insert(0,str(root/'outputs/remote-review-20261002/test-runtime'))
sys.path.insert(0,str(root/'tests'))
from lupa.lua54 import LuaRuntime
from render_sea_fusion import NVGCapture,_lua_to_python
out=root/'outputs/circle1-a2'
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().package.path=(root/'scripts/?.lua').as_posix()+';'+lua.globals().package.path
cap=NVGCapture();rec=cap.bind(lua)
rows={}
for name in ['tests.SeaFusionRenderTests','tests.Circle1A2FishingTests']:
    try:
        module=lua.eval('function(n) local m=require(n); return m end')(name)
        rows[name]=_lua_to_python(module.Run(rec))
    except Exception as e: rows[name]={'error':str(e)}
(out/'root-render-tests.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(rows,ensure_ascii=False))
module=lua.eval('function() return require("tests.SeaFusionRenderTests") end')()
draw=lua.eval('function() return require("Ocean.SeaDraw") end')()
images=[]
for name,phase,t in [('aim','aim',0),('casting-flight','casting',.25),('landing','casting',.5),('reeling','reeling',2.25)]:
    rt=module.CreatePreviewRuntime(1920,1080)
    view=lua.table_from({'phase':phase,'center':lua.table_from({'x':8,'y':-6}),'elapsedSec':t})
    cap.reset();draw.Scene(lua.table(),1920,1080,rt,None,view)
    png=out/f'{name}.png';svg=out/f'{name}.svg'
    svg.write_text(cap.to_svg(1920,1080,name),encoding='utf8');cap.render_png(1920,1080,png)
    images.append({'name':name,'file':png.relative_to(root).as_posix(),'sha256':hashlib.sha256(png.read_bytes()).hexdigest(),'nvgCalls':sum(cap.counts.values())})
(out/'offline-render.json').write_text(json.dumps({'engineScreenshot':False,'realBConnectionVerified':False,'images':images},indent=2),encoding='utf8')


# Compare unchanged visible output with the exact before-source snapshot, including
# fish whose full silhouette is beyond the horizon or screen edges.
comparisons=[]
for label,w,h in [('landscape',1920,1080),('portrait',1200,1150)]:
    captures=[]
    for version in ['before','after']:
        vm=LuaRuntime(unpack_returned_tuples=True)
        search=(root/'scripts/?.lua').as_posix()
        if version=='before': search=(out/'baseline/?.lua').as_posix()+';'+search
        vm.globals().package.path=search+';'+vm.globals().package.path
        nc=NVGCapture();nc.bind(vm)
        rt=vm.eval('function() local R=require("Ocean.SeaRuntime"); return R.New({initializeRegions=false,daySeed=31415}) end')()
        rt.movement.SetViewport(rt.movement,w,h);rt.setDebugFlag(rt,'showUnderwater',True)
        for px,py in [(0,20),(50,-4),(0,12.6),(-40.05,-4),(-8,-8),(8,-14)]:
            rt.spawnFish(rt,'sardine',vm.table_from({'x':px,'y':py}),0)
        sd=vm.eval('function() local d=require("Ocean.SeaDraw"); return d end')()
        sd.Scene(vm.table(),w,h,rt)
        p=out/f'equivalence-{label}-{version}.png';nc.render_png(w,h,p)
        captures.append({'version':version,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'nvgCalls':sum(nc.counts.values())})
    comparisons.append({'scene':label,'captures':captures,'pixelsIdentical':captures[0]['sha256']==captures[1]['sha256']})
(out/'draw-equivalence.json').write_text(json.dumps(comparisons,indent=2),encoding='utf8')
print(json.dumps({'drawEquivalence':comparisons}))

scope_images=[]
for enabled in [False,True]:
    rt=module.CreatePreviewRuntime(1920,1080)
    rt.ship.rotation=-1.5707963267948966
    rt.ship.direction=lua.table_from({'x':0,'y':-1})
    rt.SetScopeEnabled(rt,enabled)
    cap.reset();draw.Scene(lua.table(),1920,1080,rt)
    name='scope-on' if enabled else 'scope-off'
    png=out/f'{name}.png';cap.render_png(1920,1080,png)
    (out/f'{name}.svg').write_text(cap.to_svg(1920,1080,name),encoding='utf8')
    scope_images.append({'name':name,'scopeEnabled':enabled,'fishVisible':[rt.world.isVisible(rt.world,rt.previewSardine),rt.world.isVisible(rt.world,rt.previewTuna)],'png':png.relative_to(root).as_posix()})
(out/'scope-render.json').write_text(json.dumps({'evidence':'offline NanoVG capture, not native engine','views':scope_images},indent=2),encoding='utf8')
