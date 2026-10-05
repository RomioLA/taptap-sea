-- B owns the player loop and the only UI tree; A supplies the existing ocean renderer.
local UI = require("urhox-libs/UI")
local FusedScene = require("Ocean.FusedScene")
local Bridge = require("Integration.Bridge")
local HUD = require("Gameplay.HUD")
local Debug = require("Gameplay.Debug")
local SeaDebug = require("Ocean.SeaDebug")
local SeaConfig = require("Ocean.Config")
local Circle1BInput = require("Integration.Circle1BInput")
local Persistence = require("Gameplay.Persistence")
local Diagnostics = require("Gameplay.Diagnostics")

local Scene = {}
---@type table?
local activeSea = nil

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
    -- 紧凑捕鱼面板自带小尺寸（≤216px），不参与左侧栏等宽注入，避免重新被拉宽遮挡船心。
    local fishingCompact = nil
    if type(hud.root.FindById) == "function" then
        fishingCompact = hud.root:FindById("fishingCompactPanel")
    end
    local width = math.floor(math.min(620, logicalScreenWidth() * 0.62))
    for index = 1, visibleChildCount do
        local child = children[index]
        -- 左侧宽度只约束信息流；absolute操作坞、抽屉及遮罩由HUD自行定位；
        -- 紧凑捕鱼面板自带小尺寸（≤216px），不参与左侧栏等宽注入，避免重新被拉宽遮挡船心。
        if (not child.props or child.props.position ~= "absolute") and child ~= fishingCompact then
            setStyle(child, {
                width = width,
                maxWidth = width,
                alignSelf = "flex-start",
            })
        end
    end
    if children[1] then setStyle(children[1], { flexWrap = "wrap" }) end

    -- A flexing ScrollView otherwise wins empty sea clicks across its viewport.
    local contentScroll = hud.root:FindById("gameplayContentScroll")
    if contentScroll then setStyle(contentScroll, { pointerEvents = "box-none" }) end
end

function Scene.Start(options)
    if activeSea then
        local stopped, reason = activeSea:Stop()
        if stopped == false then error(reason or "scene_stop_failed", 0) end
    end

    local settings = copyOptions(options)
    local uiTheme = settings.theme or "default-taptap"
    local bridgeOptions = copyOptions(settings)
    bridgeOptions.store = settings.store or Persistence.Dual(settings.cloud)
    bridgeOptions.loadSaved = false

    UI.Init({ theme = uiTheme, scale = UI.Scale.DEFAULT,
        -- 当前运行包不含主题默认圆体；复用包内 MiSans，避免开场按钮无文字。
        fonts = { { family = "sans", weights = {
            normal = "Fonts/MiSans-Regular.ttf", bold = "Fonts/MiSans-Bold.ttf",
        } } },
    })
    local root = UI.Panel {
        id = "seaIntegrationRoot",
        width = "100%",
        height = "100%",
        backgroundColor = { 0, 0, 0, 0 },
        pointerEvents = "box-none",
    }
    UI.SetRoot(root)

    ---@type GameplayOceanBridge?
    local bridge = nil
    ---@type table?
    local hud = nil
    ---@type table?
    local debugTools = nil
    ---@type table?
    local seaDebugTools = nil
    ---@type number
    local lastLayoutWidth = 0
    local oceanOptions = copyOptions(settings)
    oceanOptions.ownsUI = false
    oceanOptions.debugUI = false
    oceanOptions.theme = uiTheme
    oceanOptions.uiFactory = function(runtime, ocean)
        local sceneBridge = Bridge.New(runtime, bridgeOptions)
        -- Captured callbacks use initialized references, rather than optional outer slots.
        bridge = sceneBridge
        sceneBridge:Sync()
        debugTools = Debug.New(sceneBridge.loop, settings.development == true)
        local sceneHud = HUD.Create(sceneBridge.loop, root, settings.development == true and debugTools or nil)
        hud = sceneHud
        fitHudToLeftSide(sceneHud)
        lastLayoutWidth = logicalScreenWidth()
        if settings.development == true and SeaConfig.debug.enabled then
            seaDebugTools = SeaDebug.Create(runtime, {
                parent = root,
                panelVisible = false,
                onPause = function()
                    sceneBridge:TogglePause()
                    sceneBridge:Sync()
                    sceneHud.Refresh()
                end,
                onReset = function()
                    local ok, reason = sceneBridge:NewRun()
                    if ok == false then sceneBridge.loop:SetMessage(tostring(reason or "新周目未能开始")) end
                    sceneBridge:Sync()
                    ocean:SyncViewport()
                    sceneHud.Refresh()
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
            sceneBridge:Sync()
            if seaDebugTools then seaDebugTools.refresh(dt or 0) end
        end

        -- HUD 全量刷新节流（UI 精简性能项）：Refresh 内含 ~15 个 pcall、背包签名拼接
        -- 与 20+ 个 string.format，每帧执行产生大量 Lua 临时对象，GC 抖动=画面卡顿。
        -- 时钟/体力等文本变化粒度为秒级，0.15s 节流无感知；事件路径（按钮回调、
        -- 指针按下、按键）仍走 refreshNow 即时刷新，交互不受影响。
        local hudRefreshInterval = 0.15
        local hudRefreshTimer = hudRefreshInterval -- 首帧立即刷一次
        local function refreshNow()
            sceneBridge:Sync()
            sceneHud.Refresh()
        end

        return {
            refresh = function(dt)
                local currentWidth = logicalScreenWidth()
                if math.abs(currentWidth - lastLayoutWidth) > 1 then
                    fitHudToLeftSide(sceneHud)
                    lastLayoutWidth = currentWidth
                end
                hudRefreshTimer = hudRefreshTimer + (dt or 0)
                if hudRefreshTimer >= hudRefreshInterval then
                    hudRefreshTimer = 0
                    sceneHud.Refresh()
                end
                refresh(dt)
            end,
            handleKey = function(key)
                sceneBridge:Sync()
                if key == KEY_SPACE then
                    sceneBridge:TogglePause()
                    refreshNow()
                    return true
                elseif key == KEY_R and settings.development == true then
                    local ok, reason = sceneBridge:NewRun()
                    if ok == false then sceneBridge.loop:SetMessage(tostring(reason or "新周目未能开始")) end
                    sceneBridge:Sync()
                    ocean:SyncViewport()
                    refreshNow()
                    return true
                end
                if seaDebugTools and seaDebugTools.handleKey(key) then
                    sceneBridge:Sync()
                    refreshNow()
                    return true
                end
                return false
            end,
            sync = function() sceneBridge:Sync() end,
            stop = function()
                sceneHud.Destroy()
            end,
        }
    end
    oceanOptions.simulationUpdate = function(_, dt, axisX, axisY)
        if bridge then bridge:Update(dt, axisX, axisY) end
    end
    oceanOptions.getClock = function()
        return bridge and bridge.loop.clock or nil
    end
    oceanOptions.isLocationRecognized = function(contentId)
        return bridge ~= nil and bridge.loop.player:IsRecognized(contentId) == true
    end
    oceanOptions.beforePointer = function()
        if bridge then bridge:Sync() end
    end
    oceanOptions.onSeaPointer = function(position)
        if not bridge then return false end
        local consumed = bridge:OnSeaPointer(position)
        if hud then hud.Refresh() end
        return consumed
    end
    oceanOptions.getFishingView = function()
        if not bridge then return nil end
        local state = bridge.loop:GetFishingState()
        if not state.center then return nil end
        local phase = state.state == "selecting" and "aim"
            or state.state == "casting" and "casting" or state.state == "landed" and "reeling" or nil
        if not phase then return nil end
        return { phase = phase, center = state.center, elapsedSec = phase == "aim" and 0 or state.elapsed }
    end

    local ok, seaOrError = Diagnostics.Call("Integration", "scene_start", FusedScene.Start, oceanOptions)
    if not ok then
        if hud then Diagnostics.Call("Integration", "hud_destroy", hud.Destroy) end
        UI.Shutdown()
        error(seaOrError, 0)
    end

    local sea = seaOrError
    if not bridge then error("Integration scene requires initialized gameplay bridge", 0) end
    ---@type GameplayOceanBridge
    local initializedBridge = assert(bridge)
    ---@type number?
    local pendingPointerListener
    if UI.Input and type(UI.Input.On) == "function" then
        pendingPointerListener = UI.Input.On("PointerDown", function(event)
            Circle1BInput.HandlePendingPointer(initializedBridge, sea, event, UI)
            if hud then hud.Refresh() end
        end)
    end
    sea.bridge = initializedBridge
    sea.loop = initializedBridge.loop
    sea.hud = hud
    sea.uiRoot = root

    if settings.loadSaved ~= false then
        initializedBridge.loop:BeginEntry()
        initializedBridge:LoadSaved(function()
            if hud then hud.Refresh() end
        end)
        if hud then hud.Refresh() end
    end

    ---@type fun(self:table)
    local oceanStop = sea.Stop
    local uiShutdown = false
    function sea:Stop()
        if uiShutdown then return end
        if initializedBridge.loop:HasPendingCatch() then return false, "pending_catch_required" end
        if initializedBridge.loop.inventoryRollback then return false, "inventory_rollback_pending" end
        local cancelled, cancelReason = assert(initializedBridge.loop.actions):CancelActiveFishing("scene_stopped")
        if not cancelled then return false, cancelReason end
        local barrelCancelled, barrelReason = initializedBridge.loop.barrel:Cancel("scene_stopped")
        if not barrelCancelled then return false, barrelReason end
        initializedBridge.loop:CloseStoryDialog()
        initializedBridge.loop:CancelThrowSelection()
        local scopeClosed, scopeReason = initializedBridge.loop:DisableScope()
        if not scopeClosed and scopeReason ~= "scope_interface_unavailable" then
            initializedBridge.loop:SetMessage("透镜观察未能关闭，请重试关闭场景。")
            return false, scopeReason
        end
        if pendingPointerListener then UI.Input.Off("PointerDown", pendingPointerListener) end
        initializedBridge.loop:Close()
        uiShutdown = true
        local stopOk, stopError = Diagnostics.Call("Integration", "scene_stop", oceanStop, self)
        if activeSea == self then activeSea = nil end
        UI.Shutdown()
        if not stopOk then error(stopError, 0) end
    end
    activeSea = sea
    return sea
end

return Scene
