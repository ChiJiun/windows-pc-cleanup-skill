# 不依賴 Pester 的測試，Windows PowerShell 5.1 與 PowerShell 7 都能跑。
# 所有測試都在暫存資料夾中進行，不會動到使用者的檔案。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'skills\windows-pc-cleanup\scripts'
. (Join-Path $scripts 'common.ps1')
$ps = (Get-Process -Id $PID).Path
$script:failures = 0; $script:passes = 0
function Assert($cond, $msg) { if ($cond) { $script:passes++; Write-Host "  PASS  $msg" } else { $script:failures++; Write-Host "  FAIL  $msg" -ForegroundColor Red } }
function Run([string]$name, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts $name) @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host "  （$name 結束代碼 $LASTEXITCODE）`n$out" -ForegroundColor Yellow }
    $out
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("pcc-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Write-Host '== 語法與編碼 =='
    foreach ($f in Get-ChildItem (Join-Path $repo 'skills') -Recurse -Filter *.ps1) {
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        Assert ($errs.Count -eq 0) "$($f.Name) 可以解析"
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
        Assert ((-not $nonAscii) -or $hasBom) "$($f.Name) 含非 ASCII 字元時有 UTF-8 BOM"
    }
    $rules = Read-PccJson (Join-Path $repo 'skills\windows-pc-cleanup\assets\organize-rules.default.json')
    Assert ($null -ne $rules -and $rules.topics.Count -gt 0) '預設整理規則是合法 JSON'
    foreach ($t in $rules.topics) { try { [void]('x' -match $t.pattern); $ok = $true } catch { $ok = $false }; Assert $ok "主題「$($t.name)」的 pattern 是合法正規表示式" }

    Write-Host '== Get-PccDirStats 不跟隨 junction =='
    $real = Join-Path $work 'real'; $scan = Join-Path $work 'scan'
    New-Item -ItemType Directory -Path $real, $scan | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $real 'big.bin'), (New-Object byte[] 4096))
    [IO.File]::WriteAllBytes((Join-Path $scan 'small.bin'), (New-Object byte[] 100))
    New-Item -ItemType Junction -Path (Join-Path $scan 'link') -Target $real | Out-Null
    $s = Get-PccDirStats $scan
    Assert ($s.Bytes -eq 100) "只計算實體檔案（得到 $($s.Bytes)，預期 100）"
    Assert ($s.SkippedLinks -eq 1) '略過 1 個 junction'
    Assert ((Resolve-PccRealPath (Join-Path $scan 'link')) -eq $real) 'Resolve-PccRealPath 回傳 junction 目標'

    Write-Host '== new-session / log-action =='
    $session = (Run 'new-session.ps1' @('-Root', (Join-Path $work 'sessions'))).Trim()
    Assert (Test-Path (Join-Path $session 'baseline.json')) 'new-session 建立 baseline.json'
    Run 'log-action.ps1' @('-SessionDir', $session, '-Category', '測試', '-Action', '<script>alert(1)</script>', '-BytesFreed', '1234', '-Result', 'done', '-Reversible', 'no') | Out-Null
    Run 'log-action.ps1' @('-SessionDir', $session, '-Category', '測試', '-Action', '待決定項目', '-Result', 'pending') | Out-Null
    $acts = @(Read-PccActions $session)
    Assert ($acts.Count -eq 2) 'actions.jsonl 有 2 筆'
    Assert ($acts[0].bytesFreed -eq 1234 -and $acts[0].category -eq '測試') '欄位與中文正確寫入'

    Write-Host '== clean-old-files 試跑與執行 =='
    $tmp = Join-Path $work 'tmpdir'; New-Item -ItemType Directory -Path (Join-Path $tmp 'keep'), (Join-Path $tmp 'sub') | Out-Null
    $old = Join-Path $tmp 'sub\old.txt'; $new = Join-Path $tmp 'new.txt'; $kept = Join-Path $tmp 'keep\old2.txt'
    'a' | Set-Content $old; 'b' | Set-Content $new; 'c' | Set-Content $kept
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-30); (Get-Item $kept).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item (Join-Path $tmp 'sub')).LastWriteTime = (Get-Date).AddDays(-30)
    Run 'clean-old-files.ps1' @('-SessionDir', $session, '-Path', $tmp, '-OlderThanDays', '7', '-ExcludeTopLevel', 'keep') | Out-Null
    Assert (Test-Path $old) '試跑模式不刪除'
    Run 'clean-old-files.ps1' @('-SessionDir', $session, '-Path', $tmp, '-OlderThanDays', '7', '-ExcludeTopLevel', 'keep', '-Apply') | Out-Null
    Assert (-not (Test-Path $old)) '刪除舊檔'
    Assert (Test-Path $new) '保留新檔'
    Assert (Test-Path $kept) '保留排除資料夾中的舊檔'
    Assert (-not (Test-Path (Join-Path $tmp 'sub'))) '移除變空的舊資料夾'
    Assert (@(Get-ChildItem $session -Filter 'clean-old-files-*.log').Count -eq 1) '留下逐檔明細'

    Write-Host '== clear-folder 遇到執行中的程式會中止 =='
    $cache = Join-Path $work 'cache'; New-Item -ItemType Directory -Path $cache | Out-Null; 'x' | Set-Content (Join-Path $cache 'a.tmp')
    $selfName = (Get-Process -Id $PID).ProcessName
    Run 'clear-folder.ps1' @('-SessionDir', $session, '-Path', $cache, '-ProcessNames', $selfName, '-Apply') | Out-Null
    Assert (Test-Path (Join-Path $cache 'a.tmp')) '程式執行中時不刪除'
    Run 'clear-folder.ps1' @('-SessionDir', $session, '-Path', $cache, '-Apply') | Out-Null
    Assert ((Test-Path $cache) -and -not (Test-Path (Join-Path $cache 'a.tmp'))) '清空內容但保留資料夾'

    Write-Host '== 檔案整理：計畫 → 執行（隔離）→ 還原 =='
    $dl = Join-Path $work 'Downloads'; New-Item -ItemType Directory -Path $dl | Out-Null
    'same' | Set-Content (Join-Path $dl 'report.pdf'); 'same' | Set-Content (Join-Path $dl 'report (1).pdf')
    'hw' | Set-Content (Join-Path $dl 'HW1_answer.pdf'); 'x' | Set-Content (Join-Path $dl 'random-file.pdf')
    'img' | Set-Content (Join-Path $dl 'photo.png'); 'secret' | Set-Content (Join-Path $dl 'openai-recovery-codes.txt')
    'exe' | Set-Content (Join-Path $dl 'tool-setup.exe'); 'vpn' | Set-Content (Join-Path $dl 'GlobalProtect64.msi')
    'zip' | Set-Content (Join-Path $dl 'project.zip'); New-Item -ItemType Directory -Path (Join-Path $dl 'project') | Out-Null
    'n' | Set-Content (Join-Path $dl 'project\readme.txt')
    $before = @(Get-ChildItem $dl -Recurse -Force | ForEach-Object { $_.FullName.Substring($dl.Length) } | Sort-Object)

    Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $dl) | Out-Null
    $planFile = (Get-ChildItem $session -Filter 'organize-plan-*.csv' | Select-Object -First 1).FullName
    $plan = @(Import-Csv $planFile)
    $byName = @{}; foreach ($p in $plan) { $byName[(Split-Path $p.Source -Leaf)] = $p }
    Assert ($byName['report (1).pdf'].Action -eq 'Recycle') '重複檔保留較好的檔名、移除「(1)」'
    Assert ($byName['report.pdf'].Action -eq 'Move') '重複檔的保留者被搬移'
    Assert ($byName['HW1_answer.pdf'].Dest -like '*\文件\課業\*') '作業分到 文件\課業'
    Assert ($byName['random-file.pdf'].Dest -like '*\文件\未分類\*') '無法判斷的文件分到 未分類'
    Assert ($byName['openai-recovery-codes.txt'].Dest -like '*\個人證件與機密\*') '敏感檔集中'
    Assert ($byName['tool-setup.exe'].Action -eq 'Recycle') '一般安裝檔移除'
    Assert ($byName['GlobalProtect64.msi'].Action -eq 'Move') 'VPN 安裝檔保留'
    Assert ($byName['project.zip'].Action -eq 'Recycle') '已解壓縮的壓縮檔移除'
    Assert ($byName['project'].Dest -like '*\資料夾\project') '子資料夾集中'
    Assert (@(Get-ChildItem $dl -Force).Count -eq 10) '產生計畫時沒有搬動任何檔案'

    $q = Join-Path $work 'quarantine'
    Run 'organize-apply.ps1' @('-SessionDir', $session, '-Plan', $planFile, '-QuarantineDir', $q) | Out-Null
    Assert (Test-Path (Join-Path $dl 'photo.png')) 'organize-apply 未加 -Apply 時不搬移'
    Run 'organize-apply.ps1' @('-SessionDir', $session, '-Plan', $planFile, '-QuarantineDir', $q, '-Apply') | Out-Null
    Assert (Test-Path (Join-Path $dl '圖片\photo.png')) '圖片已搬移'
    Assert (Test-Path (Join-Path $q 'tool-setup.exe')) '移除項目進入隔離資料夾'
    Assert (Test-Path (Join-Path $dl '_整理紀錄\organize-undo.ps1')) '整理目標底下留有還原腳本'
    $logFile = (Get-ChildItem (Join-Path $dl '_整理紀錄') -Filter 'organize-log-*.csv' | Select-Object -First 1).FullName
    Assert (@(Import-Csv $logFile | Where-Object Status -ne 'OK').Count -eq 0) '所有項目都成功'

    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dl '_整理紀錄\organize-undo.ps1') -Log $logFile -Apply | Out-Null
    Remove-Item -LiteralPath (Join-Path $dl '_整理紀錄') -Recurse -Force
    Get-ChildItem $dl -Directory | Where-Object { -not (Get-ChildItem $_.FullName -Recurse -File) } | Remove-Item -Recurse -Force
    $after = @(Get-ChildItem $dl -Recurse -Force | ForEach-Object { $_.FullName.Substring($dl.Length) } | Sort-Object)
    Assert ((Compare-Object $before $after).Count -eq 0) "還原後結構與原本相同（差異：$((Compare-Object $before $after | ForEach-Object { $_.InputObject }) -join ', ')）"

    Write-Host '== 資源回收筒放不下時不刪除 =='
    $binFile = Join-Path $work 'bin-test.txt'; 'x' | Set-Content $binFile
    Assert ($null -eq (Get-PccRecycleBinBlocker -Path $binFile -Bytes 10)) '本機小檔案可以進資源回收筒'
    Assert ([bool](Get-PccRecycleBinBlocker -Path '\\server\share\a.txt' -Bytes 10)) '網路路徑判定為無法進資源回收筒'
    Assert ([bool](Get-PccRecycleBinBlocker -Path $binFile -Bytes (1024L * 1TB))) '超過上限判定為無法進資源回收筒'
    $threw = $false; try { Remove-PccToRecycleBin -Path $binFile -Bytes (1024L * 1TB) } catch { $threw = $true }
    Assert ($threw -and (Test-Path $binFile)) '放不下時丟出例外並保留原檔'

    Write-Host '== 整理計畫拒絕危險的根目錄 =='
    $planCount = @(Get-ChildItem $session -Filter 'organize-plan-*.csv').Count
    $o1 = Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $env:USERPROFILE)
    $o2 = Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', ($env:SystemDrive + '\'))
    Assert ($o1 -match '不建議整理') '拒絕使用者資料夾本身'
    Assert ($o2 -match '不建議整理') '拒絕磁碟根目錄'
    $appDataRoot = Join-Path $env:USERPROFILE 'AppData'
    Assert ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $appDataRoot)) -match '不建議整理') '拒絕 AppData 本身'
    $lowDir = Join-Path $appDataRoot 'LocalLow'
    if (Test-Path $lowDir) { Assert ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $lowDir)) -match '不建議整理') '拒絕 AppData\LocalLow' }
    Assert ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $env:TEMP)) -match '不建議整理') '拒絕 Temp 本身（只允許 Temp 底下的子資料夾）'
    $shortPf = (Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Filter 'PROGRA~1' -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($shortPf -and (Test-Path ($env:SystemDrive + '\PROGRA~1'))) {
        Assert ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', ($env:SystemDrive + '\PROGRA~1'))) -match '不建議整理') '拒絕 8.3 短檔名的 Program Files'
    } else { Write-Host '  SKIP  這台電腦沒有 8.3 短檔名，略過 PROGRA~1 測試' }
    $toProfile = Join-Path $work 'to-profile'
    New-Item -ItemType Junction -Path $toProfile -Target $env:USERPROFILE | Out-Null
    try { Assert ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $toProfile)) -match '不建議整理') '拒絕指向使用者資料夾的 junction' }
    finally { [IO.Directory]::Delete($toProfile, $false) }  # 只刪連結本身，不碰目標
    Assert ((Test-Path $env:USERPROFILE) -and -not (Test-Path $toProfile)) '測試用 junction 已移除，目標完好'
    Assert (@(Get-ChildItem $session -Filter 'organize-plan-*.csv').Count -eq $planCount) '被拒絕時沒有產生計畫'
    Assert ($byName['report (1).pdf'].Keep -like '*\report.pdf') '重複檔的計畫記下保留的那份'
    Assert ($byName['openai-recovery-codes.txt'] -and ((Run 'organize-plan.ps1' @('-SessionDir', $session, '-Root', $dl)) -notmatch 'openai-recovery')) '輸出不印出敏感檔名'

    Write-Host '== 重複檔：保留的那份被改動時略過 =='
    $dup = Join-Path $work 'dup'; New-Item -ItemType Directory -Path $dup | Out-Null
    'same' | Set-Content (Join-Path $dup 'a.txt'); 'same' | Set-Content (Join-Path $dup 'a (1).txt')
    $dupSession = Join-Path $work 'dup-session'
    Run 'organize-plan.ps1' @('-SessionDir', $dupSession, '-Root', $dup) | Out-Null
    $dupPlan = (Get-ChildItem $dupSession -Filter 'organize-plan-*.csv' | Select-Object -First 1).FullName
    'changed' | Set-Content (Join-Path $dup 'a.txt')
    Run 'organize-apply.ps1' @('-SessionDir', $dupSession, '-Plan', $dupPlan, '-QuarantineDir', (Join-Path $work 'dup-q'), '-Apply') | Out-Null
    $dupLog = Import-Csv (Get-ChildItem $dupSession -Filter 'organize-log-*.csv' | Select-Object -First 1).FullName
    Assert (($dupLog | Where-Object { $_.Source -like '*a (1).txt' }).Status -like 'SKIPPED*') '內容已不同時略過，不移除'
    Assert (Test-Path (Join-Path $dup 'a (1).txt')) '被略過的重複檔仍在原位'

    Write-Host '== 還原失敗會被計入 =='
    $u = Join-Path $work 'undo'; New-Item -ItemType Directory -Path $u | Out-Null
    $moved = Join-Path $u 'moved.txt'; 'm' | Set-Content $moved
    $undoLog = Join-Path $u 'log.csv'
    @([pscustomobject]@{ Source = (Join-Path $u 'orig.txt'); Action = 'Move'; Final = $moved; Status = 'OK'; Reason = '' }) | Export-Csv -LiteralPath $undoLog -NoTypeInformation -Encoding UTF8
    $lock = [IO.File]::Open($moved, 'Open', 'Read', 'None')
    try { $uo = Run 'organize-undo.ps1' @('-Log', $undoLog, '-Apply'); $uCode = $LASTEXITCODE } finally { $lock.Close() }
    Assert ($uo -match '失敗 1 筆' -and $uo -match '已還原 0 筆') "搬移失敗時不算成功（輸出：$($uo.Trim() -replace '\s+', ' ')）"
    Assert ($uCode -eq 1) '還原失敗時結束代碼為 1'

    Write-Host '== HTML 報告 =='
    $out = Join-Path $session 'report.html'
    Run 'build-report.ps1' @('-SessionDir', $session) | Out-Null
    Assert (Test-Path $out) '產生 report.html'
    $html = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
    Assert ($html -notmatch '<script>alert') '動作內容有經過 HTML 跳脫'
    Assert ($html -match '&lt;script&gt;alert') '跳脫後的內容仍顯示'
    Assert ($html -match '待決定項目') '包含待決定項目'
    Assert ($html -match '溯源方式' -and $html -match 'actions\.jsonl') '包含溯源章節'
    Assert ($html -match '檔案整理') '包含檔案整理統計'
    Assert ($html -notmatch '<script|<link|src=\"http|href=\"http') '沒有外部資源或腳本'
    $hashRow = [regex]::Match($html, 'actions\.jsonl</code></td><td class="num">[^<]*</td><td>[^<]*</td><td><code>([0-9A-F]{64})</code>')
    Assert ($hashRow.Success -and $hashRow.Groups[1].Value -eq (Get-FileHash (Join-Path $session 'actions.jsonl') -Algorithm SHA256).Hash) '報告中的 SHA256 與實際檔案相符'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "通過 $script:passes、失敗 $script:failures"
if ($script:failures -gt 0) { exit 1 }
