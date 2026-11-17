"""MCP server for disk-clean.

Bridges the PowerShell CLI (disk-clean.ps1) to any MCP-capable agent.
Safety: preview is read-only; apply requires confirm=True.
"""
import os
import subprocess

try:
    from mcp.server.mcpserver import MCPServer as _Server  # mcp 2.x
except ImportError:
    try:
        from mcp.server.fastmcp import FastMCP as _Server  # mcp 1.x
    except ImportError:  # fallback to the standalone fastmcp package
        from fastmcp import FastMCP as _Server

def _find_ps1():
    here = os.path.dirname(os.path.abspath(__file__))
    local = os.path.join(here, "disk-clean.ps1")
    if os.path.exists(local):
        return local
    # Fallback for running from the source checkout (mcp/server.py -> ../disk-clean.ps1)
    return os.path.normpath(os.path.join(here, "..", "disk-clean.ps1"))


PS1 = os.environ.get("DISK_CLEAN_PS1", _find_ps1())

mcp = _Server("disk-clean")


def run(action, extra=None):
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PS1, action]
    if extra:
        cmd += extra
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)
        out = (p.stdout or "").strip()
        err = (p.stderr or "").strip()
        if err:
            out = (out + "\n" + err).strip()
        return out or "(no output)"
    except subprocess.TimeoutExpired:
        return "error: TIMEOUT - command took too long (full-drive scan/cleanup can be slow)."
    except Exception as e:
        return "error: %s" % e


@mcp.tool()
def preview(channel: str = "") -> str:
    """Read-only preview of what would be cleaned. Never deletes anything.
    Leave channel empty to preview all enabled channels."""
    return run("preview", ["-Channel", channel] if channel else [])


@mcp.tool()
def apply(confirm: bool, channel: str = "") -> str:
    """Actually clean the disk. confirm MUST be True to run.
    Run preview first and get explicit user approval before calling this."""
    if not confirm:
        return "Refused: apply requires confirm=True. Run preview and get the user's approval first."
    return run("apply", ["-Confirm"] + (["-Channel", channel] if channel else []))


@mcp.tool()
def restore(index: str = "") -> str:
    """List quarantined items, or restore one by its number. Leave index empty to list."""
    return run("restore", [index] if index else [])


@mcp.tool()
def status() -> str:
    """Show quarantine holdings and the most recent report."""
    return run("status")


@mcp.tool()
def doctor() -> str:
    """Health check: version, admin status, tools, free disk space."""
    return run("doctor")


@mcp.tool()
def channels() -> str:
    """List cleanup channels (categories) and their enabled state."""
    return run("channels")


if __name__ == "__main__":
    mcp.run()
