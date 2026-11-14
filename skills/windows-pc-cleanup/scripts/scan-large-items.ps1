# 唯讀：找大型檔案與各磁碟根目錄的資料夾大小。不跟隨 junction，避免重複計算。
# 掃整顆磁碟可能要 10 分鐘以上，建議在背景執行。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [string[]]$Roots,
    [int]$MinSizeMB = 500,
    [int]$Top = 40,
    [string[]]$ExcludePattern = @('\\AppData\\Local\\Temp\\', '\\\$Recycle\.Bin\\', '\\System Volume Information\\'),
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir

if (-not $Roots) {
    $Roots = @($env:USERPROFILE) + @(Get-PccDriveSnapshot | Where-Object { $_.Drive -ne $env:SystemDrive } | ForEach-Object { "$($_.Drive)\" })
}
$min = [int64]$MinSizeMB * 1MB
$exclude = ($ExcludePattern -join '|')
$big = New-Object System.Collections.Generic.List[object]

foreach ($root in $Roots) {
    $real = Resolve-PccRealPath $root
    if (-not $real) { continue }
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push((New-Object System.IO.DirectoryInfo $real))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($e -is [System.IO.DirectoryInfo]) {
                if (-not (Test-PccReparsePoint $e) -and ($e.FullName + '\') -notmatch $exclude) { $stack.Push($e) }
                continue
            }
            if ($e.Length -ge $min -and $e.FullName -notmatch $exclude) {
                $big.Add([pscustomobject]@{ Path = $e.FullName; Bytes = [int64]$e.Length; LastWrite = $e.LastWriteTime.ToString('yyyy-MM-dd') })
            }
        }
    }
}

$folders = foreach ($root in ($Roots | Where-Object { $_ -match '^[A-Za-z]:\\$' })) {
    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\$|^System Volume Information$' -and -not (Test-PccReparsePoint $_) } | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName; Bytes = (Get-PccDirStats $_.FullName).Bytes }
    }
}

$result = [ordered]@{
    collectedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    roots = $Roots; minSizeMB = $MinSizeMB
    largeFiles = @($big | Sort-Object Bytes -Descending | Select-Object -First $Top)
    rootFolders = @($folders | Sort-Object Bytes -Descending)
}
Save-PccJson $result (Join-Path $SessionDir 'large-items.json')

Msg "大於 $MinSizeMB MB 的檔案（前 $Top 個）:" "Files larger than $MinSizeMB MB (top $Top):"
$result.largeFiles | ForEach-Object { "  {0,10}  {1}  {2}" -f (Format-PccSize $_.Bytes), $_.LastWrite, $_.Path }
if ($result.rootFolders) { Msg '磁碟根目錄資料夾大小:' 'Top-level folder sizes:'; $result.rootFolders | Select-Object -First 25 | ForEach-Object { "  {0,10}  {1}" -f (Format-PccSize $_.Bytes), $_.Path } }
