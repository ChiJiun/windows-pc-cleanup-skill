# 依 organize-apply.ps1 的執行紀錄，把搬移過（含隔離資料夾）的項目搬回原位。
# 送進資源回收筒的項目請從資源回收筒手動「還原」。預設只試跑；加上 -Apply 才執行。
# 有任何項目沒有還原（失敗、找不到或原位置已有同名項目）時，結束代碼為 1。
# 刻意不載入 common.ps1，讓這支腳本單獨複製出去也能用。
param(
    [Parameter(Mandatory)][string]$Log,
    [switch]$Apply,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
if (-not $Lang) {
    $Lang = if ($env:PCC_LANG -in 'zh-TW', 'en') { $env:PCC_LANG } elseif ((Get-UICulture).Name -like 'zh*') { 'zh-TW' } else { 'en' }
}
function Msg([string]$Zh, [string]$En) { if ($Lang -eq 'en') { $En } else { $Zh } }

# 資源回收筒標記：新版寫 (RecycleBin)；舊版紀錄寫 (資源回收筒)，用字元碼組出來以免檔案編碼影響比對
$binMarkers = @('(RecycleBin)', ('(' + -join ([char[]](0x8CC7, 0x6E90, 0x56DE, 0x6536, 0x7B52)) + ')'))

$all = @(Import-Csv -LiteralPath $Log)
$rows = @($all | Where-Object { $_.Status -eq 'OK' -and $_.Final -and ($binMarkers -notcontains $_.Final) })
[array]::Reverse($rows)
$inBin = @($all | Where-Object { $_.Status -eq 'OK' -and ($binMarkers -contains $_.Final) }).Count
Msg "可還原 $($rows.Count) 筆；另有 $inBin 筆在資源回收筒，需手動還原。" "$($rows.Count) entries can be restored; $inBin more are in the Recycle Bin and must be restored by hand."
if (-not $Apply) { Msg '試跑模式：沒有搬動任何檔案。確認後加上 -Apply 執行。' 'Dry run: nothing was moved. Add -Apply to run it after you confirm.'; return }
$ok = 0; $skip = 0; $fail = 0
foreach ($r in $rows) {
    if (Test-Path -LiteralPath $r.Source) { Msg "略過（原位置已有同名項目）：$($r.Source)" "Skipped (an item with the same name is already at the original location): $($r.Source)"; $skip++; continue }
    if (-not (Test-Path -LiteralPath $r.Final)) { Msg "略過（找不到）：$($r.Final)" "Skipped (not found): $($r.Final)"; $skip++; continue }
    try {
        $parent = Split-Path $r.Source -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        Move-Item -LiteralPath $r.Final -Destination $r.Source -ErrorAction Stop
        $ok++
    } catch { Msg "失敗：$($r.Final) → $($r.Source)：$($_.Exception.Message)" "Failed: $($r.Final) → $($r.Source): $($_.Exception.Message)"; $fail++ }
}
Msg "已還原 $ok 筆，略過 $skip 筆，失敗 $fail 筆。" "Restored $ok, skipped $skip, failed $fail."
# 有任何項目沒有回到原位（失敗或略過）就回傳 1，讓呼叫端知道還原不完整
if ($fail -gt 0 -or $skip -gt 0) { exit 1 }
