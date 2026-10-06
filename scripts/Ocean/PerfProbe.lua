-- T3（2026-10-06）：海岛帧耗时分项探针。
-- 采样走 os.clock（不可用时整体禁用，采样变 no-op）；读数走 Debug 面板
-- 快照，不每帧打日志（诊断日志铁律）。默认关闭，仅开发模式可达。
local PerfProbe = {}

local clockFn = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil

local accumulators = nil  -- { frames, scene, islandPng, islandVector, islandTotal }

function PerfProbe.IsEnabled()
    return accumulators ~= nil
end

function PerfProbe.SetEnabled(enabled)
    if enabled and clockFn then
        if accumulators == nil then
            accumulators = { frames = 0, scene = 0, islandPng = 0, islandVector = 0, islandTotal = 0 }
        end
    else
        accumulators = nil
    end
end

--- 段级采样：name ∈ scene/islandPng/islandVector/islandTotal，elapsedMs 毫秒。
function PerfProbe.Sample(name, elapsedMs)
    local bucket = accumulators and accumulators[name]
    if bucket then accumulators[name] = bucket + (elapsedMs or 0) end
end

--- 帧计数推进（SeaDraw.Scene 每帧调用一次）。
function PerfProbe.Frame()
    if accumulators then accumulators.frames = accumulators.frames + 1 end
end

--- 返回自上次快照以来的每帧均值（毫秒）并清零累计；快照为空返回提示。
function PerfProbe.SnapshotAndReset()
    if not clockFn then return "os.clock 不可用，探针禁用" end
    if accumulators == nil or accumulators.frames == 0 then
        return "探针未开启或无新帧；先开探针再绕岛航行数秒"
    end
    local frames = accumulators.frames
    local scene, png, vector, total = accumulators.scene, accumulators.islandPng,
        accumulators.islandVector, accumulators.islandTotal
    accumulators = { frames = 0, scene = 0, islandPng = 0, islandVector = 0, islandTotal = 0 }
    return string.format("帧数%d｜全帧%.2fms｜岛PNG%.2fms｜岛矢量(山树泡沫)%.2fms｜岛合计%.2fms",
        frames, scene / frames, png / frames, vector / frames, total / frames)
end

--- 计时器工厂：返回 stop 函数（毫秒）；探针关闭或无时钟时 stop 为空操作。
function PerfProbe.Timer()
    if not clockFn or not accumulators then return function() end end
    local start = clockFn() * 1000
    return function()
        if accumulators then
            return clockFn() * 1000 - start
        end
        return 0
    end
end

return PerfProbe
