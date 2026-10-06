-- 批1（2026-10-06）：OceanStory 世界层素材变体开关。
-- 默认关闭（绘制名原样透传）；开启后 island/boat/barrel/gull/waterpaper
-- 解析为 *_story 重绘版（catalog 中 preload=false，首次绘制按需加载，
-- 可能有一帧加载尖峰）。ocean_tile 作为 waterpaper 备选材质，暂不接入
-- （D3 裁决：待真机 A/B 数据）。供 SeaDebug 面板切换与真机 A/B 对比。
local ArtVariants = {}

local enabled = false

local STORY_NAMES = {
    island = "island_story",
    boat = "boat_story",
    barrel = "barrel_story",
    gull = "gull_story",
    waterpaper = "waterpaper_story",
}

function ArtVariants.SetEnabled(value)
    enabled = value and true or false
end

function ArtVariants.IsEnabled()
    return enabled
end

--- 绘制名解析：开启时返回 story 变体名，否则原样返回。
function ArtVariants.Resolve(name)
    if not enabled then return name end
    return STORY_NAMES[name] or name
end

return ArtVariants
