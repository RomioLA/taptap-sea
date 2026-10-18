-- Offline render contract tests for the fused Sea Runtime scene.
-- The Python runner supplies an NVG recorder and invokes SeaDraw.Scene directly.
local Tests = {}

local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.Draw")
local Art = require("Ocean.SeaViewArt")
local SeaDraw = require("Ocean.SeaDraw")

local function near(actual, expected, tolerance)
    return math.abs(actual - expected) <= (tolerance or 0.001)
end

local function assertNear(actual, expected, label, tolerance)
    assert(type(actual) == "number" and near(actual, expected, tolerance),
        string.format("%s: expected %.6f, got %s", label, expected, tostring(actual)))
end

local function snapshot(runtime)
    local entities = {}
    for index, entity in ipairs(runtime.world.entities) do
        entities[index] = {
            id = entity.id,
            x = entity.position.x,
            y = entity.position.y,
            removed = entity.removed,
            active = entity.active,
            frozen = entity.frozen,
        }
    end
    return {
        time = runtime.time,
        shipX = runtime.ship.position.x,
        shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x,
        cameraY = runtime.movement.camera.y,
        entityCount = #runtime.world.entities,
        revealCount = #runtime.world.reveals,
        showUnderwater = runtime.world.showUnderwater,
        entities = entities,
    }
end

local function assertUnchanged(before, runtime, label)
    local after = snapshot(runtime)
    assert(after.time == before.time, label .. " changed runtime.time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY, label .. " moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY, label .. " moved the camera")
    assert(after.entityCount == before.entityCount, label .. " changed world entity count")
    assert(after.revealCount == before.revealCount, label .. " changed visibility reveals")
    assert(after.showUnderwater == before.showUnderwater, label .. " changed underwater visibility")
    for index, entity in ipairs(after.entities) do
        local old = before.entities[index]
        assert(old and entity.id == old.id, label .. " reordered world entities")
        assert(entity.x == old.x and entity.y == old.y, label .. " moved an entity")
        assert(entity.removed == old.removed and entity.active == old.active and entity.frozen == old.frozen,
            label .. " changed entity simulation flags")
    end
end

local function wrapDrawMethod(calls, originals, name, key)
    local original = Draw[name]
    assert(type(original) == "function", "missing reusable Draw." .. name .. " API")
    originals[name] = original
    Draw[name] = function(...)
        calls[key] = (calls[key] or 0) + 1
        return original(...)
    end
end

local function wrapArtMethod(calls, originals, name, key, recorder)
    local original = Art[name]
    assert(type(original) == "function", "missing reusable SeaViewArt." .. name .. " API")
    originals[name] = original
    Art[name] = function(...)
        calls[key] = (calls[key] or 0) + 1
        if name == "Boat" and calls.expectedBoatTint ~= nil then
            assert(recorder.countFillColor(table.unpack(Config.visual.nightOverlay)) == calls.expectedBoatTint,
                "night tint must be drawn before the boat, and removed in daytime")
        end
        return original(...)
    end
end

local function restoreDrawMethods(originals)
    for name, original in pairs(originals) do Draw[name] = original end
end

local function restoreArtMethods(originals)
    for name, original in pairs(originals) do Art[name] = original end
end

local function addPreviewFixture(runtime)
    -- A presentation-only island keeps the real Config fixedObjects untouched.
    runtime.previewIsland = runtime.world:spawn({
        entityType = "island", kind = "fixed", layer = "surface",
        position = { x = -14, y = -12 }, radius = 4, blocking = false,
    })
    runtime.previewSardine = runtime:spawnFish("sardine", { x = -8, y = -8 }, 0)
    runtime.previewTuna = runtime:spawnFish("tuna", { x = 8, y = -14 }, math.pi)
end

function Tests.CreatePreviewRuntime(width, height)
    local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
    runtime.time = 8
    addPreviewFixture(runtime)
    assert(runtime.movement:SetViewport(width, height), "initial offline viewport was not applied")
    return runtime
end

function Tests.Run(recorder)
    local calls = {}
    local originals = {}
    wrapDrawMethod(calls, originals, "SceneBackdrop", "sceneBackdrop")
    wrapDrawMethod(calls, originals, "WorldFish", "worldFish")
    wrapDrawMethod(calls, originals, "NightOverlay", "nightOverlay")
    wrapArtMethod(calls, originals, "Boat", "boatArt", recorder)
    wrapArtMethod(calls, originals, "Island", "islandArt", recorder)

    local ok, result = pcall(function()
        local runtime = Tests.CreatePreviewRuntime(1920, 1080)
        local configObjectCount = #Config.world.fixedObjects
        assert(runtime.debug.showUnderwater == false and runtime.world.showUnderwater == false,
            "new preview runtime must keep ordinary fish hidden")
        assert(runtime.world:isVisible(runtime.previewSardine) == false
            and runtime.world:isVisible(runtime.previewTuna) == false,
            "preview fish unexpectedly visible before reveal")

        local shipScreenX, shipScreenY, shipScale = runtime.movement:WorldToScreen(runtime.ship.position)
        local landscapeShipScreenX, landscapeShipScreenY = shipScreenX, shipScreenY
        assertNear(shipScreenX, 1920 * Config.camera.anchorX, "landscape ship screen X")
        assertNear(shipScreenY, 1080 * Config.camera.anchorY, "landscape ship screen anchor Y")
        assertNear(shipScale, 1080 / Config.camera.viewHeight, "landscape base pixels per meter")
        assertNear(runtime.movement:GetHorizonY(), 1080 * Config.camera.horizonY, "landscape projection horizon")
        local _, _, islandScale = runtime.movement:WorldToScreen(runtime.previewIsland.position)
        assert(islandScale > shipScale, "nearer island should have a larger perspective scale than the ship anchor")

        recorder.reset()
        local beforeHidden = snapshot(runtime)
        SeaDraw.Scene({}, 1920, 1080, runtime)
        assertUnchanged(beforeHidden, runtime, "hidden-fish landscape draw")
        assert(calls.sceneBackdrop == 1, "the original scene backdrop was not reused once")
        assert(calls.boatArt == 1, "the projected SeaViewArt boat was not reused once")
        assert(calls.islandArt >= 1, "the projected SeaViewArt island was not reused")
        assert(calls.worldFish == nil, "hidden ordinary fish reached WorldFish")
        assert(recorder.countFillColor(FishData.sardine.color[1], FishData.sardine.color[2],
            FishData.sardine.color[3], FishData.sardine.color[4]) == 0,
            "hidden sardine color reached the render capture")
        assert(recorder.countFillColor(FishData.tuna.color[1], FishData.tuna.color[2],
            FishData.tuna.color[3], FishData.tuna.color[4]) == 0,
            "hidden tuna color reached the render capture")
        assert(recorder.hasEllipseArgs(1920 * 0.76, 1080 * 0.13, 0, 0, 0.01),
            "the original background sun ellipses were not drawn at their configured center")
        assert(recorder.countEllipseArgs(1, 1, 16, 6, 0.001) == #Config.birds,
            "the original configured birds were not drawn")
        assert(recorder.callCount("nvgScissor") == 1,
            "world layer should establish one sea-area NanoVG scissor")
        local landscapeHorizon = runtime.movement:GetHorizonY()
        assert(recorder.scissorMatches(0, landscapeHorizon, 1920,
            1080 - landscapeHorizon, 0.01), "world-layer scissor does not begin at the projected horizon")

        runtime:setDebugFlag("showUnderwater", true)
        assert(runtime.world:isVisible(runtime.previewSardine) and runtime.world:isVisible(runtime.previewTuna),
            "showUnderwater did not reveal both preview fish")
        assert(runtime.movement:SetViewport(1200, 1150), "portrait resize was not applied")
        shipScreenX, shipScreenY, shipScale = runtime.movement:WorldToScreen(runtime.ship.position)
        assertNear(shipScreenX, 1200 * Config.camera.anchorX, "portrait ship screen X")
        assertNear(shipScreenY, 1150 * Config.camera.anchorY, "portrait ship screen anchor Y")
        assertNear(shipScale, 1150 / Config.camera.viewHeight, "portrait base pixels per meter")
        assertNear(runtime.movement:GetHorizonY(), 1150 * Config.camera.horizonY, "portrait projection horizon")

        recorder.reset()
        local beforeReveal = snapshot(runtime)
        local fishCallsBefore = calls.worldFish or 0
        SeaDraw.Scene({}, 1200, 1150, runtime)
        assertUnchanged(beforeReveal, runtime, "revealed-fish portrait draw")
        assert((calls.worldFish or 0) - fishCallsBefore == 2,
            "showUnderwater should route both visible fixture fish through the shared shape")
        assert(recorder.countFillColor(FishData.sardine.color[1], FishData.sardine.color[2],
            FishData.sardine.color[3], FishData.sardine.color[4]) > 0,
            "revealed sardine was not rendered")
        assert(recorder.countFillColor(FishData.tuna.color[1], FishData.tuna.color[2],
            FishData.tuna.color[3], FishData.tuna.color[4]) > 0,
            "revealed tuna was not rendered")
        local portraitHorizon = runtime.movement:GetHorizonY()
        assert(recorder.scissorMatches(0, portraitHorizon, 1200,
            1150 - portraitHorizon, 0.01), "portrait world-layer scissor did not track the projected horizon")

        local _, _, portraitIslandScale = runtime.movement:WorldToScreen(runtime.previewIsland.position)
        assert(portraitIslandScale > shipScale,
            "portrait projection should preserve larger scale for the nearer island")
        assert(#Config.world.fixedObjects == configObjectCount,
            "offline presentation fixtures changed formal Config fixedObjects")

        runtime:setDebugFlag("showUnderwater", false)
        local clock = require("Gameplay.GameClock").New()
        clock:Seek("night", 10)
        clock:Pause("inventory")
        local elapsed = clock.elapsed
        local nightColor = Config.visual.nightOverlay
        local expectedTintCount = 1
        calls.expectedBoatTint = expectedTintCount
        recorder.reset()
        local beforeNight = snapshot(runtime)
        SeaDraw.Scene({}, 1200, 1150, runtime, clock)
        assertUnchanged(beforeNight, runtime, "paused nighttime draw")
        assert(clock.elapsed == elapsed and clock.phase == "night" and clock:IsPaused(),
            "rendering mutated the existing gameplay clock")
        assert(calls.nightOverlay == 1, "night rendering must tint the scene exactly once")
        assert(recorder.callCount("nvgSave") == recorder.callCount("nvgRestore"),
            "night tint left the NanoVG state stack unbalanced")
        expectedTintCount = 0
        calls.expectedBoatTint = expectedTintCount
        clock:Seek("day", 0)
        recorder.reset()
        SeaDraw.Scene({}, 1200, 1150, runtime, clock)
        assert(recorder.countFillColor(table.unpack(nightColor)) == 0,
            "returning to daytime retained the night tint")
        calls.expectedBoatTint = nil
        return {
            status = "PASS",
            tests = {
                "draw_is_pure_for_runtime_state",
                "original_sun_and_birds_reused",
                "projected_sea_view_art_apis_reused",
                "ordinary_fish_hidden_by_default",
                "show_underwater_draws_both_fixture_fish",
                "resize_preserves_projection_anchor_horizon_and_perspective_scale",
                "sea_scissor_tracks_projection_horizon_in_both_aspects",
                "presentation_fixture_does_not_change_config_world",
                "night_tint_precedes_boat_and_preserves_paused_gameplay_clock",
                "daytime_removes_night_tint_and_nvg_state_stack_is_balanced",
            },
            metrics = {
                landscape = {
                    width = 1920, height = 1080, anchorX = Config.camera.anchorX,
                    anchorY = Config.camera.anchorY, horizonY = 1080 * Config.camera.horizonY,
                    basePixelsPerMeter = 1080 / Config.camera.viewHeight,
                    shipScreenX = landscapeShipScreenX, shipScreenY = landscapeShipScreenY,
                    hiddenWorldFishCalls = 0,
                },
                portrait = {
                    width = 1200, height = 1150, anchorX = Config.camera.anchorX,
                    anchorY = Config.camera.anchorY, horizonY = 1150 * Config.camera.horizonY,
                    basePixelsPerMeter = 1150 / Config.camera.viewHeight,
                    shipScreenX = shipScreenX, shipScreenY = shipScreenY, revealedWorldFishCalls = 2,
                },
                originalConfiguredBirds = #Config.birds,
                originalFixedObjectCount = configObjectCount,
                previewFixtures = { island = "(-14,-12)", sardine = "(-8,-8)", tuna = "(8,-14)" },
            },
        }
    end)
    restoreDrawMethods(originals)
    restoreArtMethods(originals)
    if not ok then error(result) end
    return result
end

return Tests
