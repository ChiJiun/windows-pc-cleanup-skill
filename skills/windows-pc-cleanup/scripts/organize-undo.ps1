# 依 organize-apply.ps1 的執行紀錄，把搬移過（含隔離資料夾）的項目搬回原位。
# 送進資源回收筒的項目請從資源回收筒手動「還原」。預設只試跑；加上 -Apply 才執行。
param([Parameter(Mandatory)][string]$Log, [switch]$Apply)
$rows = @(Import-Csv -LiteralPath $Log | Where-Object { $_.Status -eq 'OK' -and $_.Final -and $_.Final -ne '(資源回收筒)' })
[array]::Reverse($rows)
$inBin = @(Import-Csv -LiteralPath $Log | Where-Object { $_.Final -eq '(資源回收筒)' }).Count
"可還原 $($rows.Count) 筆；另有 $inBin 筆在資源回收筒，需手動還原。"
if (-not $Apply) { '試跑模式：沒有搬動任何檔案。確認後加上 -Apply 執行。'; return }
$ok = 0; $skip = 0
foreach ($r in $rows) {
    if (Test-Path -LiteralPath $r.Source) { "略過（原位置已有同名項目）：$($r.Source)"; $skip++; continue }
    if (-not (Test-Path -LiteralPath $r.Final)) { "略過（找不到）：$($r.Final)"; $skip++; continue }
    $parent = Split-Path $r.Source -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -LiteralPath $r.Final -Destination $r.Source
    $ok++
}
"已還原 $ok 筆，略過 $skip 筆。"
