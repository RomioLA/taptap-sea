-- 只用于 -validate-test；调用正式场景公开接口，不写玩家或 Entity 字段。
local Scene = require("Integration.Scene")
local Images = require("Ocean.ImageArt")
local Config = require("Ocean.Config")
---@type {atFrame:fun(frame:integer, callback:fun()), assert:fun(condition:boolean, message:string)}
local V = assert(_G["V"], "此脚本只能通过 -validate-test 执行")
local index = tonumber(os.getenv("OCEAN_ART_DIRECTION") or "1") or 1
local directions = {
    {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1},
}
local axis = directions[index] or directions[1]
local Test = {}

local store = {
    Load = function(_, callback) callback(true, nil) end,
    Save = function(_, _, callback) callback(true) end,
}

V.atFrame(10, function()
    Test.scene = Scene.Start({ loadSaved = false, store = store, initializeRegions = false })
    Test.world = Test.scene.runtime.world
    Test.ship = Test.scene.runtime.ship
    Test.shipId = Test.ship.id
    V.assert(Test.scene.loop:Depart(), "正式 Gameplay 出航接口通过")
    Test.scene.bridge:Sync()
    Test.scene.hud.Refresh()
    Test.start = Test.scene.runtime:GetShipPosition()
    -- 现有鱼生成及 SurfaceSignals 自动产生海鸟线索；不伪造鸟或新的系统。
    Test.scene.runtime:spawnFish("sardine", { x = 7, y = 10 }, 0)
    Test.scene.options.simulationUpdate = function(_, _dt)
        Test.scene.bridge:Update(1 / 60, axis[1], axis[2])
    end
    V.assert(Images.IsLoaded(Test.scene.context, "boat"), "船 PNG 已由引擎加载")
    V.assert(Images.IsLoaded(Test.scene.context, "barrel"), "木桶 PNG 已由引擎加载")
    V.assert(Images.IsLoaded(Test.scene.context, "gull"), "海鸥 PNG 已由引擎加载")
    V.assert(Images.IsLoaded(Test.scene.context, "island"), "岛 PNG 已由引擎加载")
    V.assert(Images.IsLoaded(Test.scene.context, "ripple"), "波纹 PNG 已由引擎加载")
    V.assert(Images.IsLoaded(Test.scene.context, "waterpaper"), "水彩海面纸纹已由引擎加载")
end)

V.atFrame(115, function()
    local scene = assert(Test.scene)
    local position = scene.runtime:GetShipPosition()
    local distance = math.sqrt((position.x - Test.start.x)^2 + (position.y - Test.start.y)^2)
    V.assert(distance > 3, "船沿现有移动系统实际移动超过 3 米")
    local expected = math.atan(axis[2], axis[1])
    local actual = scene.runtime.ship.rotation
    local error = math.atan(math.sin(actual - expected), math.cos(actual - expected))
    V.assert(math.abs(error) < 0.06, "船转向到目标方向")
    V.assert(scene.runtime.world == Test.world and Test.world:get(Test.shipId) == Test.ship,
        "World、船对象及 ID 未因美术改变")
    V.assert(#scene.runtime.movement.wake.records > 0, "船移动产生既有动态尾迹")
    local count = 0
    scene.runtime.surfaceSignals:VisitBirds(function() count = count + 1 end)
    print("[OceanArtTest] direction=" .. index .. " x=" .. position.x .. " y=" .. position.y
        .. " heading=" .. actual .. " birds=" .. count .. " wake=" .. #scene.runtime.movement.wake.records)
    Test.position, Test.time = position, scene.runtime.time
    Test.scene.options.simulationUpdate = function(_, _dt)
        scene.bridge:Update(1 / 60, 0, 0)
    end
end)

V.atFrame(130, function()
    local scene = assert(Test.scene)
    scene.loop:ToggleManualPause()
    V.assert(scene.loop.clock.pauseReasons.manual == true, "现有暂停接口可用")
    scene.bridge:Sync()
    Test.pausedTime = scene.runtime.time
    Test.pausedPosition = scene.runtime:GetShipPosition()
end)

V.atFrame(145, function()
    local scene = assert(Test.scene)
    local position = scene.runtime:GetShipPosition()
    V.assert(scene.runtime.time == Test.pausedTime, "暂停不推进海面动画时间")
    V.assert(position.x == Test.pausedPosition.x and position.y == Test.pausedPosition.y,
        "暂停不移动玩家船")
    V.assert(Config.camera.anchorY == 0.72 and Config.camera.farDepth == 110,
        "保留原摄像机与世界投影参数")
end)
