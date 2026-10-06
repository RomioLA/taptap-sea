-- 音频接线契约：SPECS 注册表完整性与 headless 优雅降级（不创建世界、不依赖引擎全局）。
-- 对应设计文档《自适应音乐与空间音效系统设计方案_v1.0_2026-10-06.md》§7 接线总表。
local Tests = {}

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
    }

    check("12条注册键齐全且无多余", function()
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

    check("仅两个声床且全部走amb总线", function()
        for _, key in ipairs(expectedKeys) do
            local spec = assert(AudioDirector.GetSpec(key), key)
            if spec.loop then
                assert(key == "amb.calm_sea" or key == "amb.night_ocean", key .. " unexpected bed")
                assert(spec.bus == "amb" and spec.pitchVar == 0, key .. " bed must be amb/no pitch")
            else
                assert(key ~= "amb.calm_sea" and key ~= "amb.night_ocean", key .. " bed missing loop flag")
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

    return { results = results, evidenceKind = "offline Lua 5.4 audio registry checks; engine globals absent by design" }
end

return Tests
