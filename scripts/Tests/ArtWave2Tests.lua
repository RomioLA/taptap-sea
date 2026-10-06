-- Loaded-PNG and vector-fallback contracts. No window/native GPU is required.
local Tests = {}

function Tests.Run(recorder)
    local Image = require("Ocean.ImageArt")
    local Art = require("Ocean.SeaViewArt")
    local Geometry = require("Ocean.ProjectedGeometry")
    local Runtime = require("Ocean.SeaRuntime")
    local Scene = require("Ocean.SeaDraw")
    local Draw = require("Ocean.Draw")
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
    local oldStroke, oldSprite, oldNight, oldFish = Geometry.StrokeWorldLine, Image.Sprite, Draw.NightOverlay, Draw.WorldFish
    local oldMipmap = NVG_IMAGE_GENERATE_MIPMAPS
    local oldRepeatX, oldRepeatY = NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY
    NVG_IMAGE_GENERATE_MIPMAPS = NVG_IMAGE_GENERATE_MIPMAPS or 1
    NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = NVG_IMAGE_REPEATX or 2, NVG_IMAGE_REPEATY or 4
    local created, deleted, strokes, imageCalls, order = 0, 0, 0, {}, {}
    nvgCreateImage = function() created = created + 1; return created end
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
    check("complete island metadata is immutable and uses the W2 runtime path", function()
        local spec = assert(Image.GetSpec("island"))
        assert(spec.completeIsland and spec.pixelWidth == 768)
        assert(spec.path == "image/OceanWave2/island.png")
        spec.completeIsland = false
        assert(Image.GetSpec("island").completeIsland)
    end)
    check("loaded complete island skips coast foam hills and tree strokes", function()
        Image.Load(ctx)
        strokes = 0
        assert(Art.Island(ctx, runtime.movement, island, 9, 0))
        assert(strokes == 0, "PNG still paid for vector shore/hill/tree drawing")
        assert(imageCalls[#imageCalls].name == "island")
        assert(island.position.x == 0 and island.position.y == 0 and island.radius == 20)
    end)
    check("warm PNG drawing reads current geometry after radius position and viewport changes", function()
        island.radius = 12
        island.position.x = 2
        runtime.movement:SetViewport(1920, 1080)
        Art.Island(ctx, runtime.movement, island, 11, .5)
        local call = imageCalls[#imageCalls]
        assert(call.length == 24 and call.width == 24 and strokes == 0)
        assert(island.position.x == 2 and island.radius == 12)
    end)
    check("loaded boat retains continuous heading and world projection through a full turn", function()
        local x, y = runtime.ship.position.x, runtime.ship.position.y
        for index = 0, 23 do
            runtime.ship.rotation = index * math.pi / 12
            assert(Art.Boat(ctx, runtime.movement, runtime.ship, 9))
            assert(imageCalls[#imageCalls].name == "boat")
        end
        assert(runtime.ship.position.x == x and runtime.ship.position.y == y)
    end)
    check("unloaded complete PNG restores the original cached vector path", function()
        Image.Release(ctx)
        strokes = 0
        assert(Art.Island(ctx, runtime.movement, island, 9, 0))
        assert(strokes > 0)
        local first = strokes
        strokes = 0
        Art.Island(ctx, runtime.movement, island, 9, 0)
        assert(strokes == first, "warm fallback changed visual content")
    end)
    check("night grade follows loaded island ship and signal images while daytime has no overlay", function()
        Image.Load(ctx)
        runtime.world.entities[#runtime.world.entities + 1] = island
        runtime:spawnFish("sardine", { x = 0, y = -20 }, 0)
        runtime:setDebugFlag("showUnderwater", true)
        runtime.surfaceSignals = {
            VisitSplashes = function(_, visit) visit(0, -20, .3, .6, 0, 2) end,
            VisitBirds = function(_, visit) visit(0, -20, 0, .5) end,
        }
        order = {}
        Scene.Scene(ctx, 1920, 1080, runtime, { phase = "night" })
        assert(order[#order] == "night")
        local seen = {}
        for _, name in ipairs(order) do seen[name] = true end
        assert(seen.island and seen.boat and seen.splash and seen.gull_dive and seen.underwater)
        order = {}
        Scene.Scene(ctx, 1920, 1080, runtime, { phase = "day" })
        for _, name in ipairs(order) do assert(name ~= "night") end
    end)
    Image.Release(ctx)
    check("added runtime images retain balanced create release lifecycle", function()
        assert(created == deleted)
    end)
    Geometry.StrokeWorldLine, Image.Sprite, Draw.NightOverlay, Draw.WorldFish = oldStroke, oldSprite, oldNight, oldFish
    nvgCreateImage, nvgDeleteImage = oldCreate, oldDelete
    nvgImagePattern, nvgShapeAntiAlias = oldPattern, oldAntiAlias
    NVG_IMAGE_GENERATE_MIPMAPS = oldMipmap
    NVG_IMAGE_REPEATX, NVG_IMAGE_REPEATY = oldRepeatX, oldRepeatY
    return { results = results }
end

return Tests
