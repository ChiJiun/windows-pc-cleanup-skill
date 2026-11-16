# 唯讀：為某個資料夾（預設「下載」）產生整理計畫 CSV，不會搬動任何檔案。
# 計畫內容：依類型分類、文件再依主題分類、敏感檔集中、重複檔／已解壓縮的壓縮檔／安裝檔送資源回收筒、子資料夾集中。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [string]$Root = (Join-Path $env:USERPROFILE 'Downloads'),
    [string]$RulesFile,
    # 只有使用者明確同意整理系統、程式或使用者根資料夾時才加
    [switch]$AllowUnsafeRoot,
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
# Windows PowerShell 5.1 在 param 預設值中取不到 $PSScriptRoot，所以在這裡補
if (-not $RulesFile) { $RulesFile = Get-PccDefaultRulesFile }
$SessionDir = Get-PccSessionDir $SessionDir
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')

# 擋下危險的整理目標：磁碟根目錄、使用者資料夾本身或它的上層、系統與程式資料夾、預設使用者設定檔、
# .ssh／.gnupg、AppData（只允許 Temp 底下的子資料夾）。
# 判斷時用 Get-PccFinalPath 取得最終實際位置（解析路徑中任何一層的 junction、symlink、8.3 短檔名），
# 例如 C:\Documents and Settings\<user>\AppData、C:\Users\All Users、C:\PROGRA~1 都會被還原成真正的位置。
# 解析不出實際位置時一律拒絕（fail-closed）。
function Test-PccUnder([string]$Child, [string]$Parent) {
    if (-not $Child -or -not $Parent) { return $false }
    ($Child.TrimEnd('\') + '\').StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-PccResolved([string]$Path) { $f = Get-PccFinalPath $Path; if ($f) { $f } else { $Path.TrimEnd('\') } }
function Get-PccUnsafeReason([string]$P) {
    # 注意：PowerShell 的 -and / -or 優先順序相同，要加括號
    if (($P -match '^[A-Za-z]:$') -or ($P.StartsWith('\\') -and $P.TrimStart('\').Split('\').Count -le 2)) { return (Msg '磁碟或網路分享的根目錄' 'the root of a drive or network share') }
    $profileDir = Get-PccResolved $env:USERPROFILE
    if (Test-PccUnder $profileDir $P) { return (Msg '使用者資料夾本身或它的上層' 'the user profile itself or one of its parents') }
    $usersDir = Split-Path $profileDir -Parent
    $protected = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        (Join-Path $usersDir 'Default'), (Join-Path $profileDir '.ssh'), (Join-Path $profileDir '.gnupg'))
    foreach ($s in $protected) {
        if ($s -and (Test-PccUnder $P (Get-PccResolved $s))) { return (Msg "系統、程式或帳號設定資料夾（$s）" "a system, program or account settings folder ($s)") }
    }
    # AppData（含 Local、Roaming、LocalLow 與 AppData 本身）一律拒絕，只允許 Temp「底下」的子資料夾，不含 Temp 本身
    $appData = Join-Path $profileDir 'AppData'
    if (Test-PccUnder $P $appData) {
        foreach ($t in @((Get-PccResolved $env:TEMP), (Join-Path $appData 'Local\Temp'))) {
            if ($t -and (Test-PccUnder $P $t) -and $P.TrimEnd('\').Length -gt $t.TrimEnd('\').Length) { return $null }
        }
        return (Msg "應用程式資料夾（$appData）" "an application data folder ($appData)")
    }
    return $null
}
$finalRoot = Get-PccFinalPath $Root
$unsafe = if (-not $finalRoot) { Msg '無法解析實際位置' 'its real location cannot be resolved' } else { $null }
foreach ($cp in @($Root, $finalRoot) | Where-Object { $_ } | Select-Object -Unique) { if (-not $unsafe) { $unsafe = Get-PccUnsafeReason $cp } }
if ($unsafe -and -not $AllowUnsafeRoot) {
    throw (Msg "不建議整理這個位置：$Root（$unsafe）。整理會把子資料夾整批搬走，可能讓程式或系統壞掉。請改指定 Downloads、Desktop 這類資料夾；確定要整理時，先取得使用者明確同意再加 -AllowUnsafeRoot。" "Refusing to organize this location: $Root ($unsafe). Organizing moves whole subfolders and can break programs or Windows. Pick a folder such as Downloads or Desktop; if you really must, get the user's explicit consent first and add -AllowUnsafeRoot.")
}
$rules = Read-PccJson $RulesFile
if (-not $rules) { throw (Msg "讀不到規則檔：$RulesFile" "Cannot read rules file: $RulesFile") }

$sensitive = ($rules.topics | Where-Object { $_.name -eq $rules.sensitiveTopic } | Select-Object -First 1).pattern
function Get-TypeName([string]$ext) {
    $e = $ext.TrimStart('.').ToLower()
    foreach ($t in $rules.types) { if ($t.extensions -contains $e) { return $t.name } }
    return $rules.otherType
}
function Get-Topic([string]$name) {
    foreach ($t in $rules.topics) { if ($name -match $t.pattern) { return $t.name } }
    return $rules.fallbackTopic
}

# _quarantine 是桌面版建議的隔離資料夾名稱（<root>\_quarantine），搬走的話前一次的還原會找不到隔離的項目
$reserved = @($rules.types | ForEach-Object { $_.name }) + @($rules.otherType, $rules.subfolders.target, $rules.logFolder, '_quarantine')
# 每種語言的內建規則都要保留，避免換語言重新整理時，把另一種語言的分類資料夾與還原紀錄整批搬走
foreach ($rf in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\assets') -Filter 'organize-rules*.json' -ErrorAction SilentlyContinue) {
    $r2 = Read-PccJson $rf.FullName
    if ($r2) { $reserved += @($r2.types | ForEach-Object { $_.name }) + @($r2.otherType, $r2.subfolders.target, $r2.logFolder) }
}
$reserved = @($reserved | Where-Object { $_ } | Select-Object -Unique)
# 含有整理紀錄或還原腳本的資料夾（例如自訂規則的紀錄資料夾）也一律不搬，否則舊的還原指令會失效
function Test-OrganizeLogFolder([string]$Dir) {
    [bool](Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'organize-undo.ps1' -or $_.Name -like 'organize-log-*.csv' } | Select-Object -First 1)
}
$files = @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })
$plan = New-Object System.Collections.Generic.List[object]
$handled = @{}
function Add-Plan($Source, $Action, $Dest, $Reason, $Category, $Keep = '') {
    # Keep：重複檔要保留的那一份，執行前會重新確認它還在、內容相同
    $plan.Add([pscustomobject]@{ Source = $Source; Action = $Action; Dest = $Dest; Reason = $Reason; Category = $Category; Keep = $Keep })
    $handled[$Source] = $true
}

# 1) 內容完全相同的重複檔（先比大小、再比 SHA256），每組保留檔名最清楚的一份
if ($rules.duplicates.recycle) {
    $score = { param($n) $s = 0.0; if ($n -match '\(\d+\)') { $s -= 10 }; if ($n -match '^(下載|download|untitled|未命名)') { $s -= 20 }; $s + $n.Length / 1000 }
    $files | Group-Object Length | Where-Object { $_.Count -gt 1 -and [int64]$_.Name -gt 0 } | ForEach-Object { $_.Group } |
        ForEach-Object { [pscustomobject]@{ F = $_; H = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } } |
        Group-Object H | Where-Object Count -gt 1 | ForEach-Object {
            $sorted = @($_.Group | Sort-Object @{ Expression = { & $score $_.F.Name }; Descending = $true }, @{ Expression = { $_.F.Name } })
            $keep = $sorted[0].F
            $sorted | Select-Object -Skip 1 | ForEach-Object { Add-Plan $_.F.FullName 'Recycle' '' (Msg "與「$($keep.Name)」內容完全相同（SHA256 $($_.H.Substring(0, 12))…）" "identical to `"$($keep.Name)`" (SHA256 $($_.H.Substring(0, 12))…)") (Msg '重複檔' 'Duplicate') $keep.FullName }
        }
}

foreach ($f in $files) {
    if ($handled[$f.FullName]) { continue }
    $type = Get-TypeName $f.Extension
    if ($rules.extractedArchives.recycle -and $type -eq $rules.archiveType -and (Test-Path -LiteralPath (Join-Path $Root $f.BaseName) -PathType Container)) {
        Add-Plan $f.FullName 'Recycle' '' (Msg "已有同名解壓縮資料夾「$($f.BaseName)」" "already extracted to folder `"$($f.BaseName)`"") (Msg '已解壓縮的壓縮檔' 'Extracted archive'); continue
    }
    if ($rules.installers.recycle -and $type -eq $rules.installerType -and -not ($rules.installers.keepPattern -and $f.Name -match $rules.installers.keepPattern)) {
        Add-Plan $f.FullName 'Recycle' '' (Msg '安裝檔（需要時可重新下載）' 'installer (can be downloaded again if needed)') (Msg '安裝檔' 'Installer'); continue
    }
    if ($sensitive -and $f.Name -match $sensitive) {
        $sub = Join-Path $rules.documentType $rules.sensitiveTopic
    } elseif ($type -eq $rules.documentType) {
        $sub = Join-Path $rules.documentType (Get-Topic $f.Name)
    } else { $sub = $type }
    Add-Plan $f.FullName 'Move' (Join-Path (Join-Path $Root $sub) $f.Name) '' $sub
}

if ($rules.subfolders.move) {
    Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $reserved -notcontains $_.Name -and -not (Test-OrganizeLogFolder $_.FullName) } | ForEach-Object {
        Add-Plan $_.FullName 'Move' (Join-Path (Join-Path $Root $rules.subfolders.target) $_.Name) (Msg '子資料夾集中' 'gather subfolders') $rules.subfolders.target
    }
}

$out = Join-Path $SessionDir ("organize-plan-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$plan | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
Msg "計畫：$out（共 $($plan.Count) 筆，沒有搬動任何檔案）" "Plan: $out ($($plan.Count) entries; nothing was moved)"
Msg '— 搬移 —' '— Move —'
$plan | Where-Object Action -eq 'Move' | Group-Object Category | Sort-Object Name | ForEach-Object { "  {0,-24} {1,4}" -f $_.Name, $_.Count }
Msg '— 送資源回收筒 —' '— Remove (Recycle Bin) —'
$plan | Where-Object Action -eq 'Recycle' | Group-Object Category | ForEach-Object { "  {0,-24} {1,4}" -f $_.Name, $_.Count }
$sens = @($plan | Where-Object { $_.Category -like "*$($rules.sensitiveTopic)" })
# 敏感檔的檔名不印出來（避免進入對話紀錄），只提示數量與去處；請使用者自己打開計畫 CSV 查看
if ($sens.Count) { Msg "⚠ 偵測到 $($sens.Count) 個疑似敏感檔（只比對檔名，未開啟），會集中到「$(Join-Path $rules.documentType $rules.sensitiveTopic)」。檔名請使用者自己在計畫 CSV 的 Category 欄查看。" "⚠ Found $($sens.Count) possibly sensitive files (matched by name only, not opened); they will be gathered in `"$(Join-Path $rules.documentType $rules.sensitiveTopic)`". Ask the user to check the names themselves in the Category column of the plan CSV." }
