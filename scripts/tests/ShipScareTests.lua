-- V2.2 movement threats and regional fish availability, using real sea modules.
local Runtime = require("Ocean.SeaRuntime")
local Config = require("Ocean.Config")
local Data = require("Ocean.FishData")
local M = require("Ocean.Math")
local Tests = {}

local function fresh()
    return Runtime.New({ initializeRegions = false, departure = { x = -300, y = -300 } })
end

function Tests.Run()
    local results = {}
    local function check(name, fn)
        local ok, reason = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = not ok and tostring(reason) or nil }
    end
    check("actual movement frightens small fish; stopping restores bait attraction", function()
        -- 2026-10-20：鱼感知按 Fish.perceptionIntervalSec = 0.2s 节流（S1-d 卡顿优化，
        -- 见 Ocean/Fish.lua 顶部注释；契约由 Circle1B5FishPerceptionTests 守护）。
        -- 旧断言要求“移动后下一帧就 Flee / 停下后下一帧就 Attracted”，
        -- 那是节流引入前的帧级语义，与当前正式实现冲突。
        -- 这里改为在节流窗口内推进，验证真实玩家观感：
        --   持续移动 → 0.2s 内一定 Flee（威胁优先于诱饵）；
        --   停下 → 下一个感知窗口内回到 Attracted（无持久记忆的延迟惩罚）。
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -292, y = -298 })
        assert(r:spawnDroppedItem({ itemId = "bait", worldEffect = "ATTRACT_SMALL_FISH" }, fish.position))
        r:Update(0.05, 0, 0)
        assert(not r.ship.isMoving and fish.state == "Attracted")

        -- 保持移动直到感知刷新（最多 0.25s，> 0.2s 间隔）。
        local fled = false
        for _ = 1, 5 do
            r:Update(0.05, 1, 0)
            assert(r.ship.isMoving)
            if fish.state == "Flee" then fled = true; break end
        end
        assert(fled, "movement threat must outrank bait within one perception interval")

        -- 停止后同样只需一个感知窗口就恢复诱饵吸引（没有额外的恢复延迟）。
        local recovered = false
        for _ = 1, 5 do
            r:Update(0.05, 0, 0)
            assert(not r.ship.isMoving)
            if fish.state == "Attracted" then recovered = true; break end
        end
        assert(recovered, "stopping must restore bait attraction within one perception interval")
    end)
    check("movement threat uses existing inclusive danger radius without frightening tuna", function()
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -300 + Data.sardine.dangerRadius, y = -300 })
        local behavior = r.behaviors[fish.id]
        r.ship.isMoving = true
        assert(behavior:_findDanger() == r.ship)
        fish.position.x = fish.position.x + 0.001
        assert(behavior:_findDanger() == nil)
        local tuna = r:spawnFish("tuna", { x = -295, y = -300 })
        assert(r.behaviors[tuna.id]:_findDanger() == nil)
        r.ship.isMoving = false
        fish.position = { x = -294, y = -300 }
        assert(behavior:_findDanger() == tuna, "stopping does not remove nearby tuna danger")
    end)
    check("input without displacement is not a threat; reset clears movement state", function()
        local r = fresh()
        r.movement:SetSpeed(0)
        r:Update(0.05, 1, 0)
        assert(not r.ship.isMoving)
        r.movement:SetSpeed(Config.ship.speed)
        r:Update(0.05, 1, 0)
        assert(r.ship.isMoving)
        r.movement:ResetAtPosition({ x = -300, y = -300 })
        assert(not r.ship.isMoving)
        r.movement:SetTarget({ x = -300, y = -300 })
        r:Update(0.05)
        assert(not r.ship.isMoving and r.movement.target == nil)
    end)
    check("pause freezes fish and translation; capture lock remains stronger than threats", function()
        local r = fresh()
        local fish = r:spawnFish("sardine", { x = -292, y = -298 })
        local owner = {}
        assert(r:LockFishingTarget(fish.id, owner))
        local position, state = M.copy(fish.position), fish.state
        r:Update(0.05, 1, 0)
        assert(r.ship.isMoving and M.distanceSquared(position, fish.position) == 0 and fish.state == state)
        r.paused = true
        local time, shipPosition = r.time, M.copy(r.ship.position)
        r:Update(1, 1, 0)
        assert(r.time == time and M.distanceSquared(shipPosition, r.ship.position) == 0)
        r.paused = false
        assert(r:UnlockFishingTarget(fish.id, owner))
        r:Update(0.05, 0, 0)
        assert(not r.ship.isMoving and fish.state ~= "Flee")
    end)
    check("new regions generate fish, revisits preserve depletion, next day regenerates", function()
        local r = Runtime.New()
        local firstCount = r.world:getCounts().total
        local regions = 0
        for _ in pairs(r.initializedRegions) do regions = regions + 1 end
        r.movement:ResetAtPosition({ x = 400, y = 400 })
        r:ensureNearbyRegions()
        local newRegions = 0
        for _ in pairs(r.initializedRegions) do newRegions = newRegions + 1 end
        assert(newRegions > regions and r.world:getCounts().total > firstCount)
        r:clearOrdinaryFish()
        local depleted = r.world:getCounts().total
        r.movement:ResetAtPosition(Config.ship.start)
        r:ensureNearbyRegions()
        r.movement:ResetAtPosition({ x = 400, y = 400 })
        r:ensureNearbyRegions()
        assert(r.world:getCounts().total == depleted, "revisiting must not refill caught fish")
        r:refreshOrdinaryFish(r.daySeed + 1, Config.ship.start)
        assert(r.world:getCounts().total > depleted, "new day repopulates nearby regions")
    end)
    return { results = results }
end
return Tests
