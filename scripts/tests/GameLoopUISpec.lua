-- 非 GUI 接线验证：只记录 widget 树与按钮回调，不证明实际像素布局。
local Config = require("config.gameplay")
local Loop = require("Gameplay.Loop")
local Debug = require("Gameplay.Debug")
local passed = 0
local function test(name, fn) fn(); passed=passed+1; print("PASS "..name) end
local function eq(value, expected) assert(value==expected,tostring(value).." ~= "..tostring(expected)) end

local Widget = {}
Widget.__index = Widget
function Widget:AddChild(child) self.children[#self.children+1]=child; child.parent=self end
function Widget:RemoveChild(child)
    for index,value in ipairs(self.children) do if value==child then table.remove(self.children,index); break end end
    child.parent=nil
end
function Widget:GetChildAt(index) return self.children[index] end
function Widget:GetChildren() return self.children end
function Widget:ClearChildren() self.children={} end
function Widget:SetVisible(value) self.visible=value end
function Widget:IsVisible() return self.visible end
function Widget:Show() self:SetVisible(true) end
function Widget:Hide() self:SetVisible(false) end
function Widget:SetText(value)
    assert(self.kind=="Label" or self.kind=="Button","SetText called on "..self.kind)
    self.props.text=value
end
function Widget:SetDisabled(value) assert(self.kind=="Button"); self.disabled=value end
function Widget:Destroy()
    self.destroyed=true
    if self.parent then self.parent:RemoveChild(self) end
end
local UI={}
for _,kind in ipairs({"Panel","SafeAreaView","Label","Button","Spacer","ScrollView","TextField"}) do
    UI[kind]=function(props)
        props=props or {}
        local widget=setmetatable({kind=kind,props=props,children={},visible=props.visible~=false,disabled=false},Widget)
        for _,child in ipairs(props.children or {}) do widget:AddChild(child) end
        return widget
    end
end
package.loaded["urhox-libs/UI"]=UI
local HUD=require("Gameplay.HUD")
local Bootstrap=require("Gameplay.Bootstrap")

local function walk(root, visit, visibleOnly)
    if visibleOnly and not root.visible then return end
    visit(root)
    for _,child in ipairs(root.children) do walk(child,visit,visibleOnly) end
end
local function button(root,text,first)
    local found
    walk(root,function(widget)
        if widget.kind=="Button" and widget.props.text==text and (not first or not found) then found=widget end
    end,true)
    assert(found,"missing visible button: "..text)
    assert(not found.disabled,"disabled button: "..text)
    found.props.onClick(found)
end
local function texts(root)
    local result={}
    walk(root,function(widget) if widget.props.text then result[#result+1]=widget.props.text end end,true)
    return table.concat(result,"\n")
end
local function contains(root,text) assert(texts(root):find(text,1,true),"missing HUD text: "..text) end
local function store()
    local mock={callbacks={},saves={}}
    function mock:Load(done) done(true,nil) end
    function mock:Save(snapshot,done) self.saves[#self.saves+1]=snapshot; self.callbacks[#self.callbacks+1]=done end
    return mock
end

test("HUD always visible information, host subtree and core button wiring",function()
    local mock=store(); local parent=UI.Panel{}
    local loop,hud,update,stop=Bootstrap.Init{store=mock,parent=parent}
    eq(#parent.children,1); eq(loop.loading,false)
    contains(hud.root,"第 1 天"); contains(hud.root,"白天"); contains(hud.root,"120")
    contains(hud.root,"100/100"); contains(hud.root,"钱：100"); contains(hud.root,"2 / 5")
    contains(hud.root,"苹果"); contains(hud.root,"鱼饵"); contains(hud.root,"暂停：port")
    button(hud.root,"出航"); update(10); eq(loop.clock.elapsed,10)
    button(hud.root,"背包"); update(10); eq(loop.clock.elapsed,10); eq(loop.inventoryOpen,true)
    button(hud.root,"背包"); update(5); eq(loop.clock.elapsed,15)
    button(hud.root,"返港"); button(hud.root,"拜访老人"); eq(loop.elderOpen,true)
    button(hud.root,"给予"); eq(#loop.player.inventory:GetItems(),1)
    button(hud.root,"结束对话"); eq(loop.elderOpen,false)
    stop(); eq(#parent.children,0); eq((hud.root --[[@as table]]).destroyed,true); eq(update(1),false)
end)

test("forced return modal and failed save retry through actual callbacks",function()
    local mock=store(); local loop,hud,update=Bootstrap.Init{store=mock}
    button(hud.root,"出航"); update(180)
    contains(hud.root,"夜深了，你必须返港。"); button(hud.root,"确认返港")
    eq(loop.player.day,2); eq(loop.player.stamina,50); eq(#mock.saves,1)
    mock.callbacks[1](false,"offline"); hud.Refresh(); contains(hud.root,"保存失败")
    button(hud.root,"重试保存"); eq(#mock.saves,2); eq(loop.player.day,2)
    mock.callbacks[2](true); hud.Refresh(); contains(hud.root,"已自动保存")
end)

test("failed save offers an explicit unsaved continuation through the HUD",function()
    local mock=store(); local loop,hud=Bootstrap.Init{store=mock}
    button(hud.root,"结束今日"); button(hud.root,"确认结算")
    mock.callbacks[1](false,"offline"); hud.Refresh()
    contains(hud.root,"退出后当天未保存进度可能丢失")
    button(hud.root,"放弃本次保存，进入下一天")
    eq(loop.player.day,2); eq(loop.saveStatus,"skipped"); eq(loop.settlementPending,false)
    contains(hud.root,"本次结算未保存")
    button(hud.root,"出航"); eq(loop.inPort,false); eq(#mock.saves,1)
end)

test("debug restricted to development, config steps and freeze during save",function()
    local mock=store(); local loop=Loop.New{store=mock}
    eq(Debug.New(loop,false):Execute("moneyPlus"),false)
    local debug=Debug.New(loop,true)
    assert(debug:Execute("moneyPlus")); eq(loop.player.money,200)
    assert(debug:Execute("staminaMinus")); eq(loop.player.stamina,80)
    assert(debug:Execute("staminaPlus")); eq(loop.player.stamina,100)
    assert(debug:Execute("clearInventory")); eq(#loop.player.inventory:GetItems(),0)
    for _,id in ipairs({"apple","bait","sardine","tuna"}) do assert(debug:Execute("addItem",id)) end
    eq(#loop.player.inventory:GetItems(),4)
    assert(debug:Execute("seekNight",55)); eq(loop.clock.elapsed,55)
    eq(debug:Execute("seekNight",61),false); eq(loop.clock.elapsed,55)
    assert(debug:Execute("timeScale",20)); eq(loop.clock.timeScale,20)
    assert(debug:Execute("pauseReasons")); assert(debug:Execute("settleDay"))
    eq(loop.player.stamina,75)
    eq(debug:Execute("moneyPlus"),false); eq(debug:Execute("clearInventory"),false)
    eq(debug:Execute("seekDay",0),false); eq(loop.player.money,200)
    mock.callbacks[1](true)
end)

test("development HUD controls configure actions without production debug",function()
    local loop,hud=Bootstrap.Init{store=store(),development=true}
    button(hud.root,"开发调试"); button(hud.root,"出航")
    local fishingText="钓鱼（"..tostring(Config.stamina.fishingCost).."体力）"
    button(hud.root,fishingText); eq(loop.player.stamina,60)
    local salvageText="打捞（"..tostring(Config.stamina.salvageCost).."体力）"
    button(hud.root,salvageText); eq(loop.player.stamina,20)
    local _,production=Bootstrap.Init{store=store()}
    eq(texts(production.root):find("开发调试",1,true),nil)
end)

test("port upgrade buttons use config prices and refresh after purchase",function()
    local loop,hud=Bootstrap.Init{store=store()}
    loop.player.money=3900; hud.Refresh()
    button(hud.root,"升级体力 · ¥400"); eq(loop.player.maxStamina,160); eq(loop.player.money,3500)
    button(hud.root,"升级体力 · ¥600"); eq(loop.player.maxStamina,200)
    button(hud.root,"升级航速 · ¥350"); eq(loop.player.boatSpeedLevel,2)
    button(hud.root,"升级航速 · ¥750"); eq(loop.player.boatSpeedLevel,3)
    button(hud.root,"背包")
    button(hud.root,"扩容 · ¥300"); eq(loop.player.inventory:GetCapacity(),10)
    button(hud.root,"扩容 · ¥600"); eq(loop.player.inventory:GetCapacity(),15)
    button(hud.root,"扩容 · ¥900"); eq(loop.player.inventory:GetCapacity(),20); eq(loop.player.money,0)
end)

test("daily shop stock sold-out UI and next-day refresh",function()
    for _,case in ipairs({{"苹果",30},{"鱼饵",20}}) do
        local loop,hud=Bootstrap.Init{store=store()}; loop.player.money=1000; hud.Refresh()
        contains(hud.root,case[1].."库存：2")
        button(hud.root,case[1].." · ¥"..case[2]); button(hud.root,case[1].." · ¥"..case[2])
        contains(hud.root,case[1].."库存：0"); contains(hud.root,case[1].." · 售罄")
        local soldOut
        walk(hud.root,function(w) if w.kind=="Button" and w.props.text==case[1].." · 售罄" then soldOut=w end end,true)
        assert(soldOut and not soldOut.disabled)
        local money, count = loop.player.money, #loop.player.inventory:GetItems()
        button(hud.root,case[1].." · 售罄")
        contains(hud.root,"售罄")
        eq(loop.player.money,money); eq(#loop.player.inventory:GetItems(),count)
        assert(loop:EndToday()); assert(loop:ConfirmSettlement())
        -- mock异步保存，成功后库存和商店可用性均刷新。
        loop.store.callbacks[1](true); hud.Refresh(); contains(hud.root,case[1].."库存：2")
    end
end)

local FishingFlow = require("Tests.Circle1BFishingFlowTests")

test("production fishing HUD selects confirms pauses cancels without a debug shortcut",function()
    local env=FishingFlow.Fixture()
    env.runtime:spawnFish("sardine",{x=1,y=0})
    assert(env.loop:Depart())
    local hud=HUD.Create(env.loop)
    button(hud.root,"捕鱼 · 选择网心")
    eq(env.runtime.selectCalls,0)
    assert(env.loop:SetFishingCenter({x=0,y=0})); hud.Refresh()
    button(hud.root,"确认抛网")
    eq(env.loop:SetInventoryOpen(true),false)
    env.bridge:Update(0.5,1,1); hud.Refresh()
    eq(env.loop:GetFishingState().state,"landed")
    env.loop:ToggleManualPause(); env.bridge:Update(1); hud.Refresh()
    eq(env.loop:GetFishingState().elapsed,0.5)
    button(hud.root,"取消捕鱼")
    eq(env.loop.player.stamina,100); eq(env.loop:GetFishingState().state,"cancelled")
end)

test("pending cabin menu returns without closing then consumes and claims exactly once",function()
    local env=FishingFlow.Fixture{items={"apple","bait","bait","bait","bait"}}
    env.runtime:spawnFish("sardine",{x=1,y=0}); assert(env.loop:Depart())
    local hud=HUD.Create(env.loop)
    button(hud.root,"捕鱼 · 选择网心");assert(env.loop:SetFishingCenter({x=0,y=0}));hud.Refresh()
    button(hud.root,"确认抛网"); env.bridge:Update(4); hud.Refresh()
    eq(env.loop:HasPendingCatch(),true);eq(env.loop.inventoryOpen,true)
    eq(env.loop:SetInventoryOpen(false),false)
    contains(hud.root,"空间不足")
    button(hud.root,"操作",true); button(hud.root,"给予")
    contains(hud.root,"请先打开老人对话")
    button(hud.root,"返回");eq(env.loop.inventoryOpen,true);eq(env.loop:HasPendingCatch(),true)
    button(hud.root,"操作",true);button(hud.root,"使用")
    local stamina=env.loop.player.stamina
    button(hud.root,"领取渔获")
    eq(env.loop:HasPendingCatch(),false);eq(env.loop.player.stamina,stamina)
    eq(#env.loop.player.inventory:GetItems(),5)
    eq(env.loop:ClaimPendingCatch(),false)
    button(hud.root,"背包");eq(env.loop.inventoryOpen,false)
end)

test("pending cabin pointer chooses drop position while paused with mouse and touch",function()
    local PendingInput=require("Integration.Circle1BInput")
    for _,kind in ipairs({"mouse","touch"}) do
        local env=FishingFlow.Fixture{items={"bait","bait","bait","bait","bait"}}
        env.runtime:spawnFish("sardine",{x=1,y=0});assert(env.loop:Depart())
        assert(env.bridge:BeginFishing({x=0,y=0}));env.bridge:Update(4)
        local screenX,screenY
        env.runtime.movement={ScreenToWorld=function(_,x,y) screenX,screenY=x,y;return{x=2,y=0}end}
        local ocean={physicalWidth=200,physicalHeight=100,dpr=2,pointerMinY=0,SyncViewport=function()return true end}
        local ui={GetScale=function()return 2 end,FindWidgetAt=function()return nil end}
        local event={x=50,y=40,pointerType=kind,IsPrimaryButton=function()return true end}
        assert(PendingInput.HandlePendingPointer(env.bridge,ocean,event,ui))
        eq(screenX,50);eq(screenY,40);eq(env.runtime.paused,true)
        assert(env.loop:DropItem(1));assert(env.loop:ClaimPendingCatch())
        eq(#env.loop.player.inventory:GetItems(),5);eq(env.runtime.removeCalls,1)
        ui.FindWidgetAt=function()return{}end
        eq(PendingInput.HandlePendingPointer(env.bridge,ocean,event,ui),false)
    end
end)

print("GAME_LOOP_UI_MOCK_PASS "..passed)
return passed
