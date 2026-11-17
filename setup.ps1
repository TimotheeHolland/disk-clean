# setup.ps1 — disk-clean 一键安装：CLI + MCP 桥 + 自动注册到 Claude
# 用法：powershell -ExecutionPolicy Bypass -File setup.ps1
$ErrorActionPreference = "Stop"
$srcDir = $PSScriptRoot
$installDir = Join-Path $env:USERPROFILE ".disk-clean"

Write-Host "== disk-clean 一键安装 =="

# ---- 1. 安装 CLI 并加入用户 PATH ----
$cli = Join-Path $srcDir "disk-clean.ps1"
if (-not (Test-Path -LiteralPath $cli)) { Write-Host "缺少 disk-clean.ps1" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $cli -Destination (Join-Path $installDir "disk-clean.ps1") -Force

$shim = Join-Path $installDir "disk-clean.cmd"
@"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0disk-clean.ps1" %*
"@ | Set-Content -LiteralPath $shim -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$already = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -eq $installDir.TrimEnd('\')) })
if ($already.Count -eq 0) {
    $newPath = if ($userPath) { $userPath + ';' + $installDir } else { $installDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}
Write-Host "[1/3] CLI 已安装: $installDir"

# ---- 2. 检测 Python 并安装 mcp SDK ----
$py = $null
foreach ($c in @("python", "py")) {
    $g = Get-Command $c -ErrorAction SilentlyContinue
    if ($g -and $g.Source -and ($g.Source -notmatch 'WindowsApps')) { $py = $g.Source; break }
}
if (-not $py) {
    Write-Host "[2/3] 未找到 Python 3.10+，跳过 MCP（仅 CLI 可用）。装好 Python 后重跑本脚本即可。" -ForegroundColor Yellow
} else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    & $py -m pip install --upgrade mcp *> $null
    & $py -c "import mcp" *> $null
    $importOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if (-not $importOk) {
        Write-Host "[2/3] mcp SDK 安装失败（可能是网络问题），MCP 未注册。可稍后重跑本脚本。" -ForegroundColor Yellow
    } else {
        Write-Host "[2/3] 已安装 mcp SDK (Python: $py)"

        # ---- 3. 生成 MCP 启动包装，并自动注册到 Claude 的 MCP 配置 ----
        $serverSrc = Join-Path $srcDir "mcp\server.py"
        $server    = Join-Path $installDir "disk-clean-mcp-server.py"
        Copy-Item -LiteralPath $serverSrc -Destination $server -Force
        $wrapper = Join-Path $installDir "disk-clean-mcp.cmd"
        $pyEsc = $py.Replace('%', '%%')
        @"
@echo off
"$pyEsc" "$server"
"@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

        $configPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
        $cfg = $null
        if (Test-Path -LiteralPath $configPath) {
            try { $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { $cfg = $null }
        }
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
        if (-not ($cfg.PSObject.Properties.Name -contains "mcpServers")) {
            $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
        }
        $entry = [PSCustomObject]@{ command = "cmd"; args = @("/c", $wrapper) }
        $ms = $cfg.mcpServers
        if ($ms.PSObject.Properties.Name -contains "disk-clean") {
            $ms."disk-clean" = $entry
        } else {
            $ms | Add-Member -NotePropertyName "disk-clean" -NotePropertyValue $entry
        }
        $configDir = Split-Path -Parent $configPath
        if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force }
        $json = $cfg | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[3/3] 已自动注册 MCP 服务器: $configPath (原文件已备份为 .bak)"

        # ---- Claude Code CLI（若已安装）也注册到 user 级 MCP，便于命令行使用 ----
        $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
        $manualCmd = 'claude mcp add disk-clean --scope user -- cmd /c "' + $wrapper + '"'
        if ($claudeCmd -and $claudeCmd.Source) {
            $claudeExe = $claudeCmd.Source
            # npm 全局安装时 Get-Command 会解析到 claude.ps1，改走 claude.cmd 以规避执行策略限制
            if ($claudeExe -match '\.ps1$') {
                $cmdSibling = $claudeExe -replace '\.ps1$', '.cmd'
                if (Test-Path -LiteralPath $cmdSibling) { $claudeExe = $cmdSibling }
            }
            try {
                & $claudeExe mcp add disk-clean --scope user -- cmd /c "$wrapper"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "      Claude Code CLI：已注册到 user 级 MCP（claude mcp list 可查）"
                } else {
                    Write-Host "      Claude Code CLI：注册失败（退出码 $LASTEXITCODE），可稍后手动执行：$manualCmd" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "      Claude Code CLI：注册失败（$($_.Exception.Message)），可稍后手动执行：$manualCmd" -ForegroundColor Yellow
            }
        } else {
            Write-Host "      Claude Code CLI：未检测到，跳过。装好后手动执行：$manualCmd" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "=== 安装完成 ==="
Write-Host "请重启 Claude 让 MCP 生效，然后对它说：帮我清理多余的缓存"
Write-Host "命令行：新开终端后 disk-clean preview / apply -Confirm"
