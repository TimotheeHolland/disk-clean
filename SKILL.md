---
name: disk-clean
description: Safely free disk space on Windows by cleaning leftover caches (pip/npm caches, orphaned or stale node_modules, __pycache__, temp files) and auditing long-inactive large apps. Preview first, then apply only with explicit user confirmation. Use when the user asks to free up disk space or clean leftover caches.
---

# disk-clean

A fast, preview-first Windows disk-cleanup tool. It never touches source code or critical system directories, and quarantines recoverable folders for 7 days instead of deleting them outright.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

Installs the `disk-clean` CLI into PATH and registers it as an MCP server for Claude Desktop and Claude Code CLI.

## Safe workflow

1. **Preview first** — read-only report:
   `disk-clean preview`
2. **Apply only with explicit confirmation**:
   `disk-clean apply -Confirm`
3. **Audit heavy inactive apps (optional, read-only)**:
   `disk-clean audit` (uses adaptive size threshold based on free disk space; never auto-deletes)

## Commands

```text
disk-clean preview [-Channel <name>]     Scan and report only (never deletes)
disk-clean apply [-Channel <name>] -Confirm  Actually clean (requires confirmation)
disk-clean restore [N]                   List / restore quarantined items
disk-clean status                        Quarantine + latest report
disk-clean doctor                        Health check (admin status, tools, free space)
disk-clean channels                      List cleanup categories
disk-clean audit [-MinSizeMB N]          Audit inactive large apps (review only)
```

## Safety

- `preview` and `audit` are read-only; `apply` refuses to run without `-Confirm`.
- Critical system directories (`C:\Windows`, `WindowsApps`, `$Recycle.Bin`, `System Volume Information`, `Recovery`, `Boot`, `EFI`) and symlinks/junctions are hard-excluded.
- Temp folders keep files modified within the last 24 hours to protect active apps.
- Folder targets (`node_modules`, `__pycache__`) move to quarantine for 7 days and are recoverable via `restore`.
