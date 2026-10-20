-- 探海镜水体光学层契约（2026-10-19 用户红框反馈「透镜 90° 扇形内水下鱼与海面
-- 渲染融为一体、肉眼无法区分」，裁决 A 全套 + 远端 0.55）。只读渲染契约：
-- Config 默认值、扇区渐变/rim/光柱、鱼体接触阴影/背光、远景剪影兜底、
-- 距离衰减曲线；渲染全程零世界状态改动（快照对账）。
local Tests = {}

local Runtime = require("Ocean.SeaRuntime")
local SeaDraw = require("Ocean.SeaDraw")
local Config = require("Ocean.Config")
local Geometry = require("Ocean.ProjectedGeometry")

local LANDSCAPE = { width = 1920, height = 1080 }
-- 小视口下扇区远端沙丁鱼缩到阈值以下（640×360 基准：10.3px < 14px），
-- 用于确定性触发剪影兜底；金枪鱼同场景 24.5px 保持贴图/矢量本体。
local COMPACT = { width = 640, height = 360 }
local NEAR_FISH = { x = 10, y = 8 }     -- 扇区内常规尺寸鱼（避开固定桶 (14,6)）
local FAR_FISH = { x = 13, y = 13 }     -- 扇区远端（45° 边缘内，距船 18.4m）

local function lens()
    return Config.visual.scopeLens
end

local function snapshot(runtime)
    local entities = {}
    for index, entity in ipairs(runtime.world.entities) do
        entities[index] = {
            id = entity.id, x = entity.position.x, y = entity.position.y,
            removed = entity.removed, alive = entity.alive,
            active = entity.active, frozen = entity.frozen,
        }
    end
    return {
        runtimeTime = runtime.time, worldTime = runtime.world.time,
        shipX = runtime.ship.position.x, shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x, cameraY = runtime.movement.camera.y,
        entityCount = #runtime.world.entities, entities = entities,
    }
end

local function assertUnchanged(before, runtime, label)
    local after = snapshot(runtime)
    assert(after.runtimeTime == before.runtimeTime, label .. " advanced runtime time")
    assert(after.worldTime == before.worldTime, label .. " advanced world time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY, label .. " moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY, label .. " moved the camera")
    assert(after.entityCount == before.entityCount, label .. " changed world registration")
    for index, entity in ipairs(after.entities) do
        local old = before.entities[index]
        assert(old and entity.id == old.id, label .. " reordered world entities")
        assert(entity.x == old.x and entity.y == old.y, label .. " moved a world entity")
        assert(entity.removed == old.removed and entity.alive == old.alive
            and entity.active == old.active and entity.frozen == old.frozen,
            label .. " changed an entity state")
    end
end

local function fixture(viewport, species, offset)
    local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
    assert(runtime.movement:SetViewport(viewport.width, viewport.height),
        "offline viewport was not applied")
    assert(runtime:SetScopeEnabled(true), "scope was not enabled")
    local fish = runtime:spawnFish(species, { x = offset.x, y = offset.y }, 0)
    assert(runtime.world:isVisible(fish), "fixture fish must sit inside the scope sector")
    return runtime, fish
end

-- 640×360 等小视口同样走 SeaDraw.Scene；recorder 每次 reset 后对账。
local function renderSceneAt(runtime, recorder, viewport)
    recorder.reset()
    local ok, err = pcall(function()
        SeaDraw.Scene({}, viewport.width, viewport.height, runtime)
    end)
    assert(ok, err)
end

-- 监视 WorldSector 的实参：fillPaint 非空即渐变水体；stroke 为 rim/glow 描边色。
-- 补丁还原走 pcall 保护：渲染断言失败也不得把 MonkeyPatch 漏给后续套件。
local function renderWithSectorSpy(runtime, recorder, viewport)
    local sectors = {}
    local original = Geometry.WorldSector
    Geometry.WorldSector = function(ctx, movement, center, radius, heading, halfAngle,
        fillColor, strokeColor, strokeWidth, altitude, fillPaint)
        sectors[#sectors + 1] = { hasPaint = fillPaint ~= nil, stroke = strokeColor }
        return original(ctx, movement, center, radius, heading, halfAngle,
            fillColor, strokeColor, strokeWidth, altitude, fillPaint)
    end
    local ok, err = pcall(renderSceneAt, runtime, recorder, viewport)
    Geometry.WorldSector = original
    assert(ok, err)
    return sectors
end

function Tests.Run(recorder)
    local tests = {}
    local function check(name, fn)
        local ok, err = pcall(fn)
        tests[#tests + 1] = { name = name, passed = ok, error = not ok and tostring(err) or nil }
    end

    check("scope_lens_defaults_match_the_locked_decision", function()
        local settings = lens()
        assert(settings and settings.enabled == true, "scopeLens must ship enabled")
        assert(settings.nearAlpha == 0.30 and settings.farAlpha == 0.55,
            "locked depth alphas changed (0.30 near / 0.55 far)")
        assert(settings.silhouetteMinPx == 14, "locked silhouette threshold changed")
        assert(#settings.nearColor == 3 and #settings.farColor == 3,
            "water colors must stay RGB triples")
        assert(settings.fadeFarAlpha == 0.82, "locked far fade changed")
    end)

    check("scope_water_draws_gradient_base_glow_and_rim", function()
        local runtime = fixture(LANDSCAPE, "sardine", NEAR_FISH)
        local before = snapshot(runtime)
        local sectors = renderWithSectorSpy(runtime, recorder, LANDSCAPE)
        assert(#sectors >= 3, "scope water must fill, glow and rim the sector")
        assert(sectors[1].hasPaint, "the sector base must be a gradient water fill")
        local rimmed = false
        for _, sector in ipairs(sectors) do
            if sector.stroke and sector.stroke[1] == 235 and sector.stroke[2] == 252 then
                rimmed = true
            end
        end
        assert(rimmed, "the sector needs the bright Fresnel rim")
        assertUnchanged(before, runtime, "scope water rendering")
    end)

    check("scope_gradient_is_additive_to_the_sea_fallback", function()
        local runtime = fixture(LANDSCAPE, "sardine", NEAR_FISH)
        renderSceneAt(runtime, recorder, LANDSCAPE)
        local gradientsOn = recorder.callCount("nvgLinearGradient")
        local paintsOn = recorder.callCount("nvgFillPaint")
        assert(gradientsOn >= 1 and paintsOn >= 1, "the water gradient must reach NanoVG")
        runtime:SetScopeEnabled(false)
        renderSceneAt(runtime, recorder, LANDSCAPE)
        local gradientsOff = recorder.callCount("nvgLinearGradient")
        assert(gradientsOn > gradientsOff, "enabling the scope must add the water gradient")
    end)

    check("in_scope_fish_gets_shadow_and_glint_without_silhouette", function()
        local runtime = fixture(LANDSCAPE, "sardine", NEAR_FISH)
        local before = snapshot(runtime)
        renderSceneAt(runtime, recorder, LANDSCAPE)
        local settings = lens()
        assert(recorder.countFillColor(settings.shadowColor[1], settings.shadowColor[2],
            settings.shadowColor[3], settings.shadowAlpha) >= 1,
            "in-scope fish needs a contact shadow")
        assert(recorder.countFillColor(settings.glintColor[1], settings.glintColor[2],
            settings.glintColor[3], settings.glintAlpha) >= 2,
            "in-scope fish needs dorsal glints")
        assert(recorder.countFillColor(14, 34, 52, 255) == 0,
            "a readable in-scope fish must keep its own body, not the silhouette")
        assertUnchanged(before, runtime, "in-scope fish treatment")
    end)

    check("distant_in_scope_fish_falls_back_to_silhouette", function()
        local runtime, fish = fixture(COMPACT, "sardine", FAR_FISH)
        local _, _, scale = runtime.movement:WorldToScreen(fish.position)
        local fishPx = 1.8 * scale
        assert(fishPx < lens().silhouetteMinPx,
            "far fixture must fall below the silhouette threshold")
        local before = snapshot(runtime)
        renderSceneAt(runtime, recorder, COMPACT)
        assert(recorder.countFillColor(14, 34, 52, 255) >= 1,
            "a distant in-scope fish must switch to the dark rise silhouette")
        local settings = lens()
        assert(recorder.countFillColor(settings.glintColor[1], settings.glintColor[2],
            settings.glintColor[3], settings.glintAlpha) == 0,
            "the silhouette fallback must skip the glint pass")
        assertUnchanged(before, runtime, "silhouette fallback")
    end)

    check("scope_disabled_keeps_the_legacy_look", function()
        local settings = lens()
        -- ① 镜开关关闭：整个扇区不画
        local closed = fixture(LANDSCAPE, "sardine", NEAR_FISH)
        closed:SetScopeEnabled(false)
        local closedSectors = renderWithSectorSpy(closed, recorder, LANDSCAPE)
        assert(#closedSectors == 0, "a closed scope must not draw any sector water")
        -- ② 镜开但水体层关闭：回退旧观感（淡青单色 + 亮青描边，无渐变/无鱼体处理）
        local legacy = fixture(LANDSCAPE, "sardine", NEAR_FISH)
        settings.enabled = false
        local legacyOk, legacyErr = pcall(function()
            local legacySectors = renderWithSectorSpy(legacy, recorder, LANDSCAPE)
            assert(#legacySectors == 1, "the disabled water layer must draw exactly the legacy sector")
            assert(not legacySectors[1].hasPaint, "the legacy sector must stay a flat fill")
            assert(legacySectors[1].stroke and legacySectors[1].stroke[1] == 197
                and legacySectors[1].stroke[2] == 243, "the legacy sector must keep its old rim")
        end)
        settings.enabled = true
        assert(legacyOk, legacyErr)
        assert(recorder.countFillColor(settings.shadowColor[1], settings.shadowColor[2],
            settings.shadowColor[3], settings.shadowAlpha) == 0,
            "the disabled water layer must not shadow fish")
        assert(recorder.countFillColor(14, 34, 52, 255) == 0,
            "the disabled water layer must not silhouette fish")
    end)

    check("fade_helper_matches_the_locked_curve", function()
        local settings = lens()
        local radius = 20
        assert(SeaDraw.ScopeLensFade(settings, 0, radius) == 1,
            "the nearest fish must stay fully opaque")
        assert(SeaDraw.ScopeLensFade(settings, radius * settings.fadeStartRatio, radius) == 1,
            "fade must start at the locked ratio")
        assert(math.abs(SeaDraw.ScopeLensFade(settings, radius, radius) - settings.fadeFarAlpha) < 1e-9,
            "the rim fish must reach the locked far alpha")
        assert(math.abs(SeaDraw.ScopeLensFade(settings, (radius * settings.fadeStartRatio + radius) / 2, radius)
            - 0.91) < 1e-9, "the midpoint must sit on the locked linear curve")
        assert(SeaDraw.ScopeLensFade(nil, 10, radius) == 1, "missing settings must disable fading")
        assert(SeaDraw.ScopeLensFade(settings, 10, 0) == 1, "a degenerate radius must disable fading")
    end)

    local passed = true
    for _, test in ipairs(tests) do
        if not test.passed then passed = false end
    end
    return {
        status = passed and "PASS" or "FAIL",
        tests = tests,
        metrics = {
            landscape = LANDSCAPE, compact = COMPACT,
            nearFish = NEAR_FISH, farFish = FAR_FISH,
            farFishPxAtCompact = "below the 14px silhouette threshold",
            evidence = "offline Lua54 + NanoVG recorder; engine/UI/cloud bindings are test doubles",
        },
    }
end

return Tests
