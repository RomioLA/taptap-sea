-- 客户端云变量：唯一正式写入调用者是每日结算协调器。
local Config = require("config.gameplay")
local PlayerState = require("Gameplay.PlayerState")
local Inventory = require("Gameplay.Inventory")
local Items = require("data.items")
local Progress = require("Gameplay.Circle1B2Progress")
local Diagnostics = require("Gameplay.Diagnostics")
local LocalSaveBackend = require("Gameplay.LocalSaveBackend")
local Persistence = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function integer(value, minimum)
    return finite(value) and value >= minimum and value == math.floor(value)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function validMap(value, flagsOnly)
    if type(value) ~= "table" then return false end
    for key, child in pairs(value) do
        if type(key) ~= "string" or key == "" then return false end
        if flagsOnly then
            if type(child) ~= "boolean" then return false end
        elseif type(child) == "table" then
            if not validMap(child, false) then return false end
        elseif type(child) ~= "string" and type(child) ~= "boolean" and not finite(child) then
            return false
        end
    end
    return true
end

---@param player PlayerState
---@return table
function Persistence.Snapshot(player)
    local progressValid, progressError = Progress.Validate(player)
    assert(progressValid, progressError or "invalid_progress_state")
    return {
        schemaVersion = Config.persistence.schemaVersion,
        day = player.day, maxStamina = player.maxStamina,
        stamina = player.stamina, money = player.money,
        boatSpeedLevel = player.boatSpeedLevel,
        inventory = player.inventory:GetItems(),
        inventoryLevel = player.inventory:GetLevel(),
        inventoryCapacity = player.inventory:GetCapacity(),
        recognizedLocations = copy(player.recognizedLocations),
        treasures = copy(player.treasures), story = copy(player.story), elder = copy(player.elder),
    }
end

---@param data table
---@return PlayerState?, string?
local function restoreValidated(data)
    if type(data) ~= "table" or data.schemaVersion ~= Config.persistence.schemaVersion then
        return nil, "unsupported_save_schema"
    end
    if not integer(data.inventoryLevel, 1)
        or data.inventoryLevel > #Config.inventory.capacities then
        return nil, "invalid_inventory_level"
    end
    if not integer(data.inventoryCapacity, 1)
        or data.inventoryCapacity ~= Config.inventory.capacities[data.inventoryLevel] then
        return nil, "invalid_inventory_capacity"
    end
    -- schema v1 的增量字段；旧快照缺失时视为未购买速度升级。
    local boatSpeedLevel = data.boatSpeedLevel
    if boatSpeedLevel == nil then boatSpeedLevel = 1 end
    if not integer(boatSpeedLevel, 1)
        or boatSpeedLevel > #Config.upgrades.boatSpeed.metersPerSec then
        return nil, "invalid_boat_speed_level"
    end
    if not integer(data.day, 1) or not finite(data.maxStamina) or data.maxStamina <= 0
        or not finite(data.stamina) or data.stamina < 0 or data.stamina > data.maxStamina
        or not integer(data.money, 0)
        or type(data.inventory) ~= "table" then return nil, "invalid_save_state" end
    local count = 0
    for index, itemId in pairs(data.inventory) do
        if not integer(index, 1) or not Items.GetDefinition(itemId) then return nil, "invalid_inventory" end
        count = count + 1
    end
    if count ~= #data.inventory or count > data.inventoryCapacity then return nil, "invalid_inventory" end
    for index = 1, count do
        if not data.inventory[index] then return nil, "invalid_inventory" end
    end
    -- 老快照可能尚未包含这些进度容器；缺失时按空容器迁移。
    local treasures = data.treasures
    local story = data.story
    local elder = data.elder
    if treasures == nil then treasures = {} end
    if story == nil then story = {} end
    if elder == nil then elder = {} end
    if not validMap(data.recognizedLocations, true) or not validMap(treasures, false)
        or not validMap(story, false) or not validMap(elder, false) then
        return nil, "invalid_progress_state"
    end
    local originalProgressValid, originalProgressError = Progress.Validate(data)
    if not originalProgressValid then
        return nil, originalProgressError or "invalid_progress_state"
    end
    local player = assert(PlayerState.New())
    player.day, player.maxStamina = data.day, data.maxStamina
    player.stamina, player.money = data.stamina, data.money
    player.boatSpeedLevel = boatSpeedLevel
    player.inventory = assert(Inventory.New(data.inventoryLevel, copy(data.inventory)))
    player.recognizedLocations, player.treasures = copy(data.recognizedLocations), copy(treasures)
    player.story, player.elder = copy(story), copy(elder)
    local initialized, initializeError = Progress.Initialize(player)
    if not initialized then return nil, initializeError or "invalid_progress_state" end
    local progressValid, progressError = Progress.Validate(player)
    if not progressValid then return nil, progressError or "invalid_progress_state" end
    return player
end

-- 校验/构造在保护边界内完成；只返回完整玩家状态，不向调用方泄漏异常。
---@param data table
---@return PlayerState?, string?
function Persistence.Restore(data)
    local ok, player, err = Diagnostics.Call("persistence", "restore", restoreValidated, data)
    if not ok then return nil, "invalid_save_state:" .. tostring(player) end
    return player, err
end

-- 注入 cloud 可做纯 Lua 测试；不回退到 WASM 刷新即丢失的本地文件。
function Persistence.Cloud(cloud)
    local backend = cloud
    if backend == nil then backend = clientCloud end
    local key = Config.persistence.key

    local function safeString(value)
        local ok, result = pcall(tostring, value)
        return ok and result or "<unprintable>"
    end

    local function diagnosticReason(value)
        if value == "cloud_unavailable" or value == "cloud_timeout"
            or value == "cloud_request_rejected" or value == "cloud_invalid_response" then
            return value
        end
        return "cloud_operation_failed"
    end

    local function invoke(operation, action, done, expectsValuesTable)
        if type(done) ~= "function" then
            Diagnostics.Event("persistence", "request_rejected", {
                kind = "rejected", operation = operation, reason = "callback_required",
            })
            return false, "callback_required"
        end
        local completed = false
        local completionOk = false
        local requestReturned = false
        local function finish(ok, value)
            if completed then
                Diagnostics.Event("persistence", "callback_ignored", {
                    kind = "rejected", operation = operation, reason = "duplicate_callback",
                    phase = requestReturned and "late" or "same_request",
                })
                return false
            end
            completed = true
            completionOk = ok
            local resultKind = ok and "operation" or "failure"
            if not ok and (value == "callback_required" or value == "cloud_request_rejected"
                or value == "cloud_invalid_response") then resultKind = "rejected" end
            local fields = {
                kind = resultKind, operation = operation,
                outcome = ok and "succeeded" or "failed",
            }
            if expectsValuesTable then
                fields.resultType = ok and type(value) or "error"
                if ok then fields.hasSave = value ~= nil end
            end
            if not ok then fields.reason = diagnosticReason(value) end
            Diagnostics.Event("persistence", operation .. "_result", fields)
            Diagnostics.Call("persistence", "completion_callback", done, ok, value)
            return true
        end
        if backend == nil or backend == false then
            finish(false, "cloud_unavailable")
            return false, "cloud_unavailable"
        end
        local callbacks = {
            -- clientCloud:Get(key, events) calls ok(values, iscores). Values
            -- written by Set are in the first result table under the key.
            ok = function(values, _iscores)
                if expectsValuesTable and type(values) ~= "table" then
                    finish(false, "cloud_invalid_response")
                    return
                end
                local saved = expectsValuesTable and values[key] or nil
                finish(true, saved)
            end,
            error = function(code, reason)
                finish(false, safeString(code) .. ":" .. safeString(reason))
            end,
            timeout = function() finish(false, "cloud_timeout") end,
        }
        local callOk, result = Diagnostics.Call("persistence", operation .. "_request", action, callbacks)
        requestReturned = true
        if not callOk then
            local reason = safeString(result)
            local firstCompletion = finish(false, reason)
            if not firstCompletion then
                Diagnostics.Event("persistence", "request_exception_after_callback", {
                    kind = "failure", operation = operation, reason = "request_raised_after_completion",
                })
                return completionOk, reason
            end
            return false, reason
        end
        if result == false then
            local reason = "cloud_request_rejected"
            local firstCompletion = finish(false, reason)
            if not firstCompletion then return completionOk, reason end
            return false, reason
        end
        Diagnostics.Event("persistence", "request_accepted", {
            kind = "operation", operation = operation, outcome = "accepted",
        })
        return true
    end
    return {
        Save = function(_, snapshot, done)
            return invoke("save", function(callbacks)
                return backend:Set(key, copy(snapshot), callbacks)
            end, done, false)
        end,
        Load = function(_, done)
            return invoke("load", function(callbacks)
                return backend:Get(key, callbacks)
            end, done, true)
        end,
    }
end

-- F1: 云 + 本地双写装配。
-- 保存：本地写成功即视为存档成功（立即回调），云降级为后台影子同步；
--       本地写失败退化为纯云语义。真机 cloud_unavailable 时存档不再失败。
-- 读取：本地优先（本地总是最新：每次保存本地必写）；无本地档回退云端，
--       云端命中后回写本地缓存。本地档损坏时也回退云端。
-- 离线/无引擎环境（localBackend 为 nil 且引擎不可用）时退化为纯 Cloud 行为，测试零破坏。
---@param cloud any? clientCloud 或测试替身；nil 时 Cloud 内部取全局
---@param localBackend table? LocalSaveBackend 实例或测试替身；nil 时按引擎可用性构造
function Persistence.Dual(cloud, localBackend)
    local fallback = Persistence.Cloud(cloud)
    if localBackend == nil then
        if LocalSaveBackend.Available() then
            localBackend = LocalSaveBackend.New()
        else
            return fallback
        end
    end

    -- 防重入壳：下游（Loop/Cloud）各有防重入，这里再兜一层保证 done 只发一次。
    local function once(done)
        local fired = false
        return function(ok, value)
            if fired then return end
            fired = true
            done(ok, value)
        end
    end

    local function shadowSave(snapshot)
        local accepted = fallback:Save(snapshot, function(ok, reason)
            Diagnostics.Event("persistence", "cloud_shadow_result", {
                kind = ok and "operation" or "failure",
                outcome = ok and "succeeded" or "failed",
                reason = ok and "cloud_saved" or tostring(reason),
            })
        end)
        if not accepted then
            Diagnostics.Event("persistence", "cloud_shadow_result", {
                kind = "failure", outcome = "failed", reason = "cloud_request_rejected",
            })
        end
    end

    return {
        Save = function(_, snapshot, done)
            if type(done) ~= "function" then
                Diagnostics.Event("persistence", "dual_save_result", {
                    kind = "rejected", outcome = "failed", reason = "callback_required",
                })
                return false, "callback_required"
            end
            local guarded = once(done)
            local accepted = localBackend:Save(snapshot, function(ok, err)
                if ok then
                    Diagnostics.Event("persistence", "dual_save_result", {
                        kind = "operation", outcome = "succeeded", reason = "local_saved",
                    })
                    guarded(true, nil)
                    shadowSave(snapshot)
                else
                    Diagnostics.Event("persistence", "dual_save_result", {
                        kind = "failure", outcome = "failed", reason = "local_write_failed:" .. tostring(err),
                    })
                    -- 本地失败退化为纯云语义（Cloud 内部完成回调）
                    fallback:Save(snapshot, guarded)
                end
            end)
            if accepted == false then
                -- 本地后端拒绝（未回调），直接走云
                fallback:Save(snapshot, guarded)
            end
            return true
        end,
        Load = function(_, done)
            if type(done) ~= "function" then
                Diagnostics.Event("persistence", "dual_load_result", {
                    kind = "rejected", outcome = "failed", reason = "callback_required",
                })
                return false, "callback_required"
            end
            local guarded = once(done)
            local accepted = localBackend:Load(function(ok, data)
                if ok and data ~= nil then
                    Diagnostics.Event("persistence", "dual_load_result", {
                        kind = "operation", outcome = "succeeded", reason = "local_hit",
                    })
                    guarded(true, data)
                elseif ok then
                    -- 无本地档 → 云；云命中后回写本地缓存
                    fallback:Load(function(cloudOk, cloudData)
                        if cloudOk and cloudData ~= nil then
                            Diagnostics.Event("persistence", "dual_load_result", {
                                kind = "operation", outcome = "succeeded", reason = "cloud_hit",
                            })
                            guarded(true, cloudData)
                            localBackend:Save(cloudData, function() end)
                        else
                            Diagnostics.Event("persistence", "dual_load_result", {
                                kind = "operation", outcome = "empty", reason = "no_save_anywhere",
                            })
                            guarded(cloudOk, cloudData)
                        end
                    end)
                else
                    Diagnostics.Event("persistence", "dual_load_result", {
                        kind = "failure", outcome = "failed", reason = "local_unreadable:" .. tostring(data),
                    })
                    fallback:Load(guarded)
                end
            end)
            if accepted == false then fallback:Load(guarded) end
            return true
        end,
    }
end

return Persistence
