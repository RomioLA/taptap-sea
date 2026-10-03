-- Sea Runtime V1 ship steering and camera transforms.
-- This module stays independent from UrhoX so the runtime can use its world model directly.
local Config = require("Ocean.Config")
local Math = require("Ocean.Math")

---@class OceanPoint
---@field x number
---@field y number

---@class OceanShip
---@field id string
---@field position OceanPoint
---@field rotation number
---@field direction OceanPoint
---@field radius number
---@field level number?

---@class OceanWorld
---@field moveEntity fun(self:OceanWorld, entity:OceanShip, dx:number, dy:number): boolean, number, number

---@class OceanMovement
---@field world OceanWorld
---@field ship OceanShip
---@field target OceanPoint?
---@field speed number
---@field maxSpeed number
---@field level number
---@field camera OceanPoint
---@field viewportWidth number
---@field viewportHeight number
---@field viewWidth number
---@field viewHeight number
---@field viewportReady boolean
---@field pushRemaining number
---@field pushNormal OceanPoint
local Movement = {}
Movement.__index = Movement

local function copyPoint(point)
    return { x = point.x, y = point.y }
end

local function numberOrZero(value)
    if type(value) ~= "number" or value ~= value then return 0 end
    return value
end

local function updateDirection(ship)
    local direction = ship.direction
    if type(direction) ~= "table" then
        direction = {}
        ship.direction = direction
    end
    direction.x = math.cos(ship.rotation)
    direction.y = math.sin(ship.rotation)
end

---@param world OceanWorld
---@param ship OceanShip
---@return OceanMovement
function Movement.New(world, ship)
    local self = setmetatable({}, Movement)
    self:Init(world, ship)
    return self
end

---@param world OceanWorld
---@param ship OceanShip
function Movement:Init(world, ship)
    assert(world and type(world.moveEntity) == "function", "world.moveEntity is required")
    assert(type(ship) == "table", "ship is required")

    if type(ship.position) ~= "table" then
        ship.position = copyPoint(Config.ship.start)
    end
    assert(type(ship.position.x) == "number" and type(ship.position.y) == "number",
        "ship.position requires x,y")
    if type(ship.rotation) ~= "number" then
        local direction = ship.direction
        if type(direction) == "table" and type(direction.x) == "number" and type(direction.y) == "number" then
            ship.rotation = math.atan(direction.y, direction.x)
        else
            ship.rotation = 0
        end
    end
    updateDirection(ship)

    self.world = world
    self.ship = ship
    ---@type OceanPoint?
    self.target = nil
    self.speed = Math.clamp(Config.ship.speed, 0, Config.ship.maxSpeed)
    self.maxSpeed = Config.ship.maxSpeed
    self:SetLevel(ship.level or Config.ship.defaultLevel)
    self.camera = { x = ship.position.x, y = ship.position.y }
    self.viewportWidth = 1
    self.viewportHeight = 1
    self.viewHeight = Config.camera.viewHeight
    self.viewWidth = self.viewHeight
    self.viewportReady = false
    self.pushRemaining = 0
    self.pushNormal = { x = 0, y = 0 }
    self:_AnchorCameraToShip()
end

---@param position OceanPoint?
---@return OceanMovement
function Movement:SetTarget(position)
    if position == nil then
        self.target = nil
    else
        assert(type(position) == "table" and type(position.x) == "number" and type(position.y) == "number",
            "target requires x,y")
        self.target = copyPoint(position)
    end
    return self
end

-- Reset only the existing ship transform and transient steering feedback. The
-- owning World/entity, current speed level, and any outside sea state survive.
---@param position OceanPoint
---@return OceanMovement
function Movement:ResetAtPosition(position)
    assert(type(position) == "table" and type(position.x) == "number" and type(position.y) == "number",
        "reset position requires x,y")
    self.ship.position = copyPoint(position)
    updateDirection(self.ship)
    self.target = nil
    self.pushRemaining = 0
    self.pushNormal.x, self.pushNormal.y = 0, 0
    self:_AnchorCameraToShip()
    return self
end

---@param speed number
---@return number
function Movement:SetSpeed(speed)
    self.speed = Math.clamp(numberOrZero(speed), 0, self.maxSpeed)
    return self.speed
end

-- B owns purchase/payment; A consumes only the configured capability level.
---@param level number
---@return number speed
function Movement:SetLevel(level)
    assert(type(level) == "number" and level % 1 == 0
        and Config.ship.speedByLevel[level] ~= nil, "unsupported ship level")
    self.level, self.ship.level = level, level
    return self:SetSpeed(Config.ship.speedByLevel[level])
end

function Movement:_AnchorCameraToShip()
    local cameraConfig = Config.camera
    self.camera.x = self.ship.position.x - (cameraConfig.anchorX - 0.5) * self.viewWidth
    self.camera.y = self.ship.position.y + (cameraConfig.anchorY - 0.5) * self.viewHeight
end

---@param logicalW number
---@param logicalH number
---@return boolean
function Movement:SetViewport(logicalW, logicalH)
    logicalW, logicalH = numberOrZero(logicalW), numberOrZero(logicalH)
    if logicalW <= 0 or logicalH <= 0 then return false end

    local changed = not self.viewportReady
        or logicalW ~= self.viewportWidth
        or logicalH ~= self.viewportHeight
    if not changed then return false end

    self.viewportWidth = logicalW
    self.viewportHeight = logicalH
    self.viewHeight = Config.camera.viewHeight
    self.viewWidth = self.viewHeight * logicalW / logicalH
    self.viewportReady = true
    -- Recompute the camera offset after a resize so the ship keeps its configured screen anchor.
    self:_AnchorCameraToShip()
    return true
end

---@param position OceanPoint?
---@return number, number
function Movement:WorldToScreen(position)
    position = position or self.ship.position
    local width = self.viewportWidth
    local height = self.viewportHeight
    local scale = width / self.viewWidth
    return width * 0.5 + (position.x - self.camera.x) * scale,
        height * 0.5 - (position.y - self.camera.y) * scale
end

---@param x number
---@param y number
---@return OceanPoint
function Movement:ScreenToWorld(x, y)
    local scale = self.viewportWidth / self.viewWidth
    return {
        x = self.camera.x + (x - self.viewportWidth * 0.5) / scale,
        y = self.camera.y - (y - self.viewportHeight * 0.5) / scale,
    }
end

function Movement:_UpdateShip(step, axisX, axisY, keyboardActive)
    local ship = self.ship
    local target = self.target
    ---@type number?
    local desiredAngle
    local moveX, moveY = 0, 0

    if keyboardActive then
        desiredAngle = math.atan(axisY, axisX)
    elseif target then
        local toTargetX = target.x - ship.position.x
        local toTargetY = target.y - ship.position.y
        local targetDistance = math.sqrt(toTargetX * toTargetX + toTargetY * toTargetY)
        if targetDistance <= Config.ship.arrivalRadius then
            self.target = nil
            target = nil
        elseif targetDistance > Config.world.epsilon then
            desiredAngle = math.atan(toTargetY, toTargetX)
        end
    end

    if desiredAngle ~= nil then
        local maxTurn = Config.ship.turnDegPerSec * (math.pi / 180) * step
        ship.rotation = Math.turn(ship.rotation, desiredAngle, maxTurn)
    end
    updateDirection(ship)

    local travel = 0
    if keyboardActive then
        travel = self.speed * step
    elseif target then
        local toTargetX = target.x - ship.position.x
        local toTargetY = target.y - ship.position.y
        local targetDistance = math.sqrt(toTargetX * toTargetX + toTargetY * toTargetY)
        if targetDistance <= Config.ship.arrivalRadius then
            self.target = nil
            target = nil
        elseif targetDistance > Config.world.epsilon then
            travel = self.speed * step
            -- Stop at the closest point on this heading instead of stepping past the target.
            local forwardDistance = toTargetX * ship.direction.x + toTargetY * ship.direction.y
            if forwardDistance > 0 and travel > forwardDistance then
                travel = forwardDistance
            end
        end
    end

    if travel > 0 then
        moveX = ship.direction.x * travel
        moveY = ship.direction.y * travel
    end

    local hadPush = self.pushRemaining > Config.world.epsilon
    local pushFor = hadPush and math.min(step, self.pushRemaining) or 0
    local pushDistance = Config.world.pushSpeed * pushFor
    local pushX = self.pushNormal.x * pushDistance
    local pushY = self.pushNormal.y * pushDistance
    if hadPush then
        -- While the push feedback is active, cancel only intent into the contact.
        -- Tangential steering and input back toward open water remain available.
        local outwardIntent = moveX * self.pushNormal.x + moveY * self.pushNormal.y
        if outwardIntent < 0 then
            moveX = moveX - outwardIntent * self.pushNormal.x
            moveY = moveY - outwardIntent * self.pushNormal.y
        end
    end
    local dx, dy = moveX + pushX, moveY + pushY

    if dx ~= 0 or dy ~= 0 then
        local collided, normalX, normalY = self.world:moveEntity(ship, dx, dy)
        normalX, normalY = numberOrZero(normalX), numberOrZero(normalY)

        if hadPush then
            self.pushRemaining = math.max(0, self.pushRemaining - step)
        elseif collided and moveX * normalX + moveY * normalY < -Config.world.epsilon then
            local normalLength = math.sqrt(normalX * normalX + normalY * normalY)
            if normalLength > Config.world.epsilon then
                self.pushNormal.x = normalX / normalLength
                self.pushNormal.y = normalY / normalLength
                self.pushRemaining = Config.world.pushSec
            end
        end
    elseif hadPush then
        self.pushRemaining = math.max(0, self.pushRemaining - step)
    end

    if self.target and Math.distance(ship.position, self.target) <= Config.ship.arrivalRadius then
        self.target = nil
    end
end

function Movement:_UpdateCamera(dt)
    if dt <= 0 then return end

    local cameraConfig = Config.camera
    local ship = self.ship.position
    local shipScreenX = 0.5 + (ship.x - self.camera.x) / self.viewWidth
    local shipScreenY = 0.5 + (self.camera.y - ship.y) / self.viewHeight
    local targetX, targetY = self.camera.x, self.camera.y

    if shipScreenX < cameraConfig.minX then
        targetX = ship.x - (cameraConfig.minX - 0.5) * self.viewWidth
    elseif shipScreenX > cameraConfig.maxX then
        targetX = ship.x - (cameraConfig.maxX - 0.5) * self.viewWidth
    end
    if shipScreenY < cameraConfig.minY then
        targetY = ship.y + (cameraConfig.minY - 0.5) * self.viewHeight
    elseif shipScreenY > cameraConfig.maxY then
        targetY = ship.y + (cameraConfig.maxY - 0.5) * self.viewHeight
    end

    local followSec = math.max(cameraConfig.followSec, Config.world.epsilon)
    local blend = 1 - math.exp(-dt / followSec)
    self.camera.x = self.camera.x + (targetX - self.camera.x) * blend
    self.camera.y = self.camera.y + (targetY - self.camera.y) * blend
end

---@param dt number
---@param axisX number?
---@param axisY number?
function Movement:Update(dt, axisX, axisY)
    dt = math.max(0, numberOrZero(dt))
    axisX, axisY = numberOrZero(axisX), numberOrZero(axisY)

    local axisLength = math.sqrt(axisX * axisX + axisY * axisY)
    local keyboardActive = axisLength > Config.world.epsilon
    if keyboardActive then
        -- Keyboard directions all use the same speed, including diagonals.
        axisX, axisY = axisX / axisLength, axisY / axisLength
        self.target = nil
    end

    if dt <= 0 then return end
    local maxStep = math.max(Config.world.maxStepSec, Config.world.epsilon)
    local stepCount = math.max(1, math.ceil(dt / maxStep))
    local step = dt / stepCount
    for _ = 1, stepCount do
        self:_UpdateShip(step, axisX, axisY, keyboardActive)
    end
    self:_UpdateCamera(dt)
end

return Movement
