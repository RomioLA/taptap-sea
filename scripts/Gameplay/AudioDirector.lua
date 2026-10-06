-- AudioDirector：自适应音乐与空间音效系统 v1.0（S0 技术验证桩）
-- 设计文档：《自适应音乐与空间音效系统设计方案_v1.0_2026-10-06.md》
--
-- 实现路径（D-A1 已拍板）：方案 A——独立 SoundSource 池，脱离 Node/Scene。
-- 探针失败时优雅降级并回报原因（真机验收据此决定是否切换方案 B 隐藏音频 Scene）。
--
-- 引擎坑位守则（来源 engine-docs/api/audio.md，勿删）：
--  1) SoundSource:Play 的 frequency 是绝对 Hz，不是 pitch 倍率；
--     变调必须 sound:GetFrequency() * pitch，传 0 表示用素材采样率。
--  2) 复用 SoundSource 时旧频率会残留；每次 Play 显式传全参数。
--  3) sound.looped 修改的是缓存内共享资源；对同一路径重复设 true 幂等无害，
--     但不得对同一路径同时要求循环与非循环两种用法。
--
-- 模块加载为纯 Lua（不触碰引擎全局），可在 headless 测试中 require；
-- 引擎访问全部收敛在函数内并带能力守卫。

local AudioDirector = {}

-- ---------------------------------------------------------------------------
-- 接线总表（设计文档 §7，音量基线按 D-A3 直接实施，S4 真机微调）
-- bus: voice=UI 轨（借位 SOUND_VOICE，暂停不停） / world=世界动作轨（SOUND_EFFECT）
--      amb=环境声床轨（SOUND_AMBIENT）
-- pitchVar: 相对 1.0 的随机抖动幅度（±），0 表示不变调（保音阶完整）
-- pan: 默认声像 -1..1（0=居中；世界事件源方位由 opts.pan 覆盖）
-- ---------------------------------------------------------------------------
local SPECS = {
    ["ui.button_click"]              = { path = "audio/sfx/ui_button_click.wav",              bus = "voice", gain = 0.90, pitchVar = 0.04, pan = 0, loop = false },
    ["ui.menu_open"]                 = { path = "audio/sfx/ui_menu_open.wav",                 bus = "voice", gain = 0.70, pitchVar = 0.00, pan = 0, loop = false },
    ["ui.confirm_choice"]            = { path = "audio/sfx/ui_confirm_choice.wav",            bus = "voice", gain = 0.80, pitchVar = 0.00, pan = 0, loop = false },
    ["action.stamina_spend"]         = { path = "audio/sfx/action_stamina_spend.wav",         bus = "world", gain = 0.50, pitchVar = 0.06, pan = 0, loop = false },
    ["action.set_sail"]              = { path = "audio/sfx/action_set_sail.wav",              bus = "world", gain = 0.80, pitchVar = 0.03, pan = 0, loop = false },
    ["action.catch_success"]         = { path = "audio/sfx/action_catch_success.wav",         bus = "world", gain = 0.90, pitchVar = 0.03, pan = 0, loop = false },
    ["action.explore_failure"]       = { path = "audio/sfx/action_explore_failure.wav",       bus = "world", gain = 0.70, pitchVar = 0.00, pan = 0, loop = false },
    ["explore.unknown_discovery"]    = { path = "audio/sfx/explore_unknown_discovery.wav",    bus = "world", gain = 0.75, pitchVar = 0.03, pan = 0, loop = false },
    ["explore.chest_ruin_discovery"] = { path = "audio/sfx/explore_chest_ruin_discovery.wav", bus = "world", gain = 0.85, pitchVar = 0.03, pan = 0, loop = false },
    ["explore.knowledge_gain"]       = { path = "audio/sfx/explore_knowledge_gain.wav",       bus = "world", gain = 0.70, pitchVar = 0.03, pan = 0, loop = false },
    ["amb.calm_sea"]                 = { path = "audio/sfx/ambience_calm_sea_loop.wav",       bus = "amb",   gain = 0.55, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.night_ocean"]              = { path = "audio/sfx/ambience_night_ocean_loop.wav",    bus = "amb",   gain = 0.50, pitchVar = 0.00, pan = 0, loop = true },
}

-- 总线主增益基线（设计文档 §4）
local BUS_GAIN = { voice = 1.0, world = 1.0, amb = 0.8, music = 0.9, master = 1.0 }
-- 捕鱼 duck（设计文档 §5.2）：amb 主增益 0.8 → 0.56
local AMB_DUCK_GAIN = 0.56

local POOL_SIZE = 8 -- one-shot 轮转池（另含 2 个常驻声床专用源）

local function countSpecs()
    local count = 0
    for _ in pairs(SPECS) do count = count + 1 end
    return count
end

local state = {
    initialized = false,
    capability = "not_probed",
    sounds = {},       -- key -> Sound
    loadedCount = 0,
    pool = {},         -- { { source, key, startedAt } }
    keySlot = {},      -- key -> pool slot（进行中占用；并发上限=1）
    beds = {},         -- key -> { source, active }
    tick = 0,
    fishingDuck = false,
    worldPaused = false,
}

-- ---------------------------------------------------------------------------
-- 引擎访问辅助（全部带守卫，headless 安全）
-- ---------------------------------------------------------------------------

local function getLog()
    if type(log) == "table" or type(log) == "userdata" then
        if type(log.Write) == "function" then return log end
    end
    return nil
end

local function logWarning(message)
    local logger = getLog()
    if logger and type(LOG_WARNING) == "number" then
        pcall(function() logger:Write(LOG_WARNING, "[AudioDirector] " .. message) end)
    end
end

local function getAudio()
    if type(GetAudio) == "function" then
        local ok, instance = pcall(GetAudio)
        if ok and instance then return instance end
    end
    return audio -- 引擎注入的全局（可能为 nil）
end

local function busConstant(bus)
    if bus == "voice" then return SOUND_VOICE or "Voice" end
    if bus == "world" then return SOUND_EFFECT or "Effect" end
    if bus == "amb" then return SOUND_AMBIENT or "Ambient" end
    if bus == "music" then return SOUND_MUSIC or "Music" end
    return SOUND_MASTER or "Master"
end

-- 方案 A 能力探针：SoundSource.new() 独立实例 + audio:AddSoundSource 注册。
-- 任一环节失败即判定方案 A 不可用，返回原因供真机验收降级决策。
local function probeStandalonePool()
    local cacheInstance = cache
    if not cacheInstance or type(cacheInstance.GetResource) ~= "function" then
        return false, "no_resource_cache"
    end
    local audioInstance = getAudio()
    if not audioInstance or type(audioInstance.AddSoundSource) ~= "function" then
        return false, "no_audio_subsystem"
    end
    if type(SoundSource) ~= "table" or type(SoundSource.new) ~= "function" then
        return false, "no_soundsource_constructor"
    end
    local ok, source = pcall(SoundSource.new)
    if not ok or not source then return false, "soundsource_new_failed" end
    local okAdd = pcall(function() audioInstance:AddSoundSource(source) end)
    if not okAdd then return false, "addsoundsource_rejected" end
    pcall(function() audioInstance:RemoveSoundSource(source) end)
    return true, source
end

-- ---------------------------------------------------------------------------
-- 池管理
-- ---------------------------------------------------------------------------

local function nextTick()
    state.tick = state.tick + 1
    return state.tick
end

local function slotPlaying(slot)
    local playing = false
    pcall(function() playing = slot.source:IsPlaying() end)
    return playing
end

local function acquireSlot(key)
    -- 同键重触发：抢占复用原槽位（§7 并发上限=1，杜绝同音叠加）
    if state.keySlot[key] then
        return state.keySlot[key]
    end
    -- 优先空闲槽位
    for _, slot in ipairs(state.pool) do
        if not slot.key and not slotPlaying(slot) then
            return slot
        end
    end
    -- 全忙：抢占启动最早的槽位（最旧优先）
    local oldest = nil
    for _, slot in ipairs(state.pool) do
        if not oldest or slot.startedAt < oldest.startedAt then oldest = slot end
    end
    if oldest then
        pcall(function() oldest.source:Stop() end)
        if oldest.key then state.keySlot[oldest.key] = nil end
        oldest.key = nil
        return oldest
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 初始化（懒加载，幂等）
-- ---------------------------------------------------------------------------

local function applyBusGains()
    local audioInstance = getAudio()
    if not audioInstance then return end
    pcall(function() audioInstance:SetMasterGain(busConstant("master"), BUS_GAIN.master) end)
    pcall(function() audioInstance:SetMasterGain(busConstant("voice"), BUS_GAIN.voice) end)
    pcall(function() audioInstance:SetMasterGain(busConstant("world"), BUS_GAIN.world) end)
    local ambGain = state.fishingDuck and AMB_DUCK_GAIN or BUS_GAIN.amb
    pcall(function() audioInstance:SetMasterGain(busConstant("amb"), ambGain) end)
    pcall(function() audioInstance:SetMasterGain(busConstant("music"), BUS_GAIN.music) end)
end

local function ensureInit()
    if state.initialized then return true end

    local probeOk, probeResult = probeStandalonePool()
    if not probeOk then
        state.capability = "方案A不可用(" .. tostring(probeResult) .. ")：需降级方案B"
        logWarning(state.capability)
        return false
    end

    local cacheInstance = cache
    local audioInstance = getAudio()
    local loaded = 0
    for key, spec in pairs(SPECS) do
        local ok, sound = pcall(function() return cacheInstance:GetResource("Sound", spec.path) end)
        if ok and sound then
            state.sounds[key] = sound
            loaded = loaded + 1
        else
            logWarning("加载失败: " .. key .. " <- " .. spec.path)
        end
    end
    state.loadedCount = loaded
    if loaded == 0 then
        state.capability = "方案A可用但0个音效加载成功：检查资源路径/DWP"
        logWarning(state.capability)
        return false
    end

    -- one-shot 轮转池
    state.pool = {}
    for _ = 1, POOL_SIZE do
        local ok, source = pcall(SoundSource.new)
        if not ok or not source then
            state.capability = "方案A可用但池创建失败"
            logWarning(state.capability)
            return false
        end
        pcall(function() source:SetDeclickEnabled(true) end)
        pcall(function() audioInstance:AddSoundSource(source) end)
        state.pool[#state.pool + 1] = { source = source, key = nil, startedAt = 0 }
    end

    -- 常驻声床专用源（各 1 个，循环）
    for key, spec in pairs(SPECS) do
        if spec.loop then
            local ok, source = pcall(SoundSource.new)
            if ok and source then
                pcall(function() source:SetDeclickEnabled(true) end)
                pcall(function() source.soundType = busConstant(spec.bus) end)
                pcall(function() audioInstance:AddSoundSource(source) end)
                state.beds[key] = { source = source, active = false }
            end
        end
    end

    applyBusGains()
    state.initialized = true
    state.capability = "方案A可用(独立池" .. tostring(#state.pool) .. "+声床" .. tostring(#state.beds) .. ")"
    return true
end

-- ---------------------------------------------------------------------------
-- 公共 API
-- ---------------------------------------------------------------------------

---播放 one-shot。opts: { gainMul = number, pan = number }
---@return boolean ok
---@return string message
function AudioDirector.Play(key, opts)
    local spec = SPECS[key]
    if not spec then return false, "unknown_audio_key(" .. tostring(key) .. ")" end
    if spec.loop then return false, "use_toggle_bed_for_loop(" .. tostring(key) .. ")" end
    if not ensureInit() then return false, state.capability end

    local sound = state.sounds[key]
    if not sound then return false, "sound_not_loaded(" .. tostring(key) .. ")" end

    local length = 0
    pcall(function() length = sound:GetLength() end)
    if length <= 0 then return false, "sound_not_ready_dwp(重试即可)" end

    local slot = acquireSlot(key)
    if not slot then return false, "pool_exhausted" end

    local source = slot.source
    local gain = spec.gain * ((opts and opts.gainMul) or 1)
    local pan = (opts and opts.pan) or spec.pan or 0
    local frequency = 0
    if spec.pitchVar > 0 then
        local pitch = 1 + (math.random() * 2 - 1) * spec.pitchVar
        frequency = sound:GetFrequency() * pitch -- 坑位守则 1：绝对 Hz
    end

    local okPlay = pcall(function()
        source.soundType = busConstant(spec.bus)
        source:Play(sound, frequency, gain, pan) -- 坑位守则 2：显式全参数
    end)
    if not okPlay then return false, "play_failed(" .. tostring(key) .. ")" end

    if slot.key and slot.key ~= key then state.keySlot[slot.key] = nil end
    slot.key = key
    slot.startedAt = nextTick()
    state.keySlot[key] = slot
    return true, "已播放 " .. key
end

---声床循环开关（S0 调试用；S2 起由 SetPhase 驱动昼夜切换与 3s 交叉淡化）
---@return boolean ok
---@return string message
function AudioDirector.ToggleBed(key)
    local spec = SPECS[key]
    if not spec then return false, "unknown_audio_key(" .. tostring(key) .. ")" end
    if not spec.loop then return false, "not_a_bed(" .. tostring(key) .. ")" end
    if not ensureInit() then return false, state.capability end

    local bed = state.beds[key]
    local sound = state.sounds[key]
    if not bed or not sound then return false, "bed_not_ready(" .. tostring(key) .. ")" end

    local length = 0
    pcall(function() length = sound:GetLength() end)
    if length <= 0 then return false, "sound_not_ready_dwp(重试即可)" end

    if bed.active then
        pcall(function() bed.source:Stop() end)
        bed.active = false
        return true, "声床已停止 " .. key
    end

    pcall(function() sound.looped = true end) -- 幂等；同路径仅循环用途
    local okPlay = pcall(function() bed.source:Play(sound, 0, spec.gain) end)
    if not okPlay then return false, "bed_play_failed(" .. tostring(key) .. ")" end
    bed.active = true
    return true, "声床已循环 " .. key
end

---调试/验收状态行（Maker 无控制台，走屏幕通道）
---@return string
function AudioDirector.Status()
    if not state.initialized then
        return "音频未初始化｜" .. state.capability
    end
    local bedText = {}
    for key, bed in pairs(state.beds) do
        bedText[#bedText + 1] = key .. ":" .. (bed.active and "开" or "关")
    end
    return state.capability
        .. "｜加载" .. tostring(state.loadedCount) .. "/" .. tostring(countSpecs())
        .. "｜声床 " .. (next(bedText) and table.concat(bedText, " ") or "无")
end

---返回接线规格副本（测试与未来 data/ 契约迁移用）
function AudioDirector.GetSpec(key)
    local spec = SPECS[key]
    if not spec then return nil end
    local copy = {}
    for field, value in pairs(spec) do copy[field] = value end
    return copy
end

function AudioDirector.ListKeys()
    local keys = {}
    for key in pairs(SPECS) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

---设置页音量滑杆
function AudioDirector.SetBusVolume(bus, gain)
    BUS_GAIN[bus] = gain
    if state.initialized then
        local audioInstance = getAudio()
        if audioInstance then
            pcall(function() audioInstance:SetMasterGain(busConstant(bus), gain) end)
        end
    end
end

---暂停策略：停世界轨与声床轨，UI（VOICE）与未来配乐轨（MUSIC）保留
function AudioDirector.SetPaused(paused)
    state.worldPaused = paused == true
    if not state.initialized then return end
    local audioInstance = getAudio()
    if not audioInstance then return end
    if state.worldPaused then
        pcall(function() audioInstance:PauseSoundType(busConstant("world")) end)
        pcall(function() audioInstance:PauseSoundType(busConstant("amb")) end)
    else
        pcall(function() audioInstance:ResumeSoundType(busConstant("world")) end)
        pcall(function() audioInstance:ResumeSoundType(busConstant("amb")) end)
    end
end

---捕鱼 duck（S2 起由 Loop 状态变化推送；S0 仅供调试）
function AudioDirector.SetFishing(active)
    state.fishingDuck = active == true
    if state.initialized then
        local audioInstance = getAudio()
        if audioInstance then
            local ambGain = state.fishingDuck and AMB_DUCK_GAIN or BUS_GAIN.amb
            pcall(function() audioInstance:SetMasterGain(busConstant("amb"), ambGain) end)
        end
    end
end

---场景关闭时停声（S1 起由 Integration/Scene.lua 生命周期调用）
function AudioDirector.Shutdown()
    for _, bed in pairs(state.beds) do
        pcall(function() bed.source:Stop() end)
        bed.active = false
    end
    for _, slot in ipairs(state.pool) do
        pcall(function() slot.source:Stop() end)
    end
    state.keySlot = {}
end

return AudioDirector
