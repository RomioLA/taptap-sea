-- 基于 2D 脚手架的界面层，文字和按钮全部使用 urhox-libs/UI。
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local HUD = {}

function HUD.Create(game)
    local statusLabel = UI.Label {
        text = "场景运行中",
        fontSize = 9,
        fontColor = { 205, 231, 218, 255 },
        textAlign = "center",
    }
    -- STEP-1~4 基座诊断行：数据自检 / 点击世界坐标直接上屏（Maker 预览无控制台日志）
    local diagLabel = UI.Label {
        text = "诊断: -",
        fontSize = 9,
        fontColor = { 255, 226, 150, 255 },
        textAlign = "center",
    }
    local function UpdateDiagnostics(text)
        diagLabel:SetText(text or "-")
    end
    local pauseButton = UI.Button {
        text = "暂停",
        width = 72,
        height = 40,
        fontSize = 10,
        borderRadius = 20,
        backgroundColor = { 247, 233, 195, 255 },
        textColor = { 36, 83, 90, 255 },
        hoverBackgroundColor = { 255, 245, 218, 255 },
        pressedBackgroundColor = { 221, 205, 169, 255 },
    }

    -- STEP-5 昼夜倒计时：每帧 tick，仅在整秒文本变化时 SetText，避免 UI 每帧重排。
    local lastStatusText
    local function FormatClock()
        local clock = game:GetClock()
        if not clock then return "" end
        local phaseText = clock.phase == "night" and "夜晚" or "白天"
        return string.format("第%d天 · %s · 剩余%d秒",
            clock.day, phaseText, math.max(0, math.ceil(clock.remaining)))
    end
    local function Tick()
        local statusText = game:IsPaused() and ("已暂停 · " .. FormatClock()) or FormatClock()
        if statusText ~= lastStatusText then
            lastStatusText = statusText
            statusLabel:SetText(statusText)
        end
    end

    local function Refresh()
        pauseButton:SetText(game:IsPaused() and "继续" or "暂停")
        Tick()
    end

    local function TogglePause()
        game:TogglePause()
        Refresh()
    end

    local function Reset()
        game:Reset()
        Refresh()
    end

    pauseButton.props.onClick = TogglePause

    local function MoveButton(text, direction)
        return UI.Button {
            text = text,
            width = 46,
            height = 40,
            fontSize = 14,
            paddingHorizontal = 0,
            borderRadius = 20,
            backgroundColor = { 249, 247, 221, 22 },
            hoverBackgroundColor = { 249, 247, 221, 50 },
            pressedBackgroundColor = { 249, 247, 221, 75 },
            textColor = { 246, 244, 218, 255 },
            borderWidth = 1,
            borderColor = { 212, 235, 219, 65 },
            onClick = function() game:MoveBy(direction) end,
        }
    end

    -- STEP-8 调试信号按钮：与键盘 B/N 同效，生成于最近一次点击的海面位置
    local function DebugButton(text, spawn)
        return UI.Button {
            text = text,
            width = 88,
            height = 40,
            fontSize = 10,
            borderRadius = 20,
            backgroundColor = { 249, 247, 221, 22 },
            textColor = { 246, 244, 218, 255 },
            hoverBackgroundColor = { 249, 247, 221, 50 },
            pressedBackgroundColor = { 249, 247, 221, 75 },
            borderWidth = 1,
            borderColor = { 212, 235, 219, 65 },
            onClick = function() spawn(game.lastClickWorld or { x = 12, y = 0 }) end,
        }
    end

    local root = UI.Panel {
        id = "oceanRoot",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            UI.SafeAreaView {
                width = "100%",
                height = "100%",
                nativeMenuInset = true,
                pointerEvents = "box-none",
                paddingHorizontal = 24,
                paddingTop = 18,
                paddingBottom = 12,
                justifyContent = "space-between",
                children = {
                    UI.Panel {
                        pointerEvents = "none",
                        paddingHorizontal = 24,
                        gap = 5,
                        children = {
                            UI.Label {
                                text = "O C E A N   /   0 1",
                                fontSize = 8,
                                fontColor = { 58, 109, 105, 255 },
                            },
                            UI.Label {
                                text = Config.title,
                                fontSize = 23,
                                fontWeight = "bold",
                                fontColor = { 35, 78, 80, 255 },
                            },
                            UI.Label {
                                text = "飞鸟 · 海浪 · 鱼群 · 船只 · 小岛",
                                fontSize = 9,
                                fontColor = { 73, 120, 115, 255 },
                            },
                        },
                    },
                    UI.Panel {
                        pointerEvents = "box-none",
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Row {
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 8,
                                pointerEvents = "box-none",
                                children = {
                                    MoveButton("←", -1),
                                    pauseButton,
                                    UI.Button {
                                        text = "重置",
                                        width = 72,
                                        height = 40,
                                        fontSize = 10,
                                        borderRadius = 20,
                                        backgroundColor = { 249, 247, 221, 22 },
                                        textColor = { 246, 244, 218, 255 },
                                        hoverBackgroundColor = { 249, 247, 221, 50 },
                                        pressedBackgroundColor = { 249, 247, 221, 75 },
                                        borderWidth = 1,
                                        borderColor = { 212, 235, 219, 65 },
                                        onClick = Reset,
                                    },
                                    MoveButton("→", 1),
                                },
                            },
                            UI.Row {
                                alignItems = "center",
                                justifyContent = "center",
                                gap = 8,
                                pointerEvents = "box-none",
                                children = {
                                    DebugButton("诱饵 (B)",
                                        function(pos) game:SpawnDebugBait(pos) end),
                                    DebugButton("捕食者 (N)",
                                        function(pos) game:SpawnDebugPredator(pos) end),
                                },
                            },
                            statusLabel,
                            diagLabel,
                        },
                    },
                },
            },
        },
    }
    UI.SetRoot(root)
    print("[海洋框架] 界面就绪：WASD/方向键移动、暂停、重置、诱饵(B)、捕食者(N)")
    return { togglePause = TogglePause, reset = Reset, refresh = Refresh,
             updateDiagnostics = UpdateDiagnostics, tick = Tick }
end

return HUD
