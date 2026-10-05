-- Real Scene/HUD/Bridge and Ocean pointer adapter with an in-memory UI host.
-- SDK and new A port interfaces here are explicit test doubles, never product fallbacks.
local Tests = {}
local Runtime = require("Ocean.SeaRuntime")
local Persistence = require("Gameplay.Persistence")
local Config = require("config.gameplay")

local function uiHost()
    local UI = { Scale = { DEFAULT = 1 }, rootCount = 0, listeners = {} }
    local Widget = {}; Widget.__index = Widget
    function Widget:AddChild(child) self.children[#self.children+1]=child; child.parent=self end
    function Widget:RemoveChild(child)
        for i,value in ipairs(self.children) do if value==child then table.remove(self.children,i); break end end
        child.parent=nil
    end
    function Widget:GetChildren() return self.children end
    function Widget:ClearChildren() self.children={} end
    function Widget:FindById(id)
        if self.props.id==id then return self end
        for _,child in ipairs(self.children) do local value=child:FindById(id); if value then return value end end
    end
    function Widget:SetStyle(style) for key,value in pairs(style) do self.props[key]=value end end
    function Widget:SetVisible(value) self.visible=value end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self.visible=true end
    function Widget:Hide() self.visible=false end
    function Widget:SetText(value) self.props.text=value end
    function Widget:SetDisabled(value) self.disabled=value end
    function Widget:Destroy() self.destroyed=true; if self.parent then self.parent:RemoveChild(self) end end
    for _,kind in ipairs({"Panel","SafeAreaView","Label","Button","Spacer","ScrollView","TextField"}) do
        UI[kind]=function(props)
            props=props or {}; local widget=setmetatable({kind=kind,props=props,children={},visible=props.visible~=false},Widget)
            for _,child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    function UI.Init() end
    function UI.Shutdown() end
    function UI.SetRoot(root) UI.root=root; UI.rootCount=UI.rootCount+1 end
    function UI.GetScale() return 1 end
    function UI.FindWidgetAt() return UI.hit end
    UI.Input={On=function(name,callback) UI.listeners[name]=callback; return 1 end,
        Off=function(name) UI.listeners[name]=nil end}
    return UI
end

local function visible(widget)
    while widget do if not widget.visible then return false end; widget=widget.parent end
    return true
end

local function button(root, text)
    if root.kind=="Button" and root.props.text==text and visible(root) then return root end
    for _,child in ipairs(root.children) do local found=button(child,text); if found then return found end end
end

local function click(root,text)
    local value=assert(button(root,text),"missing visible button: "..text)
    assert(not value.disabled,"disabled button: "..text); value.props.onClick(); return value
end

local function startNewRun(sea,sdk)
    click(sea.uiRoot,"开始新周目")
    assert(sea.loop.entryPending and sea.loop.initialSaveStatus=="saving")
    local request=assert(sdk.sets[#sdk.sets],"new run must immediately save its starting snapshot")
    request.callbacks.ok()
    sea.hud.Refresh()
    assert(not sea.loop.entryPending and sea.loop.initialSaveStatus=="saved")
end

local function withScene(action, options)
    local modules={}; for _,name in ipairs({"urhox-libs/UI","Integration.Scene","Gameplay.HUD","Ocean.FusedScene","Ocean.Bootstrap"}) do
        modules[name]={value=package.loaded[name]}; package.loaded[name]=nil
    end
    local globals={}; for _,name in ipairs({"graphics","clientCloud","KEY_SPACE","KEY_R","KEY_U","KEY_F3"}) do globals[name]={value=_G[name]} end
    local UI=uiHost(); package.loaded["urhox-libs/UI"]=UI
    local dimensions={w=900,h=700}
    _G.graphics={GetWidth=function()return dimensions.w end,GetHeight=function()return dimensions.h end,GetDPR=function()return 1 end}
    _G.KEY_SPACE,_G.KEY_R,_G.KEY_U,_G.KEY_F3=1,2,3,4
    local sdk={gets={},sets={}}
    function sdk:Get(key,callbacks) self.gets[#self.gets+1]=callbacks end
    function sdk:Set(key,snapshot,callbacks) self.sets[#self.sets+1]={snapshot=snapshot,callbacks=callbacks} end
    _G.clientCloud=sdk
    local sea
    package.loaded["Ocean.FusedScene"]={Start=function(settings)
        local runtime=Runtime.New({initializeRegions=false})
        if not (options and options.missingPort) then
            function runtime:GetPortPosition() return {x=0,y=0} end
            function runtime:ResetShipAtPort() self.ship.position={x=0,y=0}; self:ClearMovementTarget(); return true end
        else
            -- Instance nil shadows the actual inherited Runtime method via __index.
            runtime.GetPortPosition=false
            runtime.ResetShipAtPort=false
        end
        sea={runtime=runtime,options=settings,pointerMinY=0,physicalWidth=dimensions.w,physicalHeight=dimensions.h,dpr=1}
        function sea:SyncViewport()
            self.physicalWidth,self.physicalHeight=dimensions.w,dimensions.h
            self.runtime.movement:SetViewport(dimensions.w,dimensions.h); return true
        end
        sea:SyncViewport()
        sea.tools=settings.uiFactory(runtime,sea)
        function sea:Stop() self.tools.stop(); self.stopped=true end
        return sea
    end}
    local ok,err=xpcall(function()
        local Scene=require("Integration.Scene")
        local value=Scene.Start({initializeRegions=false,development=false})
        action(value,sdk,UI,dimensions)
    end,debug.traceback)
    if sea and not sea.stopped then pcall(sea.Stop,sea) end
    for name,old in pairs(modules) do package.loaded[name]=old.value end
    for name,old in pairs(globals) do _G[name]=old.value end
    if not ok then error(err,0) end
end

function Tests.Run()
    local results={}
    local function check(name, action)
        local ok,err=xpcall(action,debug.traceback)
        results[#results+1]={name=name,passed=ok,error=not ok and tostring(err) or nil}
    end
    check("formal scene defaults to clientCloud read and blocks entry until a choice",function()
        withScene(function(sea,sdk,UI)
            assert(#sdk.gets==1 and #sdk.sets==0 and sea.loop.loading and sea.loop.entryPending)
            assert(UI.rootCount==1 and button(sea.uiRoot,"重试读取"))
            sdk.gets[1].error(500,"offline"); sea.hud.Refresh()
            assert(sea.loop.loadStatus=="error" and not sea.loop:Depart())
            click(sea.uiRoot,"开始新周目")
            assert(sea.loop.entryPending and sea.loop.player.day==1 and #sdk.sets==1)
            assert(sdk.sets[1].snapshot.day==1)
            sdk.sets[1].callbacks.ok(); sea.hud.Refresh()
            assert(not sea.loop.entryPending and sea.loop.initialSaveStatus=="saved")
            sdk.gets[1].ok({[Config.persistence.key]={schemaVersion=0}})
            assert(sea.loop.player.day==1 and sea.loop.loadStatus=="idle")
        end)
    end)
    check("new-run initial save can retry or explicitly continue without waiting",function()
        withScene(function(sea,sdk)
            sdk.gets[1].ok({}); sea.hud.Refresh()
            click(sea.uiRoot,"开始新周目")
            assert(#sdk.sets==1 and sea.loop.entryPending and sea.loop.initialSaveBusy)
            assert(sdk.sets[1].snapshot.day==1)
            sdk.sets[1].callbacks.error(500,"offline"); sea.hud.Refresh()
            assert(sea.loop.initialSaveStatus=="error" and sea.loop.entryPending)
            click(sea.uiRoot,"重试初始保存")
            assert(#sdk.sets==2 and sea.loop.initialSaveStatus=="saving")
            click(sea.uiRoot,"不等待保存，继续")
            assert(not sea.loop.entryPending and sea.loop.initialSaveStatus=="skipped")
            sdk.sets[2].callbacks.ok()
            assert(sea.loop.initialSaveStatus=="skipped" and sea.loop.player.day==1)
        end)
    end)
    check("formal cloud load failure retry restores a legal snapshot at the physical port",function()
        withScene(function(sea,sdk)
            sdk.gets[1].timeout(); sea.hud.Refresh(); click(sea.uiRoot,"重试读取")
            assert(#sdk.gets==2)
            local source=require("Gameplay.Loop").New({}); assert(source:RecognizeLocation("driftwood_barrel"))
            local snapshot=Persistence.Snapshot(source.player)
            sdk.gets[2].ok({[Config.persistence.key]=snapshot},{})
            sea.hud.Refresh()
            assert(sea.loop.loadStatus=="loaded" and not sea.loop.entryPending)
            assert(sea.runtime:GetShipPosition().x==0 and sea.loop.player:IsRecognized("driftwood_barrel"))
            assert(sea.options.isLocationRecognized("driftwood_barrel"))
            assert(not sea.options.isLocationRecognized("anonymous"))
        end)
    end)
    check("missing port API does not turn empty cloud into a fake playable new run",function()
        withScene(function(sea,sdk)
            sdk.gets[1].ok({}); sea.hud.Refresh(); click(sea.uiRoot,"开始新周目")
            assert(sea.loop.entryPending and not sea.loop:Depart())
            assert(sea.loop.player.day==1 and #sdk.sets==0)
        end,{missingPort=true})
    end)
    check("closing the scene during a real adapter read ignores the old callback",function()
        withScene(function(sea,sdk)
            local player=sea.loop.player; assert(sea:Stop()~=false)
            local source=require("Gameplay.Loop").New({}); source.player.money=777
            sdk.gets[1].ok({[Config.persistence.key]=Persistence.Snapshot(source.player)})
            assert(sea.loop.closed and sea.loop.player==player and sea.loop.player.money==100)
        end)
    end)
    check("scene Stop accepts A's false disabled result and closes the real scope",function()
        withScene(function(sea,sdk)
            sdk.gets[1].ok({}); sea.hud.Refresh(); startNewRun(sea,sdk)
            assert(require("Gameplay.Circle1B2Progress").GrantLens(sea.loop.player))
            assert(sea.loop:ToggleScope() and sea.runtime:IsScopeEnabled())
            assert(sea:Stop()~=false)
            assert(not sea.runtime:IsScopeEnabled())
        end)
    end)
    check("HUD old sale callback cannot sell the next identical fish",function()
        withScene(function(sea,sdk)
            sdk.gets[1].ok({}); sea.hud.Refresh(); startNewRun(sea,sdk)
            assert(sea.loop.player.inventory:Add("sardine")); assert(sea.loop.player.inventory:Add("sardine"))
            sea.hud.Refresh(); local old=click(sea.uiRoot,"出售 ¥70")
            assert(sea.loop.player.money==170); old.props.onClick()
            assert(sea.loop.player.money==170 and #sea.loop.player.inventory:GetItems()==3)
        end)
    end)
    check("formal HUD save failure explicitly retries or abandons without double settlement",function()
        withScene(function(sea,sdk)
            sdk.gets[1].ok({}); sea.hud.Refresh(); startNewRun(sea,sdk)
            click(sea.uiRoot,"结束今日"); click(sea.uiRoot,"确认结算")
            assert(#sdk.sets==2 and sea.loop.player.day==2)
            sdk.sets[2].callbacks.error(500,"offline"); sea.hud.Refresh()
            local skip=click(sea.uiRoot,"放弃本次保存，进入下一天")
            skip.props.onClick(); sdk.sets[2].callbacks.ok()
            assert(sea.loop.player.day==2 and not sea.loop.settlementPending and sea.loop.saveStatus=="skipped")
            click(sea.uiRoot,"结束今日"); click(sea.uiRoot,"确认结算")
            assert(#sdk.sets==3); sdk.sets[3].callbacks.error(500,"offline"); sea.hud.Refresh()
            click(sea.uiRoot,"重试保存"); assert(#sdk.sets==4)
            sdk.sets[4].callbacks.ok(); assert(sea.loop.player.day==3 and sea.loop.saveStatus=="saved")
        end)
    end)
    check("ordinary mouse and touch adapter blocks UI and consumes net-center pointer once",function()
        withScene(function(sea,sdk,UI)
            sdk.gets[1].ok({}); sea.hud.Refresh(); startNewRun(sea,sdk); click(sea.uiRoot,"出航")
            local Bootstrap=require("Ocean.Bootstrap")
            UI.hit={}; assert(not Bootstrap.HandlePointer(sea,450,350)); assert(sea.runtime.movement.target==nil)
            UI.hit=nil; assert(sea.loop:BeginFishingSelection()); sea.hud.Refresh()
            local beforeStamina=sea.loop.player.stamina
            assert(sea.bridge:OnSeaPointer({x=1000,y=1000}))
            assert(sea.loop:GetFishingState().state=="selecting" and sea.loop.player.stamina==beforeStamina)
            assert(Bootstrap.HandlePointer(sea,450,350))
            assert(sea.loop:GetFishingState().state=="casting" and sea.runtime.movement.target==nil)
            assert(sea.runtime.ship.isMoving==false and sea.loop.player.stamina==beforeStamina)
            assert(sea.loop:GetThrowSelection()==nil)
            sea.hud.Refresh()
            assert(not button(sea.uiRoot,"确认抛网"))
            local hudChildren=sea.hud.root:GetChildren()
            assert(hudChildren[#hudChildren-1].props.id=="gameplayInventoryDrawer",
                "inventory drawer must precede the full-screen modal")
            assert(hudChildren[#hudChildren-1].props.position=="absolute"
                and hudChildren[#hudChildren-1].props.bottom==0)
            assert(sea.loop:CancelFishingAction())
        end)
    end)
    check("default scene hides sea cheats and recalculates HUD width on resize",function()
        withScene(function(sea,sdk,UI,dimensions)
            assert(not sea.uiRoot:FindById("seaDebugToggle") and not sea.runtime.world.showUnderwater)
            assert(not sea.tools.handleKey(KEY_U))
            assert(not sea.tools.handleKey(KEY_R))
            dimensions.w,dimensions.h=500,360; sea.tools.refresh(0)
            local header=sea.hud.root:GetChildren()[1]
            assert(header.props.maxWidth==310 and header.props.flexWrap=="wrap")
            for _, id in ipairs({"gameplayActionDock","gameplayDrawerBackdrop","gameplayInventoryDrawer"}) do
                local positioned=sea.hud.root:FindById(id)
                assert(positioned and positioned.props.position=="absolute"
                    and (positioned.props.maxWidth==nil or positioned.props.maxWidth=="100%"))
            end
            assert(sea.hud.root:FindById("gameplayInventoryDrawer").props.width=="100%")
            assert(sea.hud.root:FindById("gameplayActionDock").props.right==0)
            assert(sea.uiRoot:FindById("gameplayContentScroll").props.pointerEvents=="box-none")
            assert(UI.rootCount==1)
        end)
    end)
    return {results=results,guiVerified=false,realCloudVerified=false,kind="widget-tree and SDK protocol"}
end
return Tests
