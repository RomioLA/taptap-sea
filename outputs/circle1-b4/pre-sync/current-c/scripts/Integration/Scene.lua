-- B owns the player loop and the only UI tree; A supplies the existing ocean renderer.
local UI = require("urhox-libs/UI")
local FusedScene = require("Ocean.FusedScene")
local Bridge = require("Integration.Bridge")
local HUD = require("Gameplay.HUD")
local Debug = require("Gameplay.Debug")
local SeaDebug = require("Ocean.SeaDebug")
local SeaConfig = require("Ocean.Config")

local Scene = {}
---@type table?
local activeSea = nil

local OFFLINE_FAILURE = "离线验收未连接云存档（offline_persistence_unavailable）"
local OfflineStore = {}

function OfflineStore:Load(done)
    if type(done) == "function" then done(false, OFFLINE_FAILURE) end
    return false, OFFLINE_FAILURE
end

function OfflineStore:Save(_, done)
    if type(done) == "function" then done(false, OFFLINE_FAILURE) end
    return false, OFFLINE_FAILURE
end

local function copyOptions(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function uiScale()
    local scale = type(UI.GetScale) == "function" and UI.GetScale() or 1
    if type(scale) ~= "number" or scale <= 0 then return 1 end
    return scale
end

local function logicalScreenWidth()
    local physicalWidth = 900
    if graphics and type(graphics.GetWidth) == "function" then
        physicalWidth = graphics:GetWidth()
    end
    return math.max(1, physicalWidth / uiScale())
end

local function setStyle(widget, style)
    assert(type(widget.SetStyle) == "function", "Integration UI widget must support SetStyle")
    widget:SetStyle(style)
end

local function fitHudToLeftSide(hud)
    local children = hud.root:GetChildren()
    -- HUD's final child is its full-screen modal overlay. Keep that full-screen.
    local visibleChildCount = math.max(0, #children - 1)
    local width = math.floor(math.min(620, logicalScreenWidth() * 0.62))
    for index = 1, visibleChildCount do
        local child = children[index]
        setStyle(child, {
            width = width,
            maxWidth = width,
            alignSelf = "flex-start",
        })
    end
    if children[1] then setStyle(children[1], { flexWrap = "wrap" }) end
    if children[2] then setStyle(children[2], { flexWrap = "wrap" }) end

    -- A flexing ScrollView otherwise wins empty sea clicks across its viewport.
    local contentScroll = hud.root:GetChildAt(6)
    if contentScroll then setStyle(contentScroll, { pointerEvents = "box-none" }) end
end

local function addOfflineNotice(root, width)
    local noteWidth = math.max(120, math.floor(width * 0.34))
    local note = UI.Panel {
        id = "offlinePersistenceNotice",
        position = "absolute",
        right = 10,
        bottom = 10,
        width = noteWidth,
        maxWidth = noteWidth,
        padding = 7,
        backgroundColor = { 8, 16, 18, 205 },
        borderColor = { 159, 133, 88, 190 },
        borderWidth = 1,
        borderRadius = 6,
        pointerEvents = "none",
        children = {
            UI.Label {
                text = "离线验收：云存档未连接；日结保存需接入存档服务",
                fontSize = 11,
                fontColor = { 255, 236, 207, 255 },
                whiteSpace = "normal",
                pointerEvents = "none",
            },
        },
    }
    root:AddChild(note)
    return note
end

function Scene.Start(options)
    if activeSea then activeSea:Stop() end

    local settings = copyOptions(options)
    local uiTheme = settings.theme or "default-taptap"
    local usingOfflineStore = settings.store == nil
    local bridgeOptions = copyOptions(settings)
    bridgeOptions.store = settings.store or OfflineStore
    -- Do not let Loop fall through to Persistence.Cloud in the offline scene.
    bridgeOptions.cloud = nil
    bridgeOptions.loadSaved = false

    UI.Init({ theme = uiTheme, scale = UI.Scale.DEFAULT })
    local root = UI.Panel {
        id = "seaIntegrationRoot",
        width = "100%",
        height = "100%",
        backgroundColor = { 0, 0, 0, 0 },
        pointerEvents = "box-none",
    }
    UI.SetRoot(root)

    ---@type table?
    local bridge = nil
    ---@type table?
    local hud = nil
    ---@type table?
    local debugTools = nil
    ---@type table?
    local seaDebugTools = nil
    ---@type table?
    local offlineNotice = nil
    local lastLayoutWidth = 0
    local oceanOptions = copyOptions(settings)
    oceanOptions.ownsUI = false
    oceanOptions.debugUI = false
    oceanOptions.theme = uiTheme
    oceanOptions.uiFactory = function(runtime, ocean)
        bridge = Bridge.New(runtime, bridgeOptions)
        bridge:Sync()
        debugTools = Debug.New(bridge.loop, settings.development == true)
        hud = HUD.Create(bridge.loop, root, settings.development == true and debugTools or nil)
        fitHudToLeftSide(hud)
        lastLayoutWidth = logicalScreenWidth()
        if SeaConfig.debug.enabled then
            seaDebugTools = SeaDebug.Create(runtime, {
                parent = root,
                panelVisible = false,
                onPause = function()
                    bridge:TogglePause()
                    bridge:Sync()
                    if hud then hud.Refresh() end
                end,
                onReset = function()
                    local ok, reason = bridge:NewRun()
                    if ok == false then bridge.loop:SetMessage(tostring(reason or "新周目未能开始")) end
                    bridge:Sync()
                    ocean:SyncViewport()
                    if hud then hud.Refresh() end
                end,
            })
            root:AddChild(UI.Button {
                id = "seaDebugToggle",
                text = "海上调试",
                position = "absolute",
                right = 24,
                bottom = 72,
                width = 80,
                height = 32,
                fontSize = 10,
                borderRadius = 16,
                backgroundColor = { 249, 247, 221, 22 },
                textColor = { 246, 244, 218, 255 },
                borderWidth = 1,
                borderColor = { 212, 235, 219, 65 },
                onClick = function()
                    if seaDebugTools then seaDebugTools.handleKey(KEY_F3) end
                end,
            })
        end

        local function refresh(dt)
            bridge:Sync()
            hud.Refresh()
            if seaDebugTools then seaDebugTools.refresh(dt or 0) end
            if offlineNotice then
                local modalOpen = bridge.loop.forcedReturnPending == true
                    or bridge.loop.settlementPending == true or bridge.loop.elderOpen == true
                offlineNotice:SetVisible(not modalOpen)
            end
        end

        return {
            refresh = function(dt)
                bridge:Sync()
                local currentWidth = logicalScreenWidth()
                if math.abs(currentWidth - lastLayoutWidth) > 1 then
                    fitHudToLeftSide(hud)
                    lastLayoutWidth = currentWidth
                end
                refresh(dt)
            end,
            handleKey = function(key)
                bridge:Sync()
                if key == KEY_SPACE then
                    bridge:TogglePause()
                    refresh(0)
                    return true
                elseif key == KEY_R then
                    local ok, reason = bridge:NewRun()
                    if ok == false then bridge.loop:SetMessage(tostring(reason or "新周目未能开始")) end
                    bridge:Sync()
                    ocean:SyncViewport()
                    refresh(0)
                    return true
                end
                if seaDebugTools and seaDebugTools.handleKey(key) then
                    bridge:Sync()
                    refresh(0)
                    return true
                end
                return false
            end,
            sync = function() bridge:Sync() end,
            stop = function()
                if hud then hud.Destroy() end
            end,
        }
    end
    oceanOptions.simulationUpdate = function(_, dt, axisX, axisY)
        if bridge then bridge:Update(dt, axisX, axisY) end
    end
    oceanOptions.getClock = function()
        return bridge and bridge.loop.clock or nil
    end
    oceanOptions.beforePointer = function()
        if bridge then bridge:Sync() end
    end
    oceanOptions.onSeaPointer = function(position)
        if bridge then bridge:SetDropTarget(position) end
    end

    if usingOfflineStore then offlineNotice = addOfflineNotice(root, logicalScreenWidth()) end

    local ok, seaOrError = pcall(FusedScene.Start, oceanOptions)
    if not ok then
        if hud then pcall(hud.Destroy) end
        UI.Shutdown()
        error(seaOrError, 0)
    end

    local sea = seaOrError
    sea.bridge = bridge
    sea.loop = bridge.loop
    sea.hud = hud
    sea.uiRoot = root
    sea.offlineNotice = offlineNotice

    if settings.loadSaved == true then
        bridge:LoadSaved(function()
            if hud then hud.Refresh() end
        end)
    end

    local oceanStop = sea.Stop
    local uiShutdown = false
    function sea:Stop()
        if uiShutdown then return end
        uiShutdown = true
        local stopOk, stopError = pcall(oceanStop, self)
        if activeSea == self then activeSea = nil end
        UI.Shutdown()
        if not stopOk then error(stopError, 0) end
    end
    activeSea = sea
    return sea
end

return Scene
