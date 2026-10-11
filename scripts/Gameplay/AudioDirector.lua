-- AudioDirector：自适应音乐与空间音效系统 v1.0（S0 技术验证桩）
-- 设计文档：《自适应音乐与空间音效系统设计方案_v1.0_2026-10-06.md》
--
-- 声源由持有的隐藏 Scene/Node 创建，通过引擎组件生命周期自动注册到 Audio。
-- 不使用未导出的 SoundSource.new，也不手动重复 AddSoundSource。
-- 音频 Scene 不参与玩法 World、渲染或时钟调度。
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
    -- AI 生成版环境音（Maker 内置 batch_sound_effects / Seed Audio，2026-10-08 重出；
    -- 已按既有声床 RMS 响度归一化；v1 程序合成版见 git 历史 b3aba52 之前）
    ["amb.morning_sea"]            = { path = "audio/sfx/amb_morning_sea_ai.wav",        bus = "amb",   gain = 0.55, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.overcast_sea"]           = { path = "audio/sfx/amb_overcast_sea_ai.wav",       bus = "amb",   gain = 0.55, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.storm_premonition"]      = { path = "audio/sfx/amb_storm_premonition_ai.wav",  bus = "amb",   gain = 0.50, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.rare_fish"]              = { path = "audio/sfx/amb_rare_fish_ai.wav",          bus = "amb",   gain = 0.50, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.deep_ruins"]             = { path = "audio/sfx/amb_deep_ruins_ai.wav",         bus = "amb",   gain = 0.50, pitchVar = 0.00, pan = 0, loop = true },
    ["amb.elder_npc"]              = { path = "audio/sfx/amb_elder_npc_ai.wav",          bus = "amb",   gain = 0.55, pitchVar = 0.00, pan = 0, loop = true },
}

-- 总线主增益基线（设计文档 §4）
local BUS_GAIN = { voice = 1.0, world = 1.0, amb = 0.8, music = 0.9, master = 1.0 }
-- 捕鱼 duck（设计文档 §5.2）：amb 主增益 0.8 → 0.56
local AMB_DUCK_GAIN = 0.56

local POOL_SIZE = 8 -- one-shot 轮转池；每张环境声床另有一个专用源

local function countSpecs()
    local count = 0
    for _ in pairs(SPECS) do count = count + 1 end
    return count
end

---@type Scene?
local audioScene = nil -- 明确持有顶层 Scene，防止 Lua GC 提前回收声源宿主。
---@type SoundSource[]
local audioSources = {} -- 包括尚未加入池的组件，初始化中途失败也可完整释放。

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
    audioReady = nil,  -- 引擎音频子系统 IsInitialized()（nil=未探测；诊断用）
    pathSample = nil,  -- 首个成功解析的资源路径样本（真机路径诊断）
    firstPath = nil,   -- 首个尝试的原始路径（全部失败时上报）
    initAttempts = 0,     -- ensureInit 累计调用数（失败退避节拍器，评审 P1-2）
    lastFailAttempts = nil, -- 上次初始化失败时的 attempts（nil=从未失败）
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

-- ResourceCache 获取：优先引擎注入的 cache 全局；缺失时兜底 engine:GetResourceCache()
--（UrhoX 不同运行时的全局注入存在差异，真机曾因 cache 缺失整系统静默——2026-10-08）。
local function getCache()
    if (type(cache) == "table" or type(cache) == "userdata")
        and type(cache.GetResource) == "function" then
        return cache
    end
    local ok, fallback = pcall(function()
        local eng = (type(GetEngine) == "function" and GetEngine()) or engine
        if eng and type(eng.GetResourceCache) == "function" then
            return eng:GetResourceCache()
        end
        return nil
    end)
    if ok and fallback then return fallback end
    return nil
end

-- 候选资源路径：仓库文件位于 assets/audio/sfx/，而 SPECS 历史写法为 audio/sfx/；
-- 运行时资源根无法在脚本侧确定（Maker 打包决定），故按候选集逐一尝试自愈，
-- 并在 Status 上报实际解析路径供真机验收。2026-10-08 真机静音排查。
local function candidatePaths(spec)
    local p = spec.path
    local out = { p }
    if p:sub(1, 6) == "audio/" then
        out[#out + 1] = "assets/" .. p
        out[#out + 1] = p:sub(7) -- sfx/X.wav
    elseif p:sub(1, 7) == "assets/" then
        out[#out + 1] = p:sub(8)
    else
        out[#out + 1] = "assets/audio/" .. p
    end
    local seen, list = {}, {}
    for _, v in ipairs(out) do
        if not seen[v] then seen[v] = true; list[#list + 1] = v end
    end
    return list
end

---按候选路径逐一 GetResource，返回首个命中的 (sound, path)。
local function resolveSound(cacheInstance, spec)
    for _, path in ipairs(candidatePaths(spec)) do
        local ok, sound = pcall(function() return cacheInstance:GetResource("Sound", path) end)
        if ok and sound then return sound, path end
    end
    return nil, nil
end

local function busConstant(bus)
    if bus == "voice" then return SOUND_VOICE or "Voice" end
    if bus == "world" then return SOUND_EFFECT or "Effect" end
    if bus == "amb" then return SOUND_AMBIENT or "Ambient" end
    if bus == "music" then return SOUND_MUSIC or "Music" end
    return SOUND_MASTER or "Master"
end

-- Lua 池也持有组件引用，不能仅释放 Scene 后等待 GC；逐个移除并立即释放。
local function releaseAudioScene()
    for _, source in ipairs(audioSources) do
        pcall(function() source:StopImmediate() end)
        pcall(function() source:Remove() end)
        pcall(function() source:Dispose() end)
    end
    audioSources = {}
    state.pool, state.beds, state.keySlot = {}, {}, {}
    if audioScene then
        local scene = audioScene
        audioScene = nil
        pcall(function() scene:RemoveAllChildren() end)
        pcall(function() scene:Dispose() end)
    end
end

---@param name string
---@return SoundSource
local function createSource(name)
    local scene = assert(audioScene, "audio_scene_unavailable")
    local node = scene:CreateChild(name)
    local source = node:CreateComponent("SoundSource")
    audioSources[#audioSources + 1] = source
    source:SetDeclickEnabled(true)
    return source
end

-- 只使用实际导出的 Scene 构造器及组件 API，不依赖独立声源构造器。
local function prepareAudioScene()
    if not getCache() then return false, "no_resource_cache" end
    if not getAudio() then return false, "no_audio_subsystem" end
    releaseAudioScene()
    local ok, reason = pcall(function()
        audioScene = Scene()
        audioScene.updateEnabled = false -- 无玩法/物理更新；Audio 仍独立混音。
    end)
    if not ok or not audioScene then
        releaseAudioScene()
        return false, "audio_scene_failed(" .. tostring(reason) .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 池管理
-- ---------------------------------------------------------------------------

local function nextTick()
    state.tick = state.tick + 1
    return state.tick
end

local function slotPlaying(slot)
    -- pcall 直传方法+self，避免闭包分配
    local ok, playing = pcall(slot.source.IsPlaying, slot.source)
    return ok and playing == true
end

local function acquireSlot(key)
    -- 同键重触发：抢占复用原槽位（§7 并发上限=1，杜绝同音叠加）
    if state.keySlot[key] then
        return state.keySlot[key]
    end
    -- 优先空闲/可回收槽位：key 非空但已播完 → 回收并清标记（评审 P2-3，
    -- 否则播完的 one-shot 滞留槽位，8 槽 12 键下会提前抢占正在播的音）
    for _, slot in ipairs(state.pool) do
        if not slotPlaying(slot) then
            if slot.key then
                state.keySlot[slot.key] = nil
                slot.key = nil
            end
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

-- 初始化失败退避：失败后需间隔约 N 次 ensureInit 调用才重试
--（60fps 下 ≈1.5s）。防止"资源异步未就绪"窗口内每帧重跑探针
--（创建/销毁 SoundSource + 18 个 GetResource）与日志刷屏。评审 P1-2。
local INIT_RETRY_CALLS = 90

local function initFailed(message)
    releaseAudioScene()
    state.capability = message
    state.lastFailAttempts = state.initAttempts
    logWarning(message)
    return false
end

local function ensureInit()
    if state.initialized then return true end
    state.initAttempts = state.initAttempts + 1
    if state.lastFailAttempts
        and (state.initAttempts - state.lastFailAttempts) < INIT_RETRY_CALLS then
        return false -- 退避窗口内直接跳过
    end

    local sceneOk, sceneReason = prepareAudioScene()
    if not sceneOk then
        return initFailed("音频宿主不可用：" .. tostring(sceneReason))
    end

    local cacheInstance = getCache()
    local audioInstance = getAudio()
    -- 音频设备状态独立于组件创建成功与否，保留供真机诊断。
    if audioInstance and type(audioInstance.IsInitialized) == "function" then
        pcall(function() state.audioReady = audioInstance:IsInitialized() == true end)
    end
    local loaded = 0
    for key, spec in pairs(SPECS) do
        if not state.firstPath then state.firstPath = spec.path end
        local sound, resolvedPath = resolveSound(cacheInstance, spec)
        if sound then
            state.sounds[key] = sound
            if not state.pathSample then state.pathSample = key .. "->" .. resolvedPath end
            loaded = loaded + 1
        else
            logWarning("加载失败: " .. key .. " <- " .. spec.path)
        end
    end
    state.loadedCount = loaded
    if loaded == 0 then
        return initFailed("0个音效加载成功：首试路径 " .. tostring(state.firstPath)
            .. "｜已尝试含 assets/ 前缀候选")
    end

    -- one-shot 与声床均通过组件创建；失败后整组释放，避免退避重试泄漏。
    local poolOk, poolError = pcall(function()
        for index = 1, POOL_SIZE do
            local source = createSource("OneShot" .. tostring(index))
            state.pool[#state.pool + 1] = { source = source, key = nil, startedAt = 0 }
        end
        for key, spec in pairs(SPECS) do
            if spec.loop then
                local source = createSource(key)
                source.soundType = busConstant(spec.bus)
                state.beds[key] = { source = source, active = false }
            end
        end
    end)
    if not poolOk then return initFailed("音频组件创建失败：" .. tostring(poolError)) end

    applyBusGains()
    state.initialized = true
    local bedCount = 0
    for _ in pairs(state.beds) do bedCount = bedCount + 1 end
    state.capability = "组件池可用(" .. tostring(#state.pool) .. "+声床" .. tostring(bedCount) .. ")"
    print("[AudioDirector] " .. state.capability .. "，资源加载" .. tostring(loaded) .. "/" .. tostring(countSpecs()))
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

local function bedActive(key)
    local bed = state.beds[key]
    return bed and bed.active or false
end

---声床显式启停（幂等：状态未变直接返回，避免重复 Play/Stop 与误触发）。
---SoundSystem 的昼夜切换依赖此接口按目标状态精确设定，而非 toggle。
---@param key string
---@param active boolean
---@return boolean ok
---@return string message
function AudioDirector.SetBed(key, active)
    local spec = SPECS[key]
    if not spec then return false, "unknown_audio_key(" .. tostring(key) .. ")" end
    if not spec.loop then return false, "not_a_bed(" .. tostring(key) .. ")" end
    if not ensureInit() then return false, state.capability end

    local bed = state.beds[key]
    local sound = state.sounds[key]
    if not bed or not sound then return false, "bed_not_ready(" .. tostring(key) .. ")" end

    active = active == true
    -- 幂等早退前置于 GetLength（评审 P1-1：SyncAmbient 每帧驱动，
    -- 稳态下省去每帧 pcall 闭包 + 引擎 GetLength 跨越）
    if bed.active == active then
        return true, "bed_unchanged(" .. tostring(key) .. ")"
    end

    local length = 0
    pcall(function() length = sound:GetLength() end)
    if length <= 0 then return false, "sound_not_ready_dwp(重试即可)" end

    if active then
        pcall(function() sound.looped = true end) -- 幂等；同路径仅循环用途
        local okPlay = pcall(function() bed.source:Play(sound, 0, spec.gain) end)
        if not okPlay then return false, "bed_play_failed(" .. tostring(key) .. ")" end
        bed.active = true
        return true, "声床已循环 " .. key
    end

    pcall(function() bed.source:Stop() end)
    bed.active = false
    return true, "声床已停止 " .. key
end

---声床循环开关（S0 调试用；S2 起由 SetPhase 驱动昼夜切换与 3s 交叉淡化）
---@return boolean ok
---@return string message
function AudioDirector.ToggleBed(key)
    local spec = SPECS[key]
    if not spec then return false, "unknown_audio_key(" .. tostring(key) .. ")" end
    if not spec.loop then return false, "not_a_bed(" .. tostring(key) .. ")" end
    return AudioDirector.SetBed(key, not bedActive(key))
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
        .. (state.pathSample and ("｜路径" .. state.pathSample) or "")
        .. (state.audioReady == false and "｜音频设备未初始化" or "")
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

---设置页音量滑杆（评审 S3：bus 白名单 + gain clamp，防越界/NaN 写坏总线）
function AudioDirector.SetBusVolume(bus, gain)
    if type(BUS_GAIN[bus]) ~= "number" then
        return false, "unknown_bus(" .. tostring(bus) .. ")"
    end
    if type(gain) ~= "number" or gain ~= gain then gain = 0 end -- 非数/NaN 防御
    gain = math.max(0, math.min(1, gain))
    BUS_GAIN[bus] = gain
    if state.initialized then
        local audioInstance = getAudio()
        if audioInstance then
            pcall(function() audioInstance:SetMasterGain(busConstant(bus), gain) end)
        end
    end
    return true, "bus_volume_set(" .. tostring(bus) .. "=" .. tostring(gain) .. ")"
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

---停止本轮声音并清理临时混音状态，保留已加载资源和声源池供 reset 复用。
function AudioDirector.Reset()
    for _, bed in pairs(state.beds) do
        pcall(function() bed.source:StopImmediate() end)
        bed.active = false
    end
    for _, slot in ipairs(state.pool) do
        pcall(function() slot.source:StopImmediate() end)
        slot.key, slot.startedAt = nil, 0
    end
    state.keySlot = {}
    state.tick = 0
    AudioDirector.SetPaused(false)
    AudioDirector.SetFishing(false)
end

---场景关闭时停声并释放声源宿主；不释放 ResourceCache 共享的 Sound。
function AudioDirector.Shutdown()
    AudioDirector.Reset()
    releaseAudioScene()
    state.sounds = {}
    state.initialized, state.loadedCount = false, 0
    state.capability = "not_probed"
    state.audioReady, state.pathSample, state.firstPath = nil, nil, nil
    state.initAttempts, state.lastFailAttempts = 0, nil
end

return AudioDirector
