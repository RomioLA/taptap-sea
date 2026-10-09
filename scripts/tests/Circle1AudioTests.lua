-- 音频接线契约：SPECS 注册表完整性与 headless 优雅降级（不创建世界、不依赖引擎全局）。
-- 对应设计文档《自适应音乐与空间音效系统设计方案_v1.0_2026-10-06.md》§7 接线总表。
local Tests = {}

-- 隔离引擎边界；保留真实音频模块与 Loop，记录播放、停声、注销和释放。
local function withAudioEngine(callback)
    local savedGlobals, savedModules = {}, {}
    for _, name in ipairs({ "GetAudio", "audio", "cache", "SoundSource" }) do
        savedGlobals[name] = { value = _G[name] }
    end
    for _, name in ipairs({ "Gameplay.AudioDirector", "Systems.SoundSystem", "Gameplay.Loop" }) do
        savedModules[name] = { value = package.loaded[name] }
        package.loaded[name] = nil
    end
    local engine = { sources = {}, registered = {}, gains = {}, paused = {}, loads = 0 }
    function engine:AddSoundSource(source) self.registered[source] = true end
    function engine:RemoveSoundSource(source)
        assert(self.registered[source], "声源不可重复注销")
        self.registered[source] = nil
        source.removed = source.removed + 1
    end
    function engine:IsInitialized() return true end
    function engine:SetMasterGain(bus, gain) self.gains[bus] = gain end
    function engine:PauseSoundType(bus) self.paused[bus] = true end
    function engine:ResumeSoundType(bus) self.paused[bus] = nil end
    function engine:ActiveCount()
        local count = 0
        for _, source in ipairs(self.sources) do
            if source.playing then count = count + 1 end
        end
        return count
    end
    function engine:ActivePath()
        for _, source in ipairs(self.sources) do
            if source.playing and source.sound.looped then return source.sound.path end
        end
        return nil
    end
    _G.GetAudio = function() return engine end
    _G.audio = engine
    _G.cache = {
        GetResource = function(_, kind, path)
            assert(kind == "Sound")
            engine.loads = engine.loads + 1
            return { path = path, looped = false, GetLength = function() return 1 end,
                GetFrequency = function() return 48000 end }
        end,
    }
    _G.SoundSource = {
        new = function()
            local source = { playing = false, plays = 0, stops = 0, disposed = 0, removed = 0 }
            function source:SetDeclickEnabled() end
            function source:IsPlaying() return self.playing end
            function source:Play(sound, frequency)
                assert(self.disposed == 0 and engine.registered[self])
                assert(frequency == 0 or frequency > 40000, "播放频率必须是 Hz")
                self.sound, self.playing = sound, true
                self.plays = self.plays + 1
            end
            function source:Stop() self.playing = false; self.stops = self.stops + 1 end
            function source:StopImmediate() self:Stop() end
            function source:Dispose()
                assert(not engine.registered[self] and self.disposed == 0)
                self.disposed = self.disposed + 1
            end
            engine.sources[#engine.sources + 1] = source
            return source
        end,
    }
    local ok, reason = xpcall(function()
        callback(engine, require("Gameplay.AudioDirector"), require("Systems.SoundSystem"))
    end, debug.traceback)
    for name, entry in pairs(savedGlobals) do _G[name] = entry.value end
    for name, entry in pairs(savedModules) do package.loaded[name] = entry.value end
    if not ok then error(reason, 0) end
end

function Tests.Run()
    local AudioDirector = require("Gameplay.AudioDirector")
    local results = {}
    local function check(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    local expectedKeys = {
        "ui.button_click",
        "ui.menu_open",
        "ui.confirm_choice",
        "action.stamina_spend",
        "action.set_sail",
        "action.catch_success",
        "action.explore_failure",
        "explore.unknown_discovery",
        "explore.chest_ruin_discovery",
        "explore.knowledge_gain",
        "amb.calm_sea",
        "amb.night_ocean",
        -- 程序化生成环境音（.tmp/gen_ambience.py，2026-10-08 接入）
        "amb.morning_sea",
        "amb.overcast_sea",
        "amb.storm_premonition",
        "amb.rare_fish",
        "amb.deep_ruins",
        "amb.elder_npc",
    }

    local BED_KEYS = {
        ["amb.calm_sea"] = true,
        ["amb.night_ocean"] = true,
        ["amb.morning_sea"] = true,
        ["amb.overcast_sea"] = true,
        ["amb.storm_premonition"] = true,
        ["amb.rare_fish"] = true,
        ["amb.deep_ruins"] = true,
        ["amb.elder_npc"] = true,
    }

    check("18条注册键齐全且无多余", function()
        local actual = {}
        for _, key in ipairs(AudioDirector.ListKeys()) do actual[key] = true end
        for _, key in ipairs(expectedKeys) do
            assert(actual[key], "missing spec: " .. key)
            actual[key] = nil
        end
        assert(next(actual) == nil, "unexpected extra specs")
    end)

    check("每条规格路径总线音量抖动声像合法", function()
        for _, key in ipairs(expectedKeys) do
            local spec = assert(AudioDirector.GetSpec(key), key)
            assert(spec.path:sub(1, #"audio/sfx/") == "audio/sfx/", key .. " path prefix")
            assert(spec.path:sub(-4) == ".wav", key .. " must use wav")
            assert(spec.bus == "voice" or spec.bus == "world" or spec.bus == "amb", key .. " bus")
            assert(type(spec.gain) == "number" and spec.gain > 0 and spec.gain <= 1, key .. " gain")
            assert(type(spec.pitchVar) == "number" and spec.pitchVar >= 0 and spec.pitchVar <= 0.15, key .. " pitchVar")
            assert(type(spec.pan) == "number" and spec.pan >= -1 and spec.pan <= 1, key .. " pan")
            assert(type(spec.loop) == "boolean", key .. " loop flag")
        end
    end)

    check("仅8张环境声床且全部走amb总线", function()
        for _, key in ipairs(expectedKeys) do
            local spec = assert(AudioDirector.GetSpec(key), key)
            if spec.loop then
                assert(BED_KEYS[key] == true, key .. " unexpected bed")
                assert(spec.bus == "amb" and spec.pitchVar == 0, key .. " bed must be amb/no pitch")
            else
                assert(BED_KEYS[key] ~= true, key .. " bed missing loop flag")
            end
        end
    end)

    check("确认选择与失败提示不变调以保音阶完整", function()
        assert(AudioDirector.GetSpec("ui.confirm_choice").pitchVar == 0)
        assert(AudioDirector.GetSpec("action.explore_failure").pitchVar == 0)
        assert(AudioDirector.GetSpec("ui.menu_open").pitchVar == 0)
    end)

    check("GetSpec返回副本不泄露内部表", function()
        local spec = assert(AudioDirector.GetSpec("ui.button_click"))
        spec.gain = 42
        assert(AudioDirector.GetSpec("ui.button_click").gain ~= 42)
        assert(AudioDirector.GetSpec("no.such.key") == nil)
    end)

    check("headless下Play优雅降级不崩溃", function()
        local ok, reason = AudioDirector.Play("ui.button_click")
        assert(not ok, "headless play must fail gracefully")
        assert(type(reason) == "string" and #reason > 0, "failure reason required")
    end)

    check("未知键先于能力探针返回unknown_audio_key", function()
        local ok, reason = AudioDirector.Play("no.such.key")
        assert(not ok)
        assert(reason:find("unknown_audio_key", 1, true), reason)
        local okBed, reasonBed = AudioDirector.ToggleBed("amb.calm_sea")
        if okBed == false and reasonBed:find("unknown_audio_key", 1, true) then
            error("bed key should not be unknown")
        end
    end)

    check("循环键拒绝走one-shot通道", function()
        local ok, reason = AudioDirector.Play("amb.calm_sea")
        assert(not ok and reason:find("use_toggle_bed", 1, true), reason)
    end)

    check("Status可读且非空", function()
        local status = AudioDirector.Status()
        assert(type(status) == "string" and #status > 0)
    end)

    check("暂停与停止接口headless下可安全调用", function()
        AudioDirector.SetPaused(true)
        AudioDirector.SetPaused(false)
        AudioDirector.SetFishing(true)
        AudioDirector.SetFishing(false)
        AudioDirector.SetBusVolume("amb", 0.5)
        AudioDirector.SetBusVolume("amb", 0.8)
        AudioDirector.Shutdown()
    end)

    check("reset 清空播放与临时混音状态但复用池和音量设置", function()
        withAudioEngine(function(engine, director, sound)
            sound.SetMuted(true)
            assert(director.SetBusVolume("amb", 0.65))
            sound.SyncAmbient("night", true)
            sound.EnterElder()
            sound.Click()
            director.SetFishing(true)
            director.SetPaused(true)
            local sources, loads = #engine.sources, engine.loads
            assert(engine:ActiveCount() == 2)
            sound.Reset()
            assert(engine:ActiveCount() == 0 and next(engine.paused) == nil)
            assert(engine.gains[SOUND_AMBIENT or "Ambient"] == 0.65)
            assert(sound.IsMuted() and engine.gains[SOUND_MASTER or "Master"] == 0)
            sound.SyncAmbient("day", false)
            assert(engine:ActiveCount() == 1)
            assert(engine:ActivePath() == "audio/sfx/amb_morning_sea_ai.wav")
            sound.SyncAmbient("day", true)
            assert(engine:ActivePath() == "audio/sfx/ambience_calm_sea_loop.wav")
            assert(#engine.sources == sources and engine.loads == loads, "reset 不得重复加载或注册")
        end)
    end)

    check("Shutdown 注销释放全部声源且重入安全，重新播放无旧覆盖", function()
        withAudioEngine(function(engine, director, sound)
            sound.SyncAmbient("night", true)
            sound.EnterElder()
            sound.Click()
            assert(engine:ActiveCount() == 2)
            sound.Shutdown()
            assert(engine:ActiveCount() == 0 and next(engine.registered) == nil)
            for _, source in ipairs(engine.sources) do
                assert(source.disposed == 1 and source.removed == 1)
            end
            local count = #engine.sources
            sound.Shutdown()
            assert(#engine.sources == count and next(engine.registered) == nil)
            sound.SyncAmbient("day", true)
            assert(engine:ActiveCount() == 1)
            assert(engine:ActivePath() == "audio/sfx/ambience_calm_sea_loop.wav")
            assert(director.Status():find("加载18/18", 1, true))
        end)
    end)

    check("真实 Loop 返港后持续暂停声床，关闭菜单不恢复出海声床", function()
        withAudioEngine(function(engine)
            local loop = require("Gameplay.Loop").New({})
            assert(loop:Depart())
            loop.clock:Seek("night", 10)
            loop:Update(0)
            assert(engine:ActivePath() == "audio/sfx/ambience_night_ocean_loop.wav")
            assert(loop:ReturnToPort())
            assert(loop.inPort and loop.clock.pauseReasons.port)
            assert(engine:ActivePath() == "audio/sfx/amb_morning_sea_ai.wav")
            local elapsed, sourceCount = loop.clock.elapsed, #engine.sources
            for _ = 1, 5 do loop:Update(1) end
            assert(loop.clock.elapsed == elapsed and #engine.sources == sourceCount)
            assert(loop:SetInventoryOpen(true) and loop:SetInventoryOpen(false))
            assert(loop:SetElderOpen(true))
            assert(engine:ActivePath() == "audio/sfx/amb_elder_npc_ai.wav")
            assert(not loop:Depart(), "老人面板未关闭时不允许出港")
            assert(loop:SetElderOpen(false))
            assert(loop.clock.pauseReasons.port and engine:ActivePath() == "audio/sfx/amb_morning_sea_ai.wav")
            assert(loop:Depart())
            assert(not loop.clock:IsPaused())
            assert(engine:ActivePath() == "audio/sfx/ambience_night_ocean_loop.wav")
        end)
    end)

    check("真实 Loop reset 清旧声，初始保存成功仍暂停在港，Close 后更新不复声", function()
        withAudioEngine(function(engine, _, sound)
            local callbacks = {}
            local loop = require("Gameplay.Loop").New({ store = {
                Save = function(_, _, done) callbacks[#callbacks + 1] = done end,
            } })
            assert(loop:Depart())
            sound.EnterElder()
            sound.Click()
            assert(engine:ActiveCount() == 2)
            assert(loop:NewRun())
            assert(engine:ActiveCount() == 0 and loop.clock.pauseReasons.port)
            callbacks[1](true)
            assert(loop.inPort and loop.clock:IsPaused())
            loop:Update(0)
            assert(engine:ActivePath() == "audio/sfx/amb_morning_sea_ai.wav")
            assert(loop:Depart())
            assert(engine:ActivePath() == "audio/sfx/ambience_calm_sea_loop.wav")
            assert(loop:Close())
            assert(engine:ActiveCount() == 0 and next(engine.registered) == nil)
            local count = #engine.sources
            loop:Update(1)
            assert(#engine.sources == count and engine:ActiveCount() == 0)
        end)
    end)

    check("reset 被回滚保护拒绝时不停止现有声音", function()
        withAudioEngine(function(engine)
            local loop = require("Gameplay.Loop").New({})
            assert(loop:Depart())
            local path = engine:ActivePath()
            loop.inventoryRollback = { items = {}, stamina = 100 }
            local ok, reason = loop:ResetState()
            assert(not ok and reason == "inventory_rollback_pending")
            assert(engine:ActiveCount() == 1 and engine:ActivePath() == path)
        end)
    end)

    return { results = results, evidenceKind = "offline Lua 5.4 audio registry and lifecycle checks; engine/audio outputs are test doubles" }
end

return Tests
