-- World state is independent of rendering and future inventory/player state.
local Config = require("Ocean.Config")
local M = require("Ocean.Math")
local World = {}
World.__index = World

function World.New()
    local self = setmetatable({}, World)
    self:Init()
    return self
end

function World:Init()
    self.entities = {}
    self.byId = {}
    self.nextId = 0
    self.time = 0
    self.daySeed = Config.world.seed
    self.reveals = {}
    self.showUnderwater = false
    self.overlaps = {}
    self.events = {}
    self.onOverlap = false
    for _, object in ipairs(Config.world.fixedObjects) do
        self:spawn({ entityType = object.entityType, kind = "fixed", layer = "surface",
            position = object.position, radius = object.radius, blocking = object.blocking })
    end
end

function World:spawn(spec)
    assert(spec.position and type(spec.position.x) == "number" and type(spec.position.y) == "number", "position requires x,y")
    self.nextId = self.nextId + 1
    local entity = {
        id = "sea-" .. self.nextId, entityType = spec.entityType or "object",
        kind = spec.kind or "dynamic", layer = spec.layer or "surface",
        position = M.copy(spec.position), rotation = spec.rotation or 0,
        direction = { x = math.cos(spec.rotation or 0), y = math.sin(spec.rotation or 0) },
        active = spec.active ~= false, frozen = spec.frozen == true, state = spec.state or "Idle",
        radius = spec.radius or 0, blocking = spec.blocking == true, removed = false,
        species = spec.species, ordinaryFish = spec.ordinaryFish == true,
        itemId = spec.itemId, category = spec.category, worldEffect = spec.worldEffect or "NONE",
        lifetimeSec = spec.lifetimeSec, age = 0,
    }
    self.entities[#self.entities + 1] = entity
    self.byId[entity.id] = entity
    return entity
end

function World:get(id) return self.byId[id] end

function World:remove(id, reason)
    local entity = self.byId[id]
    if not entity then return false end
    entity.removed, entity.active, entity.frozen = true, false, false
    entity.state = "Removed"
    entity.removeReason = reason or "removed"
    self.byId[id] = nil
    self.overlaps[id] = nil
    return true
end

function World:compact()
    local live = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed then live[#live + 1] = entity end
    end
    self.entities = live
end

local function matches(entity, filter)
    if filter == nil then return true end
    if type(filter) == "function" then return filter(entity) end
    for key, expected in pairs(filter) do
        if type(expected) == "table" then
            if not expected[entity[key]] then return false end
        elseif entity[key] ~= expected then return false end
    end
    return true
end

-- Visibility/frozen flags never implicitly filter this interaction query.
function World:queryEntitiesInRadius(center, radius, filter)
    assert(type(radius) == "number" and radius >= 0, "radius must be nonnegative")
    local found = {}
    for _, entity in ipairs(self.entities) do
        if not entity.removed and M.distanceSquared(center, entity.position) <= radius * radius and matches(entity, filter) then
            found[#found + 1] = entity
        end
    end
    return found
end

function World:isPositionFree(position, radius)
    local bound = Config.world.halfSize - radius
    if math.abs(position.x) > bound or math.abs(position.y) > bound then return false end
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and M.distanceSquared(position, object.position) < (radius + object.radius)^2 then
            return false
        end
    end
    return true
end

-- Swept circle prevents tunnelling through islands even for a large caller delta.
function World:moveEntity(entity, dx, dy)
    local start = entity.position
    local epsilon = Config.world.epsilon
    local bound = Config.world.halfSize - entity.radius
    local first, normalX, normalY = 1, 0, 0
    local hit = false
    local function contact(t, nx, ny)
        if t >= 0 and t <= first then first, normalX, normalY, hit = t, nx, ny, true end
    end
    if dx > 0 and start.x+dx > bound then contact((bound-start.x)/dx, -1, 0) end
    if dx < 0 and start.x+dx < -bound then contact((-bound-start.x)/dx, 1, 0) end
    if dy > 0 and start.y+dy > bound then contact((bound-start.y)/dy, 0, -1) end
    if dy < 0 and start.y+dy < -bound then contact((-bound-start.y)/dy, 0, 1) end
    local a = dx*dx + dy*dy
    if a > epsilon then
        for _, object in ipairs(self.entities) do
            if not object.removed and object.blocking and object.id ~= entity.id then
                local ox, oy = start.x-object.position.x, start.y-object.position.y
                local combined = entity.radius+object.radius
                local b = 2*(ox*dx + oy*dy)
                local c = ox*ox+oy*oy-combined*combined
                local discriminant = b*b-4*a*c
                if c < -epsilon then
                    -- Permit exit from an externally supplied overlapping start.
                    if b < 0 then
                        local nx, ny = M.normal(ox, oy)
                        if nx == 0 and ny == 0 then nx, ny = M.normal(-dx, -dy) end
                        contact(0, nx, ny)
                    end
                elseif discriminant >= 0 and b < 0 then
                    local t = (-b-math.sqrt(discriminant))/(2*a)
                    local nx, ny = M.normal(ox+dx*t, oy+dy*t)
                    contact(t, nx, ny)
                end
            end
        end
    end
    local t = hit and math.max(0, first-epsilon) or 1
    local result = { x = M.clamp(start.x+dx*t, -bound, bound), y = M.clamp(start.y+dy*t, -bound, bound) }
    -- Final projection also repairs externally moved/debug entities inside a collider.
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and object.id ~= entity.id then
            local combined = entity.radius+object.radius
            local ox, oy = result.x-object.position.x, result.y-object.position.y
            if ox*ox+oy*oy < combined*combined then
                local nx, ny = M.normal(ox, oy)
                if nx == 0 and ny == 0 then nx, ny = 1, 0 end
                result.x, result.y = object.position.x+nx*(combined+epsilon), object.position.y+ny*(combined+epsilon)
                hit, normalX, normalY = true, nx, ny
            end
        end
    end
    result.x, result.y = M.clamp(result.x, -bound, bound), M.clamp(result.y, -bound, bound)
    entity.position = result
    return hit, normalX, normalY
end

function World:getAvoidance(entity, margin)
    local x, y = entity.position.x, entity.position.y
    local bound = Config.world.halfSize-entity.radius-margin
    local ax, ay = 0, 0
    if x >= bound then ax = ax-1 elseif x <= -bound then ax = ax+1 end
    if y >= bound then ay = ay-1 elseif y <= -bound then ay = ay+1 end
    for _, object in ipairs(self.entities) do
        if not object.removed and object.blocking and object.id ~= entity.id then
            local ox, oy = x-object.position.x, y-object.position.y
            if ox*ox+oy*oy <= (object.radius+entity.radius+margin)^2 then
                local nx, ny = M.normal(ox, oy)
                if nx == 0 and ny == 0 then nx, ny = 1, 0 end
                ax, ay = ax+nx, ay+ny
            end
        end
    end
    if ax*ax+ay*ay > Config.world.epsilon then return M.normal(ax, ay) end
    return nil
end

function World:spawnDroppedItem(payload, position)
    assert(type(payload) == "table" and type(payload.itemId) == "string", "itemId required")
    local effect = payload.worldEffect or "NONE"
    assert(effect == "NONE" or effect == "ATTRACT_SMALL_FISH" or effect == "ATTRACT_BIG_FISH", "unsupported worldEffect")
    local lifetime = payload.lifetimeSec or Config.world.temporaryLifetimeSec
    assert(type(lifetime) == "number" and lifetime > 0, "positive lifetimeSec required")
    assert(self:isPositionFree(position, 0), "drop must be inside playable sea")
    return self:spawn({ entityType = "droppedItem", kind = "temporary", layer = "surface",
        position = position, radius = Config.world.overlapRadius, itemId = payload.itemId,
        category = payload.category, worldEffect = effect, lifetimeSec = lifetime })
end

function World:updateActivity(departure)
    for _, entity in ipairs(self.entities) do
        if not entity.removed and entity.ordinaryFish then
            local distance = M.distanceSquared(entity.position, departure)
            if entity.frozen and distance <= Config.world.activateRadius^2 then
                entity.active, entity.frozen = true, false
            elseif not entity.frozen and distance > Config.world.freezeRadius^2 then
                entity.active, entity.frozen = false, true
            end
        end
    end
end

function World:updateLifecycle(dt, ship)
    self.time = self.time+dt
    self.events = {} -- bounded, per-step events; optional callback for external integration.
    for _, entity in ipairs(self.entities) do
        if not entity.removed and entity.kind == "temporary" then
            entity.age = entity.age+dt
            if entity.age >= entity.lifetimeSec then self:remove(entity.id, "expired") end
        end
        if not entity.removed and not entity.blocking and entity.layer == "surface" and entity.id ~= ship.id then
            local overlap = M.distanceSquared(ship.position, entity.position) <= (ship.radius+entity.radius)^2
            if overlap and not self.overlaps[entity.id] then
                self.events[#self.events + 1] = { type = "overlap", entityId = entity.id, shipId = ship.id }
                if self.onOverlap then self.onOverlap(entity, ship) end
            end
            -- Integration callbacks may synchronously collect/remove the entity.
            -- remove() already cleared its marker; do not reinsert a stale ID.
            self.overlaps[entity.id] = not entity.removed and overlap or nil
        end
    end
    for i = #self.reveals, 1, -1 do
        local reveal = self.reveals[i]
        reveal.remainingSec = reveal.remainingSec-dt
        if reveal.remainingSec <= 0 then table.remove(self.reveals, i) end
    end
end

function World:revealUnderwater(center, radius, durationSec)
    assert(radius >= 0 and durationSec > 0, "invalid reveal")
    self.reveals[#self.reveals + 1] = { center = M.copy(center), radius = radius, remainingSec = durationSec }
end

function World:isVisible(entity)
    if entity.removed then return false end
    if entity.layer ~= "underwater" or self.showUnderwater then return true end
    for _, reveal in ipairs(self.reveals) do
        if M.distanceSquared(entity.position, reveal.center) <= reveal.radius^2 then return true end
    end
    return false
end

function World:clearOrdinaryFish()
    for _, entity in ipairs(self.entities) do
        if entity.ordinaryFish then self:remove(entity.id, "clearOrdinaryFish") end
    end
    self:compact()
end

function World:getCounts()
    local counts = { total = 0, active = 0, frozen = 0, sardine = 0, tuna = 0, temp = 0 }
    for _, entity in ipairs(self.entities) do
        if not entity.removed then
            counts.total = counts.total+1
            if entity.ordinaryFish then
                counts[entity.species] = counts[entity.species]+1
                local key = entity.frozen and "frozen" or "active"
                counts[key] = counts[key]+1
            elseif entity.kind == "temporary" then counts.temp = counts.temp+1 end
        end
    end
    return counts
end
return World
