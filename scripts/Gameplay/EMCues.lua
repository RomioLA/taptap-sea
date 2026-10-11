-- A 任务：HUD 现象命名 / 短文案（只读事实性表现层）。
--
-- 设计约束（来源《读海》涌现现象内容卡提案 v1.0，第 0.3 / 第 6 节）：
--   * 仅依据 SurfaceSignals 的公开读取接口（GetBirds / GetSplashes）推导文案；
--   * 不写鱼 / 鸟 / 玩家任何状态；不新增 Schema、数值或独立模拟；
--   * 无信号时返回空串——绝不编造、绝不把随机结果包装成「理解」或「保证」。
--   * 文案严格沿用提案的「信号表达」口径，不得过度承诺
--     （禁止写成「很多鱼」「大鱼就在这里」「现在撒网必定有收获」等）。
--
-- 现象名（鸟影下的空隙 / 退潮的箭头）取自提案各卡「现象名（文案候选）」，
-- 仅作显示候选，不是新增系统标签。
local EMCues = {}

-- 从公开读取接口构造事实性现象短文案。
-- @param surfaceSignals Ocean.SurfaceSignals | nil  （Runtime.surfaceSignals）
-- @return string  多条线索用中文分号连接；无信号返回 ""
function EMCues.Build(surfaceSignals)
    if not surfaceSignals then return "" end
    local okB, birds = pcall(surfaceSignals.GetBirds, surfaceSignals)
    local okS, splashes = pcall(surfaceSignals.GetSplashes, surfaceSignals)
    birds = (okB and type(birds) == "table") and birds or {}
    splashes = (okS and type(splashes) == "table") and splashes or {}

    local lines = {}
    -- EM-CARD-01 §1.2 信号表达：「这里附近有仍在活动的小鱼」
    -- 仅说明附近存在活跃小鱼（模糊投饵区域），不作数量/位置/捕获保证。
    if #birds > 0 then
        lines[#lines + 1] = "鸟影下的空隙：附近有仍在活动的小鱼"
    end
    -- EM-CARD-02 §2.2 信号表达：「一条大鱼刚从这里经过，并朝某方向移动过」
    -- 水花是短暂历史痕迹，不是大鱼当前坐标或可捕鱼保证。
    if #splashes > 0 then
        lines[#lines + 1] = "退潮的箭头：一条大鱼刚从这里经过，并朝某方向移动过"
    end
    return table.concat(lines, "；")
end

return EMCues
