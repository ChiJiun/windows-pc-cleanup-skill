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
