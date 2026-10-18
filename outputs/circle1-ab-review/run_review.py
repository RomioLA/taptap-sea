"""Read-only source composition: A Ocean/Systems/FSM/Entities, B other modules.
Neither original tree nor previous delivery evidence is modified.
Engine, UI and cloud boundaries remain the original suites' explicit fixtures.
"""
from pathlib import Path
import importlib.util
import json
import sys

sys.dont_write_bytecode = True
A = Path('C:/codex/taptap-sea')
B = Path('D:/sillytavern-data/taptap-sea-B')
OUT = A / 'outputs/circle1-ab-review'
sys.path.insert(0, str(A / '.tmp/sea-test-deps'))
sys.path.insert(0, str(A / 'outputs/remote-review-20261002/test-runtime'))
spec = importlib.util.spec_from_file_location('b_runner', B / 'scripts/Tests/Circle1B3Run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
original_runtime = runner.runtime
helper_spec = importlib.util.spec_from_file_location('a_helper', A / 'tests/run_circle1_a2.py')
helper = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(helper)

def composed_runtime(log):
    lua = original_runtime(log)
    lua.globals().reviewA = str(A / 'scripts').replace('\\', '/')
    lua.globals().reviewB = str(B / 'scripts').replace('\\', '/')
    lua.execute('''
        reviewLoaded = {}
        table.insert(package.searchers, 2, function(name)
            local top = name:match('^[^./]+')
            local useA = top == 'Ocean' or top == 'Systems' or top == 'Entities' or top == 'FSM'
                or name:match('^tests.Circle1A3') ~= nil
            local root = useA and reviewA or reviewB
            local path = root .. '/' .. name:gsub('%.', '/') .. '.lua'
            local file = io.open(path, 'r')
            if not file then return '\\n review source absent: ' .. path end
            file:close()
            local fn, err = loadfile(path)
            if not fn then error(err) end
            reviewLoaded[name] = path
            return fn, path
        end)
    ''')
    return lua

def suites():
    result = [runner.run_module(p.stem, 'b3') for p in sorted((B/'scripts/Tests').glob('Circle1B3*Tests.lua'))]
    result += [runner.run_module(n, 'prior-b') for n in runner.protocol_modules()]
    result += [runner.run_script(n, 'player') for n in ('GameLoopSpec.lua','GameLoopUISpec.lua','PersistenceRegressionSpec.lua','NumericEconomySpec.lua','ShopStockSpec.lua')]
    result += [runner.run_module(n, 'existing-a') for n in ('ABIntegrationTests','ArchitectureIntegrationTests','SeaFusedSceneTests')]
    return result

def smoke():
    log = []
    lua = composed_runtime(log)
    report = lua.execute('''
        local Runtime = require('Ocean.SeaRuntime')
        local Bridge = require('Integration.Bridge')
        local Store = { Save=function(self,data,done) self.data=data; if done then done(true) end end,
            Load=function(self,done) done(self.data~=nil,self.data) end }
        local runtime = Runtime.New({ daySeed = 271828 })
        local bridge = Bridge.New(runtime, { store = Store })
        local loop = bridge.loop
        local out = {}
        local function test(name, fn)
            local ok, err = xpcall(fn, debug.traceback)
            out[#out+1] = { name=name, passed=ok, error=ok and '' or tostring(err) }
        end
        test('real A3 port and B3 new run preparation', function()
            assert(loop:NewRun())
            assert(loop:CanAccessPort())
            assert(runtime:GetShipPosition().x == 0 and runtime:GetShipPosition().y == 0)
            assert(loop:Depart())
        end)
        test('real movement normal barrel route and B recognition', function()
            runtime.movement:SetTarget({x=60,y=25})
            for _=1,240 do bridge:Update(0.05,0,0) end
            assert(loop.player:IsRecognized('driftwood_barrel'))
            local pos = runtime:GetShipPosition()
            assert(math.abs(pos.x-60)<5 and math.abs(pos.y-25)<5)
            local ok, reason = loop:ReturnToPort()
            assert(ok == false and reason == 'port_out_of_range')
            assert(runtime:GetShipPosition().x == pos.x)
        end)
        test('real normal return does not reset fish or barrel', function()
            local barrel = runtime:GetFixedBarrel()
            local generation = runtime.fishingGeneration
            local world = runtime.world
            runtime.movement:SetTarget({x=0,y=0})
            for _=1,240 do bridge:Update(0.05,0,0) end
            assert(loop:ReturnToPort())
            assert(world == runtime.world and generation == runtime.fishingGeneration)
            assert(runtime:GetFixedBarrel().id == barrel.id)
        end)
        test('real A3 fish lock with B3 timed fishing, normal population', function()
            assert(loop:Depart())
            local candidates = runtime:queryEntitiesInRadius(runtime.ship.position,30,{entityType='fish'})
            local fish = candidates[1]
            if not fish then
                runtime.movement:SetTarget({x=60,y=25})
                for _=1,240 do bridge:Update(0.05,0,0) end
                candidates=runtime:queryEntitiesInRadius(runtime.ship.position,30,{entityType='fish'})
                fish=assert(candidates[1],'no natural fish in range')
            end
            local point={x=fish.position.x,y=fish.position.y}
            local stamina=loop.player.stamina
            local count=#loop.player.inventory:GetItems()
            local token=assert(bridge:BeginFishing(point))
            assert(bridge:Update(0.5))
            local record=loop.actions._fishingTokens[token]
            assert(record.targetId ~= nil,'no natural fish selected at landing')
            local target=assert(runtime.world:get(record.targetId))
            assert(target.captureLocked==true and target.captureOwnerToken~=nil)
            assert(bridge:Update(3.5))
            local ok,result=bridge:CompleteFishing(token)
            assert(ok and result=='caught',tostring(result))
            assert(target.removed and target.captureOwnerToken==nil)
            assert(loop.player.stamina==stamina-40)
            assert(#loop.player.inventory:GetItems()==count+1)
        end)
        test('real new day preparation and memory-store restore retain recognition', function()
            runtime.movement:SetTarget({x=0,y=0})
            for _=1,240 do bridge:Update(0.05,0,0) end
            assert(loop:ReturnToPort())
            local barrel=runtime:GetFixedBarrel()
            assert(loop:EndToday())
            assert(loop:ConfirmSettlement())
            assert(loop.player.day==2 and not loop.settlementPending)
            assert(runtime:GetShipPosition().x==0 and runtime:GetShipPosition().y==0)
            assert(runtime:GetFixedBarrel().id==barrel.id)
            assert(loop.player:IsRecognized('driftwood_barrel'))
            assert(loop:NewRun())
            assert(not loop.player:IsRecognized('driftwood_barrel'))
            assert(bridge:LoadSaved())
            assert(loop.player.day==2 and loop.player:IsRecognized('driftwood_barrel'))
        end)
        test('new run resets recognition via B only', function()
            assert(loop:NewRun())
            assert(not loop.player:IsRecognized('driftwood_barrel'))
        end)
        return { results=out, provenance=reviewLoaded, log='' }
    ''')
    return runner.plain(report)

results = {}
runner.runtime = original_runtime
results['b_original'] = suites()
runner.runtime = composed_runtime
results['a3_b3_composed'] = suites()
results['a3_ocean_tests_composed'] = [runner.run_module(p.stem, 'a3') for p in []]
for path in sorted((A/'scripts/tests').glob('Circle1A3*Tests.lua')):
    log = []
    try:
        lua = composed_runtime(log)
        module = lua.eval('require(...)', 'tests.' + path.stem)
        if isinstance(module, tuple): module = module[0]
        recorder = helper._capture_type()()
        report = runner.plain(module.Run(recorder.bind(lua))) if path.stem == 'Circle1A3RecognitionTests' else runner.plain(module.Run())
        rows = runner.rows_from(report)
        results['a3_ocean_tests_composed'].append({'name':path.stem,'passed':all(r.get('passed') for r in rows), 'tests':rows})
    except Exception as error:
        results['a3_ocean_tests_composed'].append({'name':path.stem,'passed':False,'error':str(error)})
results['smoke'] = smoke()
lua=composed_runtime([])
results['boundary_fixture_diagnostic']=runner.plain(lua.execute('''
    local runtime=require('Ocean.SeaRuntime').New({departure={x=-20,y=-20},initializeRegions=false,daySeed=314159})
    local bridge=require('Integration.Bridge').New(runtime)
    assert(bridge.loop:Depart()); bridge:Sync()
    local boundary=assert(runtime:spawnFish('tuna',{x=-12,y=-20}))
    local outside=assert(runtime:spawnFish('sardine',{x=-11.99,y=-20}))
    boundary.frozen,outside.frozen=true,true; outside.position={x=-11.9,y=-20}
    local token=assert(bridge:BeginFishing({x=-20,y=-20}))
    assert(bridge:Update(0.5))
    local record=bridge.loop.actions._fishingTokens[token]
    local picked=record.targetId and runtime:GetFishingTarget(record.targetId)
    return {boundaryId=boundary.id,boundaryPosition=boundary.position,boundaryFrozen=boundary.frozen,
        targetId=record.targetId,targetPosition=picked and picked.position,
        targetSpecies=picked and picked.species,fishCount=runtime.world:getCounts().sardine+runtime.world:getCounts().tuna,
        selectedBoundary=record.targetId==boundary.id,empty=record.empty}
'''))
lua=composed_runtime([])
results['scope_contract_reproduction']=runner.plain(lua.execute('''
    local runtime=require('Ocean.SeaRuntime').New({initializeRegions=false})
    local bridge=require('Integration.Bridge').New(runtime)
    local loop=bridge.loop
    -- Explicit ownership fixture; no claim of acquiring the lens by real play.
    loop.player.treasures.scopeLens=true
    local on,onReason=loop:ToggleScope()
    local onState=runtime:IsScopeEnabled()
    local off,offReason=loop:ToggleScope()
    local offState=runtime:IsScopeEnabled()
    local stop,stopReason=loop:DisableScope()
    local stopState=runtime:IsScopeEnabled()
    local retry,retryReason=loop:DisableScope()
    return {fixture='lens ownership supplied only for API contract test',
        enable={ok=on,reason=onReason,ocean=onState},
        toggleOff={ok=off,reason=offReason,ocean=offState,expectedOcean=false},
        firstDisable={ok=stop,reason=stopReason,ocean=stopState},
        retryDisable={ok=retry,reason=retryReason,ocean=runtime:IsScopeEnabled()}}
'''))
results['method'] = 'read-only Lua searcher chooses exact A Ocean/Systems/FSM/Entities sources, B other sources; no native engine or cloud'
OUT.mkdir(parents=True, exist_ok=True)
(OUT/'composition-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
for kind, entries in results.items():
    if not isinstance(entries, list): continue
    print(kind, 'suites',len(entries),'failed',sum(not s.get('passed') for s in entries))
    for s in entries:
        if not s.get('passed'):
            print(s['name'],s.get('error',''))
            for r in s.get('tests',[]):
                if not r.get('passed'):
                    print(r.get('name'),r.get('skipped'),str(r.get('error',''))[:800])
print('smoke', [(r['name'],r['passed'],r['error'][:300]) for r in results['smoke']['results']])
