-- SoundSystem：统一音效门面（需求方要求的 AudioManager / SoundSystem）。
--
-- 设计定位：
--  * 本模块是「游戏侧」唯一音效入口，玩法脚本只调用语义化方法
--    （Click / OpenMenu / StartAction / CaptureSuccess / Discovery / 昼夜声床），
--    不直接接触 AudioDirector 的注册键与播放细节 —— 彻底杜绝「每个脚本重复写播放逻辑」。
--  * 实际播放、对象池、总线增益、能力探针、headless 降级全部下沉到
--    Gameplay.AudioDirector（S0 技术验证桩，已实现且经 Circle1AudioTests 守护）。
--    SoundSystem 只做「语义名 → AudioDirector 键」的映射与编排。
--
-- 性能与稳健（需求 6「不允许因音效卡顿」）：
--  * 全部对外方法包 pcall；音效是体验增强，绝不因音频异常阻断/拖慢玩法。
--  * 一次性的资源加载（ensureInit）只在首个实际播放发生，且为一次性，
--    不发生在逐帧/逐按钮热路径的重复加载上。
--  * 昼夜声床为 2 个常驻循环源，几乎零 CPU；one-shot 走 8 槽轮转池。
--
-- 音量（需求 5「支持以后增加音量设置」）：SetVolume(bus, gain) / SetMuted(bool)。

local SoundSystem = {}

-- ---------------------------------------------------------------------------
-- 语义事件 → AudioDirector 注册键 映射总表
-- 资源文件名（assets/audio/sfx/）与语义名的对应关系见《自适应音乐与空间音效
-- 系统设计方案_v1.0》§7；此处只维护「玩法语义 → 已注册键」的单一真相。
-- ---------------------------------------------------------------------------
local KEY = {
    uiClick       = "ui.button_click",        -- 所有按钮点击
    uiOpen        = "ui.menu_open",           -- 菜单/面板打开
    actionStart   = "action.stamina_spend",   -- 40 体力行动开始
    fishCapture   = "action.catch_success",   -- 捕获成功
    discovery     = "explore.unknown_discovery",   -- 探索发现（通用）
    discoveryChest = "explore.chest_ruin_discovery", -- 沉船/宝箱类发现（预留）
    discoveryKnowledge = "explore.knowledge_gain",   -- 知识获取类发现（圈2 预留）
    bedDay        = "amb.calm_sea",           -- 白天环境声床（循环）
    bedNight      = "amb.night_ocean",        -- 夜晚环境声床（循环）
    bedElder      = "amb.elder_npc",          -- 拜访老人环境声床（循环）
    bedMorning    = "amb.morning_sea",        -- 游戏暂停清晨海面声床（循环）
}

-- 总线名（与 AudioDirector.BUS_GAIN 对齐），供 SetVolume 使用。
local BUS = { voice = "voice", world = "world", amb = "amb", music = "music", master = "master" }

local state = {
    currentAmbient = nil,  -- "day" | "night" | nil（底层世界声床，避免重复启停）
    overlay = nil,         -- nil | "elder" | "pause"（临时覆盖世界声床的环境音）
    lastAppliedBed = nil,  -- 最近一次成功应用的声床键（稳态早退用，评审 P1-1）
    worldAudible = true,   -- 世界声床可闻开关：false=港内/未出航，昼夜声床静默（需求 环境：出航后自动播放）
    muted = false,
}

-- AudioDirector 在工程可用时为已加载模块；headless 测试环境同样 require 得到，
-- 其 Play/SetBed 等接口内部自带能力守卫，调用失败优雅降级。
local AudioDirector = require("Gameplay.AudioDirector")

-- ---------------------------------------------------------------------------
-- 内部：一次性播放（已含全部安全守卫）
-- ---------------------------------------------------------------------------
local function playOneShot(key)
    pcall(function() AudioDirector.Play(key) end)
end

local function setBed(key, active)
    -- pcall 直传函数值，避免每帧闭包分配（评审 P1-1）
    local ok, applied = pcall(AudioDirector.SetBed, key, active == true)
    return ok and applied == true
end

-- 四张环境声床对应的 AudioDirector 注册键（统一管理，避免散落硬字符串）。
local BED_KEYS = {
    day     = "amb.calm_sea",     -- 白天世界声床
    night   = "amb.night_ocean",  -- 夜晚世界声床
    elder   = "amb.elder_npc",    -- 拜访老人覆盖声床
    morning = "amb.morning_sea",  -- 游戏暂停覆盖声床
}
local AMB = BED_KEYS

-- 当前应循环的环境声床：overlay 临时覆盖优先，否则取底层世界声床（昼/夜）；
-- 未出航（港内）时世界声床静默（target=nil → 四床全停）。
local function activeBedKey()
    if state.overlay == "elder" then return BED_KEYS.elder end
    if state.overlay == "pause" then return BED_KEYS.morning end
    if state.worldAudible == false then return nil end
    return state.currentAmbient == "night" and BED_KEYS.night or BED_KEYS.day
end

-- 按当前 overlay/世界相位精确设定四张声床启停。
-- 稳态早退：目标床未变化时零开销（评审 P1-1：SyncAmbient 每帧调用）。
-- 失败（如资源未就绪）不记 lastAppliedBed，下一帧自动重试。
local function applyActiveBed()
    local target = activeBedKey()
    if state.lastAppliedBed == target then return end
    local allOk = true
    for _, k in ipairs({ BED_KEYS.day, BED_KEYS.night, BED_KEYS.elder, BED_KEYS.morning }) do
        if not setBed(k, k == target) then allOk = false end
    end
    if allOk then state.lastAppliedBed = target end
end

-- ---------------------------------------------------------------------------
-- 公开 API：语义化事件
-- ---------------------------------------------------------------------------

---所有按钮点击（需求 UI：所有按钮点击播放 ui_click）
function SoundSystem.Click()
    playOneShot(KEY.uiClick)
end

---菜单/面板打开（需求 UI：菜单打开播放 ui_open）
function SoundSystem.OpenMenu()
    playOneShot(KEY.uiOpen)
end

---40 体力行动开始（需求 行动：玩家执行 40 体力行动时播放 action_start）
function SoundSystem.StartAction()
    playOneShot(KEY.actionStart)
end

---捕获成功（需求 行动：捕获成功播放 fish_capture）
function SoundSystem.CaptureSuccess()
    playOneShot(KEY.fishCapture)
end

---探索发现（需求 行动：探索发现播放 discovery）
---@param variant? "unknown"|"chest"|"knowledge" 细分发现类型，默认 unknown
function SoundSystem.Discovery(variant)
    if variant == "chest" then
        playOneShot(KEY.discoveryChest)
    elseif variant == "knowledge" then
        playOneShot(KEY.discoveryKnowledge)
    else
        playOneShot(KEY.discovery)
    end
end

-- ---------------------------------------------------------------------------
-- 公开 API：昼夜环境声床
-- ---------------------------------------------------------------------------

---按当前昼夜相位同步环境声床：白天→白天声床，夜晚→夜晚声床。
---@param phase "day"|"night"
---@param worldActive? boolean 世界声床是否可闻：false=港内/未出航（昼夜床全停），
---   缺省视为 true（兼容既有调用）。出航后由 Loop 以 `not inPort` 传入。
---幂等：相位未变化时不重复启停，可在每帧时钟推进后安全调用。
function SoundSystem.SyncAmbient(phase, worldActive)
    state.currentAmbient = (phase == "night") and "night" or "day"
    state.worldAudible = worldActive ~= false
    if state.overlay == nil then applyActiveBed() end  -- overlay 期间仅更新底层相位，不抢床
end

---游戏开始自动播放白天环境声床（需求 环境：游戏开始自动播放 ocean_day_loop）
function SoundSystem.StartDayLoop()
    SoundSystem.SetAmbient("day")
end

---夜晚状态切换播放夜晚环境声床（需求 环境：夜晚状态切换播放 ocean_night_loop）
function SoundSystem.StartNightLoop()
    SoundSystem.SetAmbient("night")
end

---显式设定环境声床模式，并停掉另一床，避免两床叠加。
---@param mode "day"|"night"|"off"
function SoundSystem.SetAmbient(mode)
    if mode == "off" then
        state.currentAmbient = nil
        state.lastAppliedBed = nil  -- 床已显式全停，清除稳态标记以允许后续复床
        if state.overlay == nil then
            setBed(KEY.bedDay, false)
            setBed(KEY.bedNight, false)
        end
        return
    end
    -- 注意：mode 为 "day"/"night" 时不再因等于 currentAmbient 而早退，
    -- 因为 overlay 期间 currentAmbient 不变但 applyActiveBed 需据此恢复床。
    state.currentAmbient = mode
    if state.overlay == nil then applyActiveBed() end  -- 有 overlay 时不抢床
end

---拜访老人面板打开：切换为老人环境声床（木船摇晃/轻咳/翻航海日志）。
---底层世界声床（昼/夜）保留，结束对话（面板关闭）时由 ExitElder 切回。
function SoundSystem.EnterElder()
    if state.overlay == "elder" then return end  -- 已在老人声床，重入幂等不重放
    if state.overlay == "pause" then return end  -- 暂停优先，暂停中不覆盖
    state.overlay = "elder"
    applyActiveBed()
end

---结束与老人对话（面板关闭）：切回底层世界声床（昼/夜）。
function SoundSystem.ExitElder()
    if state.overlay ~= "elder" then return end
    state.overlay = nil
    applyActiveBed()
end

---游戏暂停：切换为清晨海面声床（轻浪/鸟鸣/小船木板声）。
---底层世界声床（昼/夜）保留，恢复运行时由 ExitPause 切回。
function SoundSystem.EnterPause()
    if state.overlay == "pause" then return end  -- 已在暂停声床，重入幂等不重放
    if state.overlay == "elder" then return end  -- 老人在场不覆盖
    state.overlay = "pause"
    applyActiveBed()
end

---游戏恢复运行：切回底层世界声床（昼/夜）。
function SoundSystem.ExitPause()
    if state.overlay ~= "pause" then return end
    state.overlay = nil
    applyActiveBed()
end

-- ---------------------------------------------------------------------------
-- 公开 API：音量设置（需求 5）
-- ---------------------------------------------------------------------------

---设置某总线音量（0~1）。bus 取 BUS 表中值；master 控制总开关外的整体音量。
---@param bus string
---@param gain number
function SoundSystem.SetVolume(bus, gain)
    pcall(function() AudioDirector.SetBusVolume(bus, gain) end)
end

---静音切换。静音走 master 总线归零，保留各总线设定，解除即恢复。
---@param muted boolean
function SoundSystem.SetMuted(muted)
    state.muted = muted == true
    if state.muted then
        pcall(function() AudioDirector.SetBusVolume(BUS.master, 0) end)
    else
        pcall(function() AudioDirector.SetBusVolume(BUS.master, 1) end)
    end
end

---当前是否静音（供设置页回显）
function SoundSystem.IsMuted()
    return state.muted
end

-- ---------------------------------------------------------------------------
-- 公开 API：生命周期
-- ---------------------------------------------------------------------------

---场景关闭时停声（由 Integration/Scene 等生命周期调用）
function SoundSystem.Shutdown()
    pcall(function() AudioDirector.Shutdown() end)
    state.currentAmbient = nil
    state.overlay = nil
    state.lastAppliedBed = nil
end

---调试/验收状态（屏幕通道，Maker 无控制台时可用）
function SoundSystem.Status()
    local ok, result = pcall(function() return AudioDirector.Status() end)
    return ok and result or "音频状态读取失败"
end

return SoundSystem
