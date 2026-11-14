# 唯讀：為某個資料夾（預設「下載」）產生整理計畫 CSV，不會搬動任何檔案。
# 計畫內容：依類型分類、文件再依主題分類、敏感檔集中、重複檔／已解壓縮的壓縮檔／安裝檔送資源回收筒、子資料夾集中。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [string]$Root = (Join-Path $env:USERPROFILE 'Downloads'),
    [string]$RulesFile,
    # 只有使用者明確同意整理系統、程式或使用者根資料夾時才加
    [switch]$AllowUnsafeRoot
)
. "$PSScriptRoot\common.ps1"
# Windows PowerShell 5.1 在 param 預設值中取不到 $PSScriptRoot，所以在這裡補
if (-not $RulesFile) { $RulesFile = Join-Path $PSScriptRoot '..\assets\organize-rules.default.json' }
$SessionDir = Get-PccSessionDir $SessionDir
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')

# 擋下危險的整理目標：磁碟根目錄、使用者資料夾本身或它的上層、系統與程式資料夾、AppData（Temp 除外）
function Test-PccUnder([string]$Child, [string]$Parent) {
    if (-not $Child -or -not $Parent) { return $false }
    ($Child.TrimEnd('\') + '\').StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
$unsafe = $null
# 注意：PowerShell 的 -and / -or 優先順序相同，要加括號
if (($Root -match '^[A-Za-z]:$') -or ($Root.StartsWith('\\') -and $Root.TrimStart('\').Split('\').Count -le 2)) { $unsafe = '磁碟或網路分享的根目錄' }
elseif (Test-PccUnder $env:USERPROFILE $Root) { $unsafe = '使用者資料夾本身或它的上層' }
else {
    foreach ($p in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) { if (Test-PccUnder $Root $p) { $unsafe = "系統或程式資料夾（$p）"; break } }
    # TEMP 可能是 8.3 短檔名（例如 RUNNER~1），所以同時比對 LOCALAPPDATA\Temp 的長路徑
    $inTemp = (Test-PccUnder $Root $env:TEMP) -or ($env:LOCALAPPDATA -and (Test-PccUnder $Root (Join-Path $env:LOCALAPPDATA 'Temp')))
    if (-not $unsafe -and -not $inTemp) {
        foreach ($p in @($env:APPDATA, $env:LOCALAPPDATA)) { if (Test-PccUnder $Root $p) { $unsafe = "應用程式資料夾（$p）"; break } }
    }
}
if ($unsafe -and -not $AllowUnsafeRoot) {
    throw "不建議整理這個位置：$Root（$unsafe）。整理會把子資料夾整批搬走，可能讓程式或系統壞掉。請改指定 Downloads、Desktop 這類資料夾；確定要整理時，先取得使用者明確同意再加 -AllowUnsafeRoot。"
}
$rules = Read-PccJson $RulesFile
if (-not $rules) { throw "讀不到規則檔：$RulesFile" }

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

$reserved = @($rules.types | ForEach-Object { $_.name }) + @($rules.otherType, $rules.subfolders.target, $rules.logFolder)
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
            $sorted | Select-Object -Skip 1 | ForEach-Object { Add-Plan $_.F.FullName 'Recycle' '' "與「$($keep.Name)」內容完全相同（SHA256 $($_.H.Substring(0, 12))…）" '重複檔' $keep.FullName }
        }
}

foreach ($f in $files) {
    if ($handled[$f.FullName]) { continue }
    $type = Get-TypeName $f.Extension
    if ($rules.extractedArchives.recycle -and $type -eq $rules.archiveType -and (Test-Path -LiteralPath (Join-Path $Root $f.BaseName) -PathType Container)) {
        Add-Plan $f.FullName 'Recycle' '' "已有同名解壓縮資料夾「$($f.BaseName)」" '已解壓縮的壓縮檔'; continue
    }
    if ($rules.installers.recycle -and $type -eq $rules.installerType -and -not ($rules.installers.keepPattern -and $f.Name -match $rules.installers.keepPattern)) {
        Add-Plan $f.FullName 'Recycle' '' '安裝檔（需要時可重新下載）' '安裝檔'; continue
    }
    if ($sensitive -and $f.Name -match $sensitive) {
        $sub = Join-Path $rules.documentType $rules.sensitiveTopic
    } elseif ($type -eq $rules.documentType) {
        $sub = Join-Path $rules.documentType (Get-Topic $f.Name)
    } else { $sub = $type }
    Add-Plan $f.FullName 'Move' (Join-Path (Join-Path $Root $sub) $f.Name) '' $sub
}

if ($rules.subfolders.move) {
    Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $reserved -notcontains $_.Name } | ForEach-Object {
        Add-Plan $_.FullName 'Move' (Join-Path (Join-Path $Root $rules.subfolders.target) $_.Name) '子資料夾集中' $rules.subfolders.target
    }
}

$out = Join-Path $SessionDir ("organize-plan-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$plan | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
"計畫：$out（共 $($plan.Count) 筆，沒有搬動任何檔案）"
'— 搬移 —'
$plan | Where-Object Action -eq 'Move' | Group-Object Category | Sort-Object Name | ForEach-Object { "  {0,-24} {1,4}" -f $_.Name, $_.Count }
'— 送資源回收筒 —'
$plan | Where-Object Action -eq 'Recycle' | Group-Object Category | ForEach-Object { "  {0,-24} {1,4}" -f $_.Name, $_.Count }
$sens = @($plan | Where-Object { $_.Category -like "*$($rules.sensitiveTopic)" })
# 敏感檔的檔名不印出來（避免進入對話紀錄），只提示數量與去處；請使用者自己打開計畫 CSV 查看
if ($sens.Count) { "⚠ 偵測到 $($sens.Count) 個疑似敏感檔（只比對檔名，未開啟），會集中到「$(Join-Path $rules.documentType $rules.sensitiveTopic)」。檔名請使用者自己在計畫 CSV 的 Category 欄查看。" }
