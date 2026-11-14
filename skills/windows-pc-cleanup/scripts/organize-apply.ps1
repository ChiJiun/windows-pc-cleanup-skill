# 依整理計畫執行。預設只試跑；加上 -Apply 才會搬移。
# Recycle 項目送資源回收筒；若指定 -QuarantineDir，則改搬到隔離資料夾（可用 organize-undo.ps1 完整還原）。
# 執行紀錄會存在工作階段資料夾，並複製一份到整理目標底下的紀錄資料夾，附上還原腳本。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [Parameter(Mandatory)][string]$Plan,
    [string]$QuarantineDir,
    [string]$RulesFile,
    [switch]$Apply,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
if (-not $RulesFile) { $RulesFile = Get-PccDefaultRulesFile }
$SessionDir = Get-PccSessionDir $SessionDir
$rows = @(Import-Csv -LiteralPath $Plan)
$rules = Read-PccJson $RulesFile
$nMove = @($rows | Where-Object Action -eq 'Move').Count; $nRec = @($rows | Where-Object Action -eq 'Recycle').Count
Msg "計畫共 $($rows.Count) 筆：搬移 $nMove、移除 $nRec" "Plan has $($rows.Count) entries: move $nMove, remove $nRec"
if (-not $Apply) { Msg '試跑模式：沒有搬動任何檔案。確認後加上 -Apply 執行。' 'Dry run: nothing was moved. Add -Apply after confirming.'; return }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = New-Object System.Collections.Generic.List[object]
$recycledBytes = [int64]0
foreach ($r in $rows) {
    $status = ''; $final = ''
    try {
        if (-not (Test-Path -LiteralPath $r.Source)) { $status = 'SKIPPED: ' + (Msg '來源已不存在' 'source no longer exists') }
        elseif ($r.Action -eq 'Move') {
            $destDir = Split-Path $r.Dest -Parent
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $final = Get-PccFreePath $r.Dest
            Move-Item -LiteralPath $r.Source -Destination $final -ErrorAction Stop
            $status = 'OK'
        } elseif ($r.Action -eq 'Recycle') {
            $item = Get-Item -LiteralPath $r.Source -Force
            $size = if ($item.PSIsContainer) { (Get-PccDirStats $item.FullName).Bytes } else { $item.Length }
            # 重複檔：執行前重新確認保留的那份還在、內容仍然相同
            $keep = if ($r.PSObject.Properties['Keep']) { $r.Keep } else { '' }
            if ($keep -and -not (Test-Path -LiteralPath $keep -PathType Leaf)) { $status = 'SKIPPED: ' + (Msg '保留的那份已不存在' 'the kept copy no longer exists'); throw [System.OperationCanceledException]::new() }
            # 讀不到檔案時讓 Get-FileHash 丟出例外，記為 FAILED 並帶出真正原因
            if ($keep -and (Get-FileHash -LiteralPath $keep -Algorithm SHA256 -ErrorAction Stop).Hash -ne (Get-FileHash -LiteralPath $r.Source -Algorithm SHA256 -ErrorAction Stop).Hash) {
                $status = 'SKIPPED: ' + (Msg '與保留的那份內容已不同' 'content now differs from the kept copy'); throw [System.OperationCanceledException]::new()
            }
            if ($QuarantineDir) {
                if (-not (Test-Path -LiteralPath $QuarantineDir)) { New-Item -ItemType Directory -Path $QuarantineDir -Force | Out-Null }
                $final = Get-PccFreePath (Join-Path $QuarantineDir $item.Name)
                Move-Item -LiteralPath $r.Source -Destination $final -ErrorAction Stop
                $status = 'OK'
            } else {
                # 放不進資源回收筒時會丟出例外並保留原檔（記為 FAILED），不會被永久刪除
                Remove-PccToRecycleBin -Path $r.Source -Bytes $size
                $final = $script:PccRecycleMarker; $status = 'OK'
            }
            $recycledBytes += $size
        }
    } catch [System.OperationCanceledException] {
        # 上面主動丟出的會先設定 SKIPPED；殼層刪除被取消（例如錯誤對話框按了取消）也是這個例外，這時記為 FAILED
        if (-not $status) { $status = 'FAILED: ' + (Msg '刪除被取消（' 'deletion was cancelled (') + $_.Exception.Message + (Msg '）' ')') }
    } catch { $status = 'FAILED: ' + $_.Exception.Message }
    $log.Add([pscustomobject]@{ Source = $r.Source; Action = $r.Action; Final = $final; Status = $status; Reason = $r.Reason })
}

$logFile = Join-Path $SessionDir "organize-log-$stamp.csv"
$log | Export-Csv -LiteralPath $logFile -NoTypeInformation -Encoding UTF8
# 在整理目標底下留一份紀錄與還原腳本，工作階段資料夾被刪掉也能還原
$firstSource = ($rows | Select-Object -First 1).Source
$targetRoot = if ($firstSource) { Split-Path $firstSource -Parent } else { $null }
$keepCopy = ''
if ($targetRoot -and $rules.logFolder) {
    $keepDir = Join-Path $targetRoot $rules.logFolder
    New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
    Copy-Item -LiteralPath $logFile -Destination $keepDir
    Copy-Item -LiteralPath $Plan -Destination $keepDir
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'organize-undo.ps1') -Destination (Join-Path $keepDir 'organize-undo.ps1') -Force
    $keepCopy = Join-Path $keepDir (Split-Path $logFile -Leaf)
}

$ok = @($log | Where-Object Status -eq 'OK').Count
$failed = @($log | Where-Object { $_.Status -like 'FAILED*' }).Count
$skipped = @($log | Where-Object { $_.Status -like 'SKIPPED*' }).Count
$undoLog = if ($keepCopy) { $keepCopy } else { $logFile }
$cmd = 'organize-apply.ps1 -Plan "' + $Plan + '" -Apply'
if ($QuarantineDir) { $cmd += ' -QuarantineDir "' + $QuarantineDir + '"' }
Write-PccAction -SessionDir $SessionDir -Category (Msg '檔案整理' 'File organization') -Action (Msg "整理 $targetRoot" "Organize $targetRoot") -Target $targetRoot `
    -Command $cmd `
    -BytesFreed 0 -Result $(if ($failed) { 'partial' } else { 'done' }) -Reversible 'undo-script' `
    -UndoHint ("powershell -ExecutionPolicy Bypass -File `"$(Join-Path (Split-Path $undoLog -Parent) 'organize-undo.ps1')`" -Log `"$undoLog`" -Apply" + (Msg '；送資源回收筒的項目請從資源回收筒還原' '; restore Recycle Bin items from the Recycle Bin')) `
    -Evidence (Split-Path $logFile -Leaf) -Note (Msg "成功 $ok、失敗 $failed、略過 $skipped；移除項目共 $(Format-PccSize $recycledBytes)（在資源回收筒清空前不會釋放空間）" "OK $ok, failed $failed, skipped $skipped; removed items total $(Format-PccSize $recycledBytes) (space is not freed until the Recycle Bin is emptied)")
Msg "成功 $ok、失敗 $failed、略過 $skipped。紀錄：$logFile" "OK $ok, failed $failed, skipped $skipped. Log: $logFile"
if ($keepCopy) { Msg "還原用的紀錄與腳本另存在：$(Split-Path $keepCopy -Parent)" "A copy of the log and undo script is also saved in: $(Split-Path $keepCopy -Parent)" }
