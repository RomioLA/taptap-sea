-- Phase 1 emergence regressions. World positions remain authored in data.content.
local Content = require "data.content"
local Config = require "Ocean.Config"
local World = require "Ocean.World"
local Runtime = require "Ocean.SeaRuntime"
local Bridge = require "Integration.Bridge"
local EvidenceSystem = require "Gameplay.EvidenceSystem"
local PlayerState = require "Gameplay.PlayerState"
local Persistence = require "Gameplay.Persistence"
local WorldContentProgress = require "Gameplay.WorldContentProgress"
local SeaDraw = require "Ocean.SeaDraw"
local KnowledgeSystem = require "Gameplay.KnowledgeSystem"

local Tests = {}

local EXPECTED = {
    { contentId = "island_01", entityType = "island", kind = "fixed", x = 35, y = 25,
        radius = 12, layer = "surface", blocking = true, actionKind = "explore",
        rewardId = "memory_island_01", markable = false },
    { contentId = "island_02", entityType = "island", kind = "fixed", x = -80, y = 90,
        radius = 20, layer = "surface", blocking = true, actionKind = "explore",
        rewardId = "memory_island_02", markable = false },
    { contentId = "underwater_treasure_01", entityType = "treasure", kind = "fixed", x = 35, y = 45,
        radius = 0.5, layer = "underwater", blocking = false, actionKind = "salvage",
        rewardId = "memory_treasure_01", markable = true },
}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value mismatch") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function fixedPositions(runtime)
    local result = {}
    for _, expected in ipairs(EXPECTED) do
        local content = assert(runtime:GetWorldContent(expected.contentId), expected.contentId)
        result[expected.contentId] = { x = content.position.x, y = content.position.y }
    end
    return result
end

local function assertPositions(actual, expected, label)
    for _, item in ipairs(EXPECTED) do
        local a, e = assert(actual[item.contentId]), assert(expected[item.contentId])
        eq(a.x, e.x, label .. " " .. item.contentId .. ".x")
        eq(a.y, e.y, label .. " " .. item.contentId .. ".y")
    end
end

local function newEvidencePlayer()
    local player = assert(PlayerState.New())
    local initialized, reason = EvidenceSystem.ResetRun(player)
    assert(initialized, tostring(reason))
    return player
end

local function knowledgeDouble()
    local knowledge = { calls = {}, known = {} }
    function knowledge:Grant(id)
        self.calls[id] = (self.calls[id] or 0) + 1
        self.known[id] = true
        return true
    end
    function knowledge:HasKnowledge(id)
        return self.known[id] == true
    end
    return knowledge
end

local function observation(day, bearing, generation, overrides)
    local event = {
        type = "observation_recorded",
        traceId = "flock_commute",
        traceType = "flock_commute",
        sourceContentId = "island_02",
        birdCount = 3,
        dives = false,
        circlesFish = false,
        day = day,
        bearing = bearing,
        observable = true,
        generation = generation,
    }
    for key, value in pairs(overrides or {}) do event[key] = value end
    return event
end

local function recordObservation(player, knowledge, day, bearing, generation, event)
    player.day = day
    return EvidenceSystem.RecordObservation(player,
        event or observation(day, bearing, generation), knowledge,
        { day = day, generation = generation })
end

function Tests.Run()
    local results, names = {}, {}
    local function test(name, run)
        assert(not names[name], "duplicate test name: " .. name)
        names[name] = true
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("T01 fixed content migration preserves all V25 fields", function()
        eq(#Content.fixed, #EXPECTED, "production fixed content count")
        local seaWorld = World.New()
        for index, expected in ipairs(EXPECTED) do
            local definition = Content.fixed[index]
            eq(definition.contentId, expected.contentId)
            eq(definition.entityType, expected.entityType)
            eq(definition.kind, expected.kind)
            eq(definition.position.x, expected.x)
            eq(definition.position.y, expected.y)
            eq(definition.radius, expected.radius)
            eq(definition.layer, expected.layer)
            eq(definition.blocking, expected.blocking)
            eq(definition.actionKind, expected.actionKind)
            eq(definition.rewardId, expected.rewardId)
            eq(definition.markable, expected.markable)

            local entity = assert(seaWorld.fixedContentEntities[expected.contentId])
            eq(entity.contentId, definition.contentId)
            eq(entity.entityType, definition.entityType)
            eq(entity.kind, definition.kind)
            eq(entity.position.x, expected.x)
            eq(entity.position.y, expected.y)
            eq(entity.radius, expected.radius)
            eq(entity.layer, expected.layer)
            eq(entity.blocking, expected.blocking)
        end
        eq(Config.world.fixedObjects[1], Content.fixed[1], "island compatibility view 1")
        eq(Config.world.fixedObjects[2], Content.fixed[2], "island compatibility view 2")
        eq(Config.world.fixedTreasure, Content.fixed[3], "treasure compatibility view")
        eq(Content.fixed[3].tuningStatus, "V25_INTEGRATION_PLAYTEST_GEOMETRY")
    end)

    test("T02 five NewRun cycles keep all authored positions unchanged", function()
        local runtime = Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = true,
            daySeed = 314159 })
        local saves = {}
        local store = {}
        function store:Save(snapshot, done)
            saves[#saves + 1] = snapshot
            if done then done(true) end
        end
        function store:Load(done)
            if done then done(false, "no_save") end
        end
        local bridge = Bridge.New(runtime, { store = store })
        bridge:Sync()
        local original = fixedPositions(runtime)
        for run = 1, 5 do
            local ok, reason = bridge:NewRun()
            assert(ok, tostring(reason or "NewRun failed"))
            assertPositions(fixedPositions(runtime), original, "NewRun " .. run)
        end
    end)

    test("T03 NewRun clears world progress and hypothesis evidence without moving fixed content", function()
        local runtime = Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = true,
            daySeed = 314159 })
        local store = {}
        function store:Save(_, done) if done then done(true) end end
        function store:Load(done) if done then done(false, "no_save") end end
        local bridge = Bridge.New(runtime, { store = store })
        bridge:Sync()
        local loop = bridge.loop
        assert(WorldContentProgress.Commit(loop.player, "island_01"))
        assert(WorldContentProgress.Mark(loop.player, "underwater_treasure_01"))
        local knowledge = knowledgeDouble()
        assert(recordObservation(loop.player, knowledge, 1, 20, runtime:GetFixedContentGeneration()))
        assert(recordObservation(loop.player, knowledge, 2, 22, runtime:GetFixedContentGeneration()))
        local original = fixedPositions(runtime)
        local ok, reason = bridge:NewRun()
        assert(ok, tostring(reason or "NewRun failed"))
        assertPositions(fixedPositions(runtime), original, "progress reset")
        local island = assert(WorldContentProgress.GetState(bridge.loop.player, "island_01"))
        local treasure = assert(WorldContentProgress.GetState(bridge.loop.player, "underwater_treasure_01"))
        eq(island.completed, false)
        eq(treasure.marked, false)
        local hypothesis = assert(EvidenceSystem.GetState(bridge.loop.player, "H-isle-bearing-01"))
        eq(hypothesis.distinctDays, 0)
        eq(hypothesis.confirmed, false)
    end)

    test("T05 SurfaceSignals fishing birds cannot enter the island hypothesis", function()
        local player, knowledge = newEvidencePlayer(), knowledgeDouble()
        player.day = 1
        local fishingBird = observation(1, 45, 7, {
            traceId = "surface_signals_bird", traceType = "fish_bird",
            sourceContentId = nil,
        })
        local accepted, reason = EvidenceSystem.RecordObservation(player, fishingBird, knowledge,
            { day = 1, generation = 7 })
        eq(accepted, false)
        eq(reason, "invalid_evidence")
        eq(assert(EvidenceSystem.GetState(player, "H-isle-bearing-01")).distinctDays, 0)
    end)

    test("T06 ten same-day observations count as one distinct day", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        local lastStatus
        for _ = 1, 10 do
            local accepted, status = recordObservation(player, knowledge, 1, 25, generation)
            assert(accepted)
            lastStatus = status
        end
        eq(lastStatus, "duplicate_day")
        eq(assert(EvidenceSystem.GetState(player, "H-isle-bearing-01")).distinctDays, 1)
        eq(knowledge.calls["K-isl-1"] or 0, 0)
    end)

    test("T07 three authoritative game days can satisfy the evidence count", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        local state
        for day, bearing in ipairs({ 10, 12, 15 }) do
            local accepted, status, current = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
            state = current
            if day < 3 then eq(status, "recorded") end
        end
        eq(state.distinctDays, 3)
        eq(state.confirmed, true)
        eq(knowledge.calls["K-isl-1"], 1)
    end)

    test("three self-reported event dates cannot replace the current player day", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        for day = 2, 3 do
            player.day = 1
            local accepted = EvidenceSystem.RecordObservation(player,
                observation(day, 10, generation), knowledge,
                { day = day, generation = generation })
            eq(accepted, false)
        end
        eq(assert(EvidenceSystem.GetState(player, "H-isle-bearing-01")).distinctDays, 0)
    end)

    test("stale World generation and unavailable recognition state are rejected", function()
        local player, knowledge = newEvidencePlayer(), knowledgeDouble()
        player.day = 1
        local accepted = EvidenceSystem.RecordObservation(player, observation(1, 10, 6), knowledge,
            { day = 1, generation = 7 })
        eq(accepted, false)
        local noRecognition = { day = 1, story = {} }
        accepted = EvidenceSystem.RecordObservation(noRecognition, observation(1, 10, 7), knowledge,
            { day = 1, generation = 7 })
        eq(accepted, false)
        eq(assert(EvidenceSystem.GetState(player, "H-isle-bearing-01")).distinctDays, 0)
    end)

    test("T08 bearing spread above 30 degrees does not confirm", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        for day, bearing in ipairs({ 0, 120, 240 }) do
            local accepted = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
        end
        local state = assert(EvidenceSystem.GetState(player, "H-isle-bearing-01"))
        eq(state.distinctDays, 3)
        eq(state.bearingSpreadDeg > 30, true)
        eq(state.confirmed, false)
        eq(knowledge.calls["K-isl-1"] or 0, 0)
    end)

    test("T09 circular bearing spread at 30 degrees confirms and grants once", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        local state
        for day, bearing in ipairs({ 350, 5, 20 }) do
            local accepted, _, current = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
            state = current
        end
        eq(state.bearingSpreadDeg, 30)
        eq(state.confirmed, true)
        local accepted, status = recordObservation(player, knowledge, 3, 20, generation)
        assert(accepted)
        eq(status, "already_confirmed")
        eq(knowledge.calls["K-isl-1"], 1)
    end)

    test("EvidenceSystem grants the production K-isl-1 knowledge entry exactly once", function()
        local profile = { knowledgeLog = {} }
        function profile:RecordKnowledge(id, week) self.knowledgeLog[id] = week; return true end
        function profile:HasKnowledge(id) return self.knowledgeLog[id] ~= nil end
        local knowledge = KnowledgeSystem.New({ data = require "data.knowledge", profile = profile,
            currentWeek = 2 })
        eq(knowledge:HasKnowledge("K-isl-1"), false)
        local player, generation = newEvidencePlayer(), 7
        for day, bearing in ipairs({ 350, 5, 20 }) do
            local accepted = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
        end
        eq(knowledge:IsGranted("K-isl-1"), true)
        eq(knowledge:HasKnowledge("K-isl-1"), true)
        eq(profile.knowledgeLog["K-isl-1"], 2)
        local entry = knowledge._debug.entries["K-isl-1"]
        eq(entry.domain, "island")
        eq(entry.entry.desc, "这些鸟总朝着相近的方向飞，也许那边有陆地。")
    end)

    test("T10 confirmation grants only K-isl-1 and leaves World/island/player rewards unchanged", function()
        local runtime = Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = false })
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), runtime:GetFixedContentGeneration()
        local originalIsland = assert(runtime:GetWorldContent("island_02"))
        local entityCount, money = #runtime.world.entities, player.money
        local savedTreasures = {}
        for key, value in pairs(player.treasures) do savedTreasures[key] = value end
        local savedInventory = player.inventory:GetItems()
        for day, bearing in ipairs({ 350, 5, 20 }) do
            local accepted = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
        end
        eq(knowledge.calls["K-isl-1"], 1)
        eq(#runtime.world.entities, entityCount)
        local island = assert(runtime:GetWorldContent("island_02"))
        eq(island.position.x, originalIsland.position.x)
        eq(island.position.y, originalIsland.position.y)
        eq(player:IsRecognized("island_02"), false)
        eq(player.money, money)
        for key, value in pairs(savedTreasures) do eq(player.treasures[key], value) end
        local currentInventory = player.inventory:GetItems()
        eq(#currentInventory, #savedInventory)
        for index, itemId in ipairs(savedInventory) do eq(currentInventory[index], itemId) end
    end)

    test("T11 EvidenceSystem and save/load preserve confirmed hypothesis evidence", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        for day, bearing in ipairs({ 350, 5, 20 }) do
            local accepted = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
        end
        local evidenceSnapshot = assert(EvidenceSystem.Snapshot(player))
        local clone = newEvidencePlayer()
        assert(EvidenceSystem.Restore(clone, evidenceSnapshot))
        local restoredEvidence = assert(EvidenceSystem.GetState(clone, "H-isle-bearing-01"))
        eq(restoredEvidence.distinctDays, 3)
        eq(restoredEvidence.confirmed, true)

        local save = Persistence.Snapshot(player)
        local restored = assert(Persistence.Restore(save))
        assert(EvidenceSystem.Initialize(restored))
        local state = assert(EvidenceSystem.GetState(restored, "H-isle-bearing-01"))
        eq(state.distinctDays, 3)
        eq(state.confirmed, true)

        local corrupted = Persistence.Snapshot(player)
        corrupted.story.hypotheses["H-isle-bearing-01"].evidenceByDay["2"] = 120
        local rejected, reason = Persistence.Restore(corrupted)
        eq(rejected, nil)
        eq(reason, "invalid_confirmed_hypothesis")

        local oldSave = Persistence.Snapshot(player)
        oldSave.story.hypotheses = nil
        local oldRestored = assert(Persistence.Restore(oldSave))
        eq(oldRestored.story.hypotheses, nil, "older saves need no hypothesis migration write")
        eq(assert(EvidenceSystem.GetState(oldRestored, "H-isle-bearing-01")).distinctDays, 0)
    end)

    test("T12 NewRun reset clears hypothesis progress", function()
        local player, knowledge, generation = newEvidencePlayer(), knowledgeDouble(), 7
        for day, bearing in ipairs({ 10, 12 }) do
            local accepted = recordObservation(player, knowledge, day, bearing, generation)
            assert(accepted)
        end
        assert(EvidenceSystem.ResetRun(player))
        local state = assert(EvidenceSystem.GetState(player, "H-isle-bearing-01"))
        eq(state.distinctDays, 0)
        eq(state.confirmed, false)
    end)

    test("Loop records live World observations once per day and grants the confirmed hint", function()
        local runtime = Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = false })
        runtime.movement:SetViewport(1280, 720)
        local store = {}
        function store:Save(_, done) if done then done(true) end end
        function store:Load(done) if done then done(false, "no_save") end end
        local bridge = Bridge.New(runtime, { store = store })
        bridge:Sync()
        local loop = bridge.loop
        loop.inPort = false
        loop.clock:Resume("port")

        local function observe(day, position)
            loop.player.day = day
            runtime.movement:ResetAtPosition(position)
            assert(loop:ProcessEmergenceEvents(true))
            return assert(EvidenceSystem.GetState(loop.player, "H-isle-bearing-01"))
        end

        local first = observe(1, { x = -20, y = -20 })
        eq(first.distinctDays, 1)
        local repeated = observe(1, { x = -20, y = -20 })
        eq(repeated.distinctDays, 1)
        local second = observe(2, { x = 0, y = -20 })
        eq(second.distinctDays, 2)
        local confirmed = observe(3, { x = -40, y = -20 })
        eq(confirmed.distinctDays, 3)
        eq(confirmed.confirmed, true)
        eq(loop.lastMessage, "这些鸟总朝着相近的方向飞，也许那边有陆地。")
        eq(loop.knowledge:HasKnowledge("K-isl-1"), true)
        eq(#runtime.world.pendingEvents, 0)
        eq(confirmed.evidenceByDay["1"] ~= confirmed.evidenceByDay["2"], true)
        eq(confirmed.evidenceByDay["2"] ~= confirmed.evidenceByDay["3"], true)

        loop.player.recognizedLocations.island_02 = true
        local afterRecognition = observe(4, { x = -30, y = -20 })
        eq(afterRecognition.distinctDays, 3)
    end)

    test("World event queue is FIFO, bounded to 256, drained, and generation isolated", function()
        local world = World.New()
        local diagnostics = {}
        world.onDiagnostic = function(_, name, details)
            diagnostics[#diagnostics + 1] = { name = name, details = details }
        end
        for index = 1, 257 do
            local ok, reason = world:Emit({ type = "trace_expired", index = index })
            assert(ok, tostring(reason))
        end
        eq(#world.pendingEvents, 256)
        eq(#diagnostics, 1)
        eq(diagnostics[1].name, "world_event_queue_overflow")
        eq(diagnostics[1].details.limit, 256)
        local drained = world:DrainEvents()
        eq(#drained, 256)
        eq(drained[1].index, 2)
        eq(drained[256].index, 257)
        eq(#world.pendingEvents, 0)
        eq(#world:DrainEvents(), 0)

        local generation = world.fixedContentGeneration
        local staleOk, staleReason = world:Emit({ type = "observation_recorded", generation = generation - 1 })
        eq(staleOk, false)
        eq(staleReason, "stale_generation")
        local invalidOk, invalidReason = world:Emit({ type = "unapproved_event" })
        eq(invalidOk, false)
        eq(invalidReason, "invalid_event_type")
    end)

    test("T04 flock_commute is a three-bird trace and does not spawn or move an island", function()
        local runtime = Runtime.New({ departure = { x = -20, y = -20 }, initializeRegions = false })
        local world = runtime.world
        local beforeCount, beforeIslandCount = #world.entities, 0
        local originalIsland = assert(runtime:GetWorldContent("island_02"))
        for _, entity in ipairs(world.entities) do
            if not entity.removed and entity.entityType == "island" then beforeIslandCount = beforeIslandCount + 1 end
        end
        world:Update(0.05, "simulation")
        local trace = assert(runtime:GetTrace("flock_commute"))
        eq(trace.traceType, "flock_commute")
        eq(trace.sourceContentId, "island_02")
        eq(trace.birdCount, 3)
        eq(trace.dives, false)
        eq(trace.circlesFish, false)
        local afterIslandCount = 0
        for _, entity in ipairs(world.entities) do
            if not entity.removed and entity.entityType == "island" then afterIslandCount = afterIslandCount + 1 end
        end
        eq(#world.entities, beforeCount, "trace does not add World entities")
        eq(afterIslandCount, beforeIslandCount, "trace does not add islands")
        local currentIsland = assert(runtime:GetWorldContent("island_02"))
        eq(currentIsland.position.x, originalIsland.position.x)
        eq(currentIsland.position.y, originalIsland.position.y)

        local event = assert(runtime:BuildTraceObservation("flock_commute", 1, false))
        eq(event.type, "observation_recorded")
        eq(event.traceType, "flock_commute")
        eq(event.sourceContentId, "island_02")
        local expectedBearing = math.deg(math.atan(originalIsland.position.y + 20,
            originalIsland.position.x + 20)) % 360
        eq(math.abs(event.bearing - expectedBearing) < 0.000001, true, "bearing points ship -> island center")

        runtime.movement:ResetAtPosition({ x = 0, y = -20 })
        local secondEvent = assert(runtime:BuildTraceObservation("flock_commute", 2, false))
        local secondExpected = math.deg(math.atan(originalIsland.position.y + 20,
            originalIsland.position.x)) % 360
        eq(math.abs(secondEvent.bearing - secondExpected) < 0.000001, true,
            "bearing is recomputed from the current ship position")
        eq(secondEvent.bearing ~= event.bearing, true)

        runtime.movement:SetViewport(1280, 720)
        local layout = assert(SeaDraw.BuildCommuterFlockLayout(runtime, 1280, 720,
            function(contentId) return contentId == "island_02" and false end))
        eq(#layout.birds, 3)
        eq(layout.bearingRadians, math.atan(originalIsland.position.y + 20, originalIsland.position.x))
        for _, bird in ipairs(layout.birds) do
            eq(bird.x >= 0 and bird.x <= 1280, true)
            eq(bird.y >= 0 and bird.y <= 720, true)
        end
        runtime.time = 2.5
        local laterLayout = assert(SeaDraw.BuildCommuterFlockLayout(runtime, 1280, 720,
            function() return false end))
        local firstCenterX, firstCenterY, laterCenterX, laterCenterY = 0, 0, 0, 0
        for index = 1, 3 do
            firstCenterX = firstCenterX + layout.birds[index].x / 3
            firstCenterY = firstCenterY + layout.birds[index].y / 3
            laterCenterX = laterCenterX + laterLayout.birds[index].x / 3
            laterCenterY = laterCenterY + laterLayout.birds[index].y / 3
        end
        local flown = (laterCenterX - firstCenterX) * layout.screenDirection.x
            + (laterCenterY - firstCenterY) * layout.screenDirection.y
        eq(flown > 0, true, "flock advances along the current island bearing")
        eq(SeaDraw.BuildCommuterFlockLayout(runtime, 1280, 720,
            function() return true end), nil, "recognized island hides the search cue")
        runtime.movement:ResetAtPosition({ x = -80, y = 70 })
        eq(runtime:BuildTraceObservation("flock_commute", 2, false), nil,
            "formal recognition distance suppresses the evidence cue")
        eq(SeaDraw.BuildCommuterFlockLayout(runtime, 1280, 720,
            function() return false end), nil, "formal recognition distance hides the screen-edge flock")
        local recognized, recognizedReason = runtime:BuildTraceObservation("flock_commute", 1, true)
        eq(recognized, nil)
        eq(recognizedReason, "already_recognized")
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
