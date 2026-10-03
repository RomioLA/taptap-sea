-- Opt-in real-engine smoke probes used only by the standalone preview entry.
local Tests = require("tests.SeaRuntimeTests")
local Data = require("Ocean.FishData")
local Smoke = {}
function Smoke.Run(sea)
    local report = Tests.Run()
    for _, result in ipairs(report.results) do
        assert(result.passed, result.name .. ": " .. result.error)
    end
    print("[SeaV1][EngineSmoke] logic PASS " .. #report.results .. "/" .. #report.results)
    local runtime = sea.runtime
    local ship = runtime.ship
    local oldX, oldY = ship.position.x, ship.position.y
    assert(sea:HandlePointer(sea.physicalWidth*0.2, sea.physicalHeight*0.65), "pointer target was rejected on sea")
    assert(runtime.movement.target, "pointer target absent")
    sea:Update(0.25)
    assert(ship.position.x ~= oldX or ship.position.y ~= oldY, "pointer target did not move ship")
    print("[SeaV1][EngineSmoke] pointer conversion + movement PASS")
    runtime:Reset()
    -- Exercise real event subscriptions and VariantMap bindings in the engine.
    -- These are synthetic game events, not a claim of hardware input acceptance.
    local touch=VariantMap()
    touch["TouchID"],touch["X"],touch["Y"],touch["Pressure"]=Variant(0),
        Variant(math.floor(sea.physicalWidth*0.2)),Variant(math.floor(sea.physicalHeight*0.65)),Variant(1.0)
    SendEvent("TouchBegin",touch)
    local expected=runtime.movement:ScreenToWorld(touch:GetInt("X")/sea.dpr,touch:GetInt("Y")/sea.dpr)
    assert(runtime.movement.target,"TouchBegin did not create a target")
    assert(math.abs(runtime.movement.target.x-expected.x)<0.00001
        and math.abs(runtime.movement.target.y-expected.y)<0.00001,"touch target conversion mismatch")
    local finish=VariantMap();finish["TouchID"]=Variant(0);SendEvent("TouchEnd",finish)
    local pointerCalls=0
    local handler=sea.HandlePointer
    sea.HandlePointer=function(self,x,y) pointerCalls=pointerCalls+1;return handler(self,x,y) end
    local mouse=VariantMap()
    local mousePosition=input:GetMousePosition()
    mouse["Button"],mouse["Buttons"],mouse["Qualifiers"]=Variant(MOUSEB_LEFT),Variant(MOUSEB_LEFT),Variant(0)
    mouse["X"],mouse["Y"]=Variant(mousePosition.x),Variant(mousePosition.y)
    SendEvent("MouseButtonDown",mouse)
    sea.HandlePointer=handler
    assert(pointerCalls==1,"MouseButtonDown subscription was not invoked exactly once")
    mouse["Buttons"]=Variant(0);SendEvent("MouseButtonUp",mouse)
    print("[SeaV1][EngineSmoke] TouchBegin target + MouseButtonDown callback PASS")
    runtime:Reset()
    runtime:clearOrdinaryFish()
    runtime:spawnFish("sardine", {x=0,y=4})
    runtime:spawnFish("tuna", {x=20,y=4}, math.pi)
    runtime:spawnDroppedItem({itemId="engine-smoke", worldEffect="ATTRACT_SMALL_FISH"}, {x=0,y=10})
    for _, flag in ipairs({"showUnderwater", "showStates", "showPerception", "showActivity"}) do runtime:setDebugFlag(flag,true) end
    sea.tools.refresh(1)
    sea.smokeDebugPending = true
    print("[SeaV1][EngineSmoke] debug rendering queued; sardine target=" .. Data.sardine.targetActiveCount .. "; tuna target=" .. Data.tuna.targetActiveCount)
end
return Smoke
