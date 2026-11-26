# =====================================================================
#  disk-clean  —  简单 · 易用 · 高效 · 安全 的 Windows 磁盘清理 CLI
#  纯 PowerShell 5.1 + 内嵌 .NET 原生加速器，零外部依赖，Agent 友好。
#
#  安全红线：
#    1. preview / audit 永远只读；apply 必须显式传入 -Confirm
#    2. 操作系统底层核心目录/文件硬黑名单无条件生效，绝不进入或触碰
#    3. 临时文件保留最近 24 小时活跃文件，不干扰正在运行的程序
#    4. 文件夹目标一律先移入同盘隔离区，保留 7 天可恢复
# =====================================================================

#requires -Version 5.1

param(
    [Parameter(Position=0)][string]$Action = "",
    [Parameter(Position=1)][string]$Target = "",
    [string]$Channel = "",
    [switch]$Confirm,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$All,
    [int]$MinSizeMB = 0,
    [int]$StaleDays = 90
)

$ErrorActionPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:Version = "0.2.0"

# ------------------------------ 原生 .NET 加速器 ------------------------------
# 使用 C# 5 兼容语法，在内存中一次性编译，实现多线程遍历与零管道开销统计；
# 严格检查 ReparsePoint (符号链接/联接点)，绝不跨链接误算或误删共享目录。
if (-not ([System.Management.Automation.PSTypeName]'DiskCleanFast').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

public class DiskCleanCacheEntry {
    public string FullPath;
    public string Name;
    public DateTime LastWriteTime;
}

public class DiskCleanAuditEntry {
    public string Path;
    public long Size;
    public DateTime LastModified;
    public int DaysAgo;
}

public static class DiskCleanFast {
    private static bool IsReparse(FileSystemInfo fsi) {
        return (fsi.Attributes & FileAttributes.ReparsePoint) != 0;
    }

    public static long GetDirSize(string path, int minAgeHours) {
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path)) return 0L;
        DirectoryInfo root = new DirectoryInfo(path);
        if (IsReparse(root)) return 0L;

        DateTime cutoff = minAgeHours > 0 ? DateTime.Now.AddHours(-minAgeHours) : DateTime.MaxValue;
        long total = 0L;
        Stack<DirectoryInfo> stack = new Stack<DirectoryInfo>();
        stack.Push(root);

        while (stack.Count > 0) {
            DirectoryInfo cur = stack.Pop();
            try {
                FileInfo[] files = cur.GetFiles();
                for (int i = 0; i < files.Length; i++) {
                    if (minAgeHours > 0 && files[i].LastWriteTime >= cutoff) continue;
                    total += files[i].Length;
                }
            } catch {}

            try {
                DirectoryInfo[] subs = cur.GetDirectories();
                for (int i = 0; i < subs.Length; i++) {
                    if (IsReparse(subs[i])) continue;
                    stack.Push(subs[i]);
                }
            } catch {}
        }
        return total;
    }

    public static long[] GetDirSizes(string[] paths, int minAgeHours) {
        long[] sizes = new long[paths.Length];
        if (paths.Length == 0) return sizes;
        if (paths.Length == 1) {
            sizes[0] = GetDirSize(paths[0], minAgeHours);
            return sizes;
        }
        Parallel.For(0, paths.Length, i => {
            sizes[i] = GetDirSize(paths[i], minAgeHours);
        });
        return sizes;
    }

    public static long GetRecycleBinSize() {
        long total = 0L;
        try {
            DriveInfo[] drives = DriveInfo.GetDrives();
            for (int i = 0; i < drives.Length; i++) {
                if (!drives[i].IsReady || drives[i].DriveType != DriveType.Fixed) continue;
                string rb = Path.Combine(drives[i].Name, "$Recycle.Bin");
                if (Directory.Exists(rb)) total += GetDirSize(rb, 0);
            }
        } catch {}
        return total;
    }

    public static List<DiskCleanCacheEntry> FindCacheDirs(
        string[] roots,
        string[] excludePrefixes,
        string[] criticalNames,
        string[] pruneNames
    ) {
        HashSet<string> criticalSet = new HashSet<string>(criticalNames, StringComparer.OrdinalIgnoreCase);
        HashSet<string> pruneSet = new HashSet<string>(pruneNames, StringComparer.OrdinalIgnoreCase);
        ConcurrentBag<DiskCleanCacheEntry> bag = new ConcurrentBag<DiskCleanCacheEntry>();

        Parallel.ForEach(roots, root => {
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) return;
            Stack<string> stack = new Stack<string>();
            stack.Push(root);

            while (stack.Count > 0) {
                string cur = stack.Pop();
                DirectoryInfo[] dirs = null;
                try { dirs = new DirectoryInfo(cur).GetDirectories(); } catch {}
                if (dirs == null) continue;

                for (int i = 0; i < dirs.Length; i++) {
                    DirectoryInfo d = dirs[i];
                    if ((d.Attributes & (FileAttributes.ReparsePoint | FileAttributes.System)) != 0) continue;
                    if (criticalSet.Contains(d.Name) || pruneSet.Contains(d.Name)) continue;

                    string fullLower = d.FullName.ToLowerInvariant();
                    if (fullLower.Contains("disk-clean")) continue;

                    string norm = fullLower.TrimEnd('\\') + "\\";
                    bool excluded = false;
                    for (int j = 0; j < excludePrefixes.Length; j++) {
                        if (norm.StartsWith(excludePrefixes[j], StringComparison.Ordinal)) {
                            excluded = true;
                            break;
                        }
                    }
                    if (excluded) continue;

                    // 保护 Python 运行时与虚拟环境（含 python.exe / pyvenv.cfg 的目录），不进入其内部 Stdlib/site-packages
                    try {
                        if (File.Exists(Path.Combine(d.FullName, "python.exe")) ||
                            File.Exists(Path.Combine(d.FullName, "pyvenv.cfg"))) {
                            continue;
                        }
                    } catch {}

                    if (d.Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase) ||
                        d.Name.Equals("__pycache__", StringComparison.OrdinalIgnoreCase) ||
                        d.Name.Equals(".pytest_cache", StringComparison.OrdinalIgnoreCase)) {
                        bag.Add(new DiskCleanCacheEntry {
                            FullPath = d.FullName,
                            Name = d.Name,
                            LastWriteTime = d.LastWriteTime
                        });
                        continue;
                    }
                    stack.Push(d.FullName);
                }
            }
        });

        List<DiskCleanCacheEntry> list = new List<DiskCleanCacheEntry>(bag);
        list.Sort((a, b) => string.Compare(a.FullPath, b.FullPath, StringComparison.OrdinalIgnoreCase));
        return list;
    }

    public static long ClearDir(string path, int minAgeHours, string[] criticalFiles) {
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path)) return 0L;
        DirectoryInfo root = new DirectoryInfo(path);
        if (IsReparse(root)) return 0L;

        HashSet<string> criticalSet = new HashSet<string>(criticalFiles, StringComparer.OrdinalIgnoreCase);
        DateTime cutoff = minAgeHours > 0 ? DateTime.Now.AddHours(-minAgeHours) : DateTime.MaxValue;
        return ClearDirRecursive(root, true, minAgeHours, cutoff, criticalSet);
    }

    private static long ClearDirRecursive(
        DirectoryInfo dir,
        bool isRoot,
        int minAgeHours,
        DateTime cutoff,
        HashSet<string> criticalSet
    ) {
        if (IsReparse(dir)) return 0L;
        long freed = 0L;

        try {
            FileInfo[] files = dir.GetFiles();
            for (int i = 0; i < files.Length; i++) {
                FileInfo f = files[i];
                string fn = f.Name.ToLowerInvariant();
                if (criticalSet.Contains(fn) || fn.StartsWith("ntuser.dat", StringComparison.Ordinal)) continue;
                if (minAgeHours > 0 && f.LastWriteTime >= cutoff) continue;

                long len = f.Length;
                try {
                    if ((f.Attributes & FileAttributes.ReadOnly) != 0) {
                        f.Attributes = f.Attributes & ~FileAttributes.ReadOnly;
                    }
                    f.Delete();
                    freed += len;
                } catch {}
            }
        } catch {}

        try {
            DirectoryInfo[] subs = dir.GetDirectories();
            for (int i = 0; i < subs.Length; i++) {
                DirectoryInfo sub = subs[i];
                if (IsReparse(sub)) continue;
                freed += ClearDirRecursive(sub, false, minAgeHours, cutoff, criticalSet);
            }
        } catch {}

        if (!isRoot) {
            try {
                if (minAgeHours <= 0 || dir.LastWriteTime < cutoff) {
                    if (dir.GetFileSystemInfos().Length == 0) {
                        if ((dir.Attributes & FileAttributes.ReadOnly) != 0) {
                            dir.Attributes = dir.Attributes & ~FileAttributes.ReadOnly;
                        }
                        dir.Delete(false);
                    }
                }
            } catch {}
        }
        return freed;
    }

    public static List<DiskCleanAuditEntry> AuditApps(
        string[] roots,
        string[] excludePrefixes,
        string[] criticalNames,
        string[] sysKeywords,
        int minMB,
        int staleDays
    ) {
        HashSet<string> criticalSet = new HashSet<string>(criticalNames, StringComparer.OrdinalIgnoreCase);
        DateTime cutoff = DateTime.Now.AddDays(-staleDays);
        List<DirectoryInfo> candidates = new List<DirectoryInfo>();

        for (int r = 0; r < roots.Length; r++) {
            string root = roots[r];
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) continue;
            DirectoryInfo[] subs = null;
            try { subs = new DirectoryInfo(root).GetDirectories(); } catch {}
            if (subs == null) continue;

            for (int i = 0; i < subs.Length; i++) {
                DirectoryInfo d = subs[i];
                if ((d.Attributes & (FileAttributes.ReparsePoint | FileAttributes.System)) != 0) continue;
                if (criticalSet.Contains(d.Name)) continue;

                string nameLower = d.Name.ToLowerInvariant();
                if (nameLower.Contains("disk-clean")) continue;

                string norm = d.FullName.ToLowerInvariant().TrimEnd('\\') + "\\";
                bool excluded = false;
                for (int j = 0; j < excludePrefixes.Length; j++) {
                    if (norm.StartsWith(excludePrefixes[j], StringComparison.Ordinal)) { excluded = true; break; }
                }
                if (excluded) continue;

                bool isSys = false;
                for (int k = 0; k < sysKeywords.Length; k++) {
                    if (nameLower.Contains(sysKeywords[k])) { isSys = true; break; }
                }
                if (isSys) continue;
                if (d.LastWriteTime >= cutoff) continue;

                candidates.Add(d);
            }
        }

        long minBytes = (long)minMB * 1024L * 1024L;
        ConcurrentBag<DiskCleanAuditEntry> found = new ConcurrentBag<DiskCleanAuditEntry>();
        DateTime now = DateTime.Now;

        Parallel.ForEach(candidates, d => {
            long sz = GetDirSize(d.FullName, 0);
            if (sz >= minBytes) {
                found.Add(new DiskCleanAuditEntry {
                    Path = d.FullName,
                    Size = sz,
                    LastModified = d.LastWriteTime,
                    DaysAgo = (int)(now - d.LastWriteTime).TotalDays
                });
            }
        });

        List<DiskCleanAuditEntry> result = new List<DiskCleanAuditEntry>(found);
        result.Sort((a, b) => b.Size.CompareTo(a.Size));
        return result;
    }
}
'@
}

# ------------------------------ 基础工具 ------------------------------
function Write-Con { param([string]$Msg) Write-Host $Msg }

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function Get-DirSize {
    param([string]$Path, [int]$MinAgeHours = 0)
    return [double][DiskCleanFast]::GetDirSize($Path, $MinAgeHours)
}

function Exit-Err {
    param([string]$Code, [string]$Hint)
    Write-Host ("error: " + $Code) -ForegroundColor Red
    if ($Hint) { Write-Host ("  hint: " + $Hint) -ForegroundColor Yellow }
    exit 1
}

# ------------------------------ 操作系统底层硬黑名单 & 剪枝规则 ------------------------------
$script:SystemCriticalDirNames = @(
    '$recycle.bin', 'system volume information', 'recovery', 'boot', 'efi', 'windowsapps'
)
$script:ScanPruneDirNames = @(
    '.git', '.svn', '.hg', '.pnpm-store', '.yarn', '.venv', 'venv', 'site-packages', 'dist-packages', '.conda'
)
$script:SystemCriticalFiles = @(
    'pagefile.sys', 'swapfile.sys', 'hiberfil.sys', 'dumpstack.log', 'dumpstack.log.tmp', 'bootmgr', 'bootnxt'
)

function Get-SystemHardExcludes {
    return @(
        "$env:windir",
        "$env:ProgramData\Microsoft\Windows",
        "$env:SystemDrive\Recovery",
        "$env:SystemDrive\Boot",
        "$env:SystemDrive\EFI",
        "$env:ProgramFiles\WindowsApps",
        "${env:ProgramFiles(x86)}\WindowsApps",
        (Join-Path $env:USERPROFILE "AppData\Local\Microsoft\WindowsApps"),
        (Join-Path $env:USERPROFILE "AppData\Local\Packages"),
        (Join-Path $env:USERPROFILE "AppData\Local\Microsoft\Windows"),
        (Join-Path $env:USERPROFILE "AppData\Roaming\Microsoft\Windows"),
        "$env:SystemDrive\Users\Default",
        "$env:SystemDrive\Users\All Users"
    )
}

function Get-NormalizedPrefixes {
    param([string[]]$Paths)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        if ($p) {
            $norm = $p.TrimEnd('\').ToLowerInvariant() + '\'
            if (-not $list.Contains($norm)) { $list.Add($norm) }
        }
    }
    return $list.ToArray()
}

# 路径安全护栏：防止对根目录、用户主目录、系统关键目录或符号链接执行破坏性操作
function Test-SafeTargetPath {
    param([string]$Path, [string]$ActionType)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    $root = ([System.IO.Path]::GetPathRoot($full)).TrimEnd('\')
    if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    $protectedRoots = @(
        $env:USERPROFILE,
        $env:windir,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:USERPROFILE "AppData"),
        (Join-Path $env:USERPROFILE "AppData\Local"),
        (Join-Path $env:USERPROFILE "AppData\Roaming")
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    if ($protectedRoots -contains $full) { return $false }
    if ($ActionType -eq "delete") {
        $fn = [System.IO.Path]::GetFileName($full).ToLowerInvariant()
        if (($fn -in $script:SystemCriticalFiles) -or ($fn -like "ntuser.dat*")) { return $false }
    }
    if (Test-Path -LiteralPath $full) {
        try {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
        } catch { return $false }
    }
    return $true
}

# ------------------------------ 配置 ------------------------------
function Get-ConfigDir  { return (Join-Path $env:USERPROFILE ".disk-clean") }
function Get-ConfigPath { return (Join-Path (Get-ConfigDir) "config.json") }
function Get-LogDir     { return (Join-Path (Get-ConfigDir) "logs") }

function Get-DefaultConfig {
    [PSCustomObject]@{
        quarantine_days               = 7
        force_quarantine_system_drive = $true
        temp_keep_hours               = 24
        stale_node_modules_days       = 120
        delete_orphan_node_modules    = $false
        delete_stale_node_modules     = $true
        scan_roots                    = @("C:\", "D:\", "E:\")
        exclude_dirs                  = @(
            "$env:windir",
            "$env:ProgramFiles",
            "${env:ProgramFiles(x86)}",
            "$env:ProgramData",
            (Join-Path $env:USERPROFILE "AppData")
        )
        enabled_channels              = @("windows", "pip", "npm", "node-modules", "python-cache")
    }
}

function Read-Config {
    $def = Get-DefaultConfig
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $c = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($c) {
                foreach ($prop in $def.PSObject.Properties) {
                    if (-not ($c.PSObject.Properties.Name -contains $prop.Name)) {
                        $c | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
                    }
                }
                return $c
            }
        } catch {}
    }
    return $def
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

function Test-ChannelName { param([string]$Name) return ($script:ChannelDefs.Contains($Name)) }

function Resolve-TargetChannels {
    param([string]$Chan, $Cfg)
    if ($Chan) {
        if (-not (Test-ChannelName $Chan)) { Exit-Err "BAD_INPUT" ("未知渠道 '" + $Chan + "'，运行 disk-clean channels 查看") }
        return @($Chan)
    }
    return @($Cfg.enabled_channels)
}

# ------------------------------ 隔离区 ------------------------------
function Get-UserFallbackQuarantine {
    return (Join-Path (Get-ConfigDir) "quarantine")
}

function Get-QuarantineRoot {
    param([string]$TargetPath)
    $root = [System.IO.Path]::GetPathRoot($TargetPath)
    if (-not $root) { $root = "$env:SystemDrive\" }
    $driveQ = Join-Path $root "disk-clean-quarantine"
    try {
        if (-not (Test-Path -LiteralPath $driveQ)) {
            New-Item -ItemType Directory -Path $driveQ -Force -ErrorAction Stop | Out-Null
        }
        return $driveQ
    } catch {
        # 非管理员无权写入系统盘根目录时，平滑降级到用户目录下的同盘隔离区，保证 O(1) 移动
        $sysRoot = ([System.IO.Path]::GetPathRoot($env:USERPROFILE)).TrimEnd('\')
        if ($root.TrimEnd('\').Equals($sysRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $fb = Get-UserFallbackQuarantine
            if (-not (Test-Path -LiteralPath $fb)) { New-Item -ItemType Directory -Path $fb -Force | Out-Null }
            return $fb
        }
        return $driveQ
    }
}

function Get-AllQuarantineFolders {
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $q = Join-Path $drive.Name "disk-clean-quarantine"
        if ((Test-Path -LiteralPath $q) -and (-not $result.Contains($q))) { $result.Add($q) }
    }
    $fb = Get-UserFallbackQuarantine
    if ((Test-Path -LiteralPath $fb) -and (-not $result.Contains($fb))) { $result.Add($fb) }
    return $result.ToArray()
}

function Get-QuarantineItems {
    param([switch]$IncludeSize)
    $items = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($q in (Get-AllQuarantineFolders)) {
        try {
            foreach ($d in ([System.IO.DirectoryInfo]::new($q)).GetDirectories()) { $dirs.Add($d) }
        } catch {}
    }
    $sizes = @()
    if ($IncludeSize -and $dirs.Count -gt 0) {
        $paths = @($dirs | ForEach-Object { $_.FullName })
        $sizes = [DiskCleanFast]::GetDirSizes($paths, 0)
    }
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $d = $dirs[$i]
        $origin = ""
        try { $origin = (Get-Content -LiteralPath ($d.FullName + ".origin.txt") -Raw).Trim() } catch {}
        $sz = if ($IncludeSize) { [double]$sizes[$i] } else { 0.0 }
        $items.Add([PSCustomObject]@{
            Path          = $d.FullName
            Origin        = $origin
            LastWriteTime = $d.LastWriteTime
            Size          = $sz
        })
    }
    return $items.ToArray()
}

function Invoke-Quarantine {
    param([string]$Path, [string]$Kind)
    if (-not (Test-SafeTargetPath $Path "quarantine")) { return @{ ok = $false; from = $Path; to = "" } }
    $qRoot = Get-QuarantineRoot $Path
    $name  = [System.IO.Path]::GetFileName($Path)
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $base  = Join-Path $qRoot ("{0}__{1}" -f $stamp, $name)
    $dest  = $base
    $i = 0
    while (Test-Path -LiteralPath $dest) { $i++; $dest = "{0}_{1}" -f $base, $i }
    try {
        Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        try { (Get-Item -LiteralPath $dest -Force).LastWriteTime = Get-Date } catch {}
        try { Set-Content -LiteralPath "$dest.origin.txt" -Value $Path -Encoding UTF8 } catch {}
        return @{ ok = $true; from = $Path; to = $dest }
    } catch {
        return @{ ok = $false; from = $Path; to = "" }
    }
}

# ------------------------------ 扫描 ------------------------------
$script:_DirCache     = @()
$script:_DirCacheKey  = ""
$script:_DirCacheDone = $false

function Get-CachedDirs {
    param($Cfg)
    $key = ($Cfg.scan_roots -join "|")
    if ($script:_DirCacheDone -and $script:_DirCacheKey -eq $key) { return $script:_DirCache }

    $roots = @($Cfg.scan_roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    $allExcludes = @()
    if ($Cfg.exclude_dirs) { $allExcludes += $Cfg.exclude_dirs }
    $allExcludes += (Get-SystemHardExcludes)
    $prefixes = Get-NormalizedPrefixes $allExcludes

    $found = [DiskCleanFast]::FindCacheDirs($roots, $prefixes, $script:SystemCriticalDirNames, $script:ScanPruneDirNames)
    $script:_DirCache = @($found)
    $script:_DirCacheKey = $key
    $script:_DirCacheDone = $true
    return $script:_DirCache
}

# ------------------------------ 生成清理操作 ------------------------------
function New-Op {
    param([string]$Channel, [string]$Kind, [string]$Path, [double]$Size, [string]$Action, [int]$MinAgeHours = 0, [string[]]$Args = @())
    return @{ Channel = $Channel; Kind = $Kind; Path = $Path; Size = $Size; Action = $Action; MinAgeHours = $MinAgeHours; Args = $Args }
}

function Add-ClearOps {
    param([string]$Channel, [string]$Kind, [string[]]$Paths, [int]$MinAgeHours = 0)
    $existing = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($existing.Count -eq 0) { return @() }
    $sizes = [DiskCleanFast]::GetDirSizes($existing, $MinAgeHours)
    $list = @()
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $list += (New-Op -Channel $Channel -Kind $Kind -Path $existing[$i] -Size ([double]$sizes[$i]) -Action "clear" -MinAgeHours $MinAgeHours)
    }
    return $list
}

function Find-SafeExe {
    param([string[]]$Names)
    foreach ($n in $Names) {
        $g = Get-Command $n -ErrorAction SilentlyContinue
        if ($g -and $g.Source -and ($g.Source -notmatch 'WindowsApps')) { return $g.Source }
    }
    return $null
}

function Get-ChannelOps {
    param([string]$ChannelName, $Cfg)
    $ops = @()
    $keepHours = if ($null -ne $Cfg.temp_keep_hours) { [int]$Cfg.temp_keep_hours } else { 24 }

    switch ($ChannelName) {

        "windows" {
            $ops += Add-ClearOps "windows" "用户临时文件" @($env:TEMP) $keepHours
            $ops += Add-ClearOps "windows" "系统临时文件" @((Join-Path $env:windir "Temp")) $keepHours
            $ops += New-Op "windows" "回收站" "all drives" ([double][DiskCleanFast]::GetRecycleBinSize()) "recycle"
            $ops += Add-ClearOps "windows" "Windows Update 缓存" @((Join-Path $env:windir "SoftwareDistribution\Download")) 0

            $exp = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
            foreach ($f in (Get-ChildItem -LiteralPath $exp -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "thumbcache_*.db" -or $_.Name -like "iconcache_*.db" })) {
                $ops += New-Op "windows" "缩略图/图标缓存" $f.FullName ([double]$f.Length) "delete"
            }
            $ops += Add-ClearOps "windows" "崩溃转储(用户)" @((Join-Path $env:LOCALAPPDATA "CrashDumps")) 0
            foreach ($d in @((Join-Path $env:windir "Minidump\*.dmp"), (Join-Path $env:windir "MEMORY.DMP"))) {
                foreach ($f in (Get-ChildItem -Path $d -File -Force -ErrorAction SilentlyContinue)) {
                    $ops += New-Op "windows" "系统崩溃转储" $f.FullName ([double]$f.Length) "delete"
                }
            }
            break
        }

        "pip" {
            $pipDirs = @((Join-Path $env:LOCALAPPDATA "pip\Cache"), (Join-Path $env:LOCALAPPDATA "pip\cache"), (Join-Path $env:USERPROFILE ".cache\pip"))
            $ops += Add-ClearOps "pip" "pip 缓存" $pipDirs 0
            $py = Find-SafeExe @("python", "py", "python3")
            if ($py) { $ops += New-Op "pip" "pip cache purge" $py 0.0 "command" 0 @("-m", "pip", "cache", "purge") }
            break
        }

        "npm" {
            $ops += Add-ClearOps "npm" "npm 缓存" @((Join-Path $env:LOCALAPPDATA "npm-cache"), (Join-Path $env:APPDATA "npm-cache")) 0
            $ops += Add-ClearOps "npm" "yarn 缓存" @((Join-Path $env:LOCALAPPDATA "Yarn\Cache"), (Join-Path $env:LOCALAPPDATA "yarn\Berry\cache")) 0
            $npm = Find-SafeExe @("npm.cmd", "npm")
            if ($npm) { $ops += New-Op "npm" "npm cache clean" $npm 0.0 "command" 0 @("cache", "clean", "--force") }
            $pnpm = Find-SafeExe @("pnpm.cmd", "pnpm")
            if ($pnpm) { $ops += New-Op "npm" "pnpm store prune" $pnpm 0.0 "command" 0 @("store", "prune") }
            $yarn = Find-SafeExe @("yarn.cmd", "yarn")
            if ($yarn) { $ops += New-Op "npm" "yarn cache clean" $yarn 0.0 "command" 0 @("cache", "clean") }
            break
        }

        "node-modules" {
            $picked = New-Object System.Collections.Generic.List[object]
            $cutoff = (Get-Date).AddDays(-$Cfg.stale_node_modules_days)
            foreach ($d in (Get-CachedDirs $Cfg)) {
                if ($d.Name -ne "node_modules") { continue }
                $parent = Split-Path $d.FullPath -Parent
                if ($d.FullPath -match '[\\/]node_global[\\/]node_modules$') { continue }
                if (Test-Path -LiteralPath (Join-Path $parent "node.exe")) { continue }
                if (Test-Path -LiteralPath (Join-Path $d.FullPath ".package-lock.json")) { continue }
                $hasPkg = Test-Path -LiteralPath (Join-Path $parent "package.json")
                $stale  = $d.LastWriteTime -lt $cutoff
                $kind   = ""
                if ((-not $hasPkg) -and $Cfg.delete_orphan_node_modules) { $kind = "孤儿 node_modules" }
                elseif ($hasPkg -and $stale -and $Cfg.delete_stale_node_modules) { $kind = "过期 node_modules" }
                if ($kind) { $picked.Add([PSCustomObject]@{ Path = $d.FullPath; Kind = $kind }) }
            }
            if ($picked.Count -gt 0) {
                $sizes = [DiskCleanFast]::GetDirSizes(@($picked | ForEach-Object { $_.Path }), 0)
                for ($i = 0; $i -lt $picked.Count; $i++) {
                    $ops += New-Op "node-modules" $picked[$i].Kind $picked[$i].Path ([double]$sizes[$i]) "quarantine"
                }
            }
            break
        }

        "python-cache" {
            $picked = @((Get-CachedDirs $Cfg) | Where-Object { $_.Name -ne "node_modules" })
            if ($picked.Count -gt 0) {
                $sizes = [DiskCleanFast]::GetDirSizes(@($picked | ForEach-Object { $_.FullPath }), 0)
                for ($i = 0; $i -lt $picked.Count; $i++) {
                    $ops += New-Op "python-cache" $picked[$i].Name $picked[$i].FullPath ([double]$sizes[$i]) "quarantine"
                }
            }
            break
        }

        "browser" {
            $bPaths = @()
            foreach ($b in @("Google\Chrome\User Data\Default", "Microsoft\Edge\User Data\Default")) {
                foreach ($sub in @("Cache", "Code Cache")) {
                    $bPaths += Join-Path (Join-Path $env:LOCALAPPDATA $b) $sub
                }
            }
            $ops += Add-ClearOps "browser" "浏览器缓存" $bPaths 0
            break
        }

        "deep" {
            $ops += New-Op "deep" "DISM 组件清理" "dism.exe" 0.0 "command" 0 @("/Online", "/Cleanup-Image", "/StartComponentCleanup", "/NoRestart")
            break
        }
    }
    return $ops
}

# ------------------------------ 执行操作 ------------------------------
function Invoke-ApplyOps {
    param($Ops)
    $freed = 0.0

    foreach ($op in $Ops) {
        $path = $op.Path
        switch ($op.Action) {

            "clear" {
                if (-not (Test-Path -LiteralPath $path)) { Write-Con ("  跳过(不存在)  " + $op.Kind + "  " + $path); continue }
                if (-not (Test-SafeTargetPath $path "clear")) { Write-Con ("  跳过(安全保护) " + $op.Kind + "  " + $path); continue }
                $delta = [double][DiskCleanFast]::ClearDir($path, $op.MinAgeHours, $script:SystemCriticalFiles)
                $freed += $delta
                Write-Con ("  清理  " + $op.Kind + "  释放 " + (Format-Bytes $delta))
                break
            }

            "delete" {
                if (-not (Test-Path -LiteralPath $path)) { continue }
                if (-not (Test-SafeTargetPath $path "delete")) { Write-Con ("  跳过(安全保护) " + $op.Kind + "  " + $path); continue }
                $before = $op.Size
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
                    $p = Start-Process -FilePath $path -ArgumentList ($op.Args -join " ") -Wait -PassThru -WindowStyle Hidden
                    Write-Con ("       DISM 结束 (exit " + $p.ExitCode + ")")
                } else {
                    $cmdArgs = $op.Args
                    & $path @cmdArgs *> $null
                }
                break
            }
        }
    }
    return $freed
}

function Save-Report {
    param([string]$Text)
    $dir = Get-LogDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir ("report_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
    $Text | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

# ------------------------------ 子命令动作 ------------------------------
function Show-Channels {
    $cfg = Read-Config
    Write-Con "渠道 (清理类别) —— 带 * 为当前启用："
    foreach ($k in $script:ChannelDefs.Keys) {
        $d = $script:ChannelDefs[$k]
        $mark = if ($cfg.enabled_channels -contains $k) { "*" } else { " " }
        $admin = if ($d.admin) { "需管理员" } else { "无需管理员" }
        Write-Con (" [{0}] {1,-14} {2,-8} {3,-8} {4}" -f $mark, $k, $d.level, $admin, $d.desc)
    }
}

function Invoke-Preview {
    param([string]$Chan)
    $cfg = Read-Config
    $names = Resolve-TargetChannels $Chan $cfg
    $total = 0.0
    $count = 0
    foreach ($n in $names) {
        $ops = @(Get-ChannelOps $n $cfg)
        Write-Con ""
        Write-Con ("渠道: " + $n + "  (" + $ops.Count + " 项)")
        foreach ($op in $ops) {
            $total += $op.Size
            $count++
            Write-Con ("  - " + $op.Kind + "  " + (Format-Bytes $op.Size) + "  [" + $op.Action + "]  " + $op.Path)
        }
    }
    Write-Con ""
    Write-Con ("共 " + $count + " 项，预计可释放 " + (Format-Bytes $total) + "（只读预览，未删除任何内容）")
    Write-Con "确认无误后运行：disk-clean apply -Confirm"
}

function Invoke-Apply {
    param([string]$Chan)
    if (-not $Confirm) { Exit-Err "CONFIRM_REQUIRED" "apply 会真正删除/隔离文件，必须先加 -Confirm（建议先跑 preview）" }
    $cfg = Read-Config
    $names = Resolve-TargetChannels $Chan $cfg
    $rep = New-Object System.Collections.Generic.List[string]
    $rep.Add("disk-clean apply  " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    $rep.Add("渠道: " + ($names -join ", "))
    $rep.Add("")
    $total = 0.0
    foreach ($n in $names) {
        Write-Con ""
        Write-Con ("== 渠道 " + $n + " ==")
        $ops = @(Get-ChannelOps $n $cfg)
        $f = Invoke-ApplyOps $ops
        $total += $f
        $rep.Add("渠道 " + $n + " 释放 " + (Format-Bytes $f))
        foreach ($op in $ops) {
            if ($op.Action -eq "quarantine") { $rep.Add("  隔离 " + $op.Kind + "  " + $op.Path) }
        }
    }
    # 清理过期隔离项
    $cutoff = (Get-Date).AddDays(-$cfg.quarantine_days)
    foreach ($it in (Get-QuarantineItems)) {
        if ($it.LastWriteTime -lt $cutoff) {
            try { Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath ($it.Path + ".origin.txt") -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    $rep.Add("")
    $rep.Add("总计释放: " + (Format-Bytes $total))
    $file = Save-Report ($rep -join "`r`n")
    Write-Con ""
    Write-Con ("完成。总计释放 " + (Format-Bytes $total) + "，报告已存 " + $file)

    $tightDrive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.AvailableFreeSpace / 1GB) -lt 15.0 } | Select-Object -First 1
    if ($total -lt 500MB -and $tightDrive) {
        Write-Con ""
        Write-Con ("  提示: 本次常规缓存清理释放空间有限，且检测到 " + $tightDrive.Name + " 剩余空间较紧 (" + [math]::Round($tightDrive.AvailableFreeSpace / 1GB, 1) + " GB)。")
        Write-Con "        如需排查长期未使用的沉睡软件或大文件，可随时运行: disk-clean audit"
    }
}

function Invoke-Restore {
    param([string]$Index)
    $items = @(Get-QuarantineItems -IncludeSize)
    if ($items.Count -eq 0) { Write-Con "隔离区为空，无需恢复。"; return }
    if ($Index -eq "") {
        Write-Con "隔离区项目（disk-clean restore <序号> 可恢复）："
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Con (" [" + $i + "] " + (Format-Bytes $items[$i].Size) + "  " + $items[$i].Origin + "  ->  " + $items[$i].Path)
        }
        return
    }
    $idx = if ($Index -match '^\d+$') { [int]$Index } else { [array]::IndexOf(($items | ForEach-Object { $_.Origin }), $Index) }
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
    $items = @(Get-QuarantineItems -IncludeSize)
    $qsize = 0.0
    foreach ($it in $items) { $qsize += $it.Size }
    $lastLog = $null
    $logDir = Get-LogDir
    if (Test-Path -LiteralPath $logDir) {
        $lastLog = Get-ChildItem -LiteralPath $logDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    Write-Con ("disk-clean " + $script:Version)
    Write-Con ("隔离区: " + $items.Count + " 项, 共 " + (Format-Bytes $qsize) + " (保留 " + $cfg.quarantine_days + " 天)")
    Write-Con ("启用渠道: " + ($cfg.enabled_channels -join ", "))
    if ($lastLog) { Write-Con ("最近报告: " + $lastLog.FullName) } else { Write-Con "最近报告: (无)" }
}

function Invoke-Doctor {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $psv = $PSVersionTable.PSVersion.ToString()
    $cfgExists = Test-Path -LiteralPath (Get-ConfigPath)
    $tools = @{}
    foreach ($t in @("python", "pip", "npm", "pnpm", "yarn")) { $tools[$t] = [bool](Get-Command $t -ErrorAction SilentlyContinue) }
    $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; FreeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1) }
    })
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

function Invoke-Audit {
    param([int]$MinMB = 0, [int]$Days = 90)
    $isAdaptive = ($MinMB -le 0)
    $minFreeGB = 999999.0
    foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        $freeGB = $d.AvailableFreeSpace / 1GB
        if ($freeGB -lt $minFreeGB) { $minFreeGB = $freeGB }
    }
    if ($isAdaptive) {
        if ($minFreeGB -le 15.0)     { $MinMB = 1024 }
        elseif ($minFreeGB -le 30.0) { $MinMB = 768 }
        else                         { $MinMB = 500 }
    }

    Write-Con ""
    Write-Con "=== disk-clean audit — 沉睡应用与大文件自主排查清单 ==="
    if ($isAdaptive) {
        Write-Con ("排查标准: 智能自适应阈值 >= " + (Format-Bytes ($MinMB * 1MB)) + "（检测到有磁盘剩余仅 " + [math]::Round($minFreeGB, 1) + " GB，优先抓大体量）且最后活跃早于 " + $Days + " 天前")
    } else {
        Write-Con ("排查标准: 用户指定阈值 >= " + (Format-Bytes ($MinMB * 1MB)) + " 且最后活跃早于 " + $Days + " 天前")
    }
    Write-Con "正在检索非系统核心及独立应用目录，请稍候..."

    $candidateRoots = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }) {
        if ($drive.Name.ToUpper() -ne "$env:SystemDrive\") { $candidateRoots += $drive.Name }
    }
    $candidateRoots += @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", (Join-Path $env:LOCALAPPDATA "Programs"))

    $sysKeywords = @("microsoft", "windows", "common files", "driver", "nvidia", "intel", "amd", "realtek", "directx", "vcredist", "dotnet", "package cache", "uninstall information")
    $hardPrefixes = Get-NormalizedPrefixes (Get-SystemHardExcludes)

    $apps = [DiskCleanFast]::AuditApps($candidateRoots, $hardPrefixes, $script:SystemCriticalDirNames, $sysKeywords, $MinMB, $Days)

    Write-Con ""
    if ($apps.Count -eq 0) {
        Write-Con ("未发现体积超过 " + $MinMB + " MB 且早于 " + $Days + " 天未变动的应用目录。")
        Write-Con ""
        return
    }

    Write-Con ("发现 " + $apps.Count + " 个长期未活跃的大型应用/工具目录（仅供自主排查，默认绝不自动删除）：")
    Write-Con ""
    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]
        Write-Con (" [{0}] {1,9}  最后变动: {2:yyyy-MM-dd} ({3}天前)  {4}" -f ($i + 1), (Format-Bytes $app.Size), $app.LastModified, $app.DaysAgo, $app.Path)
    }

    Write-Con ""
    Write-Con "---------------------------------------------------------------------"
    Write-Con "安全提示："
    Write-Con "* 以上为完整应用或工具目录，disk-clean 坚决不执行自动删除/隔离。"
    Write-Con "* 请根据需要自主核对；如需卸载，建议优先运行自带卸载程序(如 unins000.exe)或系统“设置 -> 安装的应用”。"
    Write-Con ""
}

function Invoke-Setup {
    if (-not (Test-Path -LiteralPath (Get-ConfigPath))) {
        Save-Config (Get-DefaultConfig)
        Write-Con ("已生成默认配置: " + (Get-ConfigPath))
    } else {
        Write-Con ("配置已存在: " + (Get-ConfigPath))
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
    Write-Con "将移除："
    Write-Con ("  - 配置与日志目录: " + $dir)
    Write-Con ("  - PATH 中的: " + $dir)
    if ($All) { Write-Con "  - 各盘符及用户目录的 disk-clean 隔离区(含可恢复文件!)" }
    if ($DryRun) { Write-Con "(仅预览，未执行)"; return }
    if ($All -and -not $Confirm) { Exit-Err "CONFIRM_REQUIRED" "删除隔离区需要 -Confirm（里面的文件会被永久删除）" }
    if (-not $All) {
        Write-Con "提示：隔离区里的可恢复文件不会被删除。"
    } else {
        foreach ($q in (Get-AllQuarantineFolders)) {
            try { Remove-Item -LiteralPath $q -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dir.TrimEnd('\')) }
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
    }
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Write-Con "卸载完成。安装目录已删除；请重开终端使 PATH 生效。"
}

function Invoke-SkillLink {
    param([string]$Dir)
    if (-not $Dir) { Exit-Err "BAD_INPUT" "用法: disk-clean skill-link <目录>" }
    $skillDir = Join-Path $Dir "disk-clean"
    if (-not (Test-Path -LiteralPath $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
    $self = $MyInvocation.MyCommand.Path
    Copy-Item -LiteralPath $self -Destination (Join-Path $skillDir "disk-clean.ps1") -Force
    $localSkill = Join-Path (Split-Path $self -Parent) "SKILL.md"
    if (Test-Path -LiteralPath $localSkill) {
        Copy-Item -LiteralPath $localSkill -Destination (Join-Path $skillDir "SKILL.md") -Force
    } else {
        @"
# disk-clean (PowerShell 磁盘清理)
调用前先跑 preview，清理必须带 -Confirm。支持 audit 自适应排查沉睡大应用（只读不删）。
"@ | Set-Content -LiteralPath (Join-Path $skillDir "SKILL.md") -Encoding UTF8
    }
    Write-Con ("已生成 skill 到: " + $skillDir)
}

function Show-Update {
    Write-Con ("disk-clean 当前版本 " + $script:Version)
    Write-Con "升级方式：拉取最新 disk-clean.ps1 覆盖安装目录，再运行 disk-clean setup。"
}

function Show-Help {
    Write-Con @"
disk-clean  —  简单 · 易用 · 高效 · 安全 的 Windows 磁盘清理

用法: disk-clean <action> [参数]

  channels                                列出清理类别(渠道)
  preview [-Channel 名称]                 只扫描出报告，永不删除
  apply [-Channel 名称] -Confirm          真正清理（必须 -Confirm）
  restore [序号]                          列出/恢复隔离区项目
  status                                  隔离区与最近报告
  setup                                   生成配置 + 体检 + 安装报告
  doctor [-Json]                          体检
  audit [-MinSizeMB N] [-StaleDays 90]    沉睡应用自主排查清单（仅排查，不删除）
  add <渠道> / remove <渠道>              启用/停用清理类别
  update                                  升级指引
  uninstall [-DryRun] [-All]              卸载（-All 需 -Confirm）
  skill-link <目录>                       为另一个 AI 生成 skill

安全：preview/audit 只读；apply 必须 -Confirm；临时文件保留 24h；系统硬黑名单绝不触碰。
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
    "audit"          { Invoke-Audit -MinMB $MinSizeMB -Days $StaleDays }
    "^add$"          { Invoke-AddRemove -Name $Target -Add $true }
    "^remove$"       { Invoke-AddRemove -Name $Target -Add $false }
    "uninstall"      { Invoke-Uninstall }
    "skill-link"     { Invoke-SkillLink -Dir $Target }
    "update"         { Show-Update }
    default          { Write-Con ("未知动作 '" + $Action + "'，运行 disk-clean 查看用法") }
}
