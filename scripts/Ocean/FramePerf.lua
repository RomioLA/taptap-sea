-- P0（2026-10-06）：帧级性能采样——update/draw 毫秒、每帧 nvgFill 数、Lua 内存。
-- 与 T3 的 Ocean.PerfProbe（海岛分项）互补；读数走 SeaDebug 面板一行，
-- 不每帧打日志（诊断日志铁律）。默认关闭，os.clock 不可用时整体降级为空操作。
local FramePerf = {}

local clockFn = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil

local acc = nil

local function freshAccumulators()
    return { frames = 0, updateMs = 0, drawMs = 0, fills = 0 }
end

function FramePerf.IsEnabled()
    return acc ~= nil
end

function FramePerf.SetEnabled(enabled)
    if enabled and clockFn then
        if acc == nil then acc = freshAccumulators() end
    else
        acc = nil
    end
end

function FramePerf.BeginUpdate()
    if acc then acc.updateStart = clockFn() end
end

function FramePerf.EndUpdate()
    if acc and acc.updateStart then
        acc.updateMs = acc.updateMs + (clockFn() - acc.updateStart) * 1000
        acc.updateStart = nil
    end
end

function FramePerf.BeginDraw()
    if acc then acc.drawStart = clockFn() end
end

function FramePerf.EndDraw()
    if acc and acc.drawStart then
        acc.drawMs = acc.drawMs + (clockFn() - acc.drawStart) * 1000
        acc.drawStart = nil
        acc.frames = acc.frames + 1
    end
end

--- 返回自上次快照的每帧均值；无新帧返回 nil。
function FramePerf.SnapshotAndReset()
    if acc == nil or acc.frames == 0 then return nil end
    local frames = acc.frames
    local snapshot = {
        frames = frames,
        updateMs = acc.updateMs / frames,
        drawMs = acc.drawMs / frames,
        fillsPerFrame = acc.fills / frames,
        luaKB = (type(collectgarbage) == "function") and math.floor((collectgarbage("count") or 0)) or 0,
    }
    acc = freshAccumulators()
    return snapshot
end

return FramePerf
