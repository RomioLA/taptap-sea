-- 基于 2D 脚手架的界面层，文字和按钮全部使用 urhox-libs/UI。
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local HUD = {}

function HUD.Create(state)
    local statusLabel = UI.Label {
        text = "场景运行中",
        fontSize = 9,
        fontColor = { 205, 231, 218, 255 },
        textAlign = "center",
    }
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

    local function Refresh()
        pauseButton:SetText(state.paused and "继续" or "暂停")
        statusLabel:SetText(state.paused and "场景已暂停" or "场景运行中")
    end

    local function TogglePause()
        state:TogglePause()
        Refresh()
    end

    local function Reset()
        state:Reset()
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
            onClick = function() state:MoveBy(direction) end,
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
                            statusLabel,
                        },
                    },
                },
            },
        },
    }
    UI.SetRoot(root)
    print("[海洋框架] 界面就绪：左右移动、暂停、重置；支持键盘和触摸")
    return { togglePause = TogglePause, reset = Reset, refresh = Refresh }
end

return HUD
