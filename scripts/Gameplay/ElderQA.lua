-- scripts/Gameplay/ElderQA.lua — 老人知识问答匹配引擎（A 侧，纯逻辑）
-- 设计：轻量、离线、零依赖。不做中文分词，采用「关键词子串命中计分」：
--   1. 归一化：小写 + 去标点/空白 + 同义词扩展
--   2. 对每个知识库条目，若其任一 keyword 是查询的子串 → 加分（权重 = keyword 字节长度）
--   3. 取总分最高条目；并列时先到先得（更具体的长 keyword 天然占优）
--   4. 无任何命中 → 返回老人风味兜底话术
--
-- 纯函数，便于单测（见 scripts/tests/Circle1ElderQATests.lua）。
local KB = require("data.elder_qa")

local ElderQA = {}

-- 同义词扩展：把玩家口语词归一化到知识库 canonical 词（gsub 为纯文本替换）。
-- 注意：key 不含 Lua 正则元字符（%.%+*?[]()-），可安全作模式。
local SYNONYMS = {
    ["钓"] = "捕鱼",
    ["钓鱼"] = "捕鱼",
    ["下钩"] = "捕鱼",
    ["捞鱼"] = "捕鱼",
    ["卖钱"] = "卖鱼",
    ["换钱"] = "卖鱼",
    ["回港"] = "返港",
    ["回家"] = "返港",
    ["回港口"] = "返港",
    ["回岸"] = "返港",
    ["晚上"] = "夜晚",
    ["天黑"] = "夜晚",
    ["黑天"] = "夜晚",
    ["望远镜"] = "透镜",
    ["饿"] = "体力",
    ["饵"] = "鱼饵",
    ["谢谢"] = "感谢",
    ["感谢"] = "感谢",
    ["谢"] = "感谢",
    ["怎么玩"] = "攻略",
}

local FALLBACK = "这问题，得你自个儿去海上找答案。多看看水鸟，多听听风，海会教你的。"

-- 归一化：小写（仅影响 ascii）、去除标点与空白、应用同义词扩展。
local function normalize(s)
    if not s then return "" end
    s = string.lower(tostring(s))
    s = s:gsub("[%p%s]+", "")
    for k, v in pairs(SYNONYMS) do
        s = s:gsub(k, v)
    end
    return s
end

-- 单条目得分：返回所有命中 keyword 的字节长度之和（越长越具体，分越高）。
local function scoreEntry(entry, q)
    local best = 0
    local kws = entry.keywords
    if not kws then return 0 end
    for _, kw in ipairs(kws) do
        if #kw > 0 and string.find(q, kw, 1, true) then
            best = best + #kw
        end
    end
    return best
end

--- 向老人提问，返回应答结构。
---@param text string 玩家输入（任意自然语言）
---@return table { answer=string, tag=string|nil, matched=boolean, entryId=string|nil }
function ElderQA.ask(text)
    local q = normalize(text)
    if q == "" then
        return { answer = FALLBACK, tag = nil, matched = false, entryId = nil }
    end
    local bestEntry, bestScore = nil, 0
    for _, entry in ipairs(KB) do
        local sc = scoreEntry(entry, q)
        if sc > bestScore then
            bestScore = sc
            bestEntry = entry
        end
    end
    if bestEntry and bestScore > 0 then
        return { answer = bestEntry.answer, tag = bestEntry.tag, matched = true, entryId = bestEntry.id }
    end
    return { answer = FALLBACK, tag = nil, matched = false, entryId = nil }
end

-- 暴露内部函数，便于测试与 Python 核验脚本对照。
ElderQA._normalize = normalize
ElderQA._scoreEntry = scoreEntry
ElderQA._kb = KB
ElderQA._fallback = FALLBACK

return ElderQA
