# 清空快取資料夾的內容（保留資料夾本身）。
# 若指定 -ProcessNames 而這些程式正在執行，會中止，避免把使用中的程式弄壞。
# 預設只試跑；加上 -Apply 才執行。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [Parameter(Mandatory)][string]$Path,
    [string]$Label = '',
    [string[]]$ProcessNames = @(),
    [switch]$Apply
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { "不存在，略過：$Path"; return }
if (-not $Label) { $Label = $Path }
$running = Get-PccRunningProcesses $ProcessNames
$stats = Get-PccDirStats $Path
"$Label：$(Format-PccSize $stats.Bytes)（$($stats.Files) 個檔案）"
if ($running.Count) {
    "中止：$($running -join ', ') 正在執行，請先關閉。"
    if ($Apply) {
        Write-PccAction -SessionDir $SessionDir -Category '清理' -Action "清除快取：$Label" -Target $Path -Result 'skipped' -Note "程式執行中：$($running -join ', ')"
    }
    return
}
if (-not $Apply) { '試跑模式：沒有刪除任何檔案。確認後加上 -Apply 執行。'; return }

$before = (Get-PccDirStats $Path).Bytes
$fail = 0
Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { $fail++ }
}
$after = (Get-PccDirStats $Path).Bytes
$freed = [int64]($before - $after)
Write-PccAction -SessionDir $SessionDir -Category '清理' -Action "清除快取：$Label" -Target $Path `
    -Command "clear-folder.ps1 -Path `"$Path`" -Apply" -BytesFreed $freed -Result $(if ($fail) { 'partial' } else { 'done' }) `
    -Reversible 'no' -UndoHint '快取會由程式自動重建，不需要還原' -Note "$fail 個項目被占用而略過"
"已釋放 $(Format-PccSize $freed)，$fail 個項目被占用而略過。"
