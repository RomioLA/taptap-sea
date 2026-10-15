-- 批1（2026-10-06）：OceanStory 世界层素材变体开关。
-- 默认关闭（绘制名原样透传）；开启后 island/barrel/gull/waterpaper
-- 解析为 *_story 重绘版（catalog 中 preload=false，首次绘制按需加载，
-- 可能有一帧加载尖峰）。ocean_tile 作为 waterpaper 备选材质，暂不接入
-- （D3 裁决：待真机 A/B 数据）。供 SeaDebug 面板切换与真机 A/B 对比。
-- 2026-10-16：boat 映射移除——船贴图替换效果不好，用户裁决还原无贴图矢量形态，
-- boat/boat_story 目录项与素材文件同步删除，不再有船的贴图加载路径。
local ArtVariants = {}

-- 真机反馈 2026-10-07：默认关闭导致真机看不到水彩世界层（调试入口当时也缺失），
-- 故默认开启——重绘版即本批美术验收主体；仍可经 SeaDebug 面板 StoryArt 按钮切回原版对比。
local enabled = true

local STORY_NAMES = {
    island = "island_story",
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

--- story 变体目标名清单（catalog 键，去重）。
--- 供 ImageArt 启动预载与测试守护使用；调用方不得改写返回值语义。
---@return string[]
function ArtVariants.StoryTargets()
    local seen, targets = {}, {}
    for _, storyName in pairs(STORY_NAMES) do
        if not seen[storyName] then
            seen[storyName] = true
            targets[#targets + 1] = storyName
        end
    end
    return targets
end

return ArtVariants
