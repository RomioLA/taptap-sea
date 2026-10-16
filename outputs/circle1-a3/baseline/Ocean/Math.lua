local M = {}
function M.copy(p) return { x = p.x, y = p.y } end
function M.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function M.distanceSquared(a, b) return (a.x-b.x)^2 + (a.y-b.y)^2 end
function M.distance(a, b) return math.sqrt(M.distanceSquared(a, b)) end
function M.normal(x, y)
    local length = math.sqrt(x*x+y*y)
    if length <= require("Ocean.Config").world.epsilon then return 0, 0 end
    return x/length, y/length
end
function M.angle(x, y) return math.atan(y, x) end
function M.turn(current, target, maxRadians)
    local delta = (target-current+math.pi) % (2*math.pi)-math.pi
    return current + M.clamp(delta, -maxRadians, maxRadians)
end
-- Independent deterministic generator; no mutation of global math.random state.
function M.rng(seed)
    local value = math.floor(seed) % 2147483647
    if value <= 0 then value = 1 end
    return function()
        value = (value * 48271) % 2147483647
        return value / 2147483647
    end
end
return M
