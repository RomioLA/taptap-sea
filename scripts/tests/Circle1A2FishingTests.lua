local Tests = {}
local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")

local function readonly(values)
    return setmetatable({}, { __index = values,
        __newindex = function() error("drawing wrote fishing snapshot") end })
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end
    check("fishing_phase_geometry_and_readonly_snapshot", function()
        local runtime = Runtime.New({ initializeRegions = false })
        local originalEntityCount = #runtime.world.entities
        runtime.movement:SetViewport(1920, 1080)
        runtime:TogglePause()
        local center = readonly({ x = 8, y = -6 })
        local originalWorldCircle = Geometry.WorldCircle
        local circles = {}
        Geometry.WorldCircle = function(ctx, movement, position, radius, fill, stroke, strokeWidth, altitude)
            circles[#circles + 1] = {
                x = position.x, y = position.y, radius = radius, altitude = altitude,
            }
            return originalWorldCircle(ctx, movement, position, radius, fill, stroke, strokeWidth, altitude)
        end
        local ok, err = pcall(function()
            local ship = runtime.ship.position
            local flightCenter = { x = (ship.x + center.x) * 0.5, y = (ship.y + center.y) * 0.5 }
            local function draw(phase, elapsed)
                circles = {}
                recorder.reset()
                SeaDraw.Scene({}, 1920, 1080, runtime, nil,
                    readonly({ phase = phase, center = center, elapsedSec = elapsed }))
                assert(runtime.time == 0 and runtime.paused, "draw advanced paused runtime")
                assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"))
                return circles
            end
            local function hasCircle(list, cx, cy, radius, altitude)
                for _, circle in ipairs(list) do
                    if math.abs(circle.x - cx) < 0.001 and math.abs(circle.y - cy) < 0.001
                        and math.abs(circle.radius - radius) < 0.001
                        and (altitude == nil or math.abs((circle.altitude or 0) - altitude) < 0.001) then return true end
                end
                return false
            end
            local netRadius = Config.fishing.netRadius
            assert(hasCircle(draw("aim", 0), center.x, center.y, netRadius), "world-space aim net circle missing")
            local flight = draw("casting", 0.25)
            assert(hasCircle(flight, flightCenter.x, flightCenter.y, netRadius * 0.5, netRadius),
                "halfway cast net circle must follow the world-space flight arc and altitude")
            assert(not hasCircle(flight, center.x, center.y, netRadius), "net landed before .5s")
            assert(hasCircle(draw("casting", 0.5), center.x, center.y, netRadius),
                "world-space net circle missing at .5s landing")
            assert(recorder.callCount("nvgEllipse") > 0, "landing splash missing")
            local reeling = math.max(0, math.min(1, (2.25 - 0.5) / (Config.fishing.durationSec - 0.5)))
            assert(hasCircle(draw("reeling", 2.25), center.x, center.y, netRadius * (1 - reeling)),
                "reeling world-space visual does not contract with gameplay progress")
            draw("reeling", 4)
            assert(#runtime.world.entities == originalEntityCount, "draw selected/spawned/removed entity")
        end)
        Geometry.WorldCircle = originalWorldCircle
        if not ok then error(err) end
    end)
    check("optional_sixth_argument_keeps_fifth_clock_and_absent_view", function()
        local runtime = Runtime.New({ initializeRegions = false })
        runtime.movement:SetViewport(1920, 1080)
        for _, view in ipairs({ false, {}, { phase = "unknown", center = { x = 0, y = 0 }, elapsedSec = 0 },
            { phase = "aim", center = { x = 0/0, y = 0 }, elapsedSec = 0 } }) do
            recorder.reset()
            SeaDraw.Scene({}, 1920, 1080, runtime, readonly({ phase = "night" }), view or nil)
            assert(recorder.countFillColor(table.unpack(Config.visual.nightOverlay)) == 1, "fifth clock lost")
        end
    end)
    check("projected_fish_culling_keeps_partial_edge_and_rejects_far_depth", function()
        local runtime = Runtime.New({ initializeRegions = false })
        runtime.movement:SetViewport(1920, 1080)
        runtime:setDebugFlag("showUnderwater", true)
        runtime:spawnFish("sardine", { x = 0, y = 20 })
        runtime:spawnFish("sardine", { x = 100, y = -4 })
        local beyondFarDepth = runtime:spawnFish("sardine", { x = 0,
            y = Config.camera.farDepth + 1 })
        runtime:spawnFish("sardine", { x = -40.05, y = 0 })
        local farX, farY = runtime.movement:WorldToScreen(beyondFarDepth.position)
        assert(farY > runtime.movement:GetHorizonY(farX),
            "far ground must sink behind intervening water instead of clamping to the horizon")
        local Draw = require("Ocean.Draw")
        local original, count = Draw.WorldFish, 0
        Draw.WorldFish = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function() SeaDraw.Scene({}, 1920, 1080, runtime) end)
        Draw.WorldFish = original
        if not ok then error(err) end
        assert(count == 3, "footprint culling must retain the partial edge and possible far footprint, rejecting the offscreen fish")
    end)
    check("pointer_consumption_preserves_navigation_and_guards", function()
        local oldUI, oldBootstrap = package.loaded["urhox-libs/UI"], package.loaded["Ocean.Bootstrap"]
        local hit, hitX, hitY = false, 0, 0
        package.loaded["urhox-libs/UI"] = { GetScale = function() return 3 end,
            FindWidgetAt = function(x, y) hitX, hitY = x, y; return hit end }
        package.loaded["Ocean.Bootstrap"] = nil
        local ok, err = pcall(function()
            local Bootstrap = require("Ocean.Bootstrap")
            local runtime = Runtime.New({ initializeRegions = false })
            runtime.movement:SetViewport(960, 540)
            local ocean = setmetatable({ runtime = runtime, options = {}, stopped = false,
                physicalWidth = 1920, physicalHeight = 1080, dpr = 2, pointerMinY = 0.32,
                SyncViewport = function() return true end }, Bootstrap)
            runtime.movement:SetTarget({ x = -5, y = 0 })
            local oldTarget = runtime.movement.target
            local count = 0
            ocean.options.onSeaPointer = function(position, passedRuntime, passedOcean)
                count = count + 1
                assert(passedRuntime == runtime and passedOcean == ocean)
                assert(runtime.movement.target == oldTarget, "navigation changed before callback")
                assert(math.abs(position.x - 5) < 0.001 and math.abs(position.y + 3) < 0.001)
                return true
            end
            local lx, ly = runtime.movement:WorldToScreen({ x = 5, y = -3 })
            assert(ocean:HandlePointer(lx * 2, ly * 2))
            assert(runtime.movement.target == oldTarget and count == 1)
            assert(math.abs(hitX - lx * 2 / 3) < 0.001
                and math.abs(hitY - ly * 2 / 3) < 0.001, "UI scaling must remain independent of DPR")
            for _, consume in ipairs({ false, "nil" }) do
                ocean.options.onSeaPointer = function() if consume == false then return false end end
                assert(ocean:HandlePointer(lx * 2, ly * 2))
                assert(math.abs(runtime.movement.target.x - 5) < 0.001
                    and math.abs(runtime.movement.target.y + 3) < 0.001)
            end
            ocean.options.onSeaPointer = function() error("guard failed") end
            hit = true; assert(not ocean:HandlePointer(lx * 2, ly * 2)); hit = false
            assert(not ocean:HandlePointer(-1, 500))
            assert(not ocean:HandlePointer(600, 10))
            runtime:TogglePause(); assert(not ocean:HandlePointer(lx * 2, ly * 2)); runtime:TogglePause()
            local bx, by = runtime.movement:WorldToScreen({ x = 35, y = 25 })
            -- Separate water-legality check from horizon bounds using a central invalid point.
            runtime.IsPositionFree = function() return false end
            assert(not ocean:HandlePointer(lx * 2, ly * 2))
            assert(type(bx) == "number" and type(by) == "number")
        end)
        package.loaded["urhox-libs/UI"], package.loaded["Ocean.Bootstrap"] = oldUI, oldBootstrap
        if not ok then error(err) end
    end)
    check("bootstrap_optional_callback_is_forwarded_without_mutation", function()
        local oldUI, oldBootstrap = package.loaded["urhox-libs/UI"], package.loaded["Ocean.Bootstrap"]
        package.loaded["urhox-libs/UI"] = {}
        package.loaded["Ocean.Bootstrap"] = nil
        local oldScene, oldBegin, oldEnd = SeaDraw.Scene, nvgBeginFrame, nvgEndFrame
        local ok, err = pcall(function()
            local Bootstrap = require("Ocean.Bootstrap")
            local runtime = Runtime.New({ initializeRegions = false })
            local clock, view = readonly({ phase = "day" }), readonly({ phase = "aim" })
            local received, calls = {}, 0
            SeaDraw.Scene = function(ctx, w, h, rt, fifth, sixth)
                received = { rt, fifth, sixth }; calls = calls + 1
                assert(w == 960 and h == 540)
            end
            nvgBeginFrame, nvgEndFrame = function() end, function() end
            local ocean = setmetatable({ runtime = runtime, context = {}, options = {}, stopped = false,
                firstFrame = false, physicalWidth = 1920, physicalHeight = 1080, dpr = 2,
                SyncViewport = function() return true end }, Bootstrap)
            ocean:Render(); assert(received[1] == runtime and received[2] == nil and received[3] == nil)
            ocean.options.getClock = function() return clock end
            ocean.options.getFishingView = function() return nil end
            ocean:Render(); assert(received[2] == clock and received[3] == nil)
            ocean.options.getFishingView = function() return view end
            ocean:Render(); assert(received[2] == clock and received[3] == view and calls == 3)
        end)
        SeaDraw.Scene, nvgBeginFrame, nvgEndFrame = oldScene, oldBegin, oldEnd
        package.loaded["urhox-libs/UI"], package.loaded["Ocean.Bootstrap"] = oldUI, oldBootstrap
        if not ok then error(err) end
    end)
    return { results = results }
end

return Tests
