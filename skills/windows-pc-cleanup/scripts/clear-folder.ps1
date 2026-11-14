# 清空快取資料夾的內容（保留資料夾本身）。
# 若指定 -ProcessNames 而這些程式正在執行，會中止，避免把使用中的程式弄壞。
# 預設只試跑；加上 -Apply 才執行。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [Parameter(Mandatory)][string]$Path,
    [string]$Label = '',
    [string[]]$ProcessNames = @(),
    [switch]$Apply,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Msg "不存在，略過：$Path" "Not found, skipped: $Path"; return }
if (-not $Label) { $Label = $Path }
$running = Get-PccRunningProcesses $ProcessNames
$stats = Get-PccDirStats $Path
Msg "$Label：$(Format-PccSize $stats.Bytes)（$($stats.Files) 個檔案）" "${Label}: $(Format-PccSize $stats.Bytes) ($($stats.Files) files)"
if ($running.Count) {
    Msg "中止：$($running -join ', ') 正在執行，請先關閉。" "Aborted: $($running -join ', ') is running. Close it first."
    if ($Apply) {
        Write-PccAction -SessionDir $SessionDir -Category (Msg '清理' 'Cleanup') -Action (Msg "清除快取：$Label" "Clear cache: $Label") -Target $Path -Result 'skipped' `
            -Note (Msg "程式執行中：$($running -join ', ')" "App running: $($running -join ', ')")
    }
    return
}
if (-not $Apply) { Msg '試跑模式：沒有刪除任何檔案。確認後加上 -Apply 執行。' 'Dry run: nothing was deleted. Add -Apply after confirming.'; return }

$before = (Get-PccDirStats $Path).Bytes
$fail = 0
Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { $fail++ }
}
$after = (Get-PccDirStats $Path).Bytes
$freed = [int64]($before - $after)
Write-PccAction -SessionDir $SessionDir -Category (Msg '清理' 'Cleanup') -Action (Msg "清除快取：$Label" "Clear cache: $Label") -Target $Path `
    -Command "clear-folder.ps1 -Path `"$Path`" -Apply" -BytesFreed $freed -Result $(if ($fail) { 'partial' } else { 'done' }) `
    -Reversible 'no' -UndoHint (Msg '快取會由程式自動重建，不需要還原' 'The app rebuilds its cache automatically; no restore needed') `
    -Note (Msg "$fail 個項目被占用而略過" "$fail items skipped (in use)")
Msg "已釋放 $(Format-PccSize $freed)，$fail 個項目被占用而略過。" "Freed $(Format-PccSize $freed); $fail items skipped (in use)."
