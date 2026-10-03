-- Offline render regression using real PlayerState/Persistence; no cloud calls.
local Tests = {}
local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")
local PlayerState = require("Gameplay.PlayerState")
local Persistence = require("Gameplay.Persistence")
local CONTENT_ID = "driftwood_barrel"

local function near(a, b) return math.abs(a - b) < 0.001 end

-- Geometry setup is a render fixture, not a sailing/playthrough claim.
local function placeForRender(runtime, distance, width)
    local barrel = runtime:GetFixedBarrel()
    runtime.ship.position = { x = barrel.position.x + distance, y = barrel.position.y }
    runtime.movement:SetViewport(width, 1080)
    runtime.movement:_AnchorCameraToShip()
    return runtime.movement:WorldToScreen(barrel.position)
end

local function render(recorder, runtime, callback, width)
    width = width or 5000
    local barrel = runtime:GetFixedBarrel()
    local originalCircle = Geometry.WorldCircle
    local details = 0
    Geometry.WorldCircle = function(ctx, movement, center, radius, ...)
        if near(center.x, barrel.position.x) and near(center.y, barrel.position.y)
            and near(radius, Config.world.fixedBarrel.radius * 0.72) then details = details + 1 end
        return originalCircle(ctx, movement, center, radius, ...)
    end
    recorder.reset()
    local ok, err = pcall(SeaDraw.Scene, {}, width, 1080, runtime, nil, nil, callback)
    Geometry.WorldCircle = originalCircle
    if not ok then error(err) end
    return details
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end
    check("first_approach_then_depart_and_return_reads_existing_player_progress", function()
        local player = assert(PlayerState.New())
        local runtime = Runtime.New({ initializeRegions = false })
        local reads = 0
        local query = function(contentId)
            assert(contentId == CONTENT_ID, "anonymous or unrelated object queried")
            reads = reads + 1
            return player:IsRecognized(contentId)
        end
        placeForRender(runtime, 80, 5000)
        assert(render(recorder, runtime, query) == 0)
        placeForRender(runtime, 20, 5000)
        assert(render(recorder, runtime, query) == 1)
        assert(not player:IsRecognized(CONTENT_ID), "Draw marked recognition")
        assert(player:MarkRecognized(CONTENT_ID)) -- B-side recognition action, outside Draw.
        placeForRender(runtime, 80.01, 5000)
        local oldReads = reads
        assert(render(recorder, runtime, query) == 0 and reads == oldReads,
            "recognized identity expanded visibility")
        placeForRender(runtime, 60, 5000)
        assert(render(recorder, runtime, query) == 1, "return forgot identity")
    end)
    check("restore_and_new_game_are_read_live_without_ocean_progress_copy", function()
        local player = assert(PlayerState.New())
        assert(player:MarkRecognized(CONTENT_ID))
        local save = Persistence.Snapshot(player)
        player = assert(Persistence.Restore(save))
        local runtime = Runtime.New({ initializeRegions = false })
        placeForRender(runtime, 60, 5000)
        local query = function(id) return player:IsRecognized(id) end
        assert(render(recorder, runtime, query) == 1, "loaded recognition missing")
        assert(player:Reset())
        assert(render(recorder, runtime, query) == 0, "new game retained ocean recognition")
        assert(save.recognizedLocations[CONTENT_ID] == true, "Draw altered save snapshot")
    end)
    check("missing_false_nil_and_nonboolean_queries_preserve_unknown_behavior", function()
        local runtime = Runtime.New({ initializeRegions = false })
        placeForRender(runtime, 60, 5000)
        assert(render(recorder, runtime) == 0)
        for _, value in ipairs({ false, "nil", 1, "true" }) do
            assert(render(recorder, runtime, function() if value ~= "nil" then return value end end) == 0)
        end
        placeForRender(runtime, 20, 5000)
        assert(render(recorder, runtime) == 1)
    end)
    check("recognized_offscreen_and_content_decoys_do_not_bypass_existing_filters", function()
        local runtime = Runtime.New({ initializeRegions = false })
        placeForRender(runtime, 60, 1920)
        local reads = 0
        assert(render(recorder, runtime, function() reads = reads + 1; return true end, 1920) == 0)
        assert(reads == 0, "offscreen location queried")
        placeForRender(runtime, 25, 5000)
        runtime.world:spawn({ entityType = "float", kind = "fixed", layer = "surface",
            contentId = CONTENT_ID, position = { x = 88, y = 25 }, radius = 2, blocking = false })
        runtime.world:spawn({ entityType = "island", kind = "fixed", layer = "surface",
            position = { x = 90, y = 25 }, radius = 1, blocking = false })
        reads = 0
        assert(render(recorder, runtime, function(id)
            assert(id == CONTENT_ID); reads = reads + 1; return true
        end) == 1)
        assert(reads == 1, "decoy or anonymous island acquired persistent identity")
    end)
    check("repeated_draw_is_readonly_for_world_ship_signals_and_player", function()
        local runtime = Runtime.New({ daySeed = 271828 })
        local player = assert(PlayerState.New())
        assert(player:MarkRecognized(CONTENT_ID))
        placeForRender(runtime, 25, 5000)
        ---@type SeaWorld
        local world = runtime.world
        ---@type SeaEntity
        local ship = runtime.ship
        ---@type OceanMovement
        local movement = runtime.movement
        local entities, byId = world.entities, world.byId
        local generation = runtime:GetFixedBarrel().generation
        local regions, behaviors, signals = runtime.initializedRegions, runtime.behaviors, runtime.surfaceSignals
        local time, worldTime = runtime.time, world.time
        local x, y, cx, cy = ship.position.x, ship.position.y, movement.camera.x, movement.camera.y
        local count, sequence = #entities, runtime.spawnSequence
        local playerMap, money, stamina = player.recognizedLocations, player.money, player.stamina
        local timer = signals.birdPollRemaining
        for _ = 1, 20 do
            assert(render(recorder, runtime, function(id) return player:IsRecognized(id) end) == 1)
        end
        assert(runtime.world == world and world.entities == entities and world.byId == byId)
        assert(runtime.ship == ship and runtime.movement == movement and #entities == count)
        assert(ship.position.x == x and ship.position.y == y and movement.camera.x == cx and movement.camera.y == cy)
        assert(runtime.time == time and world.time == worldTime and runtime.spawnSequence == sequence)
        assert(runtime.initializedRegions == regions and runtime.behaviors == behaviors and runtime.surfaceSignals == signals)
        assert(signals.birdPollRemaining == timer and runtime:GetFixedBarrel().generation == generation)
        assert(player.recognizedLocations == playerMap and player:IsRecognized(CONTENT_ID))
        assert(player.money == money and player.stamina == stamina)
    end)
    return { results = results, metrics = { outlineMeters = 80, recognitionMeters = 20,
        recognitionOwner = "real Gameplay.PlayerState", restore = "real Persistence.Restore (offline)",
        evidenceKind = "NanoVG recorder / render fixtures, not native gameplay" } }
end

return Tests
