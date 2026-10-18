-- Test-only lens key sources exercise capability without adding production content.
local Content = require "data.content"
local productionFixedCount = #Content.fixed

local KEY_ID = "fixture_lens_key"
local SOURCE_ID = "fixture_lens_key_source"
local MISSING_KIND_ID = "fixture_lens_key_missing_kind"
local MISSING_DURATION_ID = "fixture_lens_key_missing_duration"
local MISSING_STAMINA_ID = "fixture_lens_key_missing_stamina"

local function addFixture(contentId, action)
    Content.fixed[#Content.fixed + 1] = {
        contentId = contentId,
        entityType = "cache",
        kind = "fixed",
        position = { x = 0, y = 0 },
        radius = 0.5,
        layer = "surface",
        blocking = false,
        keySource = true,
        keyId = KEY_ID,
        revealMethod = "lens",
        markable = true,
        action = action,
    }
end

addFixture(SOURCE_ID, { kind = "fixture_take_key", duration = 2, staminaCost = 7 })
addFixture(MISSING_KIND_ID, { duration = 1, staminaCost = 0 })
addFixture(MISSING_DURATION_ID, { kind = "fixture_take_key", staminaCost = 0 })
addFixture(MISSING_STAMINA_ID, { kind = "fixture_take_key", duration = 1 })

local Player = require "Gameplay.PlayerState"
local Progress = require "Gameplay.WorldContentProgress"
local Actions = require "Gameplay.WorldContentActions"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function fixture(scopeById)
    local player = assert(Player.New())
    player.treasures.scopeLens = true
    local adapter = {
        context = {
            player = player,
            sessionGeneration = 1,
            runtimeIdentity = {},
            fixedContentGeneration = 1,
        },
        scopeById = scopeById or {},
    }
    function adapter:GetContext()
        return self.context
    end
    function adapter:GetWorldContentAccess(contentId)
        return {
            contentId = contentId,
            entityId = "fixture:" .. contentId,
            generation = self.context.fixedContentGeneration,
            surfaceGap = 0,
        }
    end
    function adapter:IsWorldContentInScope(contentId)
        return self.scopeById[contentId] == true
    end

    local actions, actionError = Actions.New(adapter)
    assert(actions, tostring(actionError))
    return { player = player, adapter = adapter, actions = actions }
end

local function markByLens(f)
    f.adapter.scopeById[SOURCE_ID] = true
    local ok, result = f.actions:Advance(1)
    eq(ok, true)
    eq(result, "idle")
end

function Tests.Run()
    local results = {}
    local names = {}
    local function test(name, run)
        assert(not names[name], "duplicate test name: " .. name)
        names[name] = true
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("production fixed content has no key source, key location, or key reward", function()
        eq(productionFixedCount, 3)
        for index = 1, productionFixedCount do
            local definition = Content.fixed[index]
            eq(definition.keySource, nil)
            eq(definition.keyId, nil)
            eq(definition.revealMethod, nil)
        end
    end)

    test("lens discovery does not mark at 0.99 seconds and Mark never grants a key", function()
        local f = fixture({ [SOURCE_ID] = true })
        local beforeStamina = f.player.stamina
        local advanced, result = f.actions:Advance(0.99)
        eq(advanced, true)
        eq(result, "idle")
        local state = assert(Progress.GetState(f.player, SOURCE_ID))
        eq(state.marked, false)
        eq(f.player.treasures.keys[KEY_ID], nil)
        local observation = f.actions:GetObservationState()
        eq(observation.contentId, SOURCE_ID)
        eq(observation.elapsed, 0.99)
        eq(observation.duration, 1)

        advanced, result = f.actions:Advance(0.01)
        eq(advanced, true)
        eq(result, "idle")
        state = assert(Progress.GetState(f.player, SOURCE_ID))
        eq(state.marked, true)
        eq(state.completed, nil)
        eq(state.rewardOwned, nil)
        eq(f.player.treasures.keys[KEY_ID], nil)
        eq(f.player.stamina, beforeStamina)
        assert(Progress.Validate(f.player))
    end)

    test("leaving lens scope clears the one-second observation timer", function()
        local f = fixture({ [SOURCE_ID] = true })
        f.actions:Advance(0.4)
        eq(f.actions:GetObservationState().elapsed, 0.4)

        f.adapter.scopeById[SOURCE_ID] = false
        local ok = f.actions:Advance(0.2)
        eq(ok, true)
        eq(f.actions:GetObservationState().elapsed, 0)
        eq(assert(Progress.GetState(f.player, SOURCE_ID)).marked, false)

        f.adapter.scopeById[SOURCE_ID] = true
        f.actions:Advance(0.99)
        eq(assert(Progress.GetState(f.player, SOURCE_ID)).marked, false)
        f.actions:Advance(0.01)
        eq(assert(Progress.GetState(f.player, SOURCE_ID)).marked, true)
        eq(f.player.treasures.keys[KEY_ID], nil)
    end)

    test("key source pickup requires Mark and explicit action metadata, then grants the key", function()
        local f = fixture()
        local beforeStamina = f.player.stamina
        local missingMark, missingMarkReason = f.actions:BeginKeySource(SOURCE_ID)
        eq(missingMark, nil)
        eq(missingMarkReason, "content_not_marked")
        eq(f.actions:GetActionState(), nil)

        markByLens(f)
        eq(f.player.treasures.keys[KEY_ID], nil)
        local token = assert(f.actions:BeginKeySource(SOURCE_ID))
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.actionKind, "fixture_take_key")
        eq(receipt.duration, 2)
        eq(receipt.staminaCost, 7)
        eq(receipt.status, "active")
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], nil)

        local advanced, result = f.actions:Advance(1.99)
        eq(advanced, true)
        eq(result, "active")
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], nil)
        advanced, result = f.actions:Advance(0.01)
        eq(advanced, true)
        eq(result, "completed")
        eq(f.player.stamina, beforeStamina - 7)
        eq(f.player.treasures.keys[KEY_ID], true)
        receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "completed")
        eq(receipt.commitState, "committed")
        eq(assert(Progress.GetState(f.player, SOURCE_ID)).marked, true)
        local duplicate, duplicateReason = f.actions:BeginKeySource(SOURCE_ID)
        eq(duplicate, nil)
        eq(duplicateReason, "key_already_owned")
    end)

    test("each missing action field is rejected without a default", function()
        local f = fixture()
        local beforeStamina = f.player.stamina
        local malformedIds = { MISSING_KIND_ID, MISSING_DURATION_ID, MISSING_STAMINA_ID }
        for _, contentId in ipairs(malformedIds) do
            local token, reason = f.actions:BeginKeySource(contentId)
            eq(token, nil, contentId .. " token")
            eq(reason, "invalid_action_config", contentId .. " reason")
        end
        eq(f.actions:GetActionState(), nil)
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], nil)
        local advanced = f.actions:Advance(1)
        eq(advanced, true)
        eq(f.actions:GetObservationState().elapsed, 0,
            "incomplete action metadata must not register a lens source")
    end)

    test("cancelling an explicit key action does not charge stamina or grant a key", function()
        local f = fixture()
        markByLens(f)
        local beforeStamina = f.player.stamina
        local token = assert(f.actions:BeginKeySource(SOURCE_ID))
        eq(f.actions:Advance(0.5), true)
        local cancelled, result = f.actions:Cancel(token)
        eq(cancelled, true)
        eq(result, "cancelled")
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], nil)
        eq(assert(f.actions:GetReceipt(token)).status, "cancelled")
    end)

    test("key grant failure uses the existing receipt rollback path", function()
        local f = fixture()
        markByLens(f)
        local beforeStamina = f.player.stamina
        local token = assert(f.actions:BeginKeySource(SOURCE_ID))
        local originalValidate = Progress.Validate
        Progress.Validate = function(player)
            if player.treasures.keys[KEY_ID] == true then
                return false, "injected_key_commit_failure"
            end
            return originalValidate(player)
        end
        local ok, reason = f.actions:Advance(2)
        Progress.Validate = originalValidate

        eq(ok, false)
        eq(reason, "injected_key_commit_failure")
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], nil)
        eq(assert(Progress.GetState(f.player, SOURCE_ID)).marked, true)
        assert(Progress.Validate(f.player))
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "failed")
        eq(receipt.commitState, "rolled_back")
        eq(receipt.rollback, "restored")
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
