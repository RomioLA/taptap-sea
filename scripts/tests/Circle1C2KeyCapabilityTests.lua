-- Key capability tests use test-only fixed content; production content remains unkeyed.
local Content = require "data.content"

local KEY_ID = "fixture_key_capability"
local CONSUME_ID = "fixture_keyed_treasure_consume"
local KEEP_ID = "fixture_keyed_treasure_keep"
local NO_POLICY_ID = "fixture_keyed_treasure_no_policy"

local function addKeyedFixture(contentId, consumeKey)
    local definition = {
        contentId = contentId,
        entityType = "treasure",
        kind = "fixed",
        position = { x = 0, y = 0 },
        radius = 0.5,
        layer = "underwater",
        blocking = false,
        actionKind = "salvage",
        rewardId = "fixture_reward_" .. contentId,
        markable = true,
        keyRequired = KEY_ID,
    }
    if consumeKey ~= nil then definition.consumeKey = consumeKey end
    Content.fixed[#Content.fixed + 1] = definition
end

addKeyedFixture(CONSUME_ID, true)
addKeyedFixture(KEEP_ID, false)
addKeyedFixture(NO_POLICY_ID, nil)

local Player = require "Gameplay.PlayerState"
local Persistence = require "Gameplay.Persistence"
local Progress = require "Gameplay.WorldContentProgress"
local Actions = require "Gameplay.WorldContentActions"

local Tests = {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "values differ") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function fixture(contentId, ownsKey)
    local player = assert(Player.New())
    if ownsKey then player.treasures.keys[KEY_ID] = true end

    local adapter = {
        context = {
            player = player,
            sessionGeneration = 1,
            runtimeIdentity = {},
            fixedContentGeneration = 1,
        },
    }
    function adapter:GetContext()
        return self.context
    end
    function adapter:GetWorldContentAccess(id)
        return {
            contentId = id,
            entityId = "fixture:" .. id,
            generation = self.context.fixedContentGeneration,
            surfaceGap = 0,
        }
    end
    function adapter:IsWorldContentInScope()
        return false
    end

    local actions, actionError = Actions.New(adapter)
    assert(actions, tostring(actionError))
    local marked, markError = Progress.Mark(player, contentId)
    assert(marked, tostring(markError))
    return { player = player, actions = actions, contentId = contentId }
end

local function withPostCommitValidationFailure(run)
    local originalCommit, originalValidate = Progress.Commit, Progress.Validate
    local commitReturned = false
    Progress.Commit = function(player, contentId)
        local ok, reason = originalCommit(player, contentId)
        if ok then commitReturned = true end
        return ok, reason
    end
    Progress.Validate = function(player)
        if commitReturned then return false, "injected_validation_failure" end
        return originalValidate(player)
    end
    local ok, err = xpcall(run, debug.traceback)
    Progress.Commit, Progress.Validate = originalCommit, originalValidate
    if not ok then error(err, 0) end
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

    test("missing required key rejects before starting salvage or changing progress", function()
        local f = fixture(CONSUME_ID, false)
        local beforeStamina = f.player.stamina
        local before = assert(Progress.GetState(f.player, CONSUME_ID))
        local token, reason = f.actions:BeginSalvage(CONSUME_ID)
        eq(token, nil)
        eq(reason, "missing_key")
        eq(f.player.stamina, beforeStamina)
        local after = assert(Progress.GetState(f.player, CONSUME_ID))
        eq(after.marked, before.marked)
        eq(after.completed, before.completed)
        eq(after.rewardOwned, before.rewardOwned)
        eq(f.actions:GetActionState(), nil)
    end)

    test("key consumption waits for successful commit and follows consumeKey true", function()
        local f = fixture(CONSUME_ID, true)
        local beforeStamina = f.player.stamina
        local token = assert(f.actions:BeginSalvage(CONSUME_ID))
        eq(f.player.treasures.keys[KEY_ID], true, "begin must not consume key")
        local ok, result = f.actions:Advance(4)
        eq(ok, true)
        eq(result, "completed")
        eq(f.player.stamina, beforeStamina - 40)
        eq(f.player.treasures.keys[KEY_ID], false)
        eq(assert(Progress.GetState(f.player, CONSUME_ID)).completed, true)
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "completed")
        eq(receipt.commitState, "committed")
    end)

    test("consumeKey false retains the key after successful commit", function()
        local f = fixture(KEEP_ID, true)
        local token = assert(f.actions:BeginSalvage(KEEP_ID))
        local ok, result = f.actions:Advance(4)
        eq(ok, true)
        eq(result, "completed")
        eq(f.player.treasures.keys[KEY_ID], true)
        eq(assert(f.actions:GetReceipt(token)).commitState, "committed")
    end)

    test("cancelling keyed salvage leaves key and stamina untouched", function()
        local f = fixture(CONSUME_ID, true)
        local beforeStamina = f.player.stamina
        local token = assert(f.actions:BeginSalvage(CONSUME_ID))
        local cancelled, result = f.actions:Cancel(token)
        eq(cancelled, true)
        eq(result, "cancelled")
        eq(f.player.treasures.keys[KEY_ID], true)
        eq(f.player.stamina, beforeStamina)
        eq(assert(f.actions:GetReceipt(token)).status, "cancelled")
    end)

    test("post-consumption commit failure restores key with the existing receipt rollback", function()
        local f = fixture(CONSUME_ID, true)
        local beforeStamina = f.player.stamina
        local token = assert(f.actions:BeginSalvage(CONSUME_ID))
        withPostCommitValidationFailure(function()
            local ok, reason = f.actions:Advance(4)
            eq(ok, false)
            eq(reason, "injected_validation_failure")
        end)
        local receipt = assert(f.actions:GetReceipt(token))
        eq(receipt.status, "failed")
        eq(receipt.commitState, "rolled_back")
        eq(receipt.rollback, "restored")
        eq(f.player.treasures.keys[KEY_ID], true)
        eq(f.player.stamina, beforeStamina)
        local state = assert(Progress.GetState(f.player, CONSUME_ID))
        eq(state.completed, false)
        eq(state.rewardOwned, false)
        assert(Progress.Validate(f.player))
    end)

    test("keyed content without explicit consumeKey policy is rejected", function()
        local f = fixture(NO_POLICY_ID, true)
        local beforeStamina = f.player.stamina
        local token, reason = f.actions:BeginSalvage(NO_POLICY_ID)
        eq(token, nil)
        eq(reason, "invalid_key_config")
        eq(f.player.stamina, beforeStamina)
        eq(f.player.treasures.keys[KEY_ID], true)
        eq(f.actions:GetActionState(), nil)
    end)

    test("existing underwater treasure remains salvageable without a key", function()
        local f = fixture("underwater_treasure_01", false)
        local token = assert(f.actions:BeginSalvage("underwater_treasure_01"))
        local ok, result = f.actions:Advance(4)
        eq(ok, true)
        eq(result, "completed")
        eq(f.player.treasures.keys[KEY_ID], nil)
        eq(assert(f.actions:GetReceipt(token)).status, "completed")
    end)

    test("key ownership snapshots, restores, validates, and migrates old saves", function()
        local player = assert(Player.New())
        eq(type(player.treasures.keys), "table")
        player.treasures.keys[KEY_ID] = true
        local snapshot = Persistence.Snapshot(player)
        eq(snapshot.treasures.keys[KEY_ID], true)
        local restored = assert(Persistence.Restore(snapshot))
        eq(restored.treasures.keys[KEY_ID], true)

        local legacy = {}
        for key, value in pairs(snapshot) do legacy[key] = value end
        legacy.treasures = {}
        for key, value in pairs(snapshot.treasures) do legacy.treasures[key] = value end
        legacy.treasures.keys = nil
        local migrated = assert(Persistence.Restore(legacy))
        eq(type(migrated.treasures.keys), "table")
        eq(next(migrated.treasures.keys), nil)
        eq(legacy.treasures.keys, nil, "Restore must not mutate the input save")

        local invalid = {}
        for key, value in pairs(snapshot) do invalid[key] = value end
        invalid.treasures = {}
        for key, value in pairs(snapshot.treasures) do invalid.treasures[key] = value end
        invalid.treasures.keys = { [KEY_ID] = "owned" }
        local invalidPlayer = Persistence.Restore(invalid)
        eq(invalidPlayer, nil, "Restore must reject non-boolean key ownership")

        local malformedPlayer = assert(Player.New())
        malformedPlayer.treasures.keys[KEY_ID] = "owned"
        local snapshotOk = pcall(Persistence.Snapshot, malformedPlayer)
        eq(snapshotOk, false, "Snapshot must reject malformed key ownership")

        local legacyPlayer = assert(Player.New())
        legacyPlayer.treasures = { found = true }
        local migratedSnapshot = Persistence.Snapshot(legacyPlayer)
        eq(type(migratedSnapshot.treasures.keys), "table")
        eq(type(legacyPlayer.treasures.keys), "table")
        eq(next(migratedSnapshot.treasures.keys), nil)
    end)

    test("PlayerState reset used by NewRun clears key ownership", function()
        local player = assert(Player.New())
        player.treasures.keys[KEY_ID] = true
        local reset, resetError = player:Reset()
        assert(reset, tostring(resetError))
        eq(type(player.treasures.keys), "table")
        eq(next(player.treasures.keys), nil)

        player.treasures.keys[KEY_ID] = true
        local freshRunPlayer = assert(Player.New())
        eq(type(freshRunPlayer.treasures.keys), "table")
        eq(next(freshRunPlayer.treasures.keys), nil)
    end)

    local passed = 0
    for _, result in ipairs(results) do
        if result.passed then passed = passed + 1 end
    end
    return { results = results, passed = passed, total = #results }
end

return Tests
