# 共用函式。其他腳本以 . "$PSScriptRoot\common.ps1" 載入。
# 相容 Windows PowerShell 5.1 與 PowerShell 7。

$script:PccVersion = '0.1.0'

function Get-PccSessionDir {
    param([string]$SessionDir)
    if (-not $SessionDir) { throw '需要 -SessionDir。請先執行 new-session.ps1 取得工作階段資料夾。' }
    if (-not (Test-Path -LiteralPath $SessionDir)) { New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null }
    (Resolve-Path -LiteralPath $SessionDir).ProviderPath
}

function Format-PccSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-PccReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Resolve-PccRealPath {
    # 若路徑本身是 junction / symlink，回傳實際指向的位置；否則回傳原路徑。
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ((Test-PccReparsePoint $item) -and $item.PSObject.Properties['Target'] -and $item.Target) {
        $t = @($item.Target)[0]
        if ($t -and -not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path $Path -Parent) $t }
        return $t
    }
    return $item.FullName
}

function Get-PccDirStats {
    # 計算資料夾大小。不跟隨子層的 junction / symlink，避免重複計算或計到別的磁碟。
    # 根目錄本身若是 junction，會改掃描實際位置（呼叫端可用 Resolve-PccRealPath 得知真實位置）。
    param(
        [string]$Path,
        [datetime]$OlderThan = [datetime]::MaxValue
    )
    $result = [pscustomobject]@{ Bytes = [int64]0; Files = 0; OldBytes = [int64]0; OldFiles = 0; SkippedLinks = 0; Errors = 0 }
    $real = Resolve-PccRealPath $Path
    if (-not $real -or -not (Test-Path -LiteralPath $real -PathType Container)) { return $result }
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push((New-Object System.IO.DirectoryInfo $real))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { $result.Errors++; continue }
        foreach ($e in $entries) {
            if (Test-PccReparsePoint $e) {
                if ($e -is [System.IO.DirectoryInfo]) { $result.SkippedLinks++; continue }
            }
            if ($e -is [System.IO.DirectoryInfo]) { $stack.Push($e); continue }
            $len = ([System.IO.FileInfo]$e).Length
            $result.Bytes += $len; $result.Files++
            if ($e.LastWriteTime -lt $OlderThan) { $result.OldBytes += $len; $result.OldFiles++ }
        }
    }
    return $result
}

function Get-PccDriveSnapshot {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{ Drive = $_.DeviceID; Label = $_.VolumeName; SizeBytes = [int64]$_.Size; FreeBytes = [int64]$_.FreeSpace }
    }
}

function Get-PccRunningProcesses {
    param([string[]]$Names)
    if (-not $Names) { return @() }
    @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
}

function Save-PccJson {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Read-PccJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Write-PccAction {
    # 把一筆動作寫進 actions.jsonl，作為 HTML 報告與溯源的依據。
    param(
        [Parameter(Mandatory)][string]$SessionDir,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        [string]$Command = '',
        [int64]$BytesFreed = 0,
        [ValidateSet('done', 'partial', 'skipped', 'failed', 'pending')][string]$Result = 'done',
        [ValidateSet('yes', 'recycle-bin', 'undo-script', 'reinstall', 'no')][string]$Reversible = 'no',
        [string]$UndoHint = '',
        [string]$Evidence = '',
        [string]$Note = ''
    )
    $entry = [ordered]@{
        time       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        category   = $Category
        action     = $Action
        target     = $Target
        command    = $Command
        bytesFreed = $BytesFreed
        result     = $Result
        reversible = $Reversible
        undoHint   = $UndoHint
        evidence   = $Evidence
        note       = $Note
        user       = $env:USERNAME
        host       = $env:COMPUTERNAME
    }
    $line = ($entry | ConvertTo-Json -Compress -Depth 4)
    $file = Join-Path $SessionDir 'actions.jsonl'
    [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
}

function Read-PccActions {
    param([string]$SessionDir)
    $file = Join-Path $SessionDir 'actions.jsonl'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    @([System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Remove-PccToRecycleBin {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    $rc = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $rc)
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $rc)
    }
}

function Get-PccFreePath {
    # 目的地已有同名項目時自動加上 (2)、(3)… 避免覆蓋。
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = Split-Path $Path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $dir "$name ($i)$ext")) { $i++ }
    Join-Path $dir "$name ($i)$ext"
}

function Test-PccIsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
