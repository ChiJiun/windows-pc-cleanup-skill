# 產生 HTML 總整報告：清理成果、健康檢查、檔案整理、待決定事項，以及溯源與還原方式。
# 只讀取工作階段資料夾內的檔案；產生單一、完全離線的 HTML（不載入任何外部資源）。
# 報告語言依 -Lang（或工作階段記錄的語言）；動作內容沿用紀錄當下寫入的文字。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [string]$Out,
    [string]$Title,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
if (-not $Out) { $Out = Join-Path $SessionDir 'report.html' }
if (-not $Title) { $Title = Msg '電腦清理與健康檢查報告' 'PC Cleanup and Health Report' }

function Enc([object]$s) { if ($null -eq $s) { return '' }; [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Sz([double]$b) { if ($b -le 0) { return '—' }; Format-PccSize $b }
$bar = Msg '｜' ' | '

$baseline = Read-PccJson (Join-Path $SessionDir 'baseline.json')
$overview = Read-PccJson (Join-Path $SessionDir 'overview.json')
$health = Read-PccJson (Join-Path $SessionDir 'health.json')
$targets = Read-PccJson (Join-Path $SessionDir 'cleanup-targets.json')
$large = Read-PccJson (Join-Path $SessionDir 'large-items.json')
$startup = Read-PccJson (Join-Path $SessionDir 'startup.json')
$actions = @(Read-PccActions $SessionDir)
$nowDrives = @(Get-PccDriveSnapshot)

$resultLabel = @{ done = (Msg '完成' 'Done'); partial = (Msg '部分完成' 'Partial'); skipped = (Msg '略過' 'Skipped'); failed = (Msg '失敗' 'Failed'); pending = (Msg '待決定' 'Pending') }
$revLabel = @{ yes = (Msg '可還原' 'Reversible'); 'recycle-bin' = (Msg '資源回收筒' 'Recycle Bin'); 'undo-script' = (Msg '還原腳本' 'Undo script'); reinstall = (Msg '重新安裝' 'Reinstall'); no = (Msg '不可還原' 'Not reversible') }
$sevLabel = @{ critical = (Msg '嚴重' 'Critical'); warn = (Msg '注意' 'Warning'); info = (Msg '資訊' 'Info') }

$executed = @($actions | Where-Object { $_.result -in 'done', 'partial', 'failed' })
$notDone = @($actions | Where-Object { $_.result -in 'skipped', 'pending' })
$recordedFreed = [int64](($executed | Measure-Object bytesFreed -Sum).Sum)
$findings = if ($health) { @($health.findings) } else { @() }

$sb = New-Object System.Text.StringBuilder
function A([string]$s) { [void]$sb.AppendLine($s) }

$css = @'
:root{--bg:#f7f7f5;--card:#ffffff;--text:#1d1d1b;--muted:#6b6b66;--line:#e3e2dc;--accent:#2f5d8a;--ok:#2e7d4f;--warn:#a86400;--bad:#b3261e;--info:#4a5d73;--chip:#efeee9}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#161615;--card:#1f1f1d;--text:#ecebe6;--muted:#a3a29b;--line:#34332f;--accent:#8fb6dd;--ok:#7cc79a;--warn:#e0a54a;--bad:#ef8a80;--info:#a9b8c9;--chip:#2a2a27}}
:root[data-theme="dark"]{--bg:#161615;--card:#1f1f1d;--text:#ecebe6;--muted:#a3a29b;--line:#34332f;--accent:#8fb6dd;--ok:#7cc79a;--warn:#e0a54a;--bad:#ef8a80;--info:#a9b8c9;--chip:#2a2a27}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 "Segoe UI","Microsoft JhengHei","Noto Sans TC",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 16px 64px}h1{font-size:26px;margin:0 0 4px}h2{font-size:19px;margin:40px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}h3{font-size:16px;margin:20px 0 8px}
.meta{color:var(--muted);font-size:13px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}.card .k{color:var(--muted);font-size:13px}.card .v{font-size:22px;font-weight:600;margin-top:2px}.card .s{font-size:13px;color:var(--muted)}
.pos{color:var(--ok)}.neg{color:var(--bad)}.tbl{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:13.5px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;white-space:nowrap;background:var(--chip)}tr:last-child td{border-bottom:0}
td.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}code{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px;background:var(--chip);padding:1px 5px;border-radius:4px;word-break:break-all}
.chip{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;background:var(--chip);white-space:nowrap}.c-critical,.c-failed{color:var(--bad)}.c-warn,.c-partial,.c-pending{color:var(--warn)}.c-info,.c-skipped{color:var(--info)}.c-done{color:var(--ok)}
.finding{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--info);border-radius:8px;padding:10px 14px;margin:8px 0}.finding.critical{border-left-color:var(--bad)}.finding.warn{border-left-color:var(--warn)}.finding .t{font-weight:600}.finding .d,.finding .a{font-size:13.5px;color:var(--muted)}
.note{font-size:13px;color:var(--muted);margin:8px 0}ol,ul{padding-left:22px}li{margin:4px 0}
@media print{body{background:#fff}.card,.tbl,.finding{break-inside:avoid}}
'@

A ('<!doctype html><html lang="{0}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' -f (Msg 'zh-Hant' 'en'))
A "<title>$(Enc $Title)</title><style>$css</style></head><body><main>"
A "<h1>$(Enc $Title)</h1>"
A (("<div class=""meta"">{0} {1}$bar{2} {3}$bar{4} {5}$bar" -f (Msg '產生時間' 'Generated'), (Enc (Get-Date).ToString('yyyy-MM-dd HH:mm')), (Msg '電腦' 'Computer'), (Enc $env:COMPUTERNAME), (Msg '工作階段開始' 'Session started'), (Enc $(if ($baseline) { $baseline.createdAt } else { Msg '未知' 'unknown' }))) + "skill v$(Enc $script:PccVersion)</div>")
if ($overview) { A ("<div class=""meta"">{0}$bar{1}$bar{2}$bar{3} {4}</div>" -f (Enc $overview.os), (Enc $overview.model), (Enc $overview.cpu), (Msg '記憶體' 'RAM'), (Enc (Sz $overview.ramTotalBytes))) }
if ($baseline -and $baseline.PSObject.Properties['note'] -and $baseline.note) { A ("<p class=""note"">{0}{1}</p>" -f (Msg '起始值說明：' 'About the starting values: '), (Enc $baseline.note)) }

# ---- 摘要 ----
A ('<h2>{0}</h2><div class="grid">' -f (Msg '一、摘要' '1. Summary'))
foreach ($d in $nowDrives) {
    $b = if ($baseline) { $baseline.drives | Where-Object Drive -eq $d.Drive | Select-Object -First 1 } else { $null }
    $k = Msg "$($d.Drive) 可用空間" "$($d.Drive) free space"
    if ($b) {
        $delta = [int64]$d.FreeBytes - [int64]$b.FreeBytes
        $cls = if ($delta -ge 0) { 'pos' } else { 'neg' }
        $sign = if ($delta -ge 0) { '+' } else { '−' }
        A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2} {3}$bar<span class=""{4}"">{5}{6}</span></div></div>" -f (Enc $k), (Enc (Sz $d.FreeBytes)), (Msg '開始時' 'At start'), (Enc (Sz $b.FreeBytes)), $cls, $sign, (Enc (Format-PccSize ([math]::Abs($delta)))))
    } else {
        A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2}</div></div>" -f (Enc $k), (Enc (Sz $d.FreeBytes)), (Msg '沒有開始時的紀錄' 'No starting record'))
    }
}
A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2}</div></div>" -f (Msg '紀錄中的釋放量合計' 'Total freed (recorded)'), (Enc (Sz $recordedFreed)), (Msg '依各動作前後實測加總' 'Sum of measured before/after differences'))
A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2} {3}$bar{4} {5}$bar{6} {7}</div></div>" -f (Msg '已執行的動作' 'Actions executed'), $executed.Count, (Msg '略過' 'Skipped'), @($actions | Where-Object result -eq 'skipped').Count, (Msg '待決定' 'Pending'), @($actions | Where-Object result -eq 'pending').Count, (Msg '失敗' 'Failed'), @($actions | Where-Object result -eq 'failed').Count)
if ($health) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1} {2}</div><div class=""s""><span class=""c-critical"">{3} {4}</span>$bar<span class=""c-warn"">{5} {6}</span>$bar{7} {8}</div></div>" -f (Msg '健康檢查' 'Health check'), $findings.Count, (Msg '項發現' 'findings'), $sevLabel.critical, @($findings | Where-Object Severity -eq 'critical').Count, $sevLabel.warn, @($findings | Where-Object Severity -eq 'warn').Count, $sevLabel.info, @($findings | Where-Object Severity -eq 'info').Count) }
A '</div>'
A ('<p class="note">{0}</p>' -f (Msg '磁碟增減是「現在」與「工作階段開始時」的實測差值；期間若有其他程式寫入（例如下載、編譯、AI 工具暫存），差值會被抵銷。送進資源回收筒的項目在清空前不會釋放空間。' 'Drive changes are measured differences between now and the start of the session; other programs writing at the same time (downloads, builds, AI tool temp files) offset them. Items in the Recycle Bin free no space until it is emptied.'))

# ---- 執行紀錄 ----
A ('<h2>{0}</h2>' -f (Msg '二、清理與變更紀錄' '2. Cleanup and change log'))
if ($executed.Count) {
    A ('<div class="tbl"><table><thead><tr><th>{0}</th><th>{1}</th><th>{2}</th><th>{3}</th><th>{4}</th><th>{5}</th><th>{6}</th></tr></thead><tbody>' -f (Msg '時間' 'Time'), (Msg '類別' 'Category'), (Msg '動作與對象' 'Action and target'), (Msg '釋放' 'Freed'), (Msg '結果' 'Result'), (Msg '還原' 'Undo'), (Msg '證據' 'Evidence'))
    foreach ($a in $executed) {
        $t = try { ([datetime]$a.time).ToString('MM-dd HH:mm') } catch { $a.time }
        $what = "<div>$(Enc $a.action)</div>"
        if ($a.target) { $what += "<div><code>$(Enc $a.target)</code></div>" }
        if ($a.command) { $what += "<div class=""note"">$(Msg '指令：' 'Command: ')<code>$(Enc $a.command)</code></div>" }
        if ($a.note) { $what += "<div class=""note"">$(Enc $a.note)</div>" }
        $undo = "<span class=""chip"">$(Enc $revLabel[$a.reversible])</span>"
        if ($a.undoHint) { $undo += "<div class=""note"">$(Enc $a.undoHint)</div>" }
        A ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=""num"">{3}</td><td><span class=""chip c-{4}"">{5}</span></td><td>{6}</td><td>{7}</td></tr>" -f (Enc $t), (Enc $a.category), $what, (Enc (Sz $a.bytesFreed)), (Enc $a.result), (Enc $resultLabel[$a.result]), $undo, $(if ($a.evidence) { "<code>$(Enc $a.evidence)</code>" } else { '' }))
    }
    A '</tbody></table></div>'
} else { A ('<p class="note">{0}</p>' -f (Msg '這個工作階段沒有執行任何清理或變更。' 'No cleanup or changes were made in this session.')) }

# ---- 待決定與略過 ----
A ('<h2>{0}</h2>' -f (Msg '三、略過與待決定的項目' '3. Skipped and pending items'))
if ($notDone.Count) {
    A ('<div class="tbl"><table><thead><tr><th>{0}</th><th>{1}</th><th>{2}</th><th>{3}</th></tr></thead><tbody>' -f (Msg '狀態' 'Status'), (Msg '類別' 'Category'), (Msg '項目' 'Item'), (Msg '原因與建議' 'Reason and advice'))
    foreach ($a in $notDone) {
        A ("<tr><td><span class=""chip c-{0}"">{1}</span></td><td>{2}</td><td>{3}{4}</td><td>{5}</td></tr>" -f (Enc $a.result), (Enc $resultLabel[$a.result]), (Enc $a.category), (Enc $a.action), $(if ($a.target) { "<div><code>$(Enc $a.target)</code></div>" } else { '' }), (Enc $a.note))
    }
    A '</tbody></table></div>'
} else { A ('<p class="note">{0}</p>' -f (Msg '沒有略過或待決定的項目。' 'No skipped or pending items.')) }

# ---- 健康檢查 ----
A ('<h2>{0}</h2>' -f (Msg '四、軟硬體健康檢查' '4. Hardware and software health'))
if ($health) {
    A ("<p class=""note"">{0} {1}$bar{2}</p>" -f (Msg '檢查時間' 'Checked at'), (Enc $health.collectedAt), (Enc (Msg "已開機 $($health.uptimeHours) 小時" "Up $($health.uptimeHours) hours")))
    if ($findings.Count) {
        foreach ($f in $findings) {
            A ("<div class=""finding {0}""><div class=""t""><span class=""chip c-{0}"">{1}</span> {2}$bar{3}</div>{4}{5}</div>" -f (Enc $f.Severity), (Enc $sevLabel[$f.Severity]), (Enc $f.Area), (Enc $f.Title), $(if ($f.Detail) { "<div class=""d"">$(Enc $f.Detail)</div>" } else { '' }), $(if ($f.Advice) { "<div class=""a"">$(Msg '建議：' 'Advice: ')$(Enc $f.Advice)</div>" } else { '' }))
        }
    } else { A ('<p>{0}</p>' -f (Msg '沒有發現異常。' 'No problems found.')) }
    A '<div class="grid">'
    if ($health.cpu) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}%</div><div class=""s"">{2} {3}%$bar{4} {5}%</div></div>" -f (Msg 'CPU（取樣平均）' 'CPU (sampled average)'), (Enc $health.cpu.totalPercent), (Msg '核心態' 'Kernel'), (Enc $health.cpu.privilegedPercent), (Msg '使用者態' 'User'), (Enc $health.cpu.userPercent)) }
    if ($health.memory) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}%</div><div class=""s"">{2} {3}%</div></div>" -f (Msg '記憶體' 'Memory'), (Enc $health.memory.usedPercent), (Msg '已認可' 'Committed'), (Enc $health.memory.commitPercent)) }
    if ($health.battery) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}%</div><div class=""s"">{2} / {3} mWh</div></div>" -f (Msg '電池健康度' 'Battery health'), (Enc $health.battery.healthPercent), (Enc $health.battery.fullChargeMWh), (Enc $health.battery.designMWh)) }
    foreach ($d in @($health.disks)) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2}</div></div>" -f (Enc $d.Name), (Enc $d.Health), (Enc $d.Status)) }
    if ($health.defender) { A ("<div class=""card""><div class=""k"">Defender</div><div class=""v"">{0}</div><div class=""s"">{1} {2}</div></div>" -f $(if ($health.defender.realTime) { Msg '即時保護開啟' 'Real-time protection on' } else { Msg '即時保護關閉' 'Real-time protection off' }), (Msg '病毒碼' 'Definitions'), (Enc $health.defender.signatureUpdated)) }
    A '</div>'
    if ($health.cpu -and $health.cpu.topProcesses) {
        A ('<h3>{0}</h3><div class="tbl"><table><thead><tr><th>{1}</th><th>CPU %</th><th>{2}</th></tr></thead><tbody>' -f (Msg 'CPU 使用最多的程式' 'Top CPU consumers'), (Msg '程式' 'Program'), (Msg '程序數' 'Processes'))
        foreach ($p in ($health.cpu.topProcesses | Select-Object -First 8)) { A ("<tr><td>{0}</td><td class=""num"">{1}</td><td class=""num"">{2}</td></tr>" -f (Enc $p.Name), (Enc $p.CpuPercent), (Enc $p.Instances)) }
        A '</tbody></table></div>'
    }
} else { A ('<p class="note">{0}</p>' -f (Msg '這個工作階段沒有執行健康檢查（health-check.ps1）。' 'No health check (health-check.ps1) was run in this session.')) }

# ---- 檔案整理 ----
$orgLogs = @(Get-ChildItem -LiteralPath $SessionDir -Filter 'organize-log-*.csv' -ErrorAction SilentlyContinue)
if ($orgLogs.Count) {
    A ('<h2>{0}</h2>' -f (Msg '五、檔案整理' '5. File organization'))
    foreach ($lf in $orgLogs) {
        $rows = @(Import-Csv -LiteralPath $lf.FullName)
        A ("<h3>{0}</h3>" -f (Enc $lf.Name))
        A ('<div class="tbl"><table><thead><tr><th>{0}</th><th>{1}</th></tr></thead><tbody>' -f (Msg '去向' 'Destination'), (Msg '數量' 'Count'))
        $rows | Where-Object Status -eq 'OK' | Group-Object { if ($_.Action -eq 'Move') { Split-Path (Split-Path $_.Final -Parent) -Leaf } elseif ($script:PccRecycleMarkers -contains $_.Final) { Msg '→ 資源回收筒' '→ Recycle Bin' } else { Msg '→ 隔離資料夾' '→ Quarantine folder' } } | Sort-Object Name | ForEach-Object { A ("<tr><td>{0}</td><td class=""num"">{1}</td></tr>" -f (Enc $_.Name), $_.Count) }
        A '</tbody></table></div>'
        $bad = @($rows | Where-Object Status -ne 'OK')
        if ($bad.Count) { A ('<p class="note">{0}</p>' -f (Enc (Msg "未成功 $($bad.Count) 筆，詳見紀錄檔。" "$($bad.Count) entries did not succeed; see the log file."))) }
    }
}

# ---- 掃描摘要 ----
A ('<h2>{0}</h2>' -f (Msg '六、掃描摘要' '6. Scan summary'))
if ($targets -and $targets.targets) {
    A ('<h3>{0}</h3><div class="tbl"><table><thead><tr><th>{1}</th><th>{2}</th><th>{3}</th><th>{4}</th><th>{5}</th></tr></thead><tbody>' -f (Msg '暫存與快取（掃描當下）' 'Temp files and caches (at scan time)'), (Msg '項目' 'Item'), (Msg '風險' 'Risk'), (Msg '大小' 'Size'), (Msg '實際位置' 'Real location'), (Msg '建議做法' 'Suggested method'))
    foreach ($t in ($targets.targets | Select-Object -First 20)) { A ("<tr><td>{0}</td><td>{1}</td><td class=""num"">{2}</td><td><code>{3}</code></td><td>{4}</td></tr>" -f (Enc $t.Name), (Enc $t.Risk), (Enc (Sz $t.Bytes)), (Enc $t.RealPath), (Enc $t.Method)) }
    A '</tbody></table></div>'
}
if ($large -and $large.largeFiles) {
    A ('<h3>{0}</h3><div class="tbl"><table><thead><tr><th>{1}</th><th>{2}</th><th>{3}</th></tr></thead><tbody>' -f (Msg '大型檔案（前 15 個）' 'Large files (top 15)'), (Msg '大小' 'Size'), (Msg '最後修改' 'Last modified'), (Msg '路徑' 'Path'))
    foreach ($l in ($large.largeFiles | Select-Object -First 15)) { A ("<tr><td class=""num"">{0}</td><td>{1}</td><td><code>{2}</code></td></tr>" -f (Enc (Sz $l.Bytes)), (Enc $l.LastWrite), (Enc $l.Path)) }
    A '</tbody></table></div>'
}
if ($startup) {
    $nEn = @($startup.startup | Where-Object State -eq 'enabled').Count; $nDis = @($startup.startup | Where-Object State -eq 'disabled').Count; $nTask = @($startup.scheduledTasks).Count
    A ('<p class="note">{0}</p>' -f (Enc (Msg "開機啟動：啟用 $nEn 項、已停用 $nDis 項；登入/開機觸發的非微軟排程工作 $nTask 項。" "Startup: $nEn enabled, $nDis disabled; $nTask non-Microsoft scheduled tasks triggered at logon/boot.")))
}
if (-not ($targets -or $large -or $startup)) { A ('<p class="note">{0}</p>' -f (Msg '沒有掃描資料。' 'No scan data.')) }

# ---- 溯源 ----
A ('<h2>{0}</h2>' -f (Msg '七、溯源方式' '7. Traceability'))
A ("<p>{0}<code>{1}</code></p>" -f (Msg '所有原始資料都在工作階段資料夾：' 'All raw data is in the session folder: '), (Enc $SessionDir))
A '<ol>'
A (Msg '<li><b>每個動作都有一筆紀錄。</b><code>actions.jsonl</code> 一行一筆 JSON，欄位：<code>time</code> 時間、<code>category</code> 類別、<code>action</code> 動作、<code>target</code> 對象路徑、<code>command</code> 實際執行的指令、<code>bytesFreed</code> 實測釋放位元組、<code>result</code> 結果、<code>reversible</code> 可否還原、<code>undoHint</code> 還原方式、<code>evidence</code> 明細檔名、<code>user</code>／<code>host</code> 執行者與電腦。</li>' '<li><b>Every action has a record.</b> <code>actions.jsonl</code> holds one JSON object per line with fields: <code>time</code>, <code>category</code>, <code>action</code>, <code>target</code> (path), <code>command</code> (what actually ran), <code>bytesFreed</code> (measured), <code>result</code>, <code>reversible</code>, <code>undoHint</code>, <code>evidence</code> (detail file name), and <code>user</code>/<code>host</code>.</li>')
A (Msg '<li><b>逐檔明細。</b>刪除舊檔的動作會留下 <code>clean-old-files-*.log</code>（每行：狀態、大小、完整路徑）；檔案整理會留下 <code>organize-plan-*.csv</code>（執行前的計畫）與 <code>organize-log-*.csv</code>（每個檔案的原位置、新位置、狀態）。</li>' '<li><b>Per-file details.</b> Deleting old files leaves <code>clean-old-files-*.log</code> (status, size, full path per line); file organization leaves <code>organize-plan-*.csv</code> (the plan before running) and <code>organize-log-*.csv</code> (original location, new location and status of every file).</li>')
A (Msg '<li><b>掃描與健檢的原始數據。</b><code>baseline.json</code>（開始時的磁碟空間）、<code>overview.json</code>、<code>cleanup-targets.json</code>、<code>large-items.json</code>、<code>startup.json</code>、<code>health.json</code>、<code>battery-report.xml</code>。</li>' '<li><b>Raw scan and health data.</b> <code>baseline.json</code> (free space at the start), <code>overview.json</code>, <code>cleanup-targets.json</code>, <code>large-items.json</code>, <code>startup.json</code>, <code>health.json</code>, <code>battery-report.xml</code>.</li>')
A (Msg '<li><b>確認檔案沒被改過。</b>下表列出產生報告當下每個檔案的 SHA256；之後若懷疑紀錄被動過，可用 <code>Get-FileHash 檔名 -Algorithm SHA256</code> 比對。</li>' '<li><b>Verify nothing was altered.</b> The table lists each file''s SHA256 when the report was generated; if you suspect a record was changed later, compare with <code>Get-FileHash &lt;file&gt; -Algorithm SHA256</code>.</li>')
A '</ol>'
A ('<div class="tbl"><table><thead><tr><th>{0}</th><th>{1}</th><th>{2}</th><th>SHA256</th></tr></thead><tbody>' -f (Msg '檔案' 'File'), (Msg '大小' 'Size'), (Msg '修改時間' 'Modified'))
Get-ChildItem -LiteralPath $SessionDir -File | Where-Object { $_.FullName -ne $Out } | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    A ("<tr><td><code>{0}</code></td><td class=""num"">{1}</td><td>{2}</td><td><code>{3}</code></td></tr>" -f (Enc $_.Name), (Enc (Format-PccSize $_.Length)), (Enc $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')), (Enc $hash))
}
A '</tbody></table></div>'
A ('<h3>{0}</h3><ul>' -f (Msg '如何還原' 'How to undo'))
A ('<li><span class="chip">{0}</span> {1}</li>' -f $revLabel['recycle-bin'], (Msg '打開資源回收筒，對項目按右鍵選「還原」。清空資源回收筒後就無法還原。' 'Open the Recycle Bin, right-click the item and choose Restore. Once the Recycle Bin is emptied it cannot be restored.'))
A ('<li><span class="chip">{0}</span> {1}</li>' -f $revLabel['undo-script'], (Msg '依該筆紀錄的「還原方式」執行 <code>organize-undo.ps1 -Log &lt;紀錄檔&gt; -Apply</code>，會把搬過的檔案逐一搬回原位（先不加 -Apply 可以試跑）。' 'Run <code>organize-undo.ps1 -Log &lt;log file&gt; -Apply</code> as given in the record''s undo hint; it moves files back one by one (omit -Apply for a dry run).'))
A ('<li><span class="chip">{0}</span> {1}</li>' -f $revLabel['reinstall'], (Msg '已解除安裝的軟體需從官方網站或啟動器重新安裝；遊戲與模擬器內的資料不一定能救回。' 'Uninstalled software must be reinstalled from the official site or launcher; data inside games and emulators may not be recoverable.'))
A ('<li><span class="chip">{0}</span> {1}</li>' -f $revLabel['no'], (Msg '快取與暫存檔會由程式自動重建；永久刪除的虛擬機、資源回收筒內容無法救回。' 'Caches and temp files are rebuilt automatically; permanently deleted virtual machines and emptied Recycle Bin contents cannot be recovered.'))
A '</ul>'
A ("<p class=""note"">{0}<code>powershell -ExecutionPolicy Bypass -File build-report.ps1 -SessionDir ""{1}""</code>{2}</p>" -f (Msg '重新產生這份報告：' 'Regenerate this report: '), (Enc $SessionDir), (Msg '。報告含本機路徑與檔名，分享前請自行檢查。' '. The report contains local paths and file names; review it before sharing.'))
A '</main></body></html>'

[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
Msg "報告已產生：$Out" "Report generated: $Out"
