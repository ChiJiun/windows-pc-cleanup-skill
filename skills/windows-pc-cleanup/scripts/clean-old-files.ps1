# 刪除某資料夾中「超過 N 天未修改」的檔案（例如 Temp）。
# 預設只試跑列出結果；加上 -Apply 才會真的刪除。被占用的檔案會略過。
# 刪除的每個檔案都會寫進明細檔，摘要寫進 actions.jsonl。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [Parameter(Mandatory)][string]$Path,
    [int]$OlderThanDays = 7,
    [string[]]$ExcludeTopLevel = @(),
    [switch]$Recycle,
    [switch]$Apply,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw (Msg "找不到資料夾：$Path" "Folder not found: $Path") }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
$cut = (Get-Date).AddDays(-$OlderThanDays)

$candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
$dirList = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
$stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
$stack.Push((New-Object System.IO.DirectoryInfo $root))
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try { $entries = $dir.GetFileSystemInfos() } catch { continue }
    foreach ($e in $entries) {
        if ($dir.FullName.TrimEnd('\') -eq $root -and ($ExcludeTopLevel | Where-Object { $e.Name -like $_ })) { continue }
        if ($e -is [System.IO.DirectoryInfo]) { if (-not (Test-PccReparsePoint $e)) { $stack.Push($e); $dirList.Add($e) }; continue }
        if ($e.LastWriteTime -lt $cut) { $candidates.Add([System.IO.FileInfo]$e) }
    }
}
$total = [int64](($candidates | Measure-Object Length -Sum).Sum)
Msg "符合條件：$($candidates.Count) 個檔案，$(Format-PccSize $total)（$root，超過 $OlderThanDays 天未修改，排除：$($ExcludeTopLevel -join ', ')）" "Matched: $($candidates.Count) files, $(Format-PccSize $total) ($root, not modified for $OlderThanDays days, excluded: $($ExcludeTopLevel -join ', '))"
if (-not $Apply) { Msg '試跑模式：沒有刪除任何檔案。確認後加上 -Apply 執行。' 'Dry run: nothing was deleted. Add -Apply after confirming.'; return }

$detail = Join-Path $SessionDir ("clean-old-files-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ok = 0; $okBytes = [int64]0; $fail = 0
$sw = New-Object System.IO.StreamWriter($detail, $false, (New-Object System.Text.UTF8Encoding $false))
foreach ($f in $candidates) {
    try {
        $len = $f.Length
        if ($Recycle) { Remove-PccToRecycleBin -Path $f.FullName -Bytes $len } else { [System.IO.File]::Delete($f.FullName) }
        $ok++; $okBytes += $len; $sw.WriteLine("DELETED`t$len`t$($f.FullName)")
    } catch { $fail++; $sw.WriteLine("SKIPPED`t0`t$($f.FullName)`t$($_.Exception.Message)") }
}
$sw.Close()
# 清掉因此變空、而且也是舊的資料夾（不進入排除的頂層資料夾與 junction）
# 用列舉當下快取的修改時間判斷（刪檔後資料夾時間會被更新成現在）
$dirList | Where-Object { $_.LastWriteTime -lt $cut -and (Test-Path -LiteralPath $_.FullName) } |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object {
        # 用 .NET 刪除（非遞迴）：資料夾不是空的或沒有權限時直接失敗，不會跳出確認提示卡住
        try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
    }

$result = if ($fail -eq 0) { 'done' } else { 'partial' }
Write-PccAction -SessionDir $SessionDir -Category (Msg '清理' 'Cleanup') -Action (Msg "刪除超過 $OlderThanDays 天的舊檔" "Delete files older than $OlderThanDays days") -Target $root `
    -Command "clean-old-files.ps1 -Path `"$root`" -OlderThanDays $OlderThanDays -Apply$(if ($Recycle) { ' -Recycle' })" `
    -BytesFreed $okBytes -Result $result -Reversible $(if ($Recycle) { 'recycle-bin' } else { 'no' }) `
    -UndoHint $(if ($Recycle) { Msg '從資源回收筒還原' 'Restore from the Recycle Bin' } else { Msg '暫存檔，無法還原，也不需要還原' 'Temporary files; cannot and need not be restored' }) `
    -Evidence (Split-Path $detail -Leaf) -Note (Msg "刪除 $ok 個，略過 $fail 個（被占用、唯讀或沒有權限$(if ($Recycle) { '、無法進資源回收筒' })；原因見明細）" "Deleted $ok, skipped $fail (in use, read-only or access denied$(if ($Recycle) { ', or cannot go to the Recycle Bin' }); see the detail log)")
Msg "已刪除 $ok 個檔案（$(Format-PccSize $okBytes)），略過 $fail 個。明細：$detail" "Deleted $ok files ($(Format-PccSize $okBytes)), skipped $fail. Detail log: $detail"
