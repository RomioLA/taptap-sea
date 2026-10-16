-- S1-d 守护：感知查询节流契约（2026-10-16 捕鱼卡顿优化）。
-- 背景：queryEntitiesInRadius 是全表扫描，每条 active 鱼每帧 2 次全表是主要稳态成本。
-- 契约：
--   1) 默认 interval=0.2：0.2s 内每条鱼的全表感知查询 ≤2 次（到期刷新一次）
--   2) interval=0（测试注入）：恢复帧级即时感知，每帧 1 次查询
--   3) 节流不破坏行为：威胁出现后 ≤0.25s 内必须进入 Flee
--   4) 缓存防护：威胁被移除后不得继续 Flee（已移除引用不参与决策）
--   5) spawnFish(deferActivity=true)：批量生成不逐条刷新活跃度（区域生成 O(N²) 根因防护）
local Tests = {}
local Runtime = require("Ocean.SeaRuntime")
local Fish = require("Ocean.Fish")
local Strategy = require("Ocean.SpawnStrategy")
local FishData = require("Ocean.FishData")
local Math = require("Ocean.Math")

local function freshBehaviorPair()
    -- departure 放在鱼群旁边：激活半径 120m 内鱼才会 active（Fish:Update 的门）
    local runtime = Runtime.New({ initializeRegions = false, departure = { x = 200, y = 0 } })
    local sardine = runtime:spawnFish("sardine", { x = 200, y = 0 }, 0)
    local tuna = runtime:spawnFish("tuna", { x = 206, y = 0 }, 0)
    return runtime, sardine, tuna, runtime.behaviors[sardine.id]
end

local function countQueries(world)
    local original = world.queryEntitiesInRadius
    local counter = { count = 0 }
    world.queryEntitiesInRadius = function(self, center, radius, filter, out)
        counter.count = counter.count + 1
        return original(self, center, radius, filter, out)
    end
    return counter, function() world.queryEntitiesInRadius = original end
end

function Tests.Run(recorder)
    local results = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    check("throttled_perception_bounds_full_table_queries_per_interval", function()
        local runtime, _, _, behavior = freshBehaviorPair()
        local counter, restore = countQueries(runtime.world)
        for _ = 1, 12 do behavior:Update(1 / 60) end
        restore()
        assert(counter.count <= 2,
            "0.2s 内全表感知查询应 ≤2 次（到期刷新一次），实际 " .. tostring(counter.count))
    end)

    check("zero_interval_restores_frame_level_perception", function()
        Fish.perceptionIntervalSec = 0
        local runtime, _, _, behavior = freshBehaviorPair()
        local counter, restore = countQueries(runtime.world)
        for _ = 1, 12 do behavior:Update(1 / 60) end
        restore()
        Fish.perceptionIntervalSec = 0.2
        assert(counter.count >= 12,
            "interval=0 时应每帧查询（≥12 次），实际 " .. tostring(counter.count))
    end)

    check("throttled_perception_still_enters_flee_within_one_interval", function()
        local runtime, sardine, tuna, behavior = freshBehaviorPair()
        tuna.position = { x = 206, y = 0 } -- 已在 dangerRadius 内，等一次到期刷新
        for _ = 1, 5 do behavior:Update(0.05) end
        assert(behavior.state == "Flee",
            "威胁出现后 0.25s（>0.2s 间隔）内必须进入 Flee，实际 " .. tostring(behavior.state))
        assert(sardine.position.x ~= 200 or sardine.position.y ~= 0, "Flee 必须产生位移")
    end)

    check("removed_threat_in_cache_does_not_keep_fleeing", function()
        local runtime, _, tuna, behavior = freshBehaviorPair()
        for _ = 1, 5 do behavior:Update(0.05) end
        assert(behavior.state == "Flee")
        runtime.world:remove(tuna.id, "test")
        behavior:Update(0.05)
        assert(behavior.state ~= "Flee",
            "缓存中的威胁被移除后不得继续 Flee，实际 " .. tostring(behavior.state))
    end)

    check("spawn_fish_defer_activity_skips_per_fish_refresh", function()
        local runtime = Runtime.New({ initializeRegions = false })
        local world = runtime.world
        local calls = 0
        local original = world.updateActivity
        world.updateActivity = function(self, departure)
            calls = calls + 1
            return original(self, departure)
        end
        for index = 1, 5 do
            runtime:spawnFish("sardine", { x = 300 + index, y = 100 }, 0, true)
        end
        assert(calls == 0, "deferActivity=true 时逐鱼不刷新活跃度，实际 " .. tostring(calls))
        runtime:spawnFish("sardine", { x = 320, y = 100 }, 0)
        assert(calls == 1, "单条 spawn 仍刷新一次，实际 " .. tostring(calls))
        world.updateActivity = original
    end)

    check("unreachable_band_region_takes_first_valid_without_full_attempts", function()
        -- S1-f：region(8,8) 距 departure(0,0) 约 360m+，超出两物种 spawn band
        -- （sardine 15-150 / tuna 200-480）→ phase1 不可能命中，必须走快速路径。
        local runtime = Runtime.New({ initializeRegions = false, departure = { x = 0, y = 0 } })
        local world = runtime.world
        local calls = 0
        local original = world.isPositionFree
        world.isPositionFree = function(self, position, radius)
            calls = calls + 1
            return original(self, position, radius)
        end
        local shipPosition = { x = 1040, y = -1040 }
        local placements = Strategy.GenerateRegion(world, 12345, 8, 8, { x = 0, y = 0 }, FishData, shipPosition)
        world.isPositionFree = original
        assert(#placements > 0, "band 不可达区域仍应有鱼（fallback 语义保留）")
        local perFish = calls / #placements
        assert(perFish <= 4,
            "band 不可达时每条鱼尝试次数应 ≤4（快速路径），实际 " .. string.format("%.1f", perFish))
        for _, placement in ipairs(placements) do
            local data = FishData[placement.species]
            assert(Math.distance(placement.position, shipPosition) >= data.minShipSpawnDistance - 1e-6,
                "minShipSpawnDistance 约束在快速路径下必须保持")
        end
    end)

    return { results = results }
end

return Tests
