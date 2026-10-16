-- Engine adapter based on scaffold-2d. Independent registration, no shared entry edits.
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local FishData = require("Ocean.FishData")
local Draw = require("Ocean.SeaDraw")
local Debug = require("Ocean.SeaDebug")
local Bootstrap = {}
Bootstrap.__index = Bootstrap

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function uiHasTextInputFocus()
    if type(UI.GetFocus) ~= "function" then return false end
    local focused = UI.GetFocus()
    return type(focused) == "table" and focused._className == "TextField"
        and type(focused.state) == "table" and focused.state.focused == true
end

function Bootstrap.Start(options)
    local self = setmetatable({}, Bootstrap)
    self:Init(options or {})
    return self
end

function Bootstrap:Init(options)
    self.options = options or {}
    options = self.options
    self.runtime = Runtime.New(options)
    self.ownsUI = options.ownsUI ~= false
    self.pointerMinY = math.max(options.pointerMinY or 0, Config.camera.horizonY)
    self.stopped = false
    self.physicalWidth, self.physicalHeight, self.dpr = 0, 0, 1
    self.firstFrame = true
    graphics.windowTitle = options.windowTitle or Config.seaTitle
    input.mouseMode, input.mouseVisible = MM_ABSOLUTE, true
    self.context = nvgCreate(1)
    assert(self.context, "Sea NanoVG context unavailable")
    nvgSetRenderOrder(self.context, 0)
    if self.ownsUI then
        UI.Init({ theme = options.theme or "default-dark", scale = UI.Scale.DEFAULT })
    end
    if type(options.uiFactory) == "function" then
        self.tools = options.uiFactory(self.runtime, self)
    else
        self.tools = options.debugUI == false and { refresh = function() end, handleKey = function() return false end }
            or Debug.Create(self.runtime)
    end
    -- A retained Node owns callbacks; Stop affects only this module's subscriptions.
    self.eventNode = Node()
    self.eventObject = assert(self.eventNode:CreateScriptObject("LuaScriptObject"))
    self.eventObject:SubscribeToEvent("Update", function(_, _, data) self:Update(data:GetFloat("TimeStep")) end)
    self.eventObject:SubscribeToEvent(self.context, "NanoVGRender", function() self:Render() end)
    self.eventObject:SubscribeToEvent("MouseButtonDown", function(_, _, data)
        if data:GetInt("Button") == MOUSEB_LEFT then
            local point = input:GetMousePosition()
            self:HandlePointer(point.x, point.y)
        end
    end)
    self.eventObject:SubscribeToEvent("TouchBegin", function(_, _, data)
        self:HandlePointer(data:GetInt("X"), data:GetInt("Y"))
    end)
    self.eventObject:SubscribeToEvent("KeyDown", function(_, _, data)
        if self.stopped or data:GetBool("Repeat") or uiHasTextInputFocus() then return end
        if self.tools and type(self.tools.handleKey) == "function" then
            self.tools.handleKey(data:GetInt("Key"))
        end
    end)
    self:SyncViewport()
    print("[SeaV1] bootstrap ready; world height=" .. Config.camera.viewHeight .. "; local density=" .. FishData.sardine.targetActiveCount .. "/" .. FishData.tuna.targetActiveCount)
end

function Bootstrap:SyncViewport()
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    local dpr = graphics:GetDPR()
    if not isFiniteNumber(width) or not isFiniteNumber(height) or not isFiniteNumber(dpr)
        or width <= 0 or height <= 0 or dpr <= Config.world.epsilon then return false end
    local logicalWidth, logicalHeight = width / dpr, height / dpr
    if not isFiniteNumber(logicalWidth) or not isFiniteNumber(logicalHeight)
        or logicalWidth <= 0 or logicalHeight <= 0 then return false end
    self.physicalWidth, self.physicalHeight, self.dpr = width, height, dpr
    self.runtime.movement:SetViewport(logicalWidth, logicalHeight)
    return true
end

function Bootstrap:HandlePointer(physicalX, physicalY)
    if self.stopped then return false end
    if not isFiniteNumber(physicalX) or not isFiniteNumber(physicalY) then return false end
    if type(self.options.beforePointer) == "function" then
        self.options.beforePointer(self.runtime, self)
    end
    if self.runtime.paused or not self:SyncViewport() then return false end
    if physicalX < 0 or physicalX > self.physicalWidth or physicalY < 0 or physicalY > self.physicalHeight then return false end
    if physicalY / self.physicalHeight < self.pointerMinY then return false end
    -- Coordinate hit test works for both mouse and touch; no stale hover dependence.
    local scale = type(UI.GetScale) == "function" and UI.GetScale() or 1
    if not isFiniteNumber(scale) or scale <= Config.world.epsilon then return false end
    if type(UI.FindWidgetAt) == "function" and UI.FindWidgetAt(physicalX / scale, physicalY / scale) then
        return false
    end
    local position = self.runtime.movement:ScreenToWorld(physicalX/self.dpr, physicalY/self.dpr)
    if type(position) ~= "table" or not isFiniteNumber(position.x) or not isFiniteNumber(position.y)
        or type(self.runtime.IsPositionFree) ~= "function" or not self.runtime:IsPositionFree(position, 0) then
        return false
    end
    if type(self.options.onSeaPointer) == "function" then
        if self.options.onSeaPointer(position, self.runtime, self) == true then return true end
    end
    self.runtime.movement:SetTarget(position)
    return true
end

function Bootstrap:Update(dt)
    if self.stopped then return end
    self:SyncViewport()
    local x, y = 0, 0
    if not uiHasTextInputFocus() then
        if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then x = x-1 end
        if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then x = x+1 end
        if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then y = y+1 end
        if input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) then y = y-1 end
    end
    if type(self.options.simulationUpdate) == "function" then
        self.options.simulationUpdate(self.runtime, dt, x, y)
    else
        self.runtime:Update(dt, x, y)
    end
    if self.tools and type(self.tools.refresh) == "function" then self.tools.refresh(dt) end
end

function Bootstrap:Render()
    if self.stopped or not self:SyncViewport() then return end
    local w, h = self.physicalWidth/self.dpr, self.physicalHeight/self.dpr
    -- Mode B: logical pixels; the movement adapter projects the meter-based world.
    nvgBeginFrame(self.context, w, h, self.dpr)
    ---@type table?
    local clock = nil
    if type(self.options.getClock) == "function" then clock = self.options.getClock() end
    ---@type table?
    local fishingView = nil
    if type(self.options.getFishingView) == "function" then fishingView = self.options.getFishingView() end
    Draw.Scene(self.context, w, h, self.runtime, clock, fishingView, self.options.isLocationRecognized)
    nvgEndFrame(self.context)
    if self.firstFrame then
        self.firstFrame = false
        print("[SeaV1] first frame rendered; underwater hidden=" .. tostring(not self.runtime.world.showUnderwater))
    end
end

function Bootstrap:Stop()
    if self.stopped then return end
    self.stopped = true
    if self.tools and type(self.tools.stop) == "function" then
        local ok, err = pcall(self.tools.stop)
        if not ok then print("[SeaV1] tool cleanup failed: " .. tostring(err)) end
    end
    self.eventObject:UnsubscribeFromAllEvents()
    self.eventNode:Remove()
    nvgDelete(self.context)
    if self.ownsUI then UI.Shutdown() end
    print("[SeaV1] bootstrap stopped")
end
return Bootstrap
