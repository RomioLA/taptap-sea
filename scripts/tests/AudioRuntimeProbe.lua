-- 原生音频回归：验证真实 WAV、组件池、混音推进与生命周期；不作为游戏入口。
-- 虚拟音频设备下的 PASS 仅证明引擎播放链，不代表真机试听通过。
local AudioDirector = require("Gameplay.AudioDirector")
local SoundSystem = require("Systems.SoundSystem")
local elapsed = 0
local baseline = 0

local function activeCount()
    local count = 0
    for _, source in ipairs(audio:GetSoundSources()) do
        if source:IsPlaying() then count = count + 1 end
    end
    return count
end

local function runChecked(callback)
    local ok, reason = xpcall(callback, debug.traceback)
    if not ok then
        print("[AudioProbe] FAIL " .. tostring(reason))
        AudioDirector.Shutdown()
        engine:Exit()
    end
    return ok
end

function Start()
    runChecked(function()
        assert(audio:IsInitialized(), "音频设备必须初始化")
        baseline = #audio:GetSoundSources()
        local sound = assert(cache:GetResource("Sound", "audio/sfx/ui_button_click.wav"))
        assert(sound:GetLength() > 0 and sound:GetFrequency() == 48000, "真实 WAV 必须就绪")
        local ok, reason = AudioDirector.Play("ui.button_click")
        assert(ok, reason)
        assert(AudioDirector.SetBed("amb.calm_sea", true))
        assert(#audio:GetSoundSources() == baseline + 16, "组件池必须只注册16个声源")
        assert(activeCount() == 2, "点击与海洋声床必须处于播放状态")
        collectgarbage("collect")
        assert(#audio:GetSoundSources() == baseline + 16 and activeCount() == 2, "GC 不得回收宿主")
        print("[AudioProbe] directorPlay=true wavReady=true sources=16 gcRetained=true")
        SubscribeToEvent("Update", "HandleAudioProbeUpdate")
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleAudioProbeUpdate(eventType, eventData)
    elapsed = elapsed + eventData:GetFloat("TimeStep")
    if elapsed < 0.4 then return end
    UnsubscribeFromEvent("Update")
    runChecked(function()
        local advanced = false
        for _, source in ipairs(audio:GetSoundSources()) do
            if source.soundType == SOUND_AMBIENT and source:IsPlaying() and source:GetTimePosition() > 0 then
                advanced = true
            end
        end
        assert(advanced, "禁用宿主场景更新后音频混音仍须推进")
        SoundSystem.Reset()
        assert(activeCount() == 0 and #audio:GetSoundSources() == baseline + 16, "reset 必须停声并复用池")
        SoundSystem.SyncAmbient("night", true)
        assert(activeCount() == 1)
        SoundSystem.SyncAmbient("night", false)
        assert(SoundSystem.Status():find("amb.morning_sea:开", 1, true), "港口暂停须切清晨声床")
        assert(activeCount() == 1)
        SoundSystem.EnterElder()
        SoundSystem.ExitElder()
        assert(SoundSystem.Status():find("amb.morning_sea:开", 1, true), "关闭老人不得恢复海上声床")
        SoundSystem.SyncAmbient("night", true)
        assert(SoundSystem.Status():find("amb.night_ocean:开", 1, true))
        SoundSystem.Shutdown()
        assert(#audio:GetSoundSources() == baseline, "关闭必须释放全部注册声源")
        SoundSystem.Shutdown()
        assert(#audio:GetSoundSources() == baseline, "重复关闭必须安全")
        assert(AudioDirector.Play("ui.button_click"))
        assert(#audio:GetSoundSources() == baseline + 16 and activeCount() == 1, "重新初始化不得复活旧声床")
        AudioDirector.Shutdown()
        assert(#audio:GetSoundSources() == baseline)
        print("[AudioProbe] PASS mixAdvanced=true reset=true port=true shutdown=true reinit=true")
        engine:Exit()
    end)
end

function Stop()
    AudioDirector.Shutdown()
end
