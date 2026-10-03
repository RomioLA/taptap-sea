local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local Presentation = require("Ocean.SeaPresentation")
local SeaDraw = require("Ocean.SeaDraw")
local Tests = {}

local function smooth(value)
    local t = math.max(0, math.min(1, value))
    return t * t * (3 - 2 * t)
end

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

    check("emergence_is_continuous_reversible_and_driven_by_configured_depth", function()
        local runtime = newRuntime(1280, 720)
        local movement = runtime.movement
        local emergence = Config.visual.emergence
        local air = Config.visual.aerialPerspective
        local startDepth, endDepth = emergence.startDepthMeters, emergence.endDepthMeters
        assert(endDepth > startDepth and air.endDepthMeters > air.startDepthMeters)

        local clear = Presentation.State(movement, { x = 0, y = 5 }, 3, 5)
        assert(clear.progress == 1 and clear.alpha == 1 and clear.airMix == 0,
            "near water should remain fully clear")

        local atAirStart = Presentation.State(movement, { x = 0, y = air.startDepthMeters }, 3, 5)
        local atAirEnd = Presentation.State(movement, { x = 0, y = air.endDepthMeters }, 3, 5)
        assertNear(atAirStart.airMix, 0, "air tint begins at zero")
        assertNear(atAirEnd.airMix, air.maxOpacityLoss, "air tint reaches configured depth strength")
        assertNear(atAirEnd.alpha, atAirEnd.progress * (1 - air.maxOpacityLoss),
            "air haze contribution to alpha")

        local previousProgress, previousAlpha = 1, 1
        for index = 0, 80 do
            local depth = startDepth + (endDepth - startDepth) * index / 80
            local state = Presentation.State(movement, { x = 10, y = depth }, 4, 5)
            assert(state and state.progress <= previousProgress + 1e-8,
                "emergence should decrease smoothly with distance")
            assert(state.alpha <= previousAlpha + 1e-8 and state.alpha >= 0,
                "combined visibility should decrease with distance")
            previousProgress, previousAlpha = state.progress, state.alpha
        end

        local midpoint = (startDepth + endDepth) * 0.5
        local farther = Presentation.State(movement, { x = 10, y = midpoint + 0.01 }, 4, 5)
        local nearer = Presentation.State(movement, { x = 10, y = midpoint - 0.01 }, 4, 5)
        assert(nearer.progress > farther.progress and nearer.alpha > farther.alpha,
            "approaching the reveal band should smoothly restore visibility")
        assert(nearer.alpha - farther.alpha < 0.001,
            "a small distance step should not pop the appearance")
        local repeated = Presentation.State(movement, { x = 10, y = midpoint }, 4, 5)
        local same = Presentation.State(movement, { x = 10, y = midpoint }, 4, 5)
        assert(repeated.progress == same.progress and repeated.alpha == same.alpha
            and repeated.risePixels == same.risePixels,
            "returning to a distance must not retrigger an animation")

        local atEnd = Presentation.State(movement, { x = 10, y = endDepth }, 4, 5)
        assert(atEnd.progress == 0 and atEnd.alpha == 0,
            "the configured end depth should fully hide the object")
    end)

    check("the_two_fixed_islands_land_in_clear_and_legible_reveal_bands", function()
        local runtime = newRuntime(1920, 1080)
        local firstIsland = Presentation.State(runtime.movement, { x = 35, y = 25 }, 12, 5.4)
        local secondIsland = Presentation.State(runtime.movement, { x = -80, y = 90 }, 20, 5.4)
        local emergence = Config.visual.emergence
        assert(firstIsland and firstIsland.progress == 1 and firstIsland.alpha > 0.98,
            "the 25m island should be fully emerged and clear")
        local expectedSecond = smooth((emergence.endDepthMeters - 90)
            / math.max(1, emergence.endDepthMeters - emergence.startDepthMeters))
        assert(secondIsland and secondIsland.progress > 0 and secondIsland.progress < 1,
            "the 90m island should be in the partial reveal band")
        assertNear(secondIsland.progress, expectedSecond, "90m island emergence")
        assert(secondIsland.alpha > 0 and secondIsland.alpha < secondIsland.progress,
            "air perspective should visibly soften the partially emerged island")
        assert(secondIsland.airMix > firstIsland.airMix,
            "the farther fixed island should carry a stronger air tint")
    end)

    check("rise_moves_the_art_up_under_a_fixed_intersected_clip_and_restores_transform", function()
        local runtime = newRuntime(1280, 720)
        local movement = runtime.movement
        local midpoint = (Config.visual.emergence.startDepthMeters
            + Config.visual.emergence.endDepthMeters) * 0.5
        local point = { x = 0, y = midpoint }
        local expected = Presentation.State(movement, point, 5, 5)
        assert(expected and expected.progress > 0 and expected.progress < 1)
        assert(expected.risePixels > 0 and expected.clipBottom > expected.clipTop,
            "partially emerged object needs a positive rise and a fixed clip span")
        assertNear(expected.risePixels, expected.screenHeight * (1 - expected.progress),
            "screen-space rise offset")

        local original = {
            save = nvgSave,
            restore = nvgRestore,
            translate = nvgTranslate,
            intersect = nvgIntersectScissor,
        }
        local transformY, transformStack = 0, {}
        local translations, scissors = {}, {}
        nvgSave = function(ctx)
            transformStack[#transformStack + 1] = transformY
            return original.save(ctx)
        end
        nvgRestore = function(ctx)
            transformY = table.remove(transformStack) or 0
            return original.restore(ctx)
        end
        nvgTranslate = function(ctx, x, y)
            translations[#translations + 1] = { x = x, y = y }
            transformY = transformY + y
            return original.translate(ctx, x, y)
        end
        nvgIntersectScissor = function(ctx, x, y, width, height)
            scissors[#scissors + 1] = { x = x, y = y, width = width, height = height }
            return original.intersect(ctx, x, y, width, height)
        end

        recorder.reset()
        local ctx = {}
        nvgSave(ctx)
        nvgScissor(ctx, 0, movement:GetHorizonY(), movement.viewportWidth,
            movement.viewportHeight - movement:GetHorizonY())
        local callbackState, callbackOffset, callbackAlpha, callbackAirMix
        local ok, result = pcall(function()
            return Presentation.Draw(ctx, movement, point, 5, 5, function(state)
                callbackState = state
                callbackOffset = transformY
                callbackAlpha = recorder.globalAlpha()
                callbackAirMix = state.airMix
            end)
        end)
        while #transformStack > 0 do nvgRestore(ctx) end
        nvgSave, nvgRestore = original.save, original.restore
        nvgTranslate, nvgIntersectScissor = original.translate, original.intersect

        assert(ok, tostring(result))
        assert(result and callbackState and callbackAlpha > 0 and callbackAlpha < 1)
        assertNear(callbackAirMix, expected.airMix, "air color-mix amount passed to draw")
        assertNear(callbackOffset, expected.risePixels, "art translation during draw")
        assert(#translations == 1 and translations[1].x == 0)
        assertNear(translations[1].y, expected.risePixels, "nvgTranslate rise offset")
        assert(#scissors == 1 and scissors[1].x == 0)
        assertNear(scissors[1].y, expected.clipTop, "intersected clip top")
        assertNear(scissors[1].height, expected.clipBottom - expected.clipTop, "fixed clip height")
        assertNear(scissors[1].y + scissors[1].height, expected.clipBottom, "fixed clip bottom")
        assertNear(transformY, 0, "restored screen transform")
        assert(recorder.callCount("nvgIntersectScissor") == 1
            and recorder.callCount("nvgScissor") == 1,
            "local rise clip must intersect the existing sea-area clip")
        assert(recorder.globalAlpha() == 1
            and recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"),
            "draw state must be balanced after the object render")

        recorder.reset()
        assert(not Presentation.Draw(ctx, movement, { x = 0, y = Config.visual.emergence.endDepthMeters },
            5, 5, function() error("fully hidden object callback must not run") end))
    end)

    check("paused_scene_keeps_hidden_fish_and_runtime_state_unchanged", function()
        local runtime = newRuntime(1280, 720)
        local hidden = runtime:spawnFish("sardine", { x = 0,
            y = (Config.visual.emergence.startDepthMeters + Config.visual.emergence.endDepthMeters) * 0.5 })
        assert(not runtime.world:isVisible(hidden))
        runtime:TogglePause()
        local oldTime, oldCount, oldX, oldY = runtime.time, #runtime.world.entities,
            runtime.ship.position.x, runtime.ship.position.y
        local Draw = require("Ocean.Draw")
        local original, count = Draw.WorldFish, 0
        Draw.WorldFish = function(...) count = count + 1; return original(...) end
        local ok, err = pcall(function()
            for _ = 1, 3 do
                recorder.reset()
                SeaDraw.Scene({}, 1280, 720, runtime)
                runtime:Update(0.25, 1, 0)
                assert(recorder.globalAlpha() == 1)
                assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"))
            end
        end)
        Draw.WorldFish = original
        assert(ok, tostring(err))
        assert(count == 0 and #runtime.world.entities == oldCount and runtime.time == oldTime)
        assert(runtime.ship.position.x == oldX and runtime.ship.position.y == oldY)
    end)
    return { results = results }
end

return Tests
