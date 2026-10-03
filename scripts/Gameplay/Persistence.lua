-- 客户端云变量：唯一正式写入调用者是每日结算协调器。
local Config = require("config.gameplay")
local PlayerState = require("Gameplay.PlayerState")
local Inventory = require("Gameplay.Inventory")
local Items = require("data.items")
local Progress = require("Gameplay.Circle1B2Progress")
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
    local ok, player, err = pcall(restoreValidated, data)
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

    local function reportError(reason)
        if type(print) == "function" then
            pcall(print, "[Persistence.Cloud] " .. safeString(reason))
        end
    end

    local function invoke(action, done, expectsValuesTable)
        if type(done) ~= "function" then return false, "callback_required" end
        local completed = false
        local completionOk = false
        local function finish(ok, value)
            if completed then return false end
            completed = true
            completionOk = ok
            local callbackOk, callbackError = pcall(done, ok, value)
            if not callbackOk then reportError("completion callback failed: " .. safeString(callbackError)) end
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
        local callOk, result = pcall(action, callbacks)
        if not callOk then
            local reason = safeString(result)
            local firstCompletion = finish(false, reason)
            if not firstCompletion then
                reportError("cloud request raised after callback: " .. reason)
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
        return true
    end
    return {
        Save = function(_, snapshot, done)
            return invoke(function(callbacks)
                return backend:Set(key, copy(snapshot), callbacks)
            end, done, false)
        end,
        Load = function(_, done)
            return invoke(function(callbacks)
                return backend:Get(key, callbacks)
            end, done, true)
        end,
    }
end

return Persistence
