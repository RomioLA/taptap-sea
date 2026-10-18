-- Loaded-PNG and vector-fallback contracts. No window/native GPU is required.
local Tests = {}

function Tests.Run(recorder)
    local Image = require("Ocean.ImageArt")
    local Art = require("Ocean.SeaViewArt")
    local Geometry = require("Ocean.ProjectedGeometry")
    local Runtime = require("Ocean.SeaRuntime")
    local Scene = require("Ocean.SeaDraw")
    local Draw = require("Ocean.Draw")
    local ArtVariants = require("Ocean.ArtVariants")
    local variantsWereEnabled = ArtVariants.IsEnabled()
    ArtVariants.SetEnabled(true)
    local results = {}
    local function check(name, callback)
        local ok, err = pcall(callback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end
    local ctx = {}
    local oldCreate, oldDelete = nvgCreateImage, nvgDeleteImage
    local oldPattern, oldAntiAlias = nvgImagePattern, nvgShapeAntiAlias
    -- The vector recorder has no native image sampler. These bindings permit
    -- real Plane UV/clipping code to run; they do not assert rasterised pixels.
    nvgImagePattern = nvgImagePattern or function(_, _, _, _, _, _, image, alpha)
        return { image = image, alpha = alpha }
    end
    nvgShapeAntiAlias = nvgShapeAntiAlias or function() end
    local oldStroke, oldSprite, oldPlane = Geometry.StrokeWorldLine, Image.Sprite, Image.Plane
    local oldNight, oldFish = Draw.NightOverlay, Draw.WorldFish
    local oldMipmap = NVG_IMAGE_GENERATE_MIPMAPS
    local oldRepeatX, oldRepeatY = NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS = NVG_IMAGE_GENERATE_MIPMAPS or 1
    NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = NVG_IMAGE_REPEATX or 2, NVG_IMAGE_REPEATY or 4
    local created, deleted, strokes, imageCalls, planeCalls, order = 0, 0, 0, {}, {}, {}
    local failedPath
    nvgCreateImage = function(_, path)
        if path == failedPath then return -1 end
        created = created + 1
        return created
    end
    nvgDeleteImage = function() deleted = deleted + 1 end
    Geometry.StrokeWorldLine = function(...)
        strokes = strokes + 1
        return oldStroke(...)
    end
    Image.Sprite = function(context, name, movement, position, length, heading, altitude, alpha, width, roll)
        imageCalls[#imageCalls + 1] = { name = name, length = length, width = width, alpha = alpha }
        order[#order + 1] = name
        return oldSprite(context, name, movement, position, length, heading, altitude, alpha, width, roll)
    end
    Image.Plane = function(context, name, movement, origin, length, width, heading, altitude, alpha, roll)
        planeCalls[#planeCalls + 1] = { name = name, length = length, width = width }
        return oldPlane(context, name, movement, origin, length, width, heading, altitude, alpha, roll)
    end
    Draw.NightOverlay = function(...)
        order[#order + 1] = "night"
        return oldNight(...)
    end
    Draw.WorldFish = function(...)
        order[#order + 1] = "underwater"
        return oldFish(...)
    end
    local runtime = Runtime.New({ initializeRegions = false, daySeed = 271828 })
    runtime.movement:SetViewport(1280, 720)
    runtime.movement:ResetAtPosition({ x = 0, y = -35 })
    local island = { position = { x = 0, y = 0 }, radius = 20, entityType = "island", layer = "surface" }
    check("boat and complete-island W2 candidates stay out of the runtime catalog", function()
        assert(Image.GetSpec("boat") == nil and Image.GetSpec("boat_story") == nil)
        local spec = assert(Image.GetSpec("island"))
        assert(not spec.completeIsland and spec.path == "image/OceanLoop/island.png")
        spec.completeIsland = false
        assert(not Image.GetSpec("island").completeIsland)
    end)
    check("island uses the base image and layered decor", function()
        Image.Load(ctx)
        planeCalls = {}
        local bounds = Art.Island(ctx, runtime.movement, island, 9, 0)
        assert(bounds and bounds.width > 0 and bounds.height > 0)
        local used = {}
        for _, call in ipairs(planeCalls) do used[call.name] = true end
        assert(used.island, "base island layer was not requested")
        assert(not used.foam_ring,
            "shore foam was removed (2026-10-18 user feedback) but a foam layer was requested")
        assert(used.hill_sand or used.hill_grass, "hill decor layer was not requested")
        assert(used.tree_palm or used.tree_round, "tree decor layer was not requested")
        assert(island.position.x == 0 and island.position.y == 0 and island.radius == 20)
    end)
    check("warm PNG drawing reads current geometry after radius position and viewport changes", function()
        island.radius = 12
        island.position.x = 2
        runtime.movement:SetViewport(1920, 1080)
        planeCalls = {}
        Art.Island(ctx, runtime.movement, island, 11, .5)
        local call
        for _, entry in ipairs(planeCalls) do
            if entry.name == "island" then call = entry; break end
        end
        local spec = assert(Image.GetSpec("island_story"))
        assert(call and math.abs(call.length - 24 * spec.pixelWidth / spec.contentWidth) < 1e-9)
        assert(math.abs(call.width - 24 * spec.pixelHeight / spec.contentHeight) < 1e-9)
        assert(island.position.x == 2 and island.radius == 12)
    end)
    check("boat remains vector-drawn through a full turn", function()
        local x, y = runtime.ship.position.x, runtime.ship.position.y
        local spriteCount = #imageCalls
        for index = 0, 23 do
            runtime.ship.rotation = index * math.pi / 12
            assert(Art.Boat(ctx, runtime.movement, runtime.ship, 9))
        end
        assert(#imageCalls == spriteCount, "vector boat unexpectedly requested a sprite")
        assert(runtime.ship.position.x == x and runtime.ship.position.y == y)
    end)
    check("failed island base image restores the vector coast path", function()
        Image.Release(ctx)
        failedPath = assert(Image.GetSpec("island_story")).path
        strokes = 0
        local bounds = Art.Island(ctx, runtime.movement, island, 9, 0)
        assert(bounds and strokes > 0, "base PNG failure did not retain vector coast geometry")
        failedPath = nil
        Image.Release(ctx)
    end)
    check("night grade follows layered island, vector ship and signal images", function()
        Image.Load(ctx)
        runtime.world.entities[#runtime.world.entities + 1] = island
        runtime:spawnFish("sardine", { x = 0, y = -20 }, 0)
        runtime:setDebugFlag("showUnderwater", true)
        runtime.surfaceSignals = {
            VisitSplashes = function(_, visit) visit(0, -20, .3, .6, 0, 2) end,
            VisitBirds = function(_, visit) visit(0, -20, 0, .5) end,
        }
        order, planeCalls = {}, {}
        Scene.Scene(ctx, 1920, 1080, runtime, { phase = "night" })
        assert(order[#order] == "night")
        local seen, planes = {}, {}
        for _, name in ipairs(order) do seen[name] = true end
        for _, call in ipairs(planeCalls) do planes[call.name] = true end
        assert(planes.island and not planes.foam_ring and (planes.hill_sand or planes.hill_grass))
        assert(not seen.island and not seen.boat, "island/boat should not use complete PNG sprites")
        assert(seen.splash and seen.gull_dive and seen.underwater)
        order = {}
        Scene.Scene(ctx, 1920, 1080, runtime, { phase = "day" })
        for _, name in ipairs(order) do assert(name ~= "night") end
    end)
    Image.Release(ctx)
    check("added runtime images retain balanced create release lifecycle", function()
        assert(created == deleted)
    end)
    Geometry.StrokeWorldLine, Image.Sprite, Image.Plane = oldStroke, oldSprite, oldPlane
    Draw.NightOverlay, Draw.WorldFish = oldNight, oldFish
    ArtVariants.SetEnabled(variantsWereEnabled)
    nvgCreateImage, nvgDeleteImage = oldCreate, oldDelete
    nvgImagePattern, nvgShapeAntiAlias = oldPattern, oldAntiAlias
    NVG_IMAGE_GENERATE_MIPMAPS = oldMipmap
    NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = oldRepeatX, oldRepeatY
    return { results = results }
end

return Tests
