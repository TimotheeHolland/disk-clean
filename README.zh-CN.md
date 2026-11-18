# disk-clean

> 和 AI 协作后，别忘了清理掉不用的缓存和镜像文件。  
> 简单 · 安全 · 高效的 Windows 磁盘清理 CLI（原生 PowerShell 5.1，零外部依赖，Agent 友好）。

[English](./README.md) | 简体中文

与 AI 协作后留下的 pip/npm 缓存、过期 `__pycache__` 或旧临时文件，交给 **disk-clean** 一键释放。先预览、显式确认才执行、重要项先进隔离区，绝不碰源代码。

---

## ⚡ 快速安装

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```
一键完成三件事：安装 CLI 并加入 PATH、安装 MCP 桥接组件、自动注册进 Claude Desktop 与 Claude Code CLI。安装后在终端运行 `disk-clean setup` 或直接对 AI 说“帮我清理磁盘缓存”。

---

## 🛠️ 常用命令

```bash
disk-clean preview [-Channel <渠道>]        # 只读预览，计算预计释放空间（永不修改文件）
disk-clean apply [-Channel <渠道>] -Confirm # 真正执行清理（必须显式加上 -Confirm）
disk-clean restore [序号]                   # 列出隔离区文件或一键还原指定项目
disk-clean status                           # 查看隔离区占用与最近清理报告
disk-clean doctor                           # 环境体检（管理员权限、工具链、磁盘剩余）
disk-clean channels                         # 查看支持的清理渠道（windows / pip / npm / deep 等）
disk-clean audit [-MinSizeMB <体积>]        # 沉睡应用与大文件自主排查（仅审计，绝不强删）
```

---

## 🛡️ 安全红线与核心特性

1. **预览只读与显式确认**：`preview` 永不触碰文件；`apply` 缺少 `-Confirm` 直接拒绝。
2. **隔离区机制**：可疑/文件夹目标同盘移动至隔离区保留 7 天，可通过 `restore` 随时无损还原。
3. **系统底层绝对硬黑名单**：严格硬排除引导与系统关键组件（`C:\Windows`、卷恢复快照、`WindowsApps`、系统恢复等），全盘扫描强制剪枝跳过，系统稳定性零风险。
4. **沉睡应用自适应排查（新增）**：新增 `audit` 命令，根据磁盘剩余空间自适应设定阈值，挖掘长期未活跃的巨型应用或工具目录，仅列出清单供用户自主核对，默认绝不擅自删除。
5. **智能收益感知（新增）**：常规缓存清理后若释放空间微薄且磁盘依然吃紧，终端会自动温和提示排查沉睡大文件，日常不产生额外打扰。

---

> 现在并不完美，还会持续维护更新。  
> 联系方式：TimmyFF63@gmail.com

## 许可证

[MIT](./LICENSE)
