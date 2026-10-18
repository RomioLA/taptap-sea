# A 保护只读检查

- 检查时间（UTC）：`2026-10-03T04:44:07Z`
- 仓库：`C:\codex\taptap-sea`
- 总状态：`attention_required`
- A 保护文件：41/43 匹配，缺失 0，变化 2。
- 补充保护文件：15/15 匹配，缺失 0，变化 0；新增不升级为违规。
- A3 交付清单：12/12 匹配。
- 历史证据：基线 212 项，当前 212 项；缺失 0，变化 0，新增 0。新增项仅报告，不自动判违规。

本报告只校验既有 A 保护哈希、A3 交付清单与历史输出哈希。B4 业务源码仍在变化且未纳入最终验收；本结果不代表 A+B 合并验收。脚本不会改动被检查源码或历史证据。

## A 保护文件需要复核

- `scripts/tests/ABIntegrationTests.lua`：`changed`
- `scripts/tests/ArchitectureIntegrationTests.lua`：`changed`
