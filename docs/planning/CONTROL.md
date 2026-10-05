# 《渔夫漂流记》团队策划入口

当前可维护策划内容在 [团队策划正文](team/)；完整阅读副本在 [导出目录](exports/)。保留七部分：游戏总览、三圈范围、系统规则、数值与物品、剧情与事件、视听与交互、进度与待决策；另有 [技术约定](team/08_技术约定.md) 附页，共八个正式工作表。工作簿内容自足，队友无需另查MD或历史工作表。

## v2.1同步状态（2026-10-03）

此前已于2026-10-03将 `D:/SillyTavern-Data/taptap/记录表_新版策划_2026-10-02_v2.1.xlsx` 的八个正式页同步到 `team/01` 至 `team/08`。随后按用户明确要求，对v2.1工作簿及MD同步小鱼逃跑上浮、海鸟首次俯冲与当前巡游参数；捕鱼、补鱼和捕食冷却保持原定。旧原始表和旧工作表仅作留档，不覆盖正式页。

本次海面信号修订前的工作簿及相关MD保存在 `_archive/surface_2026-10-03/`；更新后的工作簿副本在 `exports/记录表_新版策划_2026-10-02_v2.1.xlsx`。上浮2秒、首次俯冲1.5秒为待试玩调整的测试值；9米偏移、3米半径、每组2只按用户提供的当前参数记录，未据此声称已核验代码或实机。

## 维护方式

团队策划正文是后续内容维护入口。按具体任务决定定向更新现行工作簿或导出新版本；本次已明确授权同步v2.1，并保留修订前备份。 [TEAM_VALIDATION.md](TEAM_VALIDATION.md) 记录的是2026-10-02那次旧导出的核对，不验证本次v2.1同步。旧版 [DESIGN.md](DESIGN.md)、[CONTENT.md](CONTENT.md)、[PARAMETERS.md](PARAMETERS.md)、[QUESTIONS.md](QUESTIONS.md)、[STATUS.md](STATUS.md)、[SOURCES.md](SOURCES.md) 和 [VALIDATION.md](VALIDATION.md) 均为历史留存，不再作为现行规则依据；旧 `validate_documents.py` 仅适用旧三页格式，不再运行。

## 工程边界与架构通知

用户通知的新架构约定尚未同步到本机。本轮不fetch、不push、不修改游戏代码；不把通知写成已在本机核实。收到的约定是：Main负责生命周期；Game/Game负责全局更新与暂停；Game/World负责实体注册、生命周期和调度；实体经EntityFactory、FSM/StateMachine与Systems/EntityStateSystem组织；Ocean负责船和鱼，Gameplay负责玩家体力、库存、交易、时钟与保存，Integration Scene/Bridge负责整合。根data/items.lua、fish.lua生成scripts/GeneratedData。

远端提交2569cd4据通知仅包含AGENTS与架构文档，本机当前没有这次同步。新增字段先按DATA_SCHEMA确认；不得另建一套World、PlayerState或Clock，也不要主动推翻架构。v2.1的八个正式页是本次策划内容基线；旧表和旧Sheet5、Sheet6过程稿仅留档，只有已同步进v2.1正式页的内容才属于当前策划。内容候选只供策划讨论，不自动授权代码实现。

## 接手提示

本轮补细节、Luna全局审稿与成品版式核对见 [复核记录](REVIEW_补细节_2026-10-02.md)。

先读本页，再按任务读取七部分正文和技术附页的相关部分。已确定规则、待决策项、内容缺口和实现状态分别记录；代码现状不能自动替代策划规则。进度页分别标出最新通知和旧报告的证据边界；没有新验证时，不把旧报告中的玩法缺口断言为当前状态，也不把自动检查通过描述成玩家闭环完成。

更新规则时保留问题编号以便跨页查找。未经明确授权，不修改游戏代码、不运行GUI、不构建、不提交。
