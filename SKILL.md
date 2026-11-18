---
name: disk-clean
description: Safely free disk space on Windows by cleaning leftover caches (pip/npm caches, orphaned or stale node_modules, __pycache__, temp files). Preview first, then apply only with explicit user confirmation. Use when the user asks to free up disk space or clean leftover caches.
---

# disk-clean

A safe, preview-first Windows disk-cleanup tool. It never touches source code and
quarantines recoverable items instead of deleting them outright.

## When to use

Use this skill when the user wants to free disk space or clean up leftover caches —
pip/npm caches, orphaned or stale `node_modules`, `__pycache__` folders, temp files,
thumbnails, or the Recycle Bin.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

This installs the `disk-clean` CLI and (optionally) registers it as an MCP server for
Claude Desktop and Claude Code CLI.

## Safe workflow

1. **Preview first** — never delete anything before showing the user:
   `disk-clean preview`
2. **Report the summary** — total size, and what is quarantined vs. actually deleted.
3. **Apply only with explicit confirmation**:
   `disk-clean apply -Confirm`

## Commands

```
disk-clean preview                      Scan and report only (never deletes)
disk-clean apply -Confirm               Actually clean (requires confirmation)
disk-clean restore [N]                  List / restore quarantined items
disk-clean status                       Quarantine + latest report
disk-clean doctor                       Health check (admin status, free space)
disk-clean channels                     List cleanup categories
```

## Safety

- `preview` is read-only; `apply` refuses to run without `-Confirm`.
- Folder targets (`node_modules`, `__pycache__`) go to quarantine first and stay
  recoverable for 7 days; items on drive C: are never truly deleted.
- System directories and source code are never touched.
