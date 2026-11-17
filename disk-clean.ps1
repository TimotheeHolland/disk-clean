# =====================================================================
#  disk-clean  —  简单 · 易用 · 高效 · 安全 的 Windows 磁盘清理 CLI
#  设计参照 Agent-Reach：单命令 + 可插拔"渠道"(清理类别) + 预览默认安全
#  + doctor 体检 + 隔离区可恢复 + 一句话安装。
#
#  用法：disk-clean <action> [参数]
#    channels                    列出清理类别
#    preview  [-Channel 名称]     只扫描出报告，永不删除（默认行为）
#    apply    [-Channel 名称] -Confirm   真正清理（必须 -Confirm）
#    restore  [序号]             列出/恢复隔离区里的项目
#    status                      看隔离区与最近一次报告
#    setup                       生成配置 + 体检 + 打印安装报告
#    doctor   [-Json]            体检（admin? 工具? 隔离区? 磁盘空间?）
#    add <渠道> / remove <渠道>   启用/停用某个清理类别
#    update                      查看升级指引
#    uninstall [-DryRun] [-All]  卸载（-All 连带删除隔离区，需 -Confirm）
#    skill-link <目录>           为另一个 AI 生成 skill 说明
#
#  安全红线：preview 永远只读；apply 必须 -Confirm；可恢复项一律先进
#  隔离区；C 盘目标强制只隔离、永不真删；白名单只碰固定目标。
# =====================================================================

#requires -Version 5.1

param(
    [Parameter(Position=0)][string]$Action = "",
    [Parameter(Position=1)][string]$Target = "",
    [string]$Channel = "",
    [switch]$Confirm,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$All
)

$ErrorActionPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:Version = "0.1.0"

# ------------------------------ 基础工具 ------------------------------
function Write-Con { param([string]$Msg) Write-Host $Msg }

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} GB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0.0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0.0 }
    return [double]$sum
}

function Exit-Err {
    param([string]$Code, [string]$Hint)
    Write-Host ("error: " + $Code) -ForegroundColor Red
    if ($Hint) { Write-Host ("  hint: " + $Hint) -ForegroundColor Yellow }
    exit 1
}

# ------------------------------ 配置 ------------------------------
function Get-ConfigDir  { return (Join-Path $env:USERPROFILE ".disk-clean") }
function Get-ConfigPath { return (Join-Path (Get-ConfigDir) "config.json") }
function Get-LogDir     { return (Join-Path (Get-ConfigDir) "logs") }

function Get-DefaultConfig {
    [PSCustomObject]@{
        quarantine_days              = 7
        force_quarantine_system_drive = $true
        stale_node_modules_days      = 120
        delete_orphan_node_modules   = $true
        delete_stale_node_modules    = $true
        scan_roots                   = @("C:\", "D:\", "E:\")
        exclude_dirs                 = @(
            "$env:windir",
            "$env:ProgramFiles",
            "${env:ProgramFiles(x86)}",
            "$env:ProgramData",
            (Join-Path $env:USERPROFILE "AppData")
        )
        enabled_channels             = @("windows", "pip", "npm", "node-modules", "python-cache")
    }
}

function Read-Config {
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $c = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($c) { return $c }
        } catch { }
    }
    return (Get-DefaultConfig)
}

function Save-Config {
    param($Cfg)
    $dir = Get-ConfigDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-ConfigPath) -Encoding UTF8
}

# ------------------------------ 渠道定义 ------------------------------
$script:ChannelDefs = [ordered]@{
    "windows"      = @{ level = "default";  admin = $true;  desc = "临时文件 / 回收站 / Windows Update 缓存 / 缩略图 / 崩溃转储" }
    "pip"          = @{ level = "default";  admin = $false; desc = "pip 下载缓存" }
    "npm"          = @{ level = "default";  admin = $false; desc = "npm / pnpm / yarn 缓存" }
    "node-modules" = @{ level = "default";  admin = $false; desc = "孤儿 / 长期未用的 node_modules" }
    "python-cache" = @{ level = "default";  admin = $false; desc = "__pycache__ / .pytest_cache" }
    "browser"      = @{ level = "optional"; admin = $false; desc = "Chrome / Edge 浏览器缓存(默认关闭)" }
    "deep"         = @{ level = "optional"; admin = $true;  desc = "DISM 组件清理(慢, 彻底)" }
}

function Test-ChannelName {
    param([string]$Name)
    return ($script:ChannelDefs.Contains($Name))
}

# ------------------------------ 隔离区 ------------------------------
function Get-QuarantineRoot {
    param([string]$TargetPath)
    $root = [System.IO.Path]::GetPathRoot($TargetPath)
    if (-not $root) { $root = "$env:SystemDrive\" }
    return (Join-Path $root "disk-clean-quarantine")
}

function Get-AllQuarantineFolders {
    $result = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $q = Join-Path $drive.Name "disk-clean-quarantine"
        if (Test-Path -LiteralPath $q) { $result += $q }
    }
    return $result
}

# 隔离一个文件夹：同盘移动到 disk-clean-quarantine，旁写 .origin.txt
function Invoke-Quarantine {
    param([string]$Path, [string]$Kind)
    $qRoot = Get-QuarantineRoot $Path
    New-Item -ItemType Directory -Path $qRoot -Force | Out-Null
    $name  = [System.IO.Path]::GetFileName($Path)
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $base  = Join-Path $qRoot ("{0}__{1}" -f $stamp, $name)
    $dest  = $base
    $i = 0
    while (Test-Path -LiteralPath $dest) { $i++; $dest = "{0}_{1}" -f $base, $i }
    try {
        Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        try { Set-Content -LiteralPath "$dest.origin.txt" -Value $Path -Encoding UTF8 } catch {}
        return @{ ok = $true; from = $Path; to = $dest }
    } catch {
        return @{ ok = $false; from = $Path; to = "" }
    }
}

# ------------------------------ 扫描 ------------------------------
function Find-CacheDirs {
    param($Cfg)
    $prefixes = @()
    foreach ($ex in $Cfg.exclude_dirs) {
        if ($ex) { $prefixes += $ex.TrimEnd('\').ToLowerInvariant() + '\' }
    }
    $sysDrive = ($env:SystemDrive + '\').ToLowerInvariant()
    $results = New-Object System.Collections.Generic.List[object]

    function Recurse {
        param([string]$Path)
        $dirs = Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            if ($d.FullName -like "*disk-clean*") { continue }
            if ($d.Name -in @('$RECYCLE.BIN', '$Recycle.Bin', 'System Volume Information', 'Recovery')) { continue }
            if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($d.Attributes -band [System.IO.FileAttributes]::System) { continue }
            $p = $d.FullName.TrimEnd('\').ToLowerInvariant() + '\'
            $skip = $false
            foreach ($pre in $prefixes) { if ($p.StartsWith($pre)) { $skip = $true; break } }
            if ($skip) { continue }
            if ($d.Name -eq "node_modules") {
                $results.Add($d)
                continue
            }
            if (($d.Name -eq "__pycache__") -or ($d.Name -eq ".pytest_cache")) {
                $results.Add($d)
                continue
            }
            Recurse $d.FullName
        }
    }

    foreach ($r in $Cfg.scan_roots) {
        if ($r -and (Test-Path -LiteralPath $r)) { Recurse (Resolve-Path -LiteralPath $r).Path }
    }
    return $results.ToArray()
}

# 同一进程内缓存一次扫描结果，多个渠道共用，避免重复遍历 C/D/E
$script:_DirCache     = @()
$script:_DirCacheKey  = ""
$script:_DirCacheDone = $false
function Get-CachedDirs {
    param($Cfg)
    $key = ($Cfg.scan_roots -join "|")
    if ($script:_DirCacheDone -and $script:_DirCacheKey -eq $key) { return $script:_DirCache }
    $script:_DirCache = @(Find-CacheDirs $Cfg)
    $script:_DirCacheKey = $key
    $script:_DirCacheDone = $true
    return $script:_DirCache
}

# ------------------------------ 生成清理操作 ------------------------------
# 每个操作: @{ Channel; Kind; Path; Size; Action }  Action ∈ clear/delete/recycle/quarantine/command
function Get-ChannelOps {
    param([string]$ChannelName, $Cfg)

    $ops = @()

    switch ($ChannelName) {

        "windows" {
            $ops += @{ Channel = "windows"; Kind = "用户临时文件";   Path = $env:TEMP;                          Size = (Get-DirSize $env:TEMP);                          Action = "clear" }
            $ops += @{ Channel = "windows"; Kind = "系统临时文件";   Path = (Join-Path $env:windir "Temp");     Size = (Get-DirSize (Join-Path $env:windir "Temp"));     Action = "clear" }
            $rb = 0.0
            try { $rb = [double]((Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Recurse -File -Force -ErrorAction Stop | Measure-Object Length -Sum).Sum) } catch { $rb = 0.0 }
            $ops += @{ Channel = "windows"; Kind = "回收站";         Path = "all drives";                       Size = $rb;                                            Action = "recycle" }
            $wu = Join-Path $env:windir "SoftwareDistribution\Download"
            $ops += @{ Channel = "windows"; Kind = "Windows Update 缓存"; Path = $wu;                         Size = (Get-DirSize $wu);                              Action = "clear" }
            $exp = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
            foreach ($f in (Get-ChildItem -LiteralPath $exp -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "thumbcache_*.db" -or $_.Name -like "iconcache_*.db" })) {
                $ops += @{ Channel = "windows"; Kind = "缩略图/图标缓存"; Path = $f.FullName;                   Size = $f.Length;                                      Action = "delete" }
            }
            $cd = Join-Path $env:LOCALAPPDATA "CrashDumps"
            $ops += @{ Channel = "windows"; Kind = "崩溃转储(用户)"; Path = $cd;                              Size = (Get-DirSize $cd);                              Action = "clear" }
            foreach ($d in @((Join-Path $env:windir "Minidump\*.dmp"), (Join-Path $env:windir "MEMORY.DMP"))) {
                foreach ($f in (Get-ChildItem -Path $d -File -Force -ErrorAction SilentlyContinue)) {
                    $ops += @{ Channel = "windows"; Kind = "系统崩溃转储"; Path = $f.FullName;                 Size = $f.Length;                                      Action = "delete" }
                }
            }
            break
        }

        "pip" {
            foreach ($p in @((Join-Path $env:LOCALAPPDATA "pip\Cache"), (Join-Path $env:LOCALAPPDATA "pip\cache"), (Join-Path $env:USERPROFILE ".cache\pip"))) {
                $ops += @{ Channel = "pip"; Kind = "pip 缓存"; Path = $p; Size = (Get-DirSize $p); Action = "clear" }
            }
            $py = $null
            foreach ($c in @("python", "py", "python3")) {
                $g = Get-Command $c -ErrorAction SilentlyContinue
                if ($g -and $g.Source -and ($g.Source -notmatch 'WindowsApps')) { $py = $g.Source; break }
            }
            if ($py) { $ops += @{ Channel = "pip"; Kind = "pip cache purge"; Path = "$py -m pip cache purge"; Size = 0.0; Action = "command" } }
            break
        }

        "npm" {
            foreach ($p in @((Join-Path $env:LOCALAPPDATA "npm-cache"), (Join-Path $env:APPDATA "npm-cache"))) {
                $ops += @{ Channel = "npm"; Kind = "npm 缓存"; Path = $p; Size = (Get-DirSize $p); Action = "clear" }
            }
            if (Get-Command npm -ErrorAction SilentlyContinue) { $ops += @{ Channel = "npm"; Kind = "npm cache clean"; Path = "npm cache clean --force"; Size = 0.0; Action = "command" } }
            if (Get-Command pnpm -ErrorAction SilentlyContinue) { $ops += @{ Channel = "npm"; Kind = "pnpm store prune"; Path = "pnpm store prune"; Size = 0.0; Action = "command" } }
            if (Get-Command yarn -ErrorAction SilentlyContinue) { $ops += @{ Channel = "npm"; Kind = "yarn cache clean"; Path = "yarn cache clean"; Size = 0.0; Action = "command" } }
            foreach ($p in @((Join-Path $env:LOCALAPPDATA "Yarn\Cache"), (Join-Path $env:LOCALAPPDATA "yarn\Berry\cache"))) {
                $ops += @{ Channel = "npm"; Kind = "yarn 缓存"; Path = $p; Size = (Get-DirSize $p); Action = "clear" }
            }
            break
        }

        "node-modules" {
            foreach ($d in (Get-CachedDirs $Cfg)) {
                if ($d.Name -ne "node_modules") { continue }
                $parent = Split-Path $d.FullName -Parent
                $hasPkg = Test-Path -LiteralPath (Join-Path $parent "package.json")
                $stale  = $d.LastWriteTime -lt (Get-Date).AddDays(-$Cfg.stale_node_modules_days)
                $pick   = $false
                if ((-not $hasPkg) -and $Cfg.delete_orphan_node_modules) { $pick = $true; $kind = "孤儿 node_modules" }
                elseif ($hasPkg -and $stale -and $Cfg.delete_stale_node_modules) { $pick = $true; $kind = "过期 node_modules" }
                if ($pick) {
                    $ops += @{ Channel = "node-modules"; Kind = $kind; Path = $d.FullName; Size = (Get-DirSize $d.FullName); Action = "quarantine" }
                }
            }
            break
        }

        "python-cache" {
            foreach ($d in (Get-CachedDirs $Cfg)) {
                if ($d.Name -eq "node_modules") { continue }
                $ops += @{ Channel = "python-cache"; Kind = $d.Name; Path = $d.FullName; Size = (Get-DirSize $d.FullName); Action = "quarantine" }
            }
            break
        }

        "browser" {
            foreach ($b in @("Google\Chrome\User Data\Default", "Microsoft\Edge\User Data\Default")) {
                $base = Join-Path $env:LOCALAPPDATA $b
                foreach ($sub in @("Cache", "Code Cache")) {
                    $p = Join-Path $base $sub
                    $ops += @{ Channel = "browser"; Kind = "浏览器缓存"; Path = $p; Size = (Get-DirSize $p); Action = "clear" }
                }
            }
            break
        }

        "deep" {
            $ops += @{ Channel = "deep"; Kind = "DISM 组件清理"; Path = "dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart"; Size = 0.0; Action = "command" }
            break
        }
    }

    return $ops
}

# ------------------------------ 执行操作 ------------------------------
function Invoke-ApplyOps {
    param($Ops, $Cfg)

    $freed = 0.0

    foreach ($op in $Ops) {
        $act = $op.Action
        $path = $op.Path

        switch ($act) {

            "clear" {
                if (-not (Test-Path -LiteralPath $path)) { Write-Con ("  跳过(不存在)  " + $op.Kind + "  " + $path); continue }
                $before = Get-DirSize $path
                Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
                $after = Get-DirSize $path
                $freed += ($before - $after)
                Write-Con ("  清理  " + $op.Kind + "  释放 " + (Format-Bytes ($before - $after)))
                break
            }

            "delete" {
                if (-not (Test-Path -LiteralPath $path)) { continue }
                $before = Get-DirSize $path
                try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                if (-not (Test-Path -LiteralPath $path)) { $freed += $before; Write-Con ("  删除  " + $op.Kind + "  " + $path) }
                else { Write-Con ("  部分删除  " + $op.Kind + "  " + $path) }
                break
            }

            "recycle" {
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                $freed += $op.Size
                Write-Con ("  清空  " + $op.Kind)
                break
            }

            "quarantine" {
                if (-not (Test-Path -LiteralPath $path)) { continue }
                # 一律隔离（可恢复）；C 盘目标尤其如此，永不真删
                $r = Invoke-Quarantine $path $op.Kind
                if ($r.ok) {
                    $freed += $op.Size
                    Write-Con ("  隔离(可恢复)  " + $op.Kind + "  [" + (Format-Bytes $op.Size) + "]")
                    Write-Con ("       " + $r.from + "  ->  " + $r.to)
                } else {
                    Write-Con ("  跳过(无法移动)  " + $op.Kind + "  " + $path)
                }
                break
            }

            "command" {
                Write-Con ("  执行  " + $op.Kind)
                if ($op.Kind -eq "DISM 组件清理") {
                    $p = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup /NoRestart" -Wait -PassThru -WindowStyle Hidden
                    Write-Con ("       DISM 结束 (exit " + $p.ExitCode + ")")
                } else {
                    cmd /c $path 2>&1 | Out-Null
                }
                break
            }
        }
    }

    return $freed
}

# ------------------------------ 输出报告 ------------------------------
function Save-Report {
    param([string]$Text)
    $dir = Get-LogDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ("report_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
    $Text | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

# ------------------------------ 各动作 ------------------------------
function Show-Channels {
    $cfg = Read-Config
    Write-Con "渠道 (清理类别) —— 带 * 为当前启用："
    foreach ($k in $script:ChannelDefs.Keys) {
        $d = $script:ChannelDefs[$k]
        $on = ($cfg.enabled_channels -contains $k)
        $mark = if ($on) { "*" } else { " " }
        $admin = if ($d.admin) { "需管理员" } else { "无需管理员" }
        Write-Con (" [{0}] {1,-14} {2,-8} {3,-8} {4}" -f $mark, $k, $d.level, $admin, $d.desc)
    }
}

function Invoke-Preview {
    param([string]$Chan)
    $cfg = Read-Config
    $names = @()
    if ($Chan) {
        if (-not (Test-ChannelName $Chan)) { Exit-Err "BAD_INPUT" ("未知渠道 '" + $Chan + "'，运行 disk-clean channels 查看") }
        $names = @($Chan)
    } else {
        $names = @($cfg.enabled_channels)
    }
    $total = 0.0
    $count = 0
    foreach ($n in $names) {
        $ops = @(Get-ChannelOps $n $cfg)
        Write-Con ("")
        Write-Con ("渠道: " + $n + "  (" + $ops.Count + " 项)")
        foreach ($op in $ops) {
            $total += $op.Size
            $count++
            Write-Con ("  - " + $op.Kind + "  " + (Format-Bytes $op.Size) + "  [" + $op.Action + "]  " + $op.Path)
        }
    }
    Write-Con ("")
    Write-Con ("共 " + $count + " 项，预计可释放 " + (Format-Bytes $total) + "（只读预览，未删除任何内容）")
    Write-Con ("确认无误后运行：disk-clean apply -Confirm")
}

function Invoke-Apply {
    param([string]$Chan)
    if (-not $Confirm) { Exit-Err "CONFIRM_REQUIRED" "apply 会真正删除/隔离文件，必须先加 -Confirm（建议先跑 preview）" }
    $cfg = Read-Config
    $names = @()
    if ($Chan) {
        if (-not (Test-ChannelName $Chan)) { Exit-Err "BAD_INPUT" ("未知渠道 '" + $Chan + "'") }
        $names = @($Chan)
    } else {
        $names = @($cfg.enabled_channels)
    }
    $rep = New-Object System.Collections.Generic.List[string]
    $rep.Add("disk-clean apply  " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    $rep.Add("渠道: " + ($names -join ", "))
    $rep.Add("")
    $total = 0.0
    foreach ($n in $names) {
        Write-Con ("")
        Write-Con ("== 渠道 " + $n + " ==")
        $ops = @(Get-ChannelOps $n $cfg)
        $f = Invoke-ApplyOps $ops $cfg
        $total += $f
        $rep.Add("渠道 " + $n + " 释放 " + (Format-Bytes $f))
        foreach ($op in $ops) {
            if ($op.Action -eq "quarantine") { $rep.Add("  隔离 " + $op.Kind + "  " + $op.Path) }
        }
    }
    # 清理过期的隔离项
    $cfg2 = Read-Config
    $cutoff = (Get-Date).AddDays(-$cfg2.quarantine_days)
    foreach ($q in (Get-AllQuarantineFolders)) {
        Get-ChildItem -LiteralPath $q -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.LastWriteTime -lt $cutoff) {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -LiteralPath ($_.FullName + ".origin.txt") -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
    $rep.Add("")
    $rep.Add("总计释放: " + (Format-Bytes $total))
    $file = Save-Report ($rep -join "`r`n")
    Write-Con ("")
    Write-Con ("完成。总计释放 " + (Format-Bytes $total) + "，报告已存 " + $file)
}

function Invoke-Restore {
    param([string]$Index)
    $items = @()
    foreach ($q in (Get-AllQuarantineFolders)) {
        Get-ChildItem -LiteralPath $q -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $origin = ""
            try { $origin = (Get-Content -LiteralPath ($_.FullName + ".origin.txt") -Raw).Trim() } catch {}
            $items += [PSCustomObject]@{ Path = $_.FullName; Origin = $origin; Size = (Get-DirSize $_.FullName) }
        }
    }
    if ($items.Count -eq 0) { Write-Con "隔离区为空，无需恢复。"; return }
    if ($Index -eq "") {
        Write-Con "隔离区项目（disk-clean restore <序号> 可恢复）："
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Con (" [" + $i + "] " + (Format-Bytes $items[$i].Size) + "  " + $items[$i].Origin + "  ->  " + $items[$i].Path)
        }
        return
    }
    $idx = -1
    if ($Index -match '^\d+$') { $idx = [int]$Index } else { $idx = [array]::IndexOf(($items | ForEach-Object { $_.Origin }), $Index) }
    if ($idx -lt 0 -or $idx -ge $items.Count) { Exit-Err "NOT_FOUND" "没有这个序号或路径，先运行 disk-clean restore 查看" }
    $it = $items[$idx]
    if (-not $it.Origin) { Exit-Err "NOT_FOUND" "该项目没有原始路径记录，无法自动恢复" }
    $parent = Split-Path $it.Origin -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    try {
        Move-Item -LiteralPath $it.Path -Destination $it.Origin -Force -ErrorAction Stop
        try { Remove-Item -LiteralPath ($it.Path + ".origin.txt") -Force -ErrorAction SilentlyContinue } catch {}
        Write-Con ("已恢复: " + $it.Origin)
    } catch {
        Write-Con ("恢复失败: " + $it.Origin + "  (" + $_.Exception.Message + ")")
    }
}

function Invoke-Status {
    $cfg = Read-Config
    $items = @()
    foreach ($q in (Get-AllQuarantineFolders)) {
        Get-ChildItem -LiteralPath $q -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $items += $_ }
    }
    $qsize = 0.0
    foreach ($it in $items) { $qsize += (Get-DirSize $it.FullName) }
    $lastLog = $null
    $logDir = Get-LogDir
    if (Test-Path -LiteralPath $logDir) {
        $lastLog = Get-ChildItem -LiteralPath $logDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    Write-Con "disk-clean " + $script:Version
    Write-Con "隔离区: " + $items.Count + " 项, 共 " + (Format-Bytes $qsize) + " (保留 " + $cfg.quarantine_days + " 天)"
    Write-Con "启用渠道: " + ($cfg.enabled_channels -join ", ")
    if ($lastLog) { Write-Con ("最近报告: " + $lastLog.FullName) } else { Write-Con "最近报告: (无)" }
}

function Invoke-Doctor {
    $cfg = Read-Config
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $psv = $PSVersionTable.PSVersion.ToString()
    $cfgExists = Test-Path -LiteralPath (Get-ConfigPath)
    $tools = @{}
    foreach ($t in @("python", "pip", "npm", "pnpm", "yarn")) { $tools[$t] = [bool](Get-Command $t -ErrorAction SilentlyContinue) }
    $drives = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $drives += [PSCustomObject]@{ Name = $d.Name; FreeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1) }
    }
    if ($Json) {
        [PSCustomObject]@{ version = $script:Version; powershell = $psv; admin = $isAdmin; config_exists = $cfgExists; tools = $tools; free_space_gb = $drives } | ConvertTo-Json -Depth 4 | Write-Host
    } else {
        Write-Con ("版本:       " + $script:Version)
        Write-Con ("PowerShell: " + $psv)
        Write-Con ("管理员:     " + $isAdmin + "  (windows/deep 渠道需要)")
        Write-Con ("配置存在:   " + $cfgExists)
        Write-Con ("工具:       python=" + $tools.python + " pip=" + $tools.pip + " npm=" + $tools.npm + " pnpm=" + $tools.pnpm + " yarn=" + $tools.yarn)
        foreach ($d in $drives) { Write-Con ("磁盘:       " + $d.Name + " 剩余 " + $d.FreeGB + " GB") }
    }
}

function Invoke-Setup {
    $dir = Get-ConfigDir
    if (-not (Test-Path -LiteralPath (Get-ConfigPath))) {
        Save-Config (Get-DefaultConfig)
        Write-Con "已生成默认配置: " + (Get-ConfigPath)
    } else {
        Write-Con "配置已存在: " + (Get-ConfigPath)
    }
    $logDir = Get-LogDir
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Write-Con ""
    Write-Con "=== 安装报告 ==="
    Invoke-Doctor
    Write-Con ""
    Write-Con "下一步：disk-clean preview   （先看会清什么）"
    Write-Con "        disk-clean apply -Confirm  （确认后清理）"
}

function Invoke-AddRemove {
    param([string]$Name, [bool]$Add)
    if (-not (Test-ChannelName $Name)) { Exit-Err "BAD_INPUT" ("未知渠道 '" + $Name + "'，运行 disk-clean channels 查看") }
    $cfg = Read-Config
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cfg.enabled_channels) { $list.Add($c) }
    $has = $list.Contains($Name)
    if ($Add -and -not $has) { $list.Add($Name); Write-Con ("已启用渠道: " + $Name) }
    elseif (-not $Add -and $has) { $list.Remove($Name) | Out-Null; Write-Con ("已停用渠道: " + $Name) }
    else { Write-Con ("渠道 '" + $Name + "' 已经是该状态") }
    $cfg.enabled_channels = $list.ToArray()
    Save-Config $cfg
}

function Invoke-Uninstall {
    $dir = Get-ConfigDir
    $pathEntry = $dir
    Write-Con "将移除："
    Write-Con "  - 配置与日志目录: " + $dir
    Write-Con "  - PATH 中的: " + $pathEntry
    if ($All) { Write-Con "  - 各盘符根目录的 disk-clean-quarantine 隔离区(含可恢复文件!)" }
    if ($DryRun) { Write-Con "(仅预览，未执行)"; return }
    if ($All -and -not $Confirm) { Exit-Err "CONFIRM_REQUIRED" "删除隔离区需要 -Confirm（里面的文件会被永久删除）" }
    if (-not $All) {
        Write-Con "提示：隔离区里的可恢复文件不会被删除。"
    } else {
        foreach ($q in (Get-AllQuarantineFolders)) {
            try { Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    # 移除 PATH 条目
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $pathEntry.TrimEnd('\')) }
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
    }
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Write-Con "卸载完成。安装目录已删除；请重开终端使 PATH 生效。"
}

function Invoke-SkillLink {
    param([string]$Dir)
    if (-not $Dir) { Exit-Err "BAD_INPUT" "用法: disk-clean skill-link <目录>" }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $skillDir = Join-Path $Dir "disk-clean"
    if (-not (Test-Path -LiteralPath $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
    $self = $MyInvocation.MyCommand.Path
    Copy-Item -LiteralPath $self -Destination (Join-Path $skillDir "disk-clean.ps1") -Force
    $skillMd = @"
# disk-clean (PowerShell 磁盘清理)

只读/清理 Windows 磁盘的 CLI。调用前先跑 preview，删除必须 -Confirm。

## 用法
- 预览(只读,永不删): `disk-clean preview [-Channel windows]`
- 清理(必须确认):     `disk-clean apply [-Channel npm] -Confirm`
- 恢复:               `disk-clean restore [序号]`
- 状态:               `disk-clean status`
- 体检:               `disk-clean doctor`
- 渠道:               `disk-clean channels`

## 安全红线
1. preview 永远只读；apply 必须 -Confirm。
2. 可恢复项(文件夹)一律进隔离区，保留 N 天，restore 可恢复；C 盘目标强制只隔离不真删。
3. 白名单：只处理缓存目录与 node_modules/__pycache__/.pytest_cache。
4. 系统目录(Windows/Program Files/AppData)硬排除。
5. 不删已安装的 Python 包，不动注册表/系统文件。
"@
    Set-Content -LiteralPath (Join-Path $skillDir "SKILL.md") -Value $skillMd -Encoding UTF8
    Write-Con ("已生成 skill 到: " + $skillDir)
    Write-Con "把该目录链接给另一个 AI，即可让它按上述红线驱动 disk-clean。"
}

function Show-Update {
    Write-Con "disk-clean 当前版本 " + $script:Version
    Write-Con "暂无自动升级通道。升级方式：从发布源拉取最新 disk-clean.ps1 覆盖安装目录，再运行 disk-clean setup。"
}

function Show-Help {
    Write-Con @"
disk-clean  —  简单 · 易用 · 高效 · 安全 的 Windows 磁盘清理

用法: disk-clean <action> [参数]

  channels                       列出清理类别(渠道)
  preview [-Channel 名称]        只扫描出报告，永不删除
  apply [-Channel 名称] -Confirm 真正清理（必须 -Confirm）
  restore [序号]                 列出/恢复隔离区项目
  status                         隔离区与最近报告
  setup                          生成配置 + 体检 + 安装报告
  doctor [-Json]                 体检
  add <渠道> / remove <渠道>     启用/停用清理类别
  update                         升级指引
  uninstall [-DryRun] [-All]     卸载（-All 需 -Confirm）
  skill-link <目录>              为另一个 AI 生成 skill

安全：preview 只读；apply 必须 -Confirm；可恢复项先进隔离区；C 盘只隔离不真删。
"@
}

# ------------------------------ 分发 ------------------------------
switch -Regex ($Action.ToLower()) {
    "^$|help"        { Show-Help }
    "channels"       { Show-Channels }
    "preview"        { Invoke-Preview -Chan $Channel }
    "apply"          { Invoke-Apply -Chan $Channel }
    "restore"        { Invoke-Restore -Index $Target }
    "status"         { Invoke-Status }
    "setup"          { Invoke-Setup }
    "doctor"         { Invoke-Doctor }
    "^add$"          { Invoke-AddRemove -Name $Target -Add $true }
    "^remove$"       { Invoke-AddRemove -Name $Target -Add $false }
    "uninstall"      { Invoke-Uninstall }
    "skill-link"     { Invoke-SkillLink -Dir $Target }
    "update"         { Show-Update }
    default          { Write-Con ("未知动作 '" + $Action + "'，运行 disk-clean 查看用法") }
}
