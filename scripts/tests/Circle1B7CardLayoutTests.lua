-- 圈1B7 三卡结构回归（2026-10-08，v2.2 三卡重构配套）。
--
-- 守护两条用户诉求，写成结构断言而非像素断言（无 GUI）：
--   ① 信息完整呈现 —— 商店四分区与前置数值、背包属性副行、出售与礼物品行
--      都必须在树上存在且带全部字段。
--   ② 选项不被遮挡 —— 三卡统一「标题 / 主体滚动区 / 固定操作条」三段，
--      操作条 flexShrink=0，且其内关键按钮在父链上恒可见；老人卡 v3.2 起
--      为四段式（一级/二级键迁入 options 选项区，footer 恒定 1 行），
--      连续交互后选项仍全部可点。
--
-- 附带守护 v2.1 §7.15 遗留回归：infoLayer 必须挂在 root 上
-- （曾被误删，导致整棵 cardHost 子树游离、真机三卡不可见）。
local Flow = require("tests.Circle1BFishingFlowTests")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function makeUI()
    local Widget = {}
    Widget.__index = Widget

    function Widget:AddChild(child)
        self.children[#self.children + 1] = child
        child.parent = self
    end

    function Widget:RemoveChild(child)
        for index, value in ipairs(self.children) do
            if value == child then table.remove(self.children, index) break end
        end
        child.parent = nil
    end

    function Widget:GetChildAt(index) return self.children[index] end
    function Widget:GetChildren() return self.children end
    function Widget:ClearChildren()
        for _, child in ipairs(self.children) do child.parent = nil end
        self.children = {}
    end

    function Widget:SetVisible(value) self.visible = value == true end
    function Widget:IsVisible() return self.visible end
    function Widget:Show() self:SetVisible(true) end
    function Widget:Hide() self:SetVisible(false) end
    function Widget:SetText(value)
        assert(self.kind == "Label" or self.kind == "Button", "SetText requires a text widget")
        self.props.text = value
    end

    function Widget:SetDisabled(value)
        assert(self.kind == "Button", "SetDisabled requires a button")
        self.disabled = value == true
    end

    function Widget:Destroy()
        self.destroyed = true
        if self.parent then self.parent:RemoveChild(self) end
    end

    local UI = { widgets = {} }
    for _, kind in ipairs({ "Panel", "SafeAreaView", "Label", "Button", "Spacer", "ScrollView", "TextField" }) do
        UI[kind] = function(props)
            props = props or {}
            local widget = setmetatable({
                kind = kind, props = props, children = {},
                visible = props.visible ~= false, disabled = false,
            }, Widget)
            UI.widgets[#UI.widgets + 1] = widget
            for _, child in ipairs(props.children or {}) do widget:AddChild(child) end
            return widget
        end
    end
    return UI
end

local function withHUD(run)
    local previousUI = package.loaded["urhox-libs/UI"]
    local previousHUD = package.loaded["Gameplay.HUD"]
    local UI = makeUI()
    package.loaded["urhox-libs/UI"] = UI
    package.loaded["Gameplay.HUD"] = nil
    local ok, result = xpcall(function() return run(require("Gameplay.HUD"), UI) end, debug.traceback)
    package.loaded["urhox-libs/UI"] = previousUI
    package.loaded["Gameplay.HUD"] = previousHUD
    if not ok then error(result, 0) end
    return result
end

local function isVisible(widget)
    while widget do
        if widget.visible ~= true then return false end
        widget = widget.parent
    end
    return true
end

local function findById(root, id)
    if root.props and root.props.id == id then return root end
    for _, child in ipairs(root.children or {}) do
        local found = findById(child, id)
        if found then return found end
    end
    return nil
end

-- 精确匹配按钮；visibleOnly 时沿父链判可见（与其它 HUD 套件同语义）
local function findButton(root, text, visibleOnly)
    local found
    local function walk(widget)
        if found then return end
        if visibleOnly and not widget.visible then return end
        if widget.kind == "Button" and widget.props.text == text then
            if not visibleOnly or isVisible(widget) then found = widget end
            return
        end
        for _, child in ipairs(widget.children or {}) do walk(child) end
    end
    walk(root)
    return found
end

-- 前缀匹配：升级/扩容按钮文案会带价格后缀（如「扩容 · ¥300」）
local function findButtonPrefix(root, prefix)
    local found
    local function walk(widget)
        if found then return end
        if not widget.visible then return end
        if widget.kind == "Button" and type(widget.props.text) == "string"
            and widget.props.text:sub(1, #prefix) == prefix and isVisible(widget) then
            found = widget
            return
        end
        for _, child in ipairs(widget.children or {}) do walk(child) end
    end
    walk(root)
    return found
end

-- 点击第一个匹配按钮；缺失即报错（避免静默跳过断言）
local function click_first(button)
    assert(button, "expected a button to click but found none")
    assert(not button.disabled, "button is disabled: " .. tostring(button.props.text))
    button.props.onClick()
end

local function findLabelContaining(root, needle)    local found
    local function walk(widget)
        if found then return end
        if widget.visible and widget.kind == "Label" and type(widget.props.text) == "string"
            and widget.props.text:find(needle, 1, true) then
            found = widget
            return
        end
        for _, child in ipairs(widget.children or {}) do walk(child) end
    end
    walk(root)
    return found
end

local function visibleButtonTexts(root, out)
    out = out or {}
    if root.visible then
        if root.kind == "Button" then out[#out + 1] = tostring(root.props.text) end
        for _, child in ipairs(root.children or {}) do visibleButtonTexts(child, out) end
    end
    return out
end

-- 卡片首个子 Label 即标题（sectionCard 约定：标题是 card 的第一个子节点）
local function cardTitle(card)
    for _, child in ipairs(card.children or {}) do
        if child.kind == "Label" then return child.props.text end
    end
    return "?"
end

local function visibleCardTitles(host)
    local titles = {}
    for _, card in ipairs(host.children or {}) do
        if card.visible then titles[#titles + 1] = cardTitle(card) end
    end
    return titles
end

-- 数「带背景图且可见」的面板 = 对话气泡计数（v2.2 限高后应恒定有界）
local function countVisibleImagePanels(root)
    local count = 0
    local function walk(widget)
        if not widget.visible then return end
        for _, child in ipairs(widget.children or {}) do
            if child.visible and child.kind == "Panel" and type(child.props.backgroundImage) == "string" then
                count = count + 1
            end
            walk(child)
        end
    end
    walk(root)
    return count
end

function Tests.Run()
    local results = {}
    local function test(name, run)
        local ok, err = xpcall(run, debug.traceback)
        results[#results + 1] = { name = name, passed = ok, error = ok and "" or tostring(err) }
    end

    test("card host is anchored on four edges and carries all three cards", function()
        withHUD(function(HUD)
            local fixture = Flow.Fixture({ items = { "apple", "bait" } })
            local hud = HUD.Create(fixture.loop)
            local host = findById(hud.root, "gameplayCardHost")
            assert(host, "gameplayCardHost must exist")
            eq(host.props.position, "absolute", "card host must be absolutely positioned")
            -- 四边锚定：top/bottom 让开状态栏与按钮坞，left/right 撑满宽度。
            -- 旧实现只有 top + 百分比 height，屏幕高度变化时卡片下沿会漂移，
            -- 与底部按钮坞互相压盖。
            eq(host.props.left, 0, "card host anchors left")
            eq(host.props.right, 0, "card host anchors right")
            assert(type(host.props.top) == "number" and host.props.top > 0,
                "card host must clear the status bar with a top anchor")
            assert(type(host.props.bottom) == "number" and host.props.bottom > 0,
                "card host must clear the action dock with a bottom anchor")
            assert(host.props.height == nil and host.props.maxHeight == nil,
                "card host must not use percentage height any more")
            eq(host.props.pointerEvents, "box-none", "host blanks pass clicks through to the sea")
            -- 三卡平级挂在宿主下（商店必须与背包/老人平级，旧版挂在 contentScroll）
            local titles = {}
            for _, card in ipairs(host.children) do titles[#titles + 1] = cardTitle(card) end
            assert(#titles >= 3, "three cards must hang under the host, got " .. #titles)
            for _, want in ipairs({ "背包", "港口商店", "拜访老人" }) do
                local hit = false
                for _, title in ipairs(titles) do if title == want then hit = true end end
                assert(hit, "host must carry the card titled " .. want)
            end
        end)
    end)

    test("info layer is attached to root so the cards are reachable", function()
        withHUD(function(HUD)
            -- 回归守护：v2.1 §7.15 重排 root 子节点时误删了 root:AddChild(infoLayer)，
            -- 整棵 cardHost 子树成为游离节点 —— 真机三卡完全不显示，
            -- 且测试沿 parent 链判可见时链首即失效。
            local fixture = Flow.Fixture({ items = { "apple" } })
            local hud = HUD.Create(fixture.loop)
            local infoLayer = findById(hud.root, "gameplayInfoLayer")
            assert(infoLayer, "gameplayInfoLayer must exist")
            eq(infoLayer.parent, hud.root, "info layer must be a direct child of root")
            local host = findById(hud.root, "gameplayCardHost")
            assert(host and host.parent == infoLayer, "card host must live inside the info layer")
            -- 契约：抽屉仍是 root 倒数第二位，倒数第一是全屏模态
            local children = hud.root:GetChildren()
            eq(children[#children - 1].props.id, "gameplayInventoryDrawer",
                "drawer must precede the full-screen modal")
            eq(children[#children].props.id, nil, "modal overlay must stay last")
            local scroll = findById(hud.root, "gameplayContentScroll")
            assert(scroll and scroll.props.pointerEvents == "box-none",
                "content scroll must let empty sea clicks through")
        end)
    end)

    test("port shop shows every section with complete figures and a fixed action bar", function()
        withHUD(function(HUD)
            local fixture = Flow.Fixture({ items = { "sardine" } })
            local loop = fixture.loop
            assert(loop:Depart())
            assert(loop:ReturnToPort())
            local hud = HUD.Create(loop)
            hud.Refresh()
            -- 前置数值摘要：金币/体力/船速/容量一次给全
            assert(findLabelContaining(hud.root, "金币"), "port summary must state the coin count")
            assert(findLabelContaining(hud.root, "体力"), "port summary must state stamina")
            assert(findLabelContaining(hud.root, "船速"), "port summary must state the boat speed level")
            assert(findLabelContaining(hud.root, "船舱"), "port summary must state the cargo capacity")
            -- 升级区：当前值 → 下一档，不只是一个带价格的动作按钮
            assert(findLabelContaining(hud.root, "体力上限"), "stamina upgrade must show current → next")
            assert(findLabelContaining(hud.root, "航速"), "boat speed upgrade must show current → next")
            for _, want in ipairs({ "升级体力", "升级航速", "读取云存档", "开始新周目" }) do
                assert(findButtonPrefix(hud.root, want), "port must expose " .. want)
            end
            -- 购买区：库存说明与禁用原因独立成行（契约：X库存：N 前缀不可改）
            assert(findLabelContaining(hud.root, "苹果库存："), "shop must state apple stock")
            assert(findLabelContaining(hud.root, "鱼饵库存："), "shop must state bait stock")
            assert(findButtonPrefix(hud.root, "苹果 · ¥"), "shop must expose the apple purchase button")
            assert(findButtonPrefix(hud.root, "鱼饵 · ¥"), "shop must expose the bait purchase button")
            -- 出售区：名称/稀有度/槽位/售价 + 独立出售按钮
            assert(findLabelContaining(hud.root, "槽位 01 · 售价"), "sale row must state slot and price")
            assert(findButtonPrefix(hud.root, "出售 ¥"), "port must expose a per-fish sell button")
            -- 固定操作条：全部卖出在端口底部，不随主体内容增长被顶出屏幕
            local sellAll = findButtonPrefix(hud.root, "全部卖出")
            assert(sellAll and isVisible(sellAll), "sell-all must stay visible in the port action bar")
            assert(not sellAll.disabled, "a loaded hold enables sell-all at port")
        end)
    end)

    test("backpack separates the item list from a fixed action bar", function()
        withHUD(function(HUD)
            local fixture = Flow.Fixture({ items = { "apple", "bait" } })
            local loop = fixture.loop
            assert(loop:Depart())
            assert(loop:ReturnToPort())
            local hud = HUD.Create(loop)
            loop:SetInventoryOpen(true)
            hud.Refresh()
            -- 两条物品行都可操作
            local operations = 0
            for _, text in ipairs(visibleButtonTexts(hud.root)) do
                if text == "操作" then operations = operations + 1 end
            end
            eq(operations, 2, "both cargo rows expose their action button")
            -- 属性副行：类别 / 恢复量 / 可否给老人，信息完整不靠猜。
            -- 注：苹果/鱼饵 buy 有价但 sell=0，故不断言「售价 ¥」——
            -- 售价只在鱼获（有 sellPrice）上出现，由港口出售区用例覆盖。
            assert(findLabelContaining(hud.root, "食物"), "backpack must state the item category")
            assert(findLabelContaining(hud.root, "恢复体力 20"), "backpack must state the heal amount")
            assert(findLabelContaining(hud.root, "可给老人"), "backpack must state give-ability")
            -- 操作条固定在卡内底部：全部卖出 / 扩容 / 收起恒可见
            for _, want in ipairs({ "全部卖出", "扩容", "收起" }) do
                local button = findButtonPrefix(hud.root, want)
                assert(button and isVisible(button), "backpack action bar must keep " .. want .. " visible")
            end
            -- 选中物品后，操作区出现在固定操作条而非列表上方
            click_first(findButton(hud.root, "操作", true))
            hud.Refresh()
            for _, want in ipairs({ "使用", "丢弃", "投掷" }) do
                local button = findButton(hud.root, want, true)
                assert(button, "selected item must expose " .. want)
                assert(isVisible(button), want .. " must stay visible after selecting a row")
            end
        end)
    end)

    test("elder card keeps every option reachable no matter how long the conversation runs", function()
        withHUD(function(HUD)
            local fixture = Flow.Fixture({ items = { "apple", "bait" } })
            local loop = fixture.loop
            assert(loop:Depart())
            assert(loop:ReturnToPort())
            local hud = HUD.Create(loop)
            click_first(findButton(hud.root, "拜访老人", true))
            hud.Refresh()
            assert(loop.elderOpen == true, "visiting the elder must open the dialogue")
            -- v2.3 契约：打开即见一级键（分类键带 ▸ 后缀避免与物品按钮撞名）。
            -- v3.2（2026-10-13）：提问二级随智能体功能整体移除，一级键剩两枚；
            -- 全局键行常驻 footer（四段式，footer 恒定 1 行）。
            for _, want in ipairs({ "给予 ▸", "展示 ▸", "聊天记录", "结束对话" }) do
                local button = findButton(hud.root, want, true)
                assert(button, "elder card must expose " .. want .. " immediately")
                assert(isVisible(button), want .. " must be visible immediately")
            end
            -- 二级·展示：点分类键展开，物品行出现（行结构守 %02d 契约）
            click_first(findButton(hud.root, "展示 ▸", true))
            hud.Refresh()
            local shows = 0
            for _, text in ipairs(visibleButtonTexts(hud.root)) do
                if text == "展示" then shows = shows + 1 end
            end
            eq(shows, 1, "the show submenu lists the displayable bait row")
            assert(findLabelContaining(hud.root, "只能展示，不能给老人"),
                "show rows must explain why they cannot be given")
            -- 二级·给予：食物行 + 透镜不在此处
            click_first(findButton(hud.root, "← 返回", true))
            hud.Refresh()
            click_first(findButton(hud.root, "给予 ▸", true))
            hud.Refresh()
            assert(findButton(hud.root, "给予", true), "the give submenu lists the apple row")
            -- 二级操作后不自动返回一级（可连续给予/展示）
            assert(findButton(hud.root, "← 返回", true), "submenu must stay open after the action row is built")
            -- 连续交互（给予苹果 + 展示鱼饵）：对话流持续增长，
            -- 每轮交互后选项仍全部可点（自由问答移除后对话流靠交互续写）。
            click_first(findButton(hud.root, "给予", true))
            hud.Refresh()
            assert(findLabelContaining(hud.root, "老人收下了苹果"),
                "the elder must acknowledge the gift in the dialogue stream")
            click_first(findButton(hud.root, "← 返回", true))
            hud.Refresh()
            click_first(findButton(hud.root, "展示 ▸", true))
            hud.Refresh()
            click_first(findButton(hud.root, "展示", true))
            hud.Refresh()
            assert(findLabelContaining(hud.root, "向老人展示了"),
                "the show action must be recorded in the dialogue stream")
            -- v3.1 羊皮卷：对话流改为 ScrollView（elderDialogueScroll）全量渲染，
            -- 完整历史滚动可读；不再有 N 条限条与「更早对话已折叠」溢出提示。
            click_first(findButton(hud.root, "← 返回", true))
            hud.Refresh()
            -- 开场白 1 条 + 给予 2 条 + 展示 2 条 = 5 个气泡，全部渲染在卷上。
            local bubbles = countVisibleImagePanels(hud.root)
            assert(bubbles >= 5, "the parchment scroll must render the full history, got " .. bubbles)
            local scroll = findById(hud.root, "elderDialogueScroll")
            assert(scroll ~= nil and scroll.kind == "ScrollView",
                "the dialogue stream must be a scrollable parchment (ScrollView)")
            assert(not findLabelContaining(hud.root, "更早对话已折叠"),
                "the parchment scroll renders everything; no fold notice may exist")

            -- v2.3 回看态：点[聊天记录] → 选项区收起为把手；点把手展开/收起
            hud.Refresh()
            click_first(findButton(hud.root, "聊天记录", true))
            hud.Refresh()
            assert(findButton(hud.root, "选项 ▴", true), "review mode must collapse options into a handle")
            assert(not findButton(hud.root, "给予 ▸", true),
                "level-1 keys must hide while reviewing the chat log")
            local speakers = 0
            local function countSpeakers(widget)
                if widget.visible and widget.kind == "Label"
                    and (widget.props.text == "老人" or widget.props.text == "你") then
                    speakers = speakers + 1
                end
                for _, child in ipairs(widget.children or {}) do countSpeakers(child) end
            end
            countSpeakers(hud.root)
            assert(speakers >= 5, "the chat log must keep the full history, got " .. speakers)
            -- 点把手展开选项区
            click_first(findButton(hud.root, "选项 ▴", true))
            hud.Refresh()
            assert(findButton(hud.root, "给予 ▸", true), "the handle must expand the option keys")
            assert(findButton(hud.root, "结束对话", true), "ending the dialogue must stay reachable in review mode")
            -- 再点收起
            click_first(findButton(hud.root, "选项 ▾", true))
            hud.Refresh()
            assert(findButton(hud.root, "选项 ▴", true) and not findButton(hud.root, "给予 ▸", true),
                "the handle must collapse the option keys again")
            -- 收起记录回常态：一级键恢复（文案带 ▾ 后缀，用前缀匹配）
            click_first(findButtonPrefix(hud.root, "收起记录"))
            hud.Refresh()
            assert(findButton(hud.root, "给予 ▸", true) and not findButton(hud.root, "选项 ▴", true),
                "leaving review mode must restore the level-1 keys")
        end)
    end)

    test("the three cards stay mutually exclusive", function()
        withHUD(function(HUD)
            local fixture = Flow.Fixture({ items = { "apple", "bait" } })
            local loop = fixture.loop
            assert(loop:Depart())
            assert(loop:ReturnToPort())
            local hud = HUD.Create(loop)
            local host = findById(hud.root, "gameplayCardHost")

            click_first(findButton(hud.root, "拜访老人", true))
            hud.Refresh()
            eq(table.concat(visibleCardTitles(host), "/"), "拜访老人", "elder card wins the host")

            click_first(findButton(hud.root, "结束对话", true))
            hud.Refresh()
            click_first(findButton(hud.root, "背包", true))
            hud.Refresh()
            eq(table.concat(visibleCardTitles(host), "/"), "背包", "backpack takes over after the dialogue")

            -- 用精确文案收起背包（前缀匹配会撞上「收起信息」按钮）
            click_first(findButton(hud.root, "收起", true))
            hud.Refresh()
            assert(loop.inventoryOpen ~= true, "collapsing the backpack must close it")
            eq(table.concat(visibleCardTitles(host), "/"), "港口商店", "port shop returns when nothing else is open")

            -- v2.3.1 总开合：点「收起信息」= 左侧整块收起（三卡+滚动屏一起走），
            -- 再点「信息」恢复。真机反馈原话："点击就收起左侧不管是商店、
            -- 背包还是老人对话UI"。
            click_first(findButton(hud.root, "收起信息", true))
            hud.Refresh()
            eq(host.visible, false, "collapsing info must hide the whole card host")
            click_first(findButton(hud.root, "信息", true))
            hud.Refresh()
            eq(host.visible, true, "tapping info again must restore the card host")
            eq(table.concat(visibleCardTitles(host), "/"), "港口商店",
                "restoring shows the card that should be open")
        end)
    end)

    test("elder submenu rows survive per-frame refreshes so real taps land", function()
        withHUD(function(HUD)
            -- 真机修复回归（2026-10-08 反馈"问题选项显示但点不了"）：
            -- Bootstrap.Update 每帧 hud.Refresh()；若物品行每帧销毁重建，
            -- 真机手指从按下到抬起之间 widget 已被替换，click 丢失。
            -- 断言：连续两次 refresh 后物品行按钮必须是**同一个实例**。
            local fixture = Flow.Fixture({ items = { "apple" } })
            local loop = fixture.loop
            assert(loop:Depart())
            assert(loop:ReturnToPort())
            local hud = HUD.Create(loop)
            click_first(findButton(hud.root, "拜访老人", true))
            hud.Refresh()
            click_first(findButton(hud.root, "给予 ▸", true))
            hud.Refresh()
            local first = findButton(hud.root, "给予", true)
            assert(first, "give submenu must list the apple row")
            hud.Refresh()
            hud.Refresh()
            local second = findButton(hud.root, "给予", true)
            assert(second == first,
                "submenu rows must not be rebuilt on every refresh frame")
            -- 点击后仍可用（交付成功 → 对话流出现老人答复）
            first.props.onClick()
            hud.Refresh()
            assert(findLabelContaining(hud.root, "老人收下了苹果"),
                "the elder answer must appear after tapping the give row")
        end)
    end)

    return { results = results }
end

return Tests
