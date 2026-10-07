-- HUD表现辅助：不持有玩法状态；UI依赖由宿主传入，保持测试/宿主实例隔离。
local Presentation = {}

function Presentation.Create(UI, Config, Items)
    local ERROR_MESSAGES = {
        busy = "当前操作尚未完成",
        port_interface_unavailable = "港口位置接口暂不可用，无法确认交易权限。",
        port_out_of_range = "距港超过10米；请航行到港口标记10米内，再返港或交易。",
        port_reset_unavailable = "实际返港接口暂不可用，请稍后重试。",
        port_reset_failed = "船只未能回到港口，请重试。",
        cargo_changed = "船舱物品已变化，请重新选择要出售的鱼。",
        transaction_failed = "交易未完成，金钱与物品已恢复，请重试。",
        transaction_snapshot_failed = "暂时无法核对交易物品，请重试。",
        inventory_rollback_pending = "物品正在恢复，请稍后重试。",
        speed_upgrade_failed = "海洋船速未能更新，本次升级已撤销，请重试。",
        maximum_level = "已经达到最高等级。",
        unsupported_stamina_level = "当前体力上限没有对应的升级方案。",
        invalid_upgrade_configuration = "升级数据暂不可用。",
        busy_or_at_sea = "请先在港口结束当前操作，再读取存档。",
        scene_closed = "场景已经关闭。",
        no_settlement = "当前没有待确认的日结。",
        no_failed_settlement = "当前没有可放弃的保存。",
        new_day_preparation_failed = "港口或海洋准备未完成，请重试。",
        settlement_snapshot_failed = "日结快照尚未生成，请重试保存。",
        fishing_runtime_interface_unavailable = "捕鱼接口暂未就绪，请稍后重试。",
        cast_out_of_range_or_invalid = "请点击船只30米内的合法海面，网心不能落在陆地上。",
        fishing_requires_bridge_token = "请从正式捕鱼按钮开始操作。",
        pending_catch_required = "请先处理已有待接收收获；物品会完整保留。",
        no_forced_return = "当前没有待确认的强制返港。",
        ["insufficient money"] = "余额不足。",
        day_finished = "今天已经结束",
        port_required = "请先返港",
        close_dialog_first = "请先关闭当前界面",
        inventory_full = "背包已满",
        unknown_item = "未知物品",
        not_enough_money = "钱不够",
        not_enough_stamina = "体力不足",
        ["insufficient stamina"] = "体力不足",
        cannot_use_item = "现在无法使用该物品",
        cannot_give_item = "老人不收这件物品",
        insufficient_money = "钱不够",
        not_for_sale = "该物品不出售",
        shop_sold_out = "今日已售罄，明天补货",
        invalid_item = "物品已不存在或无法使用",
        sea_required = "请先出海",
        elder_dialog_required = "请先打开老人对话",
        elder_not_present = "老人不在船上，当前无法赠送。",
        item_has_no_use = "该物品没有可用效果，无法使用。",
        throw_selection_pending = "请先完成或取消当前投掷选择。",
        treasure_unavailable = "当前没有可展示的透镜。",
        scope_not_owned = "尚未获得透镜。",
        elder_progress_failed = "老人救助进度未能更新，苹果已保留，请重试。",
        scope_interface_unavailable = "望远镜控制接口暂不可用。",
        scope_sync_failed = "望远镜状态同步失败，请重试关闭。",
        stale_barrel_action = "木桶已变化，当前检查已取消，请重新开始。",
        stale_barrel_stage = "木桶进度已变化，请重新检查。",
        barrel_executor_failed = "木桶检查未能完成，本次不扣体力。",
        barrel_timing_unconfirmed = "木桶检查暂未开放。",
        barrel_interface_unavailable = "木桶检查暂未开放。",
        barrel_unavailable = "木桶检查暂未开放。",
        barrel_out_of_range = "请靠近海岸边的木桶。",
        barrel_finished = "木桶调查已完成。",
        barrel_cancel_failed = "木桶检查取消失败，请稍后重试。",
        barrel_commit_failed = "木桶检查结果未能保存，请稍后重试。",
        barrel_rollback_pending = "木桶检查正在恢复物品，请稍后重试。",
        barrel_action_not_completed = "木桶检查尚未完成。",
        paper_day_required = "这张纸条要到第 7 天才能查看。",
        day_required = "这张纸条要到第 7 天才能查看。",
        paper_already_shown = "这张纸条已经看过了。",
        stale_story_dialog = "纸条状态已更新，请重新打开。",
        drop_receiver_unavailable = "附近没有接收地点，物品仍保留在背包里",
        drop_rejected = "没有接收地点接收物品，物品仍保留在背包里",
        invalid_drop_position = "请在海面选择有效投放点。",
        throw_out_of_range = "投掷距离太远，请点击 12 米内的海面。",
        throw_selection_required = "请先选择要投掷的物品。",
        throw_item_changed = "所选物品已变化，请重新选择。",
        elder_rejected = "老人没有收下这件物品",
        not_sellable = "这件物品不能出售",
        action_blocked = "当前不能进行该动作",
        elapsed_exceeds_phase = "跳转时间超过了该昼夜阶段长度",
        invalid_elapsed = "请输入有效的跳转秒数",
        development_only = "仅开发模式允许此操作",
        time_scale_not_configured = "时间倍率不在配置列表中",
        invalid_time_scale = "请输入有效的时间倍率",
        unknown_debug_command = "未知调试命令",
    }

    local function userMessage(value)
        if value == nil then return "" end
        local text = tostring(value)
        if ERROR_MESSAGES[text] then return ERROR_MESSAGES[text] end
        if text:find("[A-Za-z_]") and not text:find("[\128-\255]") then
            return "操作暂未完成，当前进度保留，请稍后重试。"
        end
        return text
    end

    local function saveText(loop)
        if loop.loading then return "读取存档中…" end
        local status = loop.saveStatus
        if status == "idle" or status == nil then return "尚未保存" end
        if status == "saving" then return "正在自动保存…" end
        if status == "saved" then return "已自动保存" end
        if status == "error" then return "自动保存失败，可重试" end
        if status == "skipped" then return "已跳过本次保存等待" end
        return "存档状态：" .. tostring(status)
    end

    ---@return string[]
    local function copyItems(loop)
        local inventory = loop.player and loop.player.inventory
        if not inventory then return {} end
        local source = inventory:GetItems()
        local result = {}
        for index, itemId in ipairs(source or {}) do result[index] = itemId end
        return result
    end

    local ITEM_NAME_FALLBACK = {
        apple = "苹果", bait = "鱼饵", sardine = "沙丁鱼", tuna = "金枪鱼",
        wood = "木材", mineral = "矿产", scopeLens = "望远镜",
    }

    -- 开场教学（事物设定集：被救老人以陪伴者身份开场，赠旧背包——内含开局苹果与鱼饵）。
    -- HUD 演出层实现：不进 Loop 状态机、不阻塞出航/存档；每个周目(generation)在港演出一次。
    local OPENING_ELDER_TEXT = "被救起的老人把一只旧背包递给你：“孩子，这海上讨生活，"
        .. "先学会看海——海鸟盘旋、水面翻花的地方才有鱼。"
        .. "背包里有些苹果和鱼饵，出海去试试吧。出港往右看，那只木桶是我的旧物，靠近了敲一敲。”"

    local function itemName(itemId)
        local definition = Items.GetDefinition(itemId)
        if definition and definition.name then return definition.name end
        return ITEM_NAME_FALLBACK[itemId] or tostring(itemId)
    end

    -- 玩家界面设计方案 v1.0（2026-10-04）：所有取色来自 config.ui.palette；
    -- 未配置时回退到本表，保证旧存档/测试桩环境可运行。
    local FALLBACK_PALETTE = {
        seaDeep = { 12, 68, 124, 242 },
        seaNight = { 4, 32, 62, 248 },
        seaMid = { 24, 95, 165, 235 },
        actionPrimary = { 15, 110, 86, 255 },
        actionPressed = { 8, 80, 65, 255 },
        coinBright = { 250, 199, 117, 255 },
        coinDeep = { 133, 79, 11, 255 },
        warnCoral = { 216, 90, 48, 255 },
        textOnDark = { 230, 241, 251, 255 },
        textMuted = { 159, 225, 203, 255 },
        textGold = { 250, 213, 130, 255 },
        cardDay = { 20, 52, 92, 240 },
        cardNight = { 6, 26, 50, 246 },
        border = { 55, 138, 221, 150 },
        backdrop = { 4, 20, 40, 150 },
        disabledBg = { 96, 116, 138, 210 },
        disabledText = { 190, 204, 216, 220 },
        infoStroke = { 10, 28, 46, 225 },
        infoShadow = { 6, 16, 28, 150 },
    }
    local UI_PALETTE = {}
    local UI_SIZE = { touchMajor = 88, touchMinor = 64, touchGap = 12, buttonMinHeight = 44, radiusCard = 10 }
    do
        local cfg = Config.ui or {}
        for key, value in pairs(FALLBACK_PALETTE) do
            UI_PALETTE[key] = (cfg.palette and cfg.palette[key]) or value
        end
        for key, value in pairs(cfg.size or {}) do UI_SIZE[key] = value end
    end

    -- 安全应用背景色：真机 Widget 支持 SetBackgroundColor；测试桩缺失时静默跳过。
    local function applyBackground(widget, color)
        if type(widget) == "table" and type(widget.SetBackgroundColor) == "function" then
            widget:SetBackgroundColor(color)
        end
    end

    -- SetBackgroundColor -> SetStyle -> 引擎Transition，RGBA逐通道连续插值。
    -- 仅在phase变化时设置目标色，不在每次HUD刷新时重启动画。
    local function makeThemer()
        ---@type string|nil
        local lastPhase = nil
        return function(phase, panels)
            if lastPhase == phase then return end
            lastPhase = phase
            local night = phase == "night"
            for _, entry in ipairs(panels) do
                applyBackground(entry.widget, night and entry.night or entry.day)
            end
        end
    end

    local function makeLabel(text, size, color, weight, extraProps)
        local props = {
            text = text,
            fontSize = size or 14,
            fontColor = color or UI_PALETTE.textOnDark,
            fontWeight = weight or "normal",
            whiteSpace = "normal",
        }
        if extraProps then
            for key, value in pairs(extraProps) do props[key] = value end
        end
        return UI.Label(props)
    end

    local function fishDisplay(itemId, definition)
        if not definition or definition.category ~= "fish" then return "", nil end
        local entry = (Config.ui and Config.ui.fishDisplay or {})[itemId]
        if not entry then return "鱼获", UI_PALETTE.textOnDark end
        return entry.rarity .. "鱼获", UI_PALETTE[entry.paletteKey] or UI_PALETTE.textOnDark
    end

    local function modeText(loop, fishingPhase, pendingCatch, throwSelection)
        if loop.loading or loop.entryPending then return "读取／选择存档" end
        if loop.forcedReturnPending then return "夜尽返港" end
        if loop.endingPending then return "本周目结局" end
        if loop.settlementPending then return "每日结算" end
        if loop.elderOpen then return "老人对话" end
        if loop.storyDialog then return "剧情对话" end
        if throwSelection then return "投放选点 · " .. itemName(throwSelection.itemId) end
        if pendingCatch then return "满舱整理 · 收获待领" end
        if loop.inventoryOpen then return "背包整理" end
        if fishingPhase == "selecting" then return "捕鱼选点 · 点击30米内海面" end
        if fishingPhase == "casting" or fishingPhase == "landed" then return "抛网／收网" end
        if fishingPhase == "cleanup_pending" or fishingPhase == "rollback_pending" or fishingPhase == "committing" then
            return "捕鱼清理 · 可重试"
        end
        if loop.barrel and loop.barrel:IsBusy() then return "木桶检查" end
        if loop.clock and loop.clock.pauseReasons.manual then return "手动暂停" end
        return loop.inPort and "港口整备" or "航行／观察海面"
    end

    -- 设计方案 v2.0（零遮挡）：信息层无底板纯文字，靠描边+阴影保证海面上
    -- 白天/夜晚均可读。urhox Label 原生支持 textStroke/textShadow（测试桩
    -- 环境未知字段会被忽略，不影响断言）。
    -- extraProps：允许调用方补充布局属性（如 flexGrow/flexBasis 防压缩）。
    -- 真机反馈（2026-10-05）：textStroke 引擎按 8 方向各画一份文本实现描边，
    -- width=3 时偏移 ±3px，在 12~13px 中文字号上呈"多个重复文字叠影"。
    -- 降到 width=1（±1px 贴边描边）+ 1px 阴影：保留海面可读性，消除重影。
    local function makeInfoLabel(text, size, color, weight, extraProps)
        local props = {
            text = text,
            fontSize = size or 14,
            fontColor = color or UI_PALETTE.textOnDark,
            fontWeight = weight or "normal",
            whiteSpace = "normal",
            textStroke = { width = 1, color = UI_PALETTE.infoStroke },
            textShadow = { offsetX = 1, offsetY = 1, blur = 1, color = UI_PALETTE.infoShadow },
        }
        if extraProps then
            for key, value in pairs(extraProps) do props[key] = value end
        end
        return UI.Label(props)
    end

    -- 真机踩坑（Codex 定位确认）：row 布局下无宽度约束的 label 会被 flex
    -- 压缩为不可见——真机"两层纯色栏没有字"即此原因。信息层每行用
    -- 「行容器 + 单个 flexGrow/flexBasis=0 的 label」保证文字占满行宽。
    local INFO_FLEX = { flexGrow = 1, flexBasis = 0 }
    local function infoLine(label)
        local line = UI.Panel {
            width = "100%",
            flexDirection = "row",
            gap = 6,
        }
        line:AddChild(label)
        return line
    end

    local function makeButton(text, onClick, variant, width, extraProps)
        local props = {
            text = text,
            variant = variant or "secondary",
            width = width or "auto",
            -- 触控目标 ≥44px（设计方案 v1.0 尺寸 token）；主操作按钮的 88px 热区
            -- 由 Scene 层的抛竿交互承担，此处为通用面板按钮。
            minHeight = UI_SIZE.buttonMinHeight or 44,
            fontSize = 13,
            onClick = function() onClick() end,
        }
        -- 批3b 水彩底板换肤（v2.0 §7.2）：extraProps 由宿主注入（皮肤令牌来自
        -- DialogueStyle），本模块保持无依赖设计；缺省时完全等价原行为。
        if extraProps then
            for key, value in pairs(extraProps) do props[key] = value end
        end
        return UI.Button(props)
    end

    -- 淡入辅助：真机 urhox Widget 支持 SetOpacity（transition 驱动），
    -- 测试桩未实现该方法时静默跳过，不影响功能断言。
    local function fadeOpacity(widget, value)
        if type(widget) == "table" and type(widget.SetOpacity) == "function" then
            -- props 保存动画目标；renderProps 才是中间值。相同目标无须
            -- 再调用 SetStyle，否则引擎会无条件触发整树 Yoga 布局。
            if type(widget.props) == "table" and widget.props.opacity == value then return end
            widget:SetOpacity(value)
        end
    end

    return {
        userMessage = userMessage,
        saveText = saveText,
        copyItems = copyItems,
        itemName = itemName,
        UI_PALETTE = UI_PALETTE,
        UI_SIZE = UI_SIZE,
        makeThemer = makeThemer,
        makeLabel = makeLabel,
        fishDisplay = fishDisplay,
        modeText = modeText,
        makeInfoLabel = makeInfoLabel,
        infoLine = infoLine,
        makeButton = makeButton,
        fadeOpacity = fadeOpacity,
        OPENING_ELDER_TEXT = OPENING_ELDER_TEXT,
        INFO_FLEX = INFO_FLEX,
    }
end

return Presentation
