# 依 organize-apply.ps1 的執行紀錄，把搬移過（含隔離資料夾）的項目搬回原位。
# 送進資源回收筒的項目請從資源回收筒手動「還原」。預設只試跑；加上 -Apply 才執行。
# 有任何項目沒有還原（失敗、找不到或原位置已有同名項目）時，結束代碼為 1。
param([Parameter(Mandatory)][string]$Log, [switch]$Apply)
$rows = @(Import-Csv -LiteralPath $Log | Where-Object { $_.Status -eq 'OK' -and $_.Final -and $_.Final -ne '(資源回收筒)' })
[array]::Reverse($rows)
$inBin = @(Import-Csv -LiteralPath $Log | Where-Object { $_.Status -eq 'OK' -and $_.Final -eq '(資源回收筒)' }).Count
"可還原 $($rows.Count) 筆；另有 $inBin 筆在資源回收筒，需手動還原。"
if (-not $Apply) { '試跑模式：沒有搬動任何檔案。確認後加上 -Apply 執行。'; return }
$ok = 0; $skip = 0; $fail = 0
foreach ($r in $rows) {
    if (Test-Path -LiteralPath $r.Source) { "略過（原位置已有同名項目）：$($r.Source)"; $skip++; continue }
    if (-not (Test-Path -LiteralPath $r.Final)) { "略過（找不到）：$($r.Final)"; $skip++; continue }
    try {
        $parent = Split-Path $r.Source -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        Move-Item -LiteralPath $r.Final -Destination $r.Source -ErrorAction Stop
        $ok++
    } catch { "失敗：$($r.Final) → $($r.Source)：$($_.Exception.Message)"; $fail++ }
}
"已還原 $ok 筆，略過 $skip 筆，失敗 $fail 筆。"
# 有任何項目沒有回到原位（失敗或略過）就回傳 1，讓呼叫端知道還原不完整
if ($fail -gt 0 -or $skip -gt 0) { exit 1 }
