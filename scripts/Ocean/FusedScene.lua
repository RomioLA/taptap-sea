-- Original ocean artwork/HUD plus the independently testable Sea Runtime.
local UI = require("urhox-libs/UI")
local Config = require("Ocean.Config")
local Bootstrap = require("Ocean.Bootstrap")
local HUD = require("Ocean.HUD")
local Debug = require("Ocean.SeaDebug")
local SceneState = require("Ocean.SceneState")
local FusedScene = {}

function FusedScene.Start(options)
    local settings = {}
    for key, value in pairs(options or {}) do settings[key] = value end
    settings.theme = settings.theme or "default-taptap"
    settings.windowTitle = settings.windowTitle or Config.title
    settings.pointerMinY = settings.pointerMinY or Config.camera.horizonY
    if settings.ownsUI == false and not settings.uiFactory and settings.debugUI == nil then
        settings.debugUI = false
    end
    if not settings.uiFactory and settings.ownsUI ~= false then
        settings.uiFactory = function(runtime, sea)
            local state = SceneState.New(runtime, function() sea:SyncViewport() end)
            local hud = HUD.Create(state)
            local root = assert(UI.GetRoot(), "Original ocean HUD root unavailable")
            local tools = settings.debugUI == false
                and { refresh = function() end, handleKey = function() return false end }
                or Debug.Create(runtime, { parent = root, panelVisible = false })
            if Config.debug.enabled and settings.debugUI ~= false then
                root:AddChild(UI.Button {
                    id = "seaDebugToggle",
                    text = "海上调试",
                    position = "absolute", right = 24, bottom = 72,
                    width = 80, height = 32, fontSize = 10, borderRadius = 16,
                    backgroundColor = { 249, 247, 221, 22 },
                    textColor = { 246, 244, 218, 255 },
                    borderWidth = 1, borderColor = { 212, 235, 219, 65 },
                    onClick = function() tools.handleKey(KEY_F3) end,
                })
            end
            return {
                refresh = function(dt)
                    if state:Sync() then hud.refresh() end
                    tools.refresh(dt)
                end,
                handleKey = function(key)
                    local handled = tools.handleKey(key)
                    if not handled and key == KEY_SPACE then state:TogglePause(); handled = true end
                    if not handled and key == KEY_R then state:Reset(); handled = true end
                    if key == KEY_R and handled then sea:SyncViewport() end
                    state:Sync()
                    hud.refresh()
                    return handled
                end,
            }
        end
    end
    return Bootstrap.Start(settings)
end

return FusedScene
