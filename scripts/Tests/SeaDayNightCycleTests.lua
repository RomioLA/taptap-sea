-- Offline regression checks for clock-driven sun and moon rendering.
-- The Python test runner supplies an NVG recorder and calls Run(recorder).
local Tests = {}

local Config = require("Ocean.Config")
local Runtime = require("Ocean.SeaRuntime")
local GameClock = require("Gameplay.GameClock")
local Projection = require("Ocean.Projection")
local SeaDraw = require("Ocean.SeaDraw")

local WIDTH, HEIGHT = 1920, 1080

local function near(actual, expected, tolerance)
    return type(actual) == "number" and math.abs(actual - expected) <= (tolerance or 0.001)
end

local function snapshot(runtime)
    local entities = {}
    for index, entity in ipairs(runtime.world.entities) do
        entities[index] = {
            id = entity.id,
            x = entity.position.x,
            y = entity.position.y,
            removed = entity.removed,
            active = entity.active,
            frozen = entity.frozen,
        }
    end
    return {
        time = runtime.time,
        shipX = runtime.ship.position.x,
        shipY = runtime.ship.position.y,
        cameraX = runtime.movement.camera.x,
        cameraY = runtime.movement.camera.y,
        entityCount = #runtime.world.entities,
        revealCount = #runtime.world.reveals,
        showUnderwater = runtime.world.showUnderwater,
        entities = entities,
    }
end

local function assertUnchanged(before, runtime, label)
    local after = snapshot(runtime)
    assert(after.time == before.time, label .. " changed runtime.time")
    assert(after.shipX == before.shipX and after.shipY == before.shipY,
        label .. " moved the ship")
    assert(after.cameraX == before.cameraX and after.cameraY == before.cameraY,
        label .. " moved the camera")
    assert(after.entityCount == before.entityCount and after.revealCount == before.revealCount,
        label .. " changed runtime entities or visibility")
    assert(after.showUnderwater == before.showUnderwater,
        label .. " changed underwater visibility")
    for index, entity in ipairs(after.entities) do
        local old = before.entities[index]
        assert(old and entity.id == old.id, label .. " reordered runtime entities")
        assert(entity.x == old.x and entity.y == old.y,
            label .. " moved a runtime entity")
        assert(entity.removed == old.removed and entity.active == old.active
            and entity.frozen == old.frozen, label .. " changed runtime entity state")
    end
end

local function expectedCelestial(phase, progress, movement)
    local radius = math.min(WIDTH * 0.055, HEIGHT * 0.065)
    if phase == "night" then radius = radius * 0.78 end
    local x = WIDTH * (0.94 - 0.88 * progress)
    local horizonY = Projection.Horizon(movement, x)
    local horizonRatio = Config.camera.horizonY or 0.24
    horizonRatio = math.max(0.18, math.min(0.38, horizonRatio))
    local startY = horizonY + radius
    local topY = HEIGHT * math.min(0.12, horizonRatio * 0.5)
    local y = startY + (topY - startY) * math.sin(math.pi * progress)
    return x, y, radius, horizonY
end

function Tests.Run(recorder)
    assert(recorder ~= nil and recorder.reset ~= nil and recorder.countEllipseArgs ~= nil,
        "the NVG recorder must expose ellipse capture helpers")

    local runtime = Runtime.New({ departure = { x = 0, y = 0 }, initializeRegions = false })
    assert(runtime.movement:SetViewport(WIDTH, HEIGHT), "offline viewport was not applied")

    local function render(state, label)
        recorder.reset()
        local before = snapshot(runtime)
        SeaDraw.Scene({}, WIDTH, HEIGHT, runtime, state)
        assertUnchanged(before, runtime, label)
    end

    local function assertCelestial(state, progress, label)
        local x, y, radius, horizonY = expectedCelestial(state.phase, progress, runtime.movement)
        local captured = recorder.countEllipseArgs(x, y, radius, radius, 0.02)
        assert(captured == 1, string.format(
            "%s should draw one celestial core at (%.3f, %.3f), found %d",
            label, x, y, captured))
        if progress == 0 or progress == 1 then
            assert(y - radius >= horizonY - 0.02,
                label .. " should put the full disc at or below the projected horizon")
        else
            assert(y - radius < horizonY,
                label .. " should rise the disc above the projected horizon")
        end
        return x, y, radius, horizonY
    end

    local function assertSunCoreColor(color, label)
        local count = recorder.countFillColor(color[1], color[2], color[3], color[4])
        assert(count == 1, label .. " should record one sun core with its clock-driven color")
    end

    -- V2.8 正式规则：白天 60 秒 / 夜晚 30 秒（scripts/config/gameplay.lua clock）。
    -- 本套件验的是「天象按归一化 progress 绘制」，不锁具体秒数；旧 120/60 断言
    -- 是 V2.7 之前的时长，已随正式规则作废。
    local clock = GameClock.New()
    local DAY_SEC, NIGHT_SEC = clock.daySec, clock.nightSec
    assert(DAY_SEC == 60 and NIGHT_SEC == 30,
        "the celestial cycle should follow the sealed 60/30 second configuration")

    clock:Seek("day", 0)
    local east = clock:GetState()
    assert(east.progress == 0 and east.duration == DAY_SEC,
        "day state should expose normalized progress and configured duration")
    render(east, "day sunrise draw")
    local eastX, eastY, sunRadius, eastHorizon = assertCelestial(east, 0, "sunrise")
    assertSunCoreColor({ 255, 207, 136, 255 }, "dawn")
    assert(recorder.countFillColor(table.unpack(Config.visual.nightOverlay)) == 0,
        "daytime should not use the night overlay")

    clock:Seek("day", DAY_SEC / 2)
    local noon = clock:GetState()
    assert(noon.progress == 0.5, "the day midpoint should use half of its configured duration")
    render(noon, "day midpoint draw")
    local noonX, noonY = assertCelestial(noon, 0.5, "midday")
    assertSunCoreColor({ 255, 237, 177, 255 }, "midday")
    assert(recorder.countFillColor(255, 237, 177, 255)
        ~= recorder.countFillColor(255, 207, 136, 255),
        "the daylight color should brighten from dawn toward midday")
    assert(noonX < eastX and noonY < eastY - sunRadius,
        "the sun should move westward and rise above the horizon")

    clock:Seek("day", DAY_SEC)
    local west = clock:GetState()
    render(west, "day sunset draw")
    local westX, westY, _, westHorizon = assertCelestial(west, 1, "sunset")
    assert(westX < noonX and westX < WIDTH * 0.1,
        "the sun should set at the western edge")
    assert(westY - sunRadius >= westHorizon - 0.02,
        "the sunset disc should be covered by the sea at the phase boundary")

    clock:Seek("night", NIGHT_SEC / 2)
    local moonState = clock:GetState()
    assert(moonState.progress == 0.5 and moonState.duration == NIGHT_SEC,
        "night should use its own configured duration")
    render(moonState, "night midpoint draw")
    local moonX, moonY, moonRadius, moonHorizon = assertCelestial(moonState, 0.5, "moonrise arc")
    assert(near(moonX, WIDTH * 0.5) and moonY < moonHorizon,
        "the moon should follow the same east-to-west arc above the sea")
    assert(recorder.countFillColor(table.unpack(Config.visual.nightOverlay)) == 1,
        "night should reuse exactly one existing scene overlay")
    local moonCore = recorder.countEllipseArgs(moonX, moonY, moonRadius, moonRadius, 0.02)
    assert(moonCore == 1, "night should draw a single moon core")
    render(clock, "raw GameClock night midpoint draw")
    local rawMoonX, rawMoonY = assertCelestial(clock, 0.5, "raw GameClock moon")
    assert(near(rawMoonX, moonX) and near(rawMoonY, moonY),
        "SeaDraw should render the actual GameClock object like its normalized state")

    -- The visual path follows normalized progress, not an assumed fixed timer.
    clock.daySec = 240
    clock:Seek("day", 60)
    local longerDay = clock:GetState()
    assert(longerDay.duration == 240 and longerDay.progress == 0.25,
        "a changed day duration should be reflected in clock progress")
    render(longerDay, "longer configured day draw")
    local longerX, longerY = assertCelestial(longerDay, 0.25, "quarter-day sun")
    clock.daySec = DAY_SEC
    clock:Seek("day", DAY_SEC / 4)
    local defaultDayQuarter = clock:GetState()
    render(defaultDayQuarter, "default configured day draw")
    local defaultX, defaultY = assertCelestial(defaultDayQuarter, 0.25, "default quarter-day sun")
    assert(near(longerX, defaultX) and near(longerY, defaultY),
        "equal normalized day progress should draw the sun at the same position")
    assertSunCoreColor({ 255, 228, 165, 255 }, "quarter-day twilight")
    render(clock, "raw GameClock day quarter draw")
    local rawSunX, rawSunY = assertCelestial(clock, 0.25, "raw GameClock quarter-day sun")
    assert(near(rawSunX, defaultX) and near(rawSunY, defaultY),
        "SeaDraw should use elapsed/phase duration when Bootstrap passes the GameClock object")

    -- The same normalized night progress must work with a changed phase length.
    clock.nightSec = 120
    clock:Seek("night", 30)
    local longerNight = clock:GetState()
    assert(longerNight.duration == 120 and longerNight.progress == 0.25,
        "a changed night duration should be reflected in clock progress")
    render(longerNight, "longer configured night draw")
    local longerMoonX, longerMoonY = assertCelestial(longerNight, 0.25, "quarter-night moon")
    clock.nightSec = NIGHT_SEC
    clock:Seek("night", NIGHT_SEC / 4)
    local defaultNightQuarter = clock:GetState()
    render(defaultNightQuarter, "default configured night draw")
    local defaultMoonX, defaultMoonY = assertCelestial(defaultNightQuarter, 0.25, "default quarter-night moon")
    assert(near(longerMoonX, defaultMoonX) and near(longerMoonY, defaultMoonY),
        "equal normalized night progress should draw the moon at the same position")

    -- Prefer GameClock's normalized progress even if compatibility fields disagree.
    local normalizedOnly = {
        phase = "day", elapsed = 0, duration = 120, progress = 0.5,
    }
    render(normalizedOnly, "normalized progress priority draw")
    assertCelestial(normalizedOnly, 0.5, "progress-priority sun")

    -- Paused daytime holds both the twilight palette and the sun location.
    clock:Seek("day", DAY_SEC / 4)
    clock:Pause("settings")
    local pausedDayBefore = clock:GetState()
    clock:Update(17)
    local pausedDayAfter = clock:GetState()
    assert(pausedDayAfter.elapsed == pausedDayBefore.elapsed
        and pausedDayAfter.progress == pausedDayBefore.progress and pausedDayAfter.paused,
        "a paused daytime clock update should freeze progress")
    render(clock, "paused daytime raw GameClock draw one")
    local pausedSunX, pausedSunY = assertCelestial(clock, 0.25, "paused twilight sun")
    assertSunCoreColor({ 255, 228, 165, 255 }, "paused twilight")
    render(clock, "paused daytime raw GameClock draw two")
    local repeatedSunX, repeatedSunY = assertCelestial(clock, 0.25, "repeated paused sun")
    assertSunCoreColor({ 255, 228, 165, 255 }, "repeated paused twilight")
    assert(near(pausedSunX, repeatedSunX) and near(pausedSunY, repeatedSunY),
        "paused twilight draws should retain both sun position and color")
    clock:Resume("settings")

    -- Paused night also retains its moon location and the one existing overlay.
    clock:Seek("night", NIGHT_SEC / 4)
    clock:Pause("settings")
    local pausedBefore = clock:GetState()
    assert(pausedBefore.paused and pausedBefore.progress == 0.25,
        "paused clock should retain its normalized night progress")
    clock:Update(17)
    local pausedAfter = clock:GetState()
    assert(pausedAfter.elapsed == pausedBefore.elapsed
        and pausedAfter.progress == pausedBefore.progress and pausedAfter.paused,
        "a paused GameClock update should not advance the moon")
    render(clock, "paused night raw GameClock draw one")
    local pausedX, pausedY = assertCelestial(clock, 0.25, "paused moon")
    render(clock, "paused night raw GameClock draw two")
    local repeatedX, repeatedY = assertCelestial(clock, 0.25, "repeated paused moon")
    assert(near(pausedX, repeatedX) and near(pausedY, repeatedY),
        "repeated paused draws should retain the same celestial position")

    return {
        status = "PASS",
        tests = {
            "clock_normalized_progress_drives_actual_sun_and_moon_ellipses",
            "sun_and_moon_rise_east_to_west_over_the_projected_horizon",
            "celestial_discs_are_covered_at_phase_boundaries_by_existing_sea_surface",
            "sealed_60_30_second_clock_configuration_is_reused",
            "equal_normalized_progress_is_independent_of_phase_duration",
            "equal_normalized_night_progress_is_independent_of_phase_duration",
            "sea_scene_accepts_the_raw_GameClock_used_by_Bootstrap_Render",
            "normalized_progress_takes_priority_over_compatibility_elapsed_fields",
            "daylight_core_color_changes_from_dawn_to_midday",
            "paused_clock_and_repeated_draws_freeze_sun_position_and_twilight_color",
            "paused_clock_and_repeated_draws_freeze_moon_position",
            "scene_draw_does_not_mutate_runtime_state",
            "night_reuses_one_existing_overlay_and_day_has_none",
        },
        metrics = {
            viewport = { width = WIDTH, height = HEIGHT },
            sunrise = { x = eastX, y = eastY, horizonY = eastHorizon },
            midday = { x = noonX, y = noonY },
            sunset = { x = westX, y = westY, horizonY = westHorizon },
            moonMidpoint = { x = moonX, y = moonY, horizonY = moonHorizon, radius = moonRadius },
            normalizedQuarterDay = { x = defaultX, y = defaultY },
        },
    }
end

return Tests
