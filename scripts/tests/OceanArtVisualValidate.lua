-- 仅供 -validate-test：最终 PNG 动态和远岸证据，不改变正式场景参数。
local Scene = require("Integration.Scene")
local Images = require("Ocean.ImageArt")
local Projection = require("Ocean.Projection")
---@type {atFrame:fun(frame:integer, callback:fun()), assert:fun(condition:boolean, message:string)}
local V = assert(_G["V"], "此脚本只能通过 -validate-test 执行")
local depth = tonumber(os.getenv("OCEAN_ART_DEPTH") or "0") or 0
local Test = {}
local function birds(scene)
    local result = {}
    scene.runtime.surfaceSignals:VisitBirds(function(x, y, heading, dive, id)
        result[#result + 1] = { x = x, y = y, heading = heading, dive = dive, id = id }
    end)
    return result
end

V.atFrame(10, function()
    local departure = depth > 0 and { x = 35, y = 25 - depth } or { x = 14, y = 0 }
    Test.scene = Scene.Start({ loadSaved = false, initializeRegions = false, departure = departure,
        store = { Load = function(_, callback) callback(true, nil) end,
            Save = function(_, _, callback) callback(true) end } })
    local scene = Test.scene
    V.assert(scene.loop:Depart(), "公开接口进入主航海场景")
    scene.bridge:Sync()
    scene.hud.Refresh()
    Test.world, Test.ship = scene.runtime.world, scene.runtime.ship
    if depth == 0 then scene.runtime:spawnFish("sardine", { x = 7, y = 10 }, 0) end
    scene.options.simulationUpdate = function() scene.bridge:Update(1 / 60, 0, 0) end
    for _, name in ipairs({ "boat", "island", "barrel", "gull", "ripple", "waterpaper" }) do
        V.assert(Images.IsLoaded(scene.context, name), name .. " PNG 实际加载")
    end
end)

V.atFrame(70, function()
    local scene = assert(Test.scene)
    Test.birds = birds(scene)
    Test.time = scene.runtime.time
    if depth == 0 then
        V.assert(#Test.birds == 1, "现有 SurfaceSignals 实际生成一只海鸟（2026-10-06 用户裁决：每处 2 只改 1 只）")
    else
        local movement = scene.runtime.movement
        local point = { x = 35, y = 25 }
        local visibility = Projection.Visibility(movement, point, 0)
        -- Project 仍返回远处延拓表面的坐标；是否遮挡由 Visibility 决定。
        if depth > 110 then
            V.assert(visibility < 0, "远岸地面遵守原地平线遮挡")
        else
            V.assert(visibility >= 0, "切线前岛面仍可见")
        end
        print("[OceanArtVisual] island depth=" .. depth)
    end
end)

V.atFrame(115, function()
    local scene = assert(Test.scene)
    V.assert(scene.runtime.world == Test.world and scene.runtime.ship == Test.ship,
        "视觉测试期间 World 与船身份稳定")
    V.assert(scene.runtime.time > Test.time, "静止船时海面仍按既有时钟更新")
    if depth == 0 then
        local current = birds(scene)
        V.assert(#current == 2, "动态海鸟群持续存在")
        local before, after = Test.birds[1], current[1]
        V.assert(before.x ~= after.x or before.y ~= after.y or before.dive ~= after.dive,
            "海鸟盘旋或俯冲状态跨帧变化")
        local a = (Test.time * 0.48) % 1
        local b = (scene.runtime.time * 0.48) % 1
        V.assert(math.abs(a - b) > 0.05, "透明波纹读取的扩散相位跨帧变化")
        print("[OceanArtVisual] birds=2 ripple phase=" .. a .. " -> " .. b)
    end
end)

V.atFrame(130, function()
    local scene = assert(Test.scene)
    scene.loop:ToggleManualPause()
    scene.bridge:Sync()
    Test.pausedTime, Test.pausedBirds = scene.runtime.time, birds(scene)
end)

V.atFrame(145, function()
    local scene = assert(Test.scene)
    V.assert(scene.runtime.time == Test.pausedTime, "暂停冻结波纹使用的海洋时间")
    local current = birds(scene)
    local same = #current == #Test.pausedBirds
    for index, before in ipairs(Test.pausedBirds) do
        local after = current[index]
        same = same and after ~= nil and before.x == after.x and before.y == after.y
            and before.heading == after.heading and before.dive == after.dive
    end
    V.assert(same, "暂停冻结海鸟位置、朝向与俯冲")
end)
