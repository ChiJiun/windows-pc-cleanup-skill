# 唯讀：開機啟動項目（含是否已在「啟動應用程式」中停用）與登入/開機觸發的非微軟排程工作。
param([Parameter(Mandatory)][string]$SessionDir, [ValidateSet('zh-TW', 'en')][string]$Lang)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir

$approved = @{}
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder') {
    if (-not (Test-Path $k)) { continue }
    $p = Get-ItemProperty $k
    foreach ($pr in $p.PSObject.Properties) {
        if ($pr.Name -match '^PS') { continue }
        $v = $pr.Value
        # 第一個位元組為偶數（2、6）代表啟用，奇數（3、7）代表已停用
        $approved[$pr.Name] = if ($v -is [byte[]] -and ($v[0] % 2) -eq 1) { 'disabled' } else { 'enabled' }
    }
}

$startup = @(Get-CimInstance Win32_StartupCommand | ForEach-Object {
    # 啟動資料夾的項目在 StartupApproved 中以「捷徑檔名.lnk」記錄
    $keys = @($_.Name, "$($_.Name).lnk")
    $hit = $keys | Where-Object { $approved.ContainsKey($_) } | Select-Object -First 1
    $state = if ($hit) { $approved[$hit] } else { 'enabled' }
    [pscustomobject]@{ Name = $_.Name; Location = $_.Location; Command = $_.Command; State = $state }
})

$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.State -ne 'Disabled' -and $_.TaskPath -notmatch '^\\Microsoft\\' -and
    ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Boot' })
} | ForEach-Object { [pscustomobject]@{ Name = $_.TaskName; Path = $_.TaskPath; Author = "$($_.Author)" } })

$result = [ordered]@{ collectedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); startup = $startup; scheduledTasks = $tasks }
Save-PccJson $result (Join-Path $SessionDir 'startup.json')

Msg '開機啟動（仍啟用）:' 'Startup items (enabled):'
$startup | Where-Object State -eq 'enabled' | ForEach-Object { "  {0}  [{1}]" -f $_.Name, $_.Location }
Msg "已停用: $(@($startup | Where-Object State -eq 'disabled').Count) 項" "Disabled: $(@($startup | Where-Object State -eq 'disabled').Count)"
Msg '登入/開機時執行的非微軟排程工作:' 'Non-Microsoft scheduled tasks triggered at logon/boot:'
$tasks | ForEach-Object { "  $($_.Path)$($_.Name)" }
