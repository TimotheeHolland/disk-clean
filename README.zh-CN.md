# 和 AI 协作之后，别忘了清理它留下的缓存

简体中文 | [English](./README.md)

每次 AI 辅助的会话都会留下点东西——pip 和 npm 缓存、孤儿 `node_modules`、过期的 `__pycache__`、以及旧临时文件。**disk-clean** 是一个简单、安全的 Windows CLI：动手前先预览、可恢复的东西先进隔离区而不是直接删，一条命令释放磁盘。它天生为 Agent 友好：先预览、只有显式确认才真正执行、绝不碰你的源码。

联系：TomAsaTea@163.com

> 这并不完美，还会持续改善。

---

## 简介

简单 · 易用 · 高效 · 安全的 Windows 磁盘清理 CLI。设计参照 Agent-Reach：**单命令 + 可插拔"渠道"（清理类别）+ 预览默认安全 + doctor 体检 + 隔离区可恢复 + 一句话安装**。纯 PowerShell 5.1，零外部依赖。

## 特性

- **简单**：一个文件 `disk-clean.ps1`，一个命令 `disk-clean`，子命令直白。
- **易用**：`setup.ps1` 一键装好并加入 PATH；`preview` 先看、`apply -Confirm` 再删。
- **高效**：整盘扫描一次、多渠道共用；只清缓存和可再生文件，不碰源文件。
- **安全**：预览只读；删除必须确认；可恢复项一律进隔离区；白名单 + 系统目录排除。

## 安装（一条命令）

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

这一条命令自动完成四件事：安装 CLI 并加入 PATH、安装 MCP SDK、把 disk-clean 注册进 Claude Desktop 与 Claude Code CLI 的 MCP 配置（原配置自动备份为 `.bak`）。**重启 Claude** 后，对它说"帮我清理多余的缓存"即可；命令行则新开终端，`disk-clean setup` 生成配置后 `disk-clean preview`。

## 用法

```
disk-clean channels                     列出清理类别(渠道)
disk-clean preview [-Channel 名称]       只扫描出报告，永不删除
disk-clean apply [-Channel 名称] -Confirm 真正清理（必须 -Confirm）
disk-clean restore [序号]                列出/恢复隔离区项目
disk-clean status                        隔离区与最近报告
disk-clean setup                         生成配置 + 体检 + 安装报告
disk-clean doctor [-Json]                体检
disk-clean audit [-MinSizeMB 500] [-StaleDays 90] 沉睡应用与大文件排查清单（仅排查，不删除）
disk-clean add <渠道> / remove <渠道>    启用/停用清理类别
disk-clean update                        升级指引
disk-clean uninstall [-DryRun] [-All]    卸载（-All 连带删除隔离区，需 -Confirm）
disk-clean skill-link <目录>             为另一个 AI 生成 skill 说明
```

## 渠道（清理类别）

| 渠道 | 级别 | 管理员 | 内容 |
|---|---|---|---|
| windows | default | 是 | 临时文件 / 回收站 / Windows Update 缓存 / 缩略图 / 崩溃转储 |
| pip | default | 否 | pip 下载缓存 |
| npm | default | 否 | npm / pnpm / yarn 缓存 |
| node-modules | default | 否 | 孤儿 / 长期未用的 node_modules |
| python-cache | default | 否 | `__pycache__` / `.pytest_cache` |
| browser | optional | 否 | Chrome / Edge 缓存（默认关闭） |
| deep | optional | 是 | DISM 组件清理（慢、彻底） |

`windows` / `deep` 需要管理员终端（以管理员身份打开 PowerShell/终端）。

## 安全红线

1. `preview` 永远只读；`apply` 缺少 `-Confirm` 直接拒绝。
2. 文件夹类目标（node_modules、`__pycache__` 等）一律**先进隔离区**、不真删；保留 `quarantine_days` 天（默认 7），`restore` 可恢复；C 盘目标尤其如此，永不真删。
3. 白名单：只处理缓存目录与 `node_modules` / `__pycache__` / `.pytest_cache` 三种文件夹，其余跳过。
4. 系统目录（`C:\Windows`、`Program Files`、`Program Files (x86)`、`ProgramData`、`AppData`）硬排除。
5. 不删已安装的 Python 包，不动注册表 / `pagefile.sys` / `hiberfil.sys` / `Windows.old` / 浏览器登录。

## 配置

`~\.disk-clean\config.json`（`disk-clean setup` 自动生成）：

- `quarantine_days` — 隔离区保留天数（默认 7）
- `stale_node_modules_days` — node_modules 多少天未动算"过期"（默认 120）
- `delete_orphan_node_modules` / `delete_stale_node_modules` — 是否处理孤儿/过期 node_modules
- `scan_roots` — 扫描根目录（默认 `C:\`、`D:\`、`E:\`）
- `exclude_dirs` — 排除目录（默认系统/软件目录）
- `enabled_channels` — 启用的渠道

## 隔离区与恢复

可恢复项被移动到 `盘符:\disk-clean-quarantine\`，每个文件夹旁有 `.origin.txt` 记原始位置。

- 查看：`disk-clean restore`
- 恢复第 3 项：`disk-clean restore 3`
- 满 `quarantine_days` 天后，下次 `apply` 会真正删除过期项。

## 给 AI 用（MCP，一句话清理）

`mcp/server.py` 把 disk-clean 暴露成 MCP 工具（preview / apply / restore / status / doctor / channels）。`setup.ps1` 会自动安装并注册，无需手动配置。注册目标有两处：Claude Desktop（`%APPDATA%\Claude\claude_desktop_config.json`）与 Claude Code CLI（`--scope user`，即 `~/.claude.json`）；装完可用 `claude mcp list` 验证（应显示 ✔ Connected）。

> 安全红线由两层共同保证：MCP 的 `apply` 工具要求 `confirm=True`；底层 disk-clean 的 `apply` 也要求 `-Confirm`。`preview` 永远只读。

另外 `disk-clean skill-link <目录>` 可生成供其它 AI 直接使用的 skill（含 SKILL.md + 脚本）。

## 目录结构

```
disk-clean/
├── disk-clean.ps1    # 主 CLI（唯一核心文件）
├── setup.ps1         # 一键安装（CLI + MCP 桥 + 自动注册）
├── mcp/
│   └── server.py     # MCP 服务器（供 AI 一句话清理）
├── README.md         # 英文说明
├── README.zh-CN.md   # 本文件（简体中文）
└── LICENSE
```

## 卸载

```powershell
disk-clean uninstall -DryRun    # 先看会删什么
disk-clean uninstall            # 卸载（保留隔离区）
disk-clean uninstall -All -Confirm   # 连同隔离区一起删
```

## 许可证

[MIT](./LICENSE)
