-- Seven-day public-flow simulations for Circle 1 B3.
-- Ocean movement and port protocol are explicitly test doubles; production
-- Ocean behavior is covered separately by the B3 spatial suite.
local Flow = require("Tests.Circle1BFishingFlowTests")

local Tests = {}
local PAPER_TEXT = "海岸边那只木桶，下面一定有什么东西，我想多打捞几次就能打捞上来吧。"

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected)
        .. ", got " .. tostring(actual))
end

local function makeUI()
    local Widget = {}
    Widget.__index = Widget

    function Widget:AddChild(child)
        self.children[#self.children + 1] = child
        child.parent = self
    end
    function Widget:RemoveChild(child)
        for index, value in ipairs(self.children) do
            if value == child then table.remove(self.children, index); break end
        end
        child.parent = nil
    end
    function Widget:GetChildren() return self.children end
    function Widget:GetChildAt(index) return self.children[index] end
    function Widget:ClearChildren()
        for _, child in ipairs(self.children) do child.parent = nil end
        self.children = {}
    end
    function Widget:SetVisible(value) self.visible = value == true end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self:SetVisible(true) end
    function Widget:Hide() self:SetVisible(false) end
    function Widget:SetText(value) self.props.text = tostring(value or "") end
    function Widget:SetDisabled(value) self.disabled = value == true end
    function Widget:SetStyle(value) self.style = value end
    function Widget:Destroy()
        self.destroyed = true
        if self.parent then self.parent:RemoveChild(self) end
    end

    local UI = { widgets = {} }
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField" }) do
        UI[kind] = function(props)
            props = props or {}
            local widget = setmetatable({
                kind = kind, props = props, children = {},
                visible = props.visible ~= false, disabled = false,
            }, Widget)
            UI.widgets[#UI.widgets + 1] = widget
            for _, child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    return UI
end

local function withHUD(loop, run)
    local previousUI = package.loaded["urhox-libs/UI"]
    local previousHUD = package.loaded["Gameplay.HUD"]
    local UI = makeUI()
    package.loaded["urhox-libs/UI"] = UI
    package.loaded["Gameplay.HUD"] = nil
    local hud
    local ok, result = xpcall(function()
        local HUD = require("Gameplay.HUD")
        local parent = UI.Panel({ id = "b3TestRoot" })
        hud = HUD.Create(loop, parent)
        return run(hud, UI)
    end, debug.traceback)
    if hud then pcall(hud.Destroy) end
    package.loaded["urhox-libs/UI"] = previousUI
    package.loaded["Gameplay.HUD"] = previousHUD
    if not ok then error(result, 0) end
    return result
end

local function walk(root, visit)
    visit(root)
    for _, child in ipairs(root.children or {}) do walk(child, visit) end
end

local function isVisible(widget)
    while widget do
        if widget.visible ~= true then return false end
        widget = widget.parent
    end
    return true
end

local function clickButton(root, wanted, prefix)
    local candidates = {}
    walk(root, function(widget)
        local text = widget.kind == "Button" and widget.props.text or nil
        local match = prefix and type(text) == "string" and text:sub(1, #wanted) == wanted
            or (not prefix and text == wanted)
        if match then candidates[#candidates + 1] = widget end
    end)
    for _, widget in ipairs(candidates) do
        if isVisible(widget) and not widget.disabled and type(widget.props.onClick) == "function" then
            widget.props.onClick()
            return widget.props.text
        end
    end
    local seen = {}
    for _, widget in ipairs(candidates) do
        seen[#seen + 1] = tostring(widget.props.text) .. (widget.disabled and "[disabled]" or "[hidden]")
    end
    error("usable HUD button not found: " .. wanted .. " candidates=" .. table.concat(seen, ","), 2)
end

local function findVisibleButton(root, wanted)
    local found
    walk(root, function(widget)
        if not found and widget.kind == "Button" and widget.props.text == wanted
            and isVisible(widget) then
            found = widget
        end
    end)
    assert(found, "visible HUD button not found: " .. wanted)
    return found
end

local function hasVisibleLabel(root, wanted)
    local found = false
    walk(root, function(widget)
        if widget.kind == "Label" and widget.props.text == wanted and isVisible(widget) then
            found = true
        end
    end)
    return found
end

local function clickInventoryRowButton(root, inventory, itemId, buttonText)
    local itemIndex
    for index, id in ipairs(inventory:GetItems()) do
        if id == itemId then itemIndex = index; break end
    end
    assert(itemIndex, "inventory item not found: " .. itemId)
    local labelPrefix = string.format("%02d · ", itemIndex)
    local rows, observed, labels = {}, {}, {}
    walk(root, function(widget)
        if widget.kind == "Label" and type(widget.props.text) == "string" then
            labels[#labels + 1] = widget.props.text
            if widget.props.text:sub(1, #labelPrefix) == labelPrefix then
                rows[#rows + 1] = widget.parent
            end
        end
    end)
    for _, row in ipairs(rows) do
        local actions = {}
        for _, widget in ipairs(row.children or {}) do
            if widget.kind == "Button" then
                actions[#actions + 1] = tostring(widget.props.text) .. (widget.disabled and "[disabled]" or "")
            end
            if widget.kind == "Button" and widget.props.text == buttonText
                and isVisible(widget) and not widget.disabled then
                widget.props.onClick()
                return true
            end
        end
        observed[#observed + 1] = "visible=" .. tostring(isVisible(row)) .. "; actions=" .. table.concat(actions, ",")
    end
    error("HUD row action missing: item=" .. itemId .. " index=" .. tostring(itemIndex)
        .. " / " .. buttonText
        .. "; rows=" .. table.concat(observed, " | ")
        .. "; labels=" .. table.concat(labels, " / "):sub(1, 700), 2)
end

local function copyItems(inventory)
    local result = {}
    for index, itemId in ipairs(inventory:GetItems()) do result[index] = itemId end
    return result
end

local function countItem(inventory, wanted)
    local count = 0
    for _, itemId in ipairs(inventory:GetItems()) do
        if itemId == wanted then count = count + 1 end
    end
    return count
end

local function snapshot(loop)
    local elder = loop:GetElderStatus()
    local stock = { apple = loop:GetShopStock("apple"), bait = loop:GetShopStock("bait") }
    return {
        day = loop.player.day,
        money = loop.player.money,
        stamina = loop.player.stamina,
        inventory = copyItems(loop.player.inventory),
        stock = stock,
        elder = { applesGiven = elder.applesGiven, decision = elder.decision, present = elder.present },
        saveStatus = loop.saveStatus,
    }
end

local function makePortProtocolDouble(runtime)
    local port = { x = 0, y = 0 }
    runtime.portProtocolDouble = {
        kind = "test-only ocean/port adapter",
        getCalls = 0,
        resetCalls = 0,
        resetFailure = nil,
    }
    function runtime:GetPortPosition()
        self.portProtocolDouble.getCalls = self.portProtocolDouble.getCalls + 1
        return { x = port.x, y = port.y }
    end
    function runtime:ResetShipAtPort()
        self.portProtocolDouble.resetCalls = self.portProtocolDouble.resetCalls + 1
        if self.portProtocolDouble.resetFailure then
            return false, self.portProtocolDouble.resetFailure
        end
        self.ship.position = { x = port.x, y = port.y }
        self.movementTarget = nil
        return true
    end
    local copy = runtime:GetPortPosition()
    copy.x = copy.x + 1000
    eq(runtime:GetPortPosition().x, port.x, "port position must be returned by value")
end

local function route(appleGiftDays)
    local fixture = Flow.Fixture({
        refreshSpawn = { species = "sardine", position = { x = 12, y = 0 },
                         options = { velocity = { x = 0, y = 0 } } },
    })
    local loop, bridge, runtime = fixture.loop, fixture.bridge, fixture.runtime
    makePortProtocolDouble(runtime)
    loop:BeginEntry()

    local routeData = {
        giftDays = appleGiftDays,
        days = {},
        simulationTime = 0,
        navigationSeconds = 0,
        fishingSeconds = 0,
        activeClockUpdateSeconds = 0,
        updateCalls = 0,
        pauseCategorySeconds = {},
        pauseRealReadingTime = "not measured; pauseCategorySeconds contains injected test dt and overlapping reasons must not be added",
        day4ElderAccess = nil,
        usesDebugTools = false,
        directPlayerResourceWrites = 0,
        directDayWrites = 0,
        seekCalls = 0,
        portAdapter = runtime.portProtocolDouble,
    }

    withHUD(loop, function(hud)
        local root = hud.root
        local nativeSeek = loop.clock.Seek
        loop.clock.Seek = function()
            routeData.seekCalls = routeData.seekCalls + 1
            error("Clock:Seek is forbidden in this route")
        end

        local function advance(dt, axisX, axisY)
            local remaining = dt
            while remaining > 1e-9 do
                local step = math.min(0.5, remaining)
                for _, reason in ipairs(loop.clock:GetPauseReasons()) do
                    routeData.pauseCategorySeconds[reason] = (routeData.pauseCategorySeconds[reason] or 0) + step
                end
                if not loop.clock:IsPaused() then
                    routeData.activeClockUpdateSeconds = routeData.activeClockUpdateSeconds + step
                end
                local ok, reason = bridge:Update(step, axisX or 0, axisY or 0)
                assert(ok, "Bridge.Update failed: " .. tostring(reason))
                routeData.simulationTime = routeData.simulationTime + step
                routeData.updateCalls = routeData.updateCalls + 1
                if (axisX or 0) ~= 0 or (axisY or 0) ~= 0 then
                    routeData.navigationSeconds = routeData.navigationSeconds + step
                end
                remaining = remaining - step
            end
            hud.Refresh()
        end

        -- BeginEntry is the normal first-entry pause. Wait through it, then
        -- start through the same button callback used by the official HUD.
        advance(0.5)
        clickButton(root, "开始新周目")
        eq(loop.player.day, 1, "new run starts on day one")
        eq(loop.clock.timeScale, 1, "normal clock scale")

        for day = 1, 7 do
            eq(loop.player.day, day, "sequential day entry")
            advance(0.25) -- observed port-pause duration, not clock time

            if day == 4 then
                hud.Refresh()
                if #appleGiftDays >= 3 then
                    local elderButton = findVisibleButton(root, "拜访老人")
                    assert(not elderButton.disabled, "saved elder visit should be enabled on day four")
                    clickButton(root, "拜访老人")
                    assert(loop.elderOpen, "saved elder HUD entry did not open the day-four dialogue")
                    assert(hasVisibleLabel(root, "老人获救"),
                        "day-four elder dialogue should show the saved state")
                    advance(0.5)
                    clickButton(root, "结束对话")
                    assert(not loop.elderOpen, "day-four elder HUD entry did not close the dialogue")
                    routeData.day4ElderAccess = {
                        visible = true, enabled = true, label = elderButton.props.text,
                        opened = true, closed = true, dialogStateShown = "老人获救",
                    }
                else
                    local elderButton = findVisibleButton(root, "老人不在")
                    assert(elderButton.disabled, "unrescued elder must not expose an enabled day-four visit")
                    assert(not loop.elderOpen, "unrescued elder dialogue must remain closed on day four")
                    routeData.day4ElderAccess = {
                        visible = true, enabled = false, label = elderButton.props.text,
                        explanation = "老人不在",
                    }
                end
            end

            local giftsToday = appleGiftDays[day] == true
            if giftsToday then
                if countItem(loop.player.inventory, "apple") == 0 then
                    clickButton(root, "苹果 · ¥", true)
                    assert(countItem(loop.player.inventory, "apple") > 0, "trade must purchase an apple")
                end
                clickButton(root, "拜访老人")
                assert(loop.elderOpen, "HUD elder button did not open the elder dialogue")
                advance(0.5) -- elderly conversation uses the real clock pause reason
                clickInventoryRowButton(root, loop.player.inventory, "apple", "给予")
                clickButton(root, "结束对话")
            end

            clickButton(root, "出航")
            advance(2, 1, 0)
            local center = runtime:GetShipPosition()
            clickButton(root, "捕鱼")
            assert(bridge:OnSeaPointer(center), "sea-pointer selection should be consumed")
            hud.Refresh() -- mirrors Scene's onSeaPointer refresh after the ocean callback
            eq(loop:GetFishingState().state, "casting", "one sea pointer starts the cast")
            assert(not loop.clock:IsPaused(), "four-second fishing must use active clock updates")
            local fishItemCountBefore = countItem(loop.player.inventory, "sardine")
            local activeBeforeFishing = routeData.activeClockUpdateSeconds
            advance(4)
            local fishingDuration = routeData.activeClockUpdateSeconds - activeBeforeFishing
            eq(fishingDuration, 4, "natural fishing duration")
            routeData.fishingSeconds = routeData.fishingSeconds + fishingDuration
            local fishingState = loop:GetFishingState()
            eq(fishingState.state, "complete", "four-second fishing should complete")
            if loop:HasPendingCatch() then clickButton(root, "领取渔获") end
            assert(countItem(loop.player.inventory, "sardine") > fishItemCountBefore,
                "completed fishing should add the caught fish to inventory")

            advance(2, -1, 0)
            clickButton(root, "返港")
            advance(0.25) -- observed time in port
            local saleLabel = clickButton(root, "出售 ¥", true)
            routeData.days[#routeData.days + 1] = {
                day = day,
                fishingSeconds = fishingDuration,
                saleAction = saleLabel,
                afterTrade = snapshot(loop),
            }

            if day < 7 then
                clickButton(root, "结束今日")
                advance(0.25) -- settlement modal pauses the clock while awaiting consent
                clickButton(root, "确认结算")
                local row = routeData.days[#routeData.days]
                row.nextDay = loop.player.day
                row.nextDayElder = loop:GetElderStatus()
                row.saveStatusAfterSettlement = loop.saveStatus
            end
        end

        routeData.day4Elder = routeData.days[3].nextDayElder
        eq(routeData.day4Elder.decision,
           #appleGiftDays >= 3 and "saved" or "dead", "day four elder decision")
        eq(loop.player.day, 7, "route stops on day seven")
        local paperOpened, paperReason = loop:OpenDay7PaperBeforeEnding()
        assert(paperOpened, "day-seven paper entry unavailable: " .. tostring(paperReason))
        hud.Refresh()
        local dialog = loop:GetStoryDialog()
        assert(dialog and dialog.kind == "paper", "day seven must expose only the existing paper entry")
        eq(dialog.text, PAPER_TEXT, "existing paper text")
        advance(0.5) -- protocol can measure simulated story pause; real reading stays unmeasured
        routeData.paperShown = loop.player.story.circle1B2.paperShown == true
        clickButton(root, "结束对话")
        routeData.paperClosed = loop:GetStoryDialog() == nil
        routeData.day7State = snapshot(loop)
        routeData.terminalEndingTriggered = false
        routeData.endingDesignStatus = "not specified; no ending is invoked or inferred"
        routeData.portApiProductionVerified = false
        routeData.realOceanRuntimeVerified = false
        loop.clock.Seek = nativeSeek
        loop:Close()
    end)

    return routeData
end

function Tests.Run()
    local results, routes = {}, {}
    local function addRoute(name, giftDays, expectedCount, expectedDecision)
        local ok, value = xpcall(function() return route(giftDays) end, debug.traceback)
        local row = { name = name, passed = ok, error = ok and "" or tostring(value) }
        if ok then
            row.applesGiven = value.day4Elder.applesGiven
            row.day4Decision = value.day4Elder.decision
            row.day7 = value.day7State.day
            row.day4ElderAccess = value.day4ElderAccess
            row.simulationTime = value.simulationTime
            row.navigationSeconds = value.navigationSeconds
            row.fishingSeconds = value.fishingSeconds
            row.pauseCategorySeconds = value.pauseCategorySeconds
            row.paperShown = value.paperShown
            row.terminalEndingTriggered = value.terminalEndingTriggered
            row.route = value
            if value.day4Elder.applesGiven ~= expectedCount then
                row.passed, row.error = false, "day four apple count mismatch"
            elseif value.day4Elder.decision ~= expectedDecision then
                row.passed, row.error = false, "day four decision mismatch"
            end
            routes[#routes + 1] = value
        end
        results[#results + 1] = row
    end

    addRoute("two apples remain below the day-four save threshold", { [1] = true, [2] = true }, 2, "dead")
    addRoute("one apple on each of days one through three saves by day four", { [1] = true, [2] = true, [3] = true }, 3, "saved")
    return {
        results = results,
        routes = routes,
        constraints = {
            source = "official Gameplay.HUD callbacks plus Bridge.Update and public loop/paper entry",
            updateOnlyClockProgress = true,
            debugResourceCommandsUsed = false,
            directDayOrPlayerResourceWrites = false,
            clockSeekUsed = false,
            portProtocol = "test double around the B1 flow runtime; not evidence of production Ocean support",
            seaFish = "deterministic simulated environment fish spawned by the protocol fixture",
            realReaderTime = "unmeasured",
            ending = "day-seven paper entry only; no ending has been designed or invoked",
        },
    }
end

return Tests
