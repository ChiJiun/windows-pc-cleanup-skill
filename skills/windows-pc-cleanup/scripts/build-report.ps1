# 產生 HTML 總整報告：清理成果、健康檢查、檔案整理、待決定事項，以及溯源與還原方式。
# 只讀取工作階段資料夾內的檔案；產生單一、完全離線的 HTML（不載入任何外部資源）。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [string]$Out,
    [string]$Title = '電腦清理與健康檢查報告'
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
if (-not $Out) { $Out = Join-Path $SessionDir 'report.html' }

function Enc([object]$s) { if ($null -eq $s) { return '' }; [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Sz([double]$b) { if ($b -le 0) { return '—' }; Format-PccSize $b }

$baseline = Read-PccJson (Join-Path $SessionDir 'baseline.json')
$overview = Read-PccJson (Join-Path $SessionDir 'overview.json')
$health = Read-PccJson (Join-Path $SessionDir 'health.json')
$targets = Read-PccJson (Join-Path $SessionDir 'cleanup-targets.json')
$large = Read-PccJson (Join-Path $SessionDir 'large-items.json')
$startup = Read-PccJson (Join-Path $SessionDir 'startup.json')
$actions = @(Read-PccActions $SessionDir)
$nowDrives = @(Get-PccDriveSnapshot)

$resultLabel = @{ done = '完成'; partial = '部分完成'; skipped = '略過'; failed = '失敗'; pending = '待決定' }
$revLabel = @{ yes = '可還原'; 'recycle-bin' = '資源回收筒'; 'undo-script' = '還原腳本'; reinstall = '重新安裝'; no = '不可還原' }
$sevLabel = @{ critical = '嚴重'; warn = '注意'; info = '資訊' }

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

A '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
A "<title>$(Enc $Title)</title><style>$css</style></head><body><main>"
A "<h1>$(Enc $Title)</h1>"
A ("<div class=""meta"">產生時間 {0}｜電腦 {1}｜工作階段開始 {2}｜skill v{3}</div>" -f (Enc (Get-Date).ToString('yyyy-MM-dd HH:mm')), (Enc $env:COMPUTERNAME), (Enc $(if ($baseline) { $baseline.createdAt } else { '未知' })), (Enc $script:PccVersion))
if ($overview) { A ("<div class=""meta"">{0}｜{1}｜{2}｜記憶體 {3}</div>" -f (Enc $overview.os), (Enc $overview.model), (Enc $overview.cpu), (Enc (Sz $overview.ramTotalBytes))) }

# ---- 摘要 ----
A '<h2>一、摘要</h2><div class="grid">'
foreach ($d in $nowDrives) {
    $b = if ($baseline) { $baseline.drives | Where-Object Drive -eq $d.Drive | Select-Object -First 1 } else { $null }
    if ($b) {
        $delta = [int64]$d.FreeBytes - [int64]$b.FreeBytes
        $cls = if ($delta -ge 0) { 'pos' } else { 'neg' }
        $sign = if ($delta -ge 0) { '+' } else { '−' }
        A ("<div class=""card""><div class=""k"">{0} 可用空間</div><div class=""v"">{1}</div><div class=""s"">開始時 {2}｜<span class=""{3}"">{4}{5}</span></div></div>" -f (Enc $d.Drive), (Enc (Sz $d.FreeBytes)), (Enc (Sz $b.FreeBytes)), $cls, $sign, (Enc (Format-PccSize ([math]::Abs($delta)))))
    } else {
        A ("<div class=""card""><div class=""k"">{0} 可用空間</div><div class=""v"">{1}</div><div class=""s"">沒有開始時的紀錄</div></div>" -f (Enc $d.Drive), (Enc (Sz $d.FreeBytes)))
    }
}
A ("<div class=""card""><div class=""k"">紀錄中的釋放量合計</div><div class=""v"">{0}</div><div class=""s"">依各動作前後實測加總</div></div>" -f (Enc (Sz $recordedFreed)))
A ("<div class=""card""><div class=""k"">已執行的動作</div><div class=""v"">{0}</div><div class=""s"">略過 {1}｜待決定 {2}｜失敗 {3}</div></div>" -f $executed.Count, @($actions | Where-Object result -eq 'skipped').Count, @($actions | Where-Object result -eq 'pending').Count, @($actions | Where-Object result -eq 'failed').Count)
if ($health) { A ("<div class=""card""><div class=""k"">健康檢查</div><div class=""v"">{0} 項發現</div><div class=""s""><span class=""c-critical"">嚴重 {1}</span>｜<span class=""c-warn"">注意 {2}</span>｜資訊 {3}</div></div>" -f $findings.Count, @($findings | Where-Object Severity -eq 'critical').Count, @($findings | Where-Object Severity -eq 'warn').Count, @($findings | Where-Object Severity -eq 'info').Count) }
A '</div>'
A '<p class="note">磁碟增減是「現在」與「工作階段開始時」的實測差值；期間若有其他程式寫入（例如下載、編譯、AI 工具暫存），差值會被抵銷。送進資源回收筒的項目在清空前不會釋放空間。</p>'

# ---- 執行紀錄 ----
A '<h2>二、清理與變更紀錄</h2>'
if ($executed.Count) {
    A '<div class="tbl"><table><thead><tr><th>時間</th><th>類別</th><th>動作與對象</th><th>釋放</th><th>結果</th><th>還原</th><th>證據</th></tr></thead><tbody>'
    foreach ($a in $executed) {
        $t = try { ([datetime]$a.time).ToString('MM-dd HH:mm') } catch { $a.time }
        $what = "<div>$(Enc $a.action)</div>"
        if ($a.target) { $what += "<div><code>$(Enc $a.target)</code></div>" }
        if ($a.command) { $what += "<div class=""note"">指令：<code>$(Enc $a.command)</code></div>" }
        if ($a.note) { $what += "<div class=""note"">$(Enc $a.note)</div>" }
        $undo = "<span class=""chip"">$(Enc $revLabel[$a.reversible])</span>"
        if ($a.undoHint) { $undo += "<div class=""note"">$(Enc $a.undoHint)</div>" }
        A ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=""num"">{3}</td><td><span class=""chip c-{4}"">{5}</span></td><td>{6}</td><td>{7}</td></tr>" -f (Enc $t), (Enc $a.category), $what, (Enc (Sz $a.bytesFreed)), (Enc $a.result), (Enc $resultLabel[$a.result]), $undo, $(if ($a.evidence) { "<code>$(Enc $a.evidence)</code>" } else { '' }))
    }
    A '</tbody></table></div>'
} else { A '<p class="note">這個工作階段沒有執行任何清理或變更。</p>' }

# ---- 待決定與略過 ----
A '<h2>三、略過與待決定的項目</h2>'
if ($notDone.Count) {
    A '<div class="tbl"><table><thead><tr><th>狀態</th><th>類別</th><th>項目</th><th>原因與建議</th></tr></thead><tbody>'
    foreach ($a in $notDone) {
        A ("<tr><td><span class=""chip c-{0}"">{1}</span></td><td>{2}</td><td>{3}{4}</td><td>{5}</td></tr>" -f (Enc $a.result), (Enc $resultLabel[$a.result]), (Enc $a.category), (Enc $a.action), $(if ($a.target) { "<div><code>$(Enc $a.target)</code></div>" } else { '' }), (Enc $a.note))
    }
    A '</tbody></table></div>'
} else { A '<p class="note">沒有略過或待決定的項目。</p>' }

# ---- 健康檢查 ----
A '<h2>四、軟硬體健康檢查</h2>'
if ($health) {
    A ("<p class=""note"">檢查時間 {0}｜已開機 {1} 小時</p>" -f (Enc $health.collectedAt), (Enc $health.uptimeHours))
    if ($findings.Count) {
        foreach ($f in $findings) {
            A ("<div class=""finding {0}""><div class=""t""><span class=""chip c-{0}"">{1}</span> {2}｜{3}</div>{4}{5}</div>" -f (Enc $f.Severity), (Enc $sevLabel[$f.Severity]), (Enc $f.Area), (Enc $f.Title), $(if ($f.Detail) { "<div class=""d"">$(Enc $f.Detail)</div>" } else { '' }), $(if ($f.Advice) { "<div class=""a"">建議：$(Enc $f.Advice)</div>" } else { '' }))
        }
    } else { A '<p>沒有發現異常。</p>' }
    A '<div class="grid">'
    if ($health.cpu) { A ("<div class=""card""><div class=""k"">CPU（取樣平均）</div><div class=""v"">{0}%</div><div class=""s"">核心態 {1}%｜使用者態 {2}%</div></div>" -f (Enc $health.cpu.totalPercent), (Enc $health.cpu.privilegedPercent), (Enc $health.cpu.userPercent)) }
    if ($health.memory) { A ("<div class=""card""><div class=""k"">記憶體</div><div class=""v"">{0}%</div><div class=""s"">已認可 {1}%</div></div>" -f (Enc $health.memory.usedPercent), (Enc $health.memory.commitPercent)) }
    if ($health.battery) { A ("<div class=""card""><div class=""k"">電池健康度</div><div class=""v"">{0}%</div><div class=""s"">{1} / {2} mWh</div></div>" -f (Enc $health.battery.healthPercent), (Enc $health.battery.fullChargeMWh), (Enc $health.battery.designMWh)) }
    foreach ($d in @($health.disks)) { A ("<div class=""card""><div class=""k"">{0}</div><div class=""v"">{1}</div><div class=""s"">{2}</div></div>" -f (Enc $d.Name), (Enc $d.Health), (Enc $d.Status)) }
    if ($health.defender) { A ("<div class=""card""><div class=""k"">Defender</div><div class=""v"">{0}</div><div class=""s"">病毒碼 {1}</div></div>" -f $(if ($health.defender.realTime) { '即時保護開啟' } else { '即時保護關閉' }), (Enc $health.defender.signatureUpdated)) }
    A '</div>'
    if ($health.cpu -and $health.cpu.topProcesses) {
        A '<h3>CPU 使用最多的程式</h3><div class="tbl"><table><thead><tr><th>程式</th><th>CPU %</th><th>程序數</th></tr></thead><tbody>'
        foreach ($p in ($health.cpu.topProcesses | Select-Object -First 8)) { A ("<tr><td>{0}</td><td class=""num"">{1}</td><td class=""num"">{2}</td></tr>" -f (Enc $p.Name), (Enc $p.CpuPercent), (Enc $p.Instances)) }
        A '</tbody></table></div>'
    }
} else { A '<p class="note">這個工作階段沒有執行健康檢查（health-check.ps1）。</p>' }

# ---- 檔案整理 ----
$orgLogs = @(Get-ChildItem -LiteralPath $SessionDir -Filter 'organize-log-*.csv' -ErrorAction SilentlyContinue)
if ($orgLogs.Count) {
    A '<h2>五、檔案整理</h2>'
    foreach ($lf in $orgLogs) {
        $rows = @(Import-Csv -LiteralPath $lf.FullName)
        A ("<h3>{0}</h3>" -f (Enc $lf.Name))
        A '<div class="tbl"><table><thead><tr><th>去向</th><th>數量</th></tr></thead><tbody>'
        $rows | Where-Object Status -eq 'OK' | Group-Object { if ($_.Action -eq 'Move') { Split-Path (Split-Path $_.Final -Parent) -Leaf } elseif ($_.Final -eq '(資源回收筒)') { '→ 資源回收筒' } else { '→ 隔離資料夾' } } | Sort-Object Name | ForEach-Object { A ("<tr><td>{0}</td><td class=""num"">{1}</td></tr>" -f (Enc $_.Name), $_.Count) }
        A '</tbody></table></div>'
        $bad = @($rows | Where-Object Status -ne 'OK')
        if ($bad.Count) { A ("<p class=""note"">未成功 {0} 筆，詳見紀錄檔。</p>" -f $bad.Count) }
    }
}

# ---- 掃描摘要 ----
A '<h2>六、掃描摘要</h2>'
if ($targets -and $targets.targets) {
    A '<h3>暫存與快取（掃描當下）</h3><div class="tbl"><table><thead><tr><th>項目</th><th>風險</th><th>大小</th><th>實際位置</th><th>建議做法</th></tr></thead><tbody>'
    foreach ($t in ($targets.targets | Select-Object -First 20)) { A ("<tr><td>{0}</td><td>{1}</td><td class=""num"">{2}</td><td><code>{3}</code></td><td>{4}</td></tr>" -f (Enc $t.Name), (Enc $t.Risk), (Enc (Sz $t.Bytes)), (Enc $t.RealPath), (Enc $t.Method)) }
    A '</tbody></table></div>'
}
if ($large -and $large.largeFiles) {
    A '<h3>大型檔案（前 15 個）</h3><div class="tbl"><table><thead><tr><th>大小</th><th>最後修改</th><th>路徑</th></tr></thead><tbody>'
    foreach ($l in ($large.largeFiles | Select-Object -First 15)) { A ("<tr><td class=""num"">{0}</td><td>{1}</td><td><code>{2}</code></td></tr>" -f (Enc (Sz $l.Bytes)), (Enc $l.LastWrite), (Enc $l.Path)) }
    A '</tbody></table></div>'
}
if ($startup) {
    $en = @($startup.startup | Where-Object State -eq 'enabled')
    A ("<p class=""note"">開機啟動：啟用 {0} 項、已停用 {1} 項；登入/開機觸發的非微軟排程工作 {2} 項。</p>" -f $en.Count, @($startup.startup | Where-Object State -eq 'disabled').Count, @($startup.scheduledTasks).Count)
}
if (-not ($targets -or $large -or $startup)) { A '<p class="note">沒有掃描資料。</p>' }

# ---- 溯源 ----
A '<h2>七、溯源方式</h2>'
A ("<p>所有原始資料都在工作階段資料夾：<code>{0}</code></p>" -f (Enc $SessionDir))
A '<ol>'
A '<li><b>每個動作都有一筆紀錄。</b><code>actions.jsonl</code> 一行一筆 JSON，欄位：<code>time</code> 時間、<code>category</code> 類別、<code>action</code> 動作、<code>target</code> 對象路徑、<code>command</code> 實際執行的指令、<code>bytesFreed</code> 實測釋放位元組、<code>result</code> 結果、<code>reversible</code> 可否還原、<code>undoHint</code> 還原方式、<code>evidence</code> 明細檔名、<code>user</code>／<code>host</code> 執行者與電腦。</li>'
A '<li><b>逐檔明細。</b>刪除舊檔的動作會留下 <code>clean-old-files-*.log</code>（每行：狀態、大小、完整路徑）；檔案整理會留下 <code>organize-plan-*.csv</code>（執行前的計畫）與 <code>organize-log-*.csv</code>（每個檔案的原位置、新位置、狀態）。</li>'
A '<li><b>掃描與健檢的原始數據。</b><code>baseline.json</code>（開始時的磁碟空間）、<code>overview.json</code>、<code>cleanup-targets.json</code>、<code>large-items.json</code>、<code>startup.json</code>、<code>health.json</code>、<code>battery-report.xml</code>。</li>'
A '<li><b>確認檔案沒被改過。</b>下表列出產生報告當下每個檔案的 SHA256；之後若懷疑紀錄被動過，可用 <code>Get-FileHash 檔名 -Algorithm SHA256</code> 比對。</li>'
A '</ol>'
A '<div class="tbl"><table><thead><tr><th>檔案</th><th>大小</th><th>修改時間</th><th>SHA256</th></tr></thead><tbody>'
Get-ChildItem -LiteralPath $SessionDir -File | Where-Object { $_.FullName -ne $Out } | Sort-Object Name | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    A ("<tr><td><code>{0}</code></td><td class=""num"">{1}</td><td>{2}</td><td><code>{3}</code></td></tr>" -f (Enc $_.Name), (Enc (Format-PccSize $_.Length)), (Enc $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')), (Enc $hash))
}
A '</tbody></table></div>'
A '<h3>如何還原</h3><ul>'
A '<li><span class="chip">資源回收筒</span> 打開資源回收筒，對項目按右鍵選「還原」。清空資源回收筒後就無法還原。</li>'
A '<li><span class="chip">還原腳本</span> 依該筆紀錄的「還原方式」執行 <code>organize-undo.ps1 -Log &lt;紀錄檔&gt; -Apply</code>，會把搬過的檔案逐一搬回原位（先不加 -Apply 可以試跑）。</li>'
A '<li><span class="chip">重新安裝</span> 已解除安裝的軟體需從官方網站或啟動器重新安裝；遊戲與模擬器內的資料不一定能救回。</li>'
A '<li><span class="chip">不可還原</span> 快取與暫存檔會由程式自動重建；永久刪除的虛擬機、資源回收筒內容無法救回。</li>'
A '</ul>'
A ("<p class=""note"">重新產生這份報告：<code>powershell -ExecutionPolicy Bypass -File build-report.ps1 -SessionDir ""{0}""</code>。報告含本機路徑與檔名，分享前請自行檢查。</p>" -f (Enc $SessionDir))
A '</main></body></html>'

[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
"報告已產生：$Out"
