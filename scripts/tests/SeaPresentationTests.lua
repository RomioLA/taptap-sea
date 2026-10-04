local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local Presentation = require("Ocean.SeaPresentation")
local SeaDraw = require("Ocean.SeaDraw")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Geometry = require("Ocean.ProjectedGeometry")
local Tests = {}

local function assertNear(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    assert(type(actual) == "number" and math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.8f, got %s", label, expected, tostring(actual)))
end

local function newRuntime(width, height)
    local runtime = Runtime.New({ initializeRegions = false, departure = { x = 0, y = 0 } })
    runtime.movement:SetViewport(width, height)
    return runtime
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("fixed_island_height_crosses_the_horizon_without_vertical_art_motion", function()
        local runtime = newRuntime(1920, 1080)
        local movement = runtime.movement
        local farIsland = { x = -80, y = 90 }
        local groundX, groundY = movement:WorldToScreen(farIsland)
        local tallestTree = { x = farIsland.x + 20 * 0.20, y = farIsland.y + 20 * 0.27 }
        local treeX, treeY = movement:WorldToScreen(tallestTree, 5.4)
        assert(groundY > movement:GetHorizonY(groundX), "island ground must remain in the water plane")
        assert(treeY < movement:GetHorizonY(treeX), "raised tree silhouette should naturally pass the horizon")

        local near = Presentation.State(movement, { x = 35, y = 25 }, 12, 5.4,
            { allowAboveHorizon = true, allowBeyondHorizon = true })
        local far = Presentation.State(movement, farIsland, 20, 5.4,
            { allowAboveHorizon = true, allowBeyondHorizon = true })
        assert(near and far and near.progress == 1 and far.progress == 1,
            "islands must not use a depth-driven geometric emergence animation")
        assert(near.risePixels == 0 and far.risePixels == 0,
            "presentation must not translate world art vertically")
        assert(far.airMix > near.airMix and far.alpha > 0,
            "the far island should retain visible atmospheric perspective")
    end)

    check("complete_footprint_bounds_replace_center_cutoff_and_opacity_emergence", function()
        local movement=newRuntime(1280,720).movement
        for _,depth in ipairs({110-1e-5,110,110+1e-5,111}) do
            local point={x=0,y=depth}
            local state=Presentation.State(movement,point,2,0)
            assert(state and state.horizonFade==1 and state.alpha>0,
                "partially visible footprints must reach their geometric draw callback")
            assert(#Geometry.ProjectPolygon(movement,Geometry.SampleCircle(point,2))>=3)
        end
        assert(Presentation.State(movement,{x=0,y=112.01},2,0)==nil)
        local high=Presentation.State(movement,{x=0,y=130},5,5)
        assert(high and high.horizonFade==1,"raised objects use geometry, not a whole-outline fade")
    end)

    check("presentation_preserves_world_coordinates_and_restores_drawing_state", function()
        local movement=newRuntime(1280,720).movement
        recorder.reset()
        local called=false
        assert(Presentation.Draw({},movement,{x=0,y=111},2,0,function(state)
            called=true;assert(state.risePixels==0)
            Geometry.WorldCircle({},movement,{x=0,y=111},2,{184,130,90,255})
        end))
        assert(called and recorder.countFillColor(184,130,90,255)>0,
            "a center beyond the horizon must still draw its visible footprint")
        assert(recorder.globalAlpha()==1 and recorder.callCount("nvgSave")==recorder.callCount("nvgRestore"))
        assert(recorder.callCount("nvgScissor")==0 and recorder.callCount("nvgIntersectScissor")==0,
            "actual geometry must be clipped without a conservative rectangular cutoff")
        assert(not Presentation.Draw({},movement,{x=0,y=112.01},2,0,
            function() error("wholly hidden footprint must not draw") end))
    end)

    check("paused_scene_keeps_hidden_and_beyond_horizon_fish_out_of_the_sky", function()
        local runtime = newRuntime(1280, 720)
        local hidden = runtime:spawnFish("sardine", { x = 0, y = Config.camera.farDepth + 8 }, 0)
        assert(not runtime.world:isVisible(hidden))
        runtime:TogglePause()
        local oldTime, oldCount = runtime.time, #runtime.world.entities
        local oldX, oldY = runtime.ship.position.x, runtime.ship.position.y
        local original, count = Draw.WorldFish, 0
        Draw.WorldFish = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            for _ = 1, 3 do
                recorder.reset()
                SeaDraw.Scene({}, 1280, 720, runtime)
                runtime:Update(0.25, 1, 0)
                assert(recorder.globalAlpha() == 1)
                assert(recorder.callCount("nvgScissor") == 0,
                    "scene-wide horizon scissor would cut elevated island silhouettes")
                assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"))
            end
            runtime:setDebugFlag("showUnderwater", true)
            recorder.reset()
            SeaDraw.Scene({}, 1280, 720, runtime)
            assert(count == 0 and recorder.countFillColor(table.unpack(FishData.sardine.color)) == 0,
                "visible-but-distant fish must be culled before they leak into the sky")
        end)
        Draw.WorldFish = original
        assert(ok, tostring(err))
        assert(#runtime.world.entities == oldCount and runtime.time == oldTime)
        assert(runtime.ship.position.x == oldX and runtime.ship.position.y == oldY)
    end)

    return { results = results }
end

return Tests
