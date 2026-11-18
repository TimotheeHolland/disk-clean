# disk-clean

> After collaborating with AI, don't forget to clean up unused caches and image files.  
> A simple, safe, and efficient Windows disk cleanup CLI (native PowerShell 5.1, zero external dependencies, Agent-friendly).

English | [简体中文](./README.zh-CN.md)

Clean up leftover pip/npm caches, stale `__pycache__`, and temporary files after AI coding sessions. **disk-clean** previews before touching anything, requires explicit confirmation, and moves items to quarantine instead of instant deletion. It never touches your source code.

---

## ⚡ Quick Install

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```
Installs the CLI, adds it to PATH, sets up the MCP bridge, and registers it into Claude Desktop & Claude Code CLI. Run `disk-clean setup` in a new terminal, or ask Claude to "clean up leftover disk caches".

---

## 🛠️ Usage

```bash
disk-clean preview [-Channel <name>]        # Read-only preview (never modifies files)
disk-clean apply [-Channel <name>] -Confirm # Actually clean (requires -Confirm)
disk-clean restore [index]                  # List or restore quarantined items
disk-clean status                           # Check quarantine holdings & latest report
disk-clean doctor                           # Health check (admin rights, tools, disk space)
disk-clean channels                         # List supported channels (windows/pip/npm/deep...)
disk-clean audit [-MinSizeMB <size>]        # Audit inactive large apps (review only, never auto-deletes)
```

---

## 🛡️ Safety Redlines & Features

1. **Read-Only Preview & Explicit Confirmation**: `preview` never modifies files; `apply` requires `-Confirm` to execute.
2. **Quarantine First**: Target folders are moved to a same-drive quarantine for 7 days and can be restored anytime via `restore`.
3. **System-Level Hard Blocklist**: Strictly excludes critical system paths (`C:\Windows`, `WindowsApps`, Volume Snapshots, Recovery, etc.) with early pruning during scans to ensure system stability.
4. **Inactive App Audit with Adaptive Thresholds (New)**: `audit` dynamically sets size thresholds based on available disk space to uncover long-inactive heavy apps/tools, outputting a review list without auto-deleting.
5. **Smart Low-Yield Sensing (New)**: When routine cache cleaning frees minimal space and disk remains tight, a gentle hint suggests auditing inactive large applications without unnecessary nagging.

---

> It's not perfect yet, but will be continuously maintained and updated.  
> Contact: TimmyFF63@gmail.com

## License

[MIT](./LICENSE)
