-- 仅供 -validate-test：在正式场景上检验新增平面图，不注册或修改任何实体。
local Scene = require("Integration.Scene")
local Art = require("Ocean.ImageArt")
---@type {atFrame:fun(frame:integer, callback:fun()), assert:fun(condition:boolean, message:string)}
local V = assert(_G["V"], "此脚本只能通过 -validate-test 执行")
local Test = {}
local samples = {
    { name = "reef", position = { x = -10, y = 14 }, length = 4, heading = 0 },
    { name = "shrub", position = { x = 10, y = 14 }, length = 4, heading = 0 },
    { name = "driftwood", position = { x = -8, y = -5 }, length = 3, heading = math.pi / 4 },
    { name = "sardine", position = { x = 8, y = -5 }, length = 2, heading = math.pi / 2 },
}

V.atFrame(10, function()
    Test.scene = Scene.Start({ loadSaved = false, initializeRegions = false,
        store = { Load = function(_, callback) callback(true, nil) end,
            Save = function(_, _, callback) callback(true) end } })
    local sea = Test.scene
    V.assert(sea.loop:Depart(), "正式场景通过公开接口出航")
    sea.bridge:Sync()
    sea.hud.Refresh()
    Test.world, Test.ship, Test.count = sea.runtime.world, sea.runtime.ship, #sea.runtime.world.entities
    sea.options.simulationUpdate = function() sea.bridge:Update(1 / 60, 0, 0) end
    Test.context = nvgCreate(1)
    nvgSetRenderOrder(Test.context, 1)
    for _, sample in ipairs(samples) do
        V.assert(not Art.IsLoaded(sea.context, sample.name), sample.name .. " 不在正式场景默认加载")
        V.assert(Art.LoadImage(Test.context, sample.name), sample.name .. " 候选 PNG 真实加载成功")
    end
    Test.node = Node()
    Test.eventObject = assert(Test.node:CreateScriptObject("LuaScriptObject"))
    Test.eventObject:SubscribeToEvent(Test.context, "NanoVGRender", function()
        local dpr = graphics:GetDPR()
        nvgBeginFrame(Test.context, graphics:GetWidth() / dpr, graphics:GetHeight() / dpr, dpr)
        for _, sample in ipairs(samples) do
            Art.Sprite(Test.context, sample.name, sea.runtime.movement, sample.position,
                sample.length, sample.heading, 0, 1)
        end
        nvgEndFrame(Test.context)
    end)
end)

V.atFrame(115, function()
    local sea = assert(Test.scene)
    V.assert(sea.runtime.world == Test.world and sea.runtime.ship == Test.ship,
        "图片层沿用正式场景 World 与船对象")
    V.assert(#sea.runtime.world.entities == Test.count, "样品绘制不新增实体")
    for _, sample in ipairs(samples) do
        local spec = assert(Art.GetSpec(sample.name))
        V.assert(spec.contentWidth > 0 and spec.contentHeight > 0, sample.name .. " 具有主体尺寸规格")
    end
    sea.loop:ToggleManualPause()
    sea.bridge:Sync()
    Test.time = sea.runtime.time
end)

V.atFrame(125, function()
    V.assert(Test.scene.runtime.time == Test.time, "新增图片不推进暂停时钟")
    Art.Release(Test.context)
    for _, sample in ipairs(samples) do
        V.assert(not Art.IsLoaded(Test.context, sample.name), sample.name .. " 停止后释放纹理")
    end
    V.assert(Art.IsLoaded(Test.scene.context, "boat"), "候选纹理释放不影响正式场景船图")
end)

V.atFrame(140, function()
    Test.eventObject:UnsubscribeFromAllEvents()
    Test.node:Remove()
    Art.Release(Test.context)
    nvgDelete(Test.context)
end)
