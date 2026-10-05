import json
import sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,'/workspace/outputs/ocean-art-loop-20261005/deps')
from lupa.lua54 import LuaRuntime, lua_type
lua=LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
package.path='/workspace/scripts/?.lua;'..package.path
requested={}
table.insert(package.searchers,1,function(name)
 requested[#requested+1]=name
 if name=='Ocean.ImageArt' then error('unexpected image require') end
 return ''
end)
R=require('Ocean.SeaRuntime');D=require('Ocean.FishData');C=require('Ocean.Config')
function snapshot(r,s,t,b)
 local ax,ay=r.world:getAvoidance(t,D.tuna.avoidMargin)
 return {sardineState=s.state,tunaState=t.state,sardinePosition={x=s.position.x,y=s.position.y},tunaPosition={x=t.position.x,y=t.position.y},preyId=b.preyId,lastPreyPosition=b.lastPreyPosition and {x=b.lastPreyPosition.x,y=b.lastPreyPosition.y},lostPreyTime=b.lostPreyTime,worldTime=r.world.time,avoidance={x=ax,y=ay},fishDangerRadius=D.sardine.dangerRadius,tunaPreyRadius=D.tuna.preyRadius,lostPreySeconds=D.tuna.lostPreySec}
end
r=R.New({initializeRegions=false});s=r:spawnFish('sardine',{x=0,y=0});t=r:spawnFish('tuna',{x=20,y=0},math.pi);b=r.behaviors[t.id]
firstBefore=snapshot(r,s,t,b);r:Update(.05);firstAfter=snapshot(r,s,t,b)
r2=R.New({initializeRegions=false});s2=r2:spawnFish('sardine',{x=20,y=0});t2=r2:spawnFish('tuna',{x=0,y=0});b2=r2.behaviors[t2.id];second={}
b2:Update(.05);second[1]=snapshot(r2,s2,t2,b2)
s2.position={x=10,y=15};secondMoved=snapshot(r2,s2,t2,b2);b2:Update(.05);second[2]=snapshot(r2,s2,t2,b2)
r2.world:remove(s2.id);b2:Update(1.9);second[3]=snapshot(r2,s2,t2,b2);b2:Update(.2);second[4]=snapshot(r2,s2,t2,b2)
imageLoaded=package.loaded['Ocean.ImageArt'] ~= nil
''')
def convert(v):
 if lua_type(v)=='table':
  return {str(k):convert(item) for k,item in v.items()}
 return v
out={k:convert(lua.globals()[k]) for k in ['firstBefore','firstAfter','secondMoved','second','imageLoaded','requested']}
p=Path('/workspace/outputs/ocean-art-loop-20261005/review/SeaRuntime-failure-steps.json')
p.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(out,ensure_ascii=False,indent=2),flush=True)
