# 一键本地测试

在项目根目录双击 `本地测试.cmd` 即可打开当前项目的本地游戏窗口。入口自动定位脚本所在目录，支持从桌面快捷方式启动，不依赖当前工作目录。

`本地测试.cmd`和配套`start-local-preview.ps1`已加入根目录`.gitignore`，仅保留在本机，不纳入Git提交或上传。

- 预览已停止时启动；预览正在运行时刷新，以加载本地最新代码。
- 刷新会重启游戏、清空内存状态；当天尚未保存的进度可能丢失。
- 只调用 Maker 的 `preview status/start/refresh`；不用先提交代码，不上传 GitHub，不触发远端构建。
- 启动失败时命令窗口保留错误信息，成功后自动关闭命令窗口；游戏由 Maker 管理。
- 这是可操作的游戏窗口，不是自动回归测试入口。现有自动回归仍使用 `tests/run_circle1_review.py`。

只检查依赖和预览状态、不打开窗口：

```powershell
& 'C:\codex\taptap-sea\本地测试.cmd' --check
```

启动链为 CMD → PowerShell 7 → 已验证的Node → 固定版本Maker CLI。当前Node路径为 `C:\ALL\APP\nodejs\node.exe`，Maker为 `C:\Users\Administrator.DESKTOP-NS4I6RF\.taptap-maker\mcp-runtime\0.0.36\dist\maker.js`；明确安装路径可避免沙箱用户目录与实际用户目录不同。本机安装路径改变时更新 `start-local-preview.ps1`，脚本不会自动下载或升级。

本地启动不等于离线：首次准备可能下载公开索引／缓存资源。此入口不增加云存档隔离，不改变游戏自身的存档行为。

本次只验证脚本语法、从其他目录调用CMD的只读检查和退出码；未打开GUI，不将请求成功当作玩法验证。
