# 共用函式。其他腳本以 . "$PSScriptRoot\common.ps1" 載入。
# 相容 Windows PowerShell 5.1 與 PowerShell 7。

$script:PccVersion = '0.1.1'

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

function Get-PccFinalPath {
    # 用 Windows API 取得路徑的最終實際位置：路徑中任何一層的 junction、symlink、8.3 短檔名都會被解析。
    # -VolumeGuid 時回傳 \\?\Volume{GUID}\... 形式（可分辨掛載到資料夾的磁碟區）。
    # 解析失敗（不存在、無法存取、網路位置不支援 GUID 形式）回傳 $null，呼叫端應視為「無法確認」而拒絕。
    param([string]$Path, [switch]$VolumeGuid)
    if (-not ('PccNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PccNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(IntPtr handle, StringBuilder buffer, uint length, uint flags);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static string GetFinalPath(string path, uint flags) {
        // 存取權 0 + FILE_FLAG_BACKUP_SEMANTICS：可以開啟資料夾，也不需要讀取權限
        IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) return null;
        try {
            StringBuilder sb = new StringBuilder(32768);
            uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, flags);
            if (n == 0 || n >= sb.Capacity) return null;
            return sb.ToString();
        } finally { CloseHandle(h); }
    }
}
'@
    }
    $r = [PccNative]::GetFinalPath($Path, $(if ($VolumeGuid) { 1 } else { 0 }))
    if (-not $r) { return $null }
    if ($VolumeGuid) { return $r }
    if ($r -like '\\?\UNC\*') { $r = '\\' + $r.Substring(8) } elseif ($r -like '\\?\*') { $r = $r.Substring(4) }
    # 本機的系統管理共用（\\localhost\C$、\\電腦名稱\C$）視為本機路徑
    if ($r -match '^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$' -and @('localhost', '127.0.0.1', '::1', '[::1]', $env:COMPUTERNAME) -contains $Matches[1]) { $r = $Matches[2] + ':' + $(if ($Matches[3]) { $Matches[3] } else { '\' }) }
    $r.TrimEnd('\')
}

$script:PccBinInfo = @{}
function Get-PccRecycleBinBlocker {
    # 回傳「這個項目無法進資源回收筒」的原因；可以進資源回收筒時回傳 $null。
    # Windows 遇到下列情況會不經詢問直接永久刪除，所以要事先擋下來：
    # 網路或卸除式磁碟、群組原則停用資源回收筒、該磁碟設定為「不要移到資源回收筒」、項目大於資源回收筒上限。
    # 判斷依據是項目「實際所在」的磁碟區（經過 junction、掛載點後的位置），不是路徑字面上的磁碟代號。
    # 無法確認時一律拒絕。資源回收筒只是已滿（但放得下）時，Windows 會清掉最舊的項目，不會永久刪除這個項目。
    param([string]$Path, [int64]$Bytes)
    if ($Path -like '\\?\UNC\*' -or ($Path.StartsWith('\\') -and -not $Path.StartsWith('\\?\'))) { return '網路路徑沒有資源回收筒' }
    # 路徑字面上的磁碟代號必須是真正的磁碟區（subst 虛擬磁碟沒有自己的資源回收筒）
    if ($null -eq $script:PccVols) { $script:PccVols = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue) }  # 同一次執行只查一次
    $vols = $script:PccVols
    $plain = if ($Path -like '\\?\*') { $Path.Substring(4) } else { $Path }
    if ($plain -match '^([A-Za-z]:)' -and -not ($vols | Where-Object { $_.DriveLetter -eq $Matches[1].ToUpper() })) { return "$($Matches[1]) 不是真正的磁碟區（可能是 subst 虛擬磁碟），不送資源回收筒" }
    $gp = Get-PccFinalPath -Path $Path -VolumeGuid
    if (-not $gp -or $gp -notmatch '\{[0-9a-fA-F-]+\}') { return '無法確認項目實際所在的磁碟區（可能是網路位置或無法存取），不送資源回收筒' }
    $guid = $Matches[0].ToLower()
    if (-not $script:PccBinInfo.ContainsKey($guid)) {
        $info = @{ Blocker = $null; Cap = [int64]0; Name = $guid }
        $vol = $vols | Where-Object { $_.DeviceID -and $_.DeviceID.ToLower().Contains($guid) } | Select-Object -First 1
        if (-not $vol) { $info.Blocker = "找不到磁碟區 $guid 的資訊，無法確認資源回收筒設定" }
        else {
            $info.Name = if ($vol.DriveLetter) { $vol.DriveLetter } else { $vol.Name }
            if ($vol.DriveType -ne 3) { $info.Blocker = "$($info.Name) 不是本機固定磁碟，可能沒有資源回收筒" }
            foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer') {
                if ((Get-ItemProperty -LiteralPath $k -Name NoRecycleFiles -ErrorAction SilentlyContinue).NoRecycleFiles -eq 1) { $info.Blocker = '群組原則停用了資源回收筒' }
            }
            if (-not $info.Blocker) {
                $p = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid" -ErrorAction SilentlyContinue
                if ($p -and $p.NukeOnDelete -eq 1) { $info.Blocker = "$($info.Name) 的資源回收筒設定為「不要將檔案移到資源回收筒」" }
                elseif ($p -and $p.MaxCapacity) { $info.Cap = [int64]$p.MaxCapacity * 1MB }
                # 沒有登錄設定（從未調整過資源回收筒）時，用保守的估計：磁碟區容量的 5%
                if (-not $info.Blocker -and -not $info.Cap) { $info.Cap = [int64]([double]$vol.Capacity * 0.05) }
            }
        }
        $script:PccBinInfo[$guid] = $info
    }
    $i = $script:PccBinInfo[$guid]
    if ($i.Blocker) { return $i.Blocker }
    if ($Bytes -gt $i.Cap) { return "大小 $(Format-PccSize $Bytes) 超過 $($i.Name) 資源回收筒上限 $(Format-PccSize $i.Cap)" }
    return $null
}

function Remove-PccToRecycleBin {
    # 送資源回收筒。無法確定能進資源回收筒時丟出例外、不刪除，避免被 Windows 直接永久刪除。
    param([string]$Path, [int64]$Bytes = -1)
    if ($Bytes -lt 0) {
        $item = Get-Item -LiteralPath $Path -Force
        $Bytes = if ($item.PSIsContainer) { (Get-PccDirStats $item.FullName).Bytes } else { $item.Length }
    }
    $blocker = Get-PccRecycleBinBlocker -Path $Path -Bytes $Bytes
    if ($blocker) { throw "無法送資源回收筒（為避免被直接永久刪除，已保留原檔）：$blocker" }
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
