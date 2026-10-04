"""Offline before/after sequence and actual-path checks; never starts Maker."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
sys.dont_write_bytecode = True
import run_sea_view_regression as runner

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--before-dir', type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    LuaRuntime, dependency = runner.load_lua_runtime_type()
    Recorder = runner.load_recorder_type()
    from PIL import Image, ImageDraw
    rows, tiles, checks = [], [], []
    for version in ('before', 'after'):
        lua = runner.make_lua(LuaRuntime)
        if version == 'before':
            lua.globals().package.path = args.before_dir.resolve().as_posix()+'/scripts/?.lua;'+lua.globals().package.path
        capture = Recorder()
        capture.bind(lua)
        runner.bind_transform(lua, capture)
        draw = lua.eval('''function(depth)
            local Runtime=require("Ocean.SeaRuntime")
            local Art=require("Ocean.SeaViewArt")
            local Draw=require("Ocean.Draw")
            local Geometry=require("Ocean.ProjectedGeometry")
            local r=Runtime.New({initializeRegions=false,departure={x=0,y=0}})
            r.movement:SetViewport(1280,720)
            local m=r.movement
            Art.Backdrop({},1280,720,2)
            Art.Surface({},m,2)
            Art.Island({},m,{position={x=m.camera.x,y=m.camera.y+depth},radius=20},2,0)
            Geometry.WorldCircle({},m,{x=m.camera.x-33,y=m.camera.y+depth},2,{184,130,90,255},nil,1)
            if Geometry.ArtAPI then
                Draw.WorldSeabird({},0,0,1,.4,0,
                    Geometry.ArtAPI({},m,{x=m.camera.x+33,y=m.camera.y+depth},1.2))
            else
                local p={x=m.camera.x+33,y=m.camera.y+depth}
                local x,y,s=m:WorldToScreen(p,1.2)
                Draw.WorldSeabird({},x,y,s,.4,0)
            end
            return m
        end''')
        for depth in (150,130,125,111,100,85):
            capture.reset()
            start = time.perf_counter()
            movement = draw(depth)
            elapsed = time.perf_counter()-start
            stem = f'{version}-{depth}m'
            (output/(stem+'.svg')).write_text(capture.to_svg(1280,720,stem),encoding='utf-8')
            capture.render_png(1280,720,output/(stem+'.png'),supersample=2)
            image=Image.open(output/(stem+'.png')).convert('RGB')
            crop=image.crop((140,105,1140,305)).resize((1000,200))
            tile=Image.new('RGB',(1000,226),'#eef2f3')
            tile.paste(crop,(0,26));ImageDraw.Draw(tile).text((10,7),f'{version}  depth={depth}m  OFFLINE paths',(10,25,30))
            tiles.append(tile)
            rows.append({'version':version,'depth':depth,'recordingSeconds':elapsed,
                'elements':len(capture.elements),'calls':sum(capture.counts.values()),
                'png':stem+'.png','svg':stem+'.svg'})
        if version == 'after':
            # Verify paint emitted by real island foam, wake, splash, rise and
            # fish functions, independent of Presentation's broad-phase return.
            probe=lua.eval('''function(kind,depth,fraction,angle)
                local Art=require("Ocean.SeaViewArt")
                local Draw=require("Ocean.Draw")
                local Geometry=require("Ocean.ProjectedGeometry")
                local Runtime=require("Ocean.SeaRuntime")
                local r=Runtime.New({initializeRegions=false,departure={x=0,y=0}})
                r.movement:SetViewport(1920,1080)
                local m=r.movement
                local _,_,s=m:WorldToScreen({x=m.camera.x,y=m.camera.y+depth})
                local p={x=m.camera.x+(fraction-.5)*1920/s,y=m.camera.y+depth}
                if kind=="foam" then Art.Island({},m,{position=p,radius=.5},1.1,0)
                elseif kind=="wake" then Art.Wake({},m,{records={{position=p,age=.5,rotation=angle}}})
                elseif kind=="splash" then Draw.WorldSplash({},0,0,1,.5,1,angle,2,Geometry.ArtAPI({},m,p,0))
                elseif kind=="rise" then Draw.WorldRise({},0,0,1,{species="sardine",surfaceDepth=.8,
                    radius=.5,rotation=angle,active=true},1.1,Geometry.ArtAPI({},m,p,0))
                else Draw.WorldFish({},0,0,1,{species="tuna",radius=1,rotation=angle,active=true},
                    1.1,Geometry.ArtAPI({},m,p,0)) end
                return m
            end''')
            horizon=lua.eval('function(m,x)return require("Ocean.Projection").Horizon(m,x)end')
            for kind in ('foam','wake','splash','rise','fish'):
                for depth in (109.99,110,110.01,111,113):
                    for fraction in (.01,.5,.99):
                        for angle in (0,.7853981634,1.5707963268):
                            capture.reset();movement=probe(kind,depth,fraction,angle)
                            points=[]
                            for element in capture.elements:
                                for command,coords in element['path']:
                                    if command in ('M','L'):
                                        points.extend(zip(coords[::2],coords[1::2]))
                            minimum=min((y-horizon(movement,x) for x,y in points),default=None)
                            assert minimum is None or minimum>=-1e-6,(kind,depth,fraction,angle,minimum)
                            checks.append({'kind':kind,'depth':depth,'fraction':fraction,'angle':angle,
                                'paintCount':len(capture.elements),'vertexCount':len(points),'minimumWaterGapPixels':minimum})
    sheet=Image.new('RGB',(2000,226*6),'white')
    for i,tile in enumerate(tiles):
        sheet.paste(tile,(0 if i<6 else 1000,(i%6)*226))
    sheet.save(output/'sequence-before-after.png')
    report={'status':'PASS','evidenceKind':'offline Lua54 NanoVG paths, Pillow rasterization',
        'nativeEngineAcceptance':'NOT_RUN','dependency':dependency,'sequence':rows,
        'groundPaintChecks':checks,'hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
            for p in output.iterdir() if p.is_file()}}
    (output/'evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'status':'PASS','pathChecks':len(checks),'sequenceFrames':len(rows),'output':str(output)}))

if __name__ == '__main__':
    main()
