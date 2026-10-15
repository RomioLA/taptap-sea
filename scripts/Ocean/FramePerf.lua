-- P0（2026-10-06）：帧级性能采样——update/draw 毫秒、每帧 nvgFill 数、Lua 内存。
-- 与 T3 的 Ocean.PerfProbe（海岛分项）互补；读数走 SeaDebug 面板一行，
-- 不每帧打日志（诊断日志铁律）。默认关闭，os.clock 不可用时整体降级为空操作。
--
-- P0b（2026-10-15，卡顿排查）：追加原始 TimeStep 直采。引擎若把 Update 事件的
-- TimeStep 钳制在 ~0.1s（常见安全钳制），帧耗时 >0.1s 时游戏时间会慢于墙钟
-- （4s 操作实测 ~6s = 40 帧 × 0.15s，比例 1.5× 与钳制值 0.1s 精确吻合）。
-- dtMax/dtOverStep 用于真机确认/排除该假设；不钳制则 dtMax ≈ 帧耗时。
local FramePerf = {}

local clockFn = (type(os) == "table" and type(os.clock) == "function") and os.clock or nil

-- 引擎 TimeStep 钳制嫌疑值：超过即计入 dtOverStep（真机诊断用，不是阈值告警）。
local DT_CLAMP_SUSPECT = 0.1

local acc = nil

local function freshAccumulators()
    return { frames = 0, updateMs = 0, drawMs = 0, fills = 0,
        dtSum = 0, dtMax = 0, dtMin = math.huge, dtOverStep = 0,
        wallStart = nil, wallEnd = nil, phases = {} }
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

---墙钟毫秒（操作计时埋点用；os.clock 不可用时返回 nil）。
function FramePerf.WallMs()
    if not clockFn then return nil end
    return clockFn() * 1000
end

---@param dt number? 宿主传入的原始 TimeStep（秒）。缺省时不统计 dt。
function FramePerf.BeginUpdate(dt)
    if not acc then return end
    acc.updateStart = clockFn()
    if type(dt) == "number" and dt == dt and dt >= 0 and dt < math.huge then
        acc.dtSum = acc.dtSum + dt
        if dt > acc.dtMax then acc.dtMax = dt end
        if dt < acc.dtMin then acc.dtMin = dt end
        if dt > DT_CLAMP_SUSPECT then acc.dtOverStep = acc.dtOverStep + 1 end
    end
    if not acc.wallStart then acc.wallStart = clockFn() end
end

---Update 内部分段起点（2026-10-15 卡顿排查）：把 Upd 57ms 级拆成
---sim（玩法+海洋模拟）与 tools（HUD/调试刷新）两类，直接定位大头。
---仅 FramePerf 启用时记录；未启用时为零开销空操作。
---@param name string
function FramePerf.BeginPhase(name)
    if not acc or type(name) ~= "string" then return end
    acc.phaseName, acc.phaseStart = name, clockFn()
end

function FramePerf.EndPhase()
    if not acc or not acc.phaseStart then return end
    acc.phases = acc.phases or {}
    local name = acc.phaseName
    acc.phases[name] = (acc.phases[name] or 0) + (clockFn() - acc.phaseStart) * 1000
    acc.phaseStart, acc.phaseName = nil, nil
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
    acc.wallEnd = clockFn()
    local wallElapsed = (acc.wallStart and acc.wallEnd) and (acc.wallEnd - acc.wallStart) or 0
    local snapshot = {
        frames = frames,
        updateMs = acc.updateMs / frames,
        drawMs = acc.drawMs / frames,
        fillsPerFrame = acc.fills / frames,
        luaKB = (type(collectgarbage) == "function") and math.floor((collectgarbage("count") or 0)) or 0,
        -- dt 直采：dtMax ≈ 帧耗时说明引擎未钳制；dtMax 钉在 ~0.1 而帧耗时更大说明被钳制。
        dtAvg = acc.dtSum / frames,
        dtMax = acc.dtMax,
        dtMin = acc.dtMin < math.huge and acc.dtMin or nil,
        dtOverStep = acc.dtOverStep,
        fps = wallElapsed > 0 and (frames / wallElapsed) or nil,
        -- Update 分段（sim=玩法+海洋模拟，tools=HUD/调试刷新）。
        simMs = (acc.phases and acc.phases.sim or 0) / frames,
        toolsMs = (acc.phases and acc.phases.tools or 0) / frames,
    }
    acc = freshAccumulators()
    return snapshot
end

return FramePerf
