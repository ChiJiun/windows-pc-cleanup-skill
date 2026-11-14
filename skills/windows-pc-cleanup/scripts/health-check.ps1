# 唯讀：軟硬體健康檢查。產生 health.json，內含 findings（嚴重度 + 說明 + 建議）。
# 不會結束任何程序、不會改任何設定。
param([Parameter(Mandatory)][string]$SessionDir, [int]$CpuSamples = 3, [int]$EventDays = 7)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding($Severity, $Area, $Title, $Detail, $Advice) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; Area = $Area; Title = $Title; Detail = $Detail; Advice = $Advice })
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$uptimeH = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)

# ---- CPU：用效能計數器拆解到程式層級 ----
$n = [Environment]::ProcessorCount
$cpu = $null
try {
    $c = Get-Counter '\Process(*)\% Processor Time' -SampleInterval 2 -MaxSamples $CpuSamples -ErrorAction Stop
    $byProc = $c.CounterSamples | Where-Object { $_.InstanceName -notin '_total', 'idle' } |
        Group-Object { $_.InstanceName -replace '#\d+$', '' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; CpuPercent = [math]::Round((($_.Group | Measure-Object CookedValue -Sum).Sum) / $CpuSamples / $n, 1); Instances = [int]($_.Group.Count / $CpuSamples) }
        } | Sort-Object CpuPercent -Descending
    $sys = Get-Counter '\Processor(_Total)\% Privileged Time', '\Processor(_Total)\% User Time', '\Processor(_Total)\% Interrupt Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
    $last = $sys[-1].CounterSamples
    $cpu = [ordered]@{
        totalPercent = [math]::Round(($byProc | Measure-Object CpuPercent -Sum).Sum, 1)
        privilegedPercent = [math]::Round(($last | Where-Object Path -match 'privileged').CookedValue, 1)
        userPercent = [math]::Round(($last | Where-Object Path -match 'user time').CookedValue, 1)
        interruptPercent = [math]::Round(($last | Where-Object Path -match 'interrupt').CookedValue, 1)
        topProcesses = @($byProc | Select-Object -First 12)
    }
    if ($cpu.totalPercent -ge 70) {
        $top = ($cpu.topProcesses | Select-Object -First 4 | ForEach-Object { "$($_.Name) $($_.CpuPercent)%（$($_.Instances) 個）" }) -join '、'
        Add-Finding 'warn' 'CPU' "CPU 持續偏高（約 $($cpu.totalPercent)%）" "主要來源：$top。注意：檢查本身（WMI、工作管理員）也會占用一部分。" '先看是否有重複啟動或殘留的程式（見「殘留的開發伺服器」），不要直接結束不確定用途的程序。'
    }
} catch { Add-Finding 'info' 'CPU' '無法讀取效能計數器' $_.Exception.Message '可改用工作管理員或資源監視器人工檢查。' }

# ---- 記憶體 ----
$memUsedPct = [math]::Round((1 - ($os.FreePhysicalMemory * 1KB) / $cs.TotalPhysicalMemory) * 100, 1)
$commitPct = [math]::Round((($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize) * 100, 1)
if ($commitPct -ge 90) { Add-Finding 'critical' '記憶體' "已認可記憶體 $commitPct%，接近上限" "實體記憶體使用 $memUsedPct%。" '關閉不用的瀏覽器分頁與程式，必要時重新開機。' }
elseif ($memUsedPct -ge 85) { Add-Finding 'warn' '記憶體' "記憶體使用率 $memUsedPct%" "已認可 $commitPct%。" '關閉不用的瀏覽器分頁與程式；Chrome 可開啟「記憶體節省」。' }

# ---- 殘留的開發伺服器／重複程序 ----
$all = @(Get-CimInstance Win32_Process)
$devNames = 'python.exe', 'pythonw.exe', 'node.exe', 'java.exe', 'dotnet.exe', 'ruby.exe', 'php.exe', 'deno.exe', 'bun.exe'
$dup = @($all | Where-Object { $devNames -contains $_.Name -and $_.CommandLine } | Group-Object CommandLine | Where-Object Count -ge 4 | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
        CommandLine = $(if ($_.Name.Length -gt 200) { $_.Name.Substring(0, 200) + '…' } else { $_.Name })
        Count = $_.Count
        FirstStart = ($g | Sort-Object CreationDate | Select-Object -First 1).CreationDate.ToString('yyyy-MM-dd HH:mm')
        WorkingSetBytes = [int64](($g | Measure-Object WorkingSetSize -Sum).Sum)
        Pids = @($g | ForEach-Object { $_.ProcessId })
    }
})
foreach ($d in $dup) {
    Add-Finding 'warn' '程序' "同一個指令有 $($d.Count) 個程序在跑" "$($d.CommandLine)（最早 $($d.FirstStart) 啟動，共 $(Format-PccSize $d.WorkingSetBytes)）" '很可能是重複啟動後沒關的開發伺服器。先確認沒有人在用，再由使用者決定要不要結束。'
}
$oldConsoles = @($all | Where-Object { $_.Name -eq 'conhost.exe' -and $_.CreationDate -lt (Get-Date).AddDays(-1) }).Count

# ---- 磁碟 ----
$disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    $r = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    [pscustomobject]@{ Name = $_.FriendlyName; Health = "$($_.HealthStatus)"; Status = "$($_.OperationalStatus)"; Temperature = $r.Temperature; Wear = $r.Wear; ReadErrorsUncorrected = $r.ReadErrorsUncorrected; PowerOnHours = $r.PowerOnHours }
})
foreach ($d in $disks) { if ($d.Health -ne 'Healthy') { Add-Finding 'critical' '磁碟' "$($d.Name) 健康狀態：$($d.Health)" "運作狀態 $($d.Status)" '立即備份重要資料，並檢查或更換硬碟。' } }
foreach ($v in Get-PccDriveSnapshot) {
    $pct = [math]::Round($v.FreeBytes / $v.SizeBytes * 100, 1)
    if ($pct -lt 10) { Add-Finding 'warn' '磁碟' "$($v.Drive) 可用空間只剩 $pct%" "$(Format-PccSize $v.FreeBytes) / $(Format-PccSize $v.SizeBytes)" '依清理建議釋放空間。' }
}

# ---- 電池 ----
$battery = $null
if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) {
    $xml = Join-Path $SessionDir 'battery-report.xml'
    powercfg /batteryreport /xml /output "$xml" | Out-Null
    if (Test-Path $xml) {
        [xml]$bx = Get-Content -LiteralPath $xml -Raw
        $b = @($bx.BatteryReport.Batteries.Battery)[0]
        if ($b -and [double]$b.DesignCapacity -gt 0) {
            $health = [math]::Round([double]$b.FullChargeCapacity / [double]$b.DesignCapacity * 100, 1)
            $battery = [ordered]@{ designMWh = [int]$b.DesignCapacity; fullChargeMWh = [int]$b.FullChargeCapacity; healthPercent = $health; cycleCount = [int]$b.CycleCount }
            if ($health -lt 40) { Add-Finding 'critical' '電池' "電池健康度只剩 $health%" "設計 $($b.DesignCapacity) mWh，目前滿充 $($b.FullChargeCapacity) mWh" '建議更換電池；拔掉電源時可能突然斷電。' }
            elseif ($health -lt 60) { Add-Finding 'warn' '電池' "電池健康度 $health%" "設計 $($b.DesignCapacity) mWh，目前滿充 $($b.FullChargeCapacity) mWh" '電池明顯老化，可考慮更換；非預期關機可能與此有關。' }
        }
    }
}

# ---- 裝置 ----
$badDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded' } | ForEach-Object { [pscustomobject]@{ Status = "$($_.Status)"; Class = "$($_.Class)"; Name = $_.FriendlyName } })
foreach ($d in $badDevices) {
    $advice = if ($d.Name -match 'PANGP|VPN|Virtual|TAP|Wintun') { 'VPN 或虛擬網卡在未連線時常顯示錯誤，通常可忽略。' } else { '到裝置製造商網站更新驅動程式。' }
    Add-Finding 'info' '裝置' "裝置異常：$($d.Name)" "類別 $($d.Class)，狀態 $($d.Status)" $advice
}

# ---- 防毒 ----
$defender = $null
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp) {
    $defender = [ordered]@{ realTime = $mp.RealTimeProtectionEnabled; signatureVersion = $mp.AntivirusSignatureVersion; signatureUpdated = $mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd'); recentThreats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { "$($_.InitialDetectionTime) $($_.Resources -join ';')" }) }
    if (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'critical' '安全' 'Defender 即時保護已關閉' '' '確認是否有其他防毒軟體；若沒有請開啟即時保護。' }
    if ($mp.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-7)) { Add-Finding 'warn' '安全' '病毒碼超過 7 天未更新' "最後更新 $($defender.signatureUpdated)" '執行 Windows Update 或在 Windows 安全性中更新。' }
    if ($defender.recentThreats.Count) { Add-Finding 'warn' '安全' "Defender 近期偵測到 $($defender.recentThreats.Count) 筆威脅" ($defender.recentThreats -join '｜') '到 Windows 安全性 > 保護歷程記錄確認是否已隔離。' }
}

# ---- 事件紀錄 ----
$since = (Get-Date).AddDays(-$EventDays)
$sysErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -ErrorAction SilentlyContinue)
$errorsByProvider = @($sysErrors | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Count = $_.Count } })
$shutdowns = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') })
if ($shutdowns.Count) { Add-Finding $(if ($shutdowns.Count -ge 3) { 'warn' } else { 'info' }) '穩定性' "近 30 天有 $($shutdowns.Count) 次非預期關機" ($shutdowns -join '、') '可能是強制關機、電池耗盡或當機。若沒有強制關機的印象，請檢查電池與溫度。' }
$bugchecks = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
if ($bugchecks.Count) { Add-Finding 'warn' '穩定性' "近 30 天有 $($bugchecks.Count) 次藍色畫面" '' '記下停止代碼，檢查最近更新的驅動程式。' }
$appCrashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Properties[0].Value)" } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ App = $_.Name; Count = $_.Count } })
foreach ($a in $appCrashes) { if ($a.Count -ge 3) { Add-Finding 'info' '穩定性' "$($a.App) 近 $EventDays 天當機 $($a.Count) 次" '' '更新或重新安裝該程式。' } }

$wuCodes = @{
    '0x80073D02' = 'App 正在執行，無法更新；關閉該 App 後會自動重試'
    '0x80070002' = '更新檔案遺失；可執行 Windows Update 疑難排解'
    '0x800F0922' = '系統保留分割區空間不足或 VPN 干擾'
    '0x80070643' = '安裝程式失敗，常見於 .NET 或 Defender 平台更新'
    '0x8024402C' = '連線或代理伺服器設定問題'
    '0x80240034' = '下載失敗，通常稍後重試即可'
}
$wuFailures = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue | ForEach-Object {
    $m = $_.Message
    $code = if ($m -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToUpper().Replace('0X', '0x') } else { '' }
    $upd = if ($m -match ':\s*(.+?)\.?\s*$') { $Matches[1] } else { '' }
    [pscustomobject]@{ Code = $code; Update = $upd }
} | Group-Object Code, Update | ForEach-Object { $f = $_.Group[0]; [pscustomobject]@{ Code = $f.Code; Update = $f.Update; Count = $_.Count; Meaning = $(if ($wuCodes.ContainsKey($f.Code)) { $wuCodes[$f.Code] } else { '未知錯誤碼，請以錯誤碼搜尋微軟說明' }) } })
if ($wuFailures.Count) {
    $onlyInUse = -not ($wuFailures | Where-Object Code -ne '0x80073D02')
    Add-Finding $(if ($onlyInUse) { 'info' } else { 'warn' }) '更新' "Windows Update 近 $EventDays 天有 $(($wuFailures | Measure-Object Count -Sum).Sum) 次安裝失敗" (($wuFailures | ForEach-Object { "$($_.Code) ×$($_.Count)：$($_.Meaning)" } | Select-Object -Unique) -join '｜') $(if ($onlyInUse) { '都是「App 使用中」造成，關閉相關 App 後會自動更新，不需處理。' } else { '依錯誤碼說明處理，或執行 Windows Update 疑難排解。' })
}
$netDriverErrors = @($sysErrors | Where-Object { $_.ProviderName -match '^(Netwtw|Netw|rt640x64|e1d|e1i|Netr|athw|mrvlpcie)' } | Group-Object ProviderName | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Count = $_.Count; Sample = (($_.Group[0].Message -replace '\s+', ' ')) } })
foreach ($e in $netDriverErrors) { Add-Finding 'info' '網路' "網卡驅動 $($e.Provider) 有 $($e.Count) 筆錯誤" $e.Sample '到筆電或網卡製造商網站更新網路驅動程式。' }

$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($pendingReboot) { Add-Finding 'info' '更新' '有更新在等待重新開機' '' '找時間重新開機完成更新。' }
if ($uptimeH -gt 24 * 7) { Add-Finding 'info' '系統' "已連續開機 $uptimeH 小時" '' '定期重新開機可以釋放記憶體並完成更新。' }

$order = @{ critical = 0; warn = 1; info = 2 }
$result = [ordered]@{
    collectedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    uptimeHours = $uptimeH
    cpu = $cpu
    memory = [ordered]@{ usedPercent = $memUsedPct; commitPercent = $commitPct }
    duplicateProcesses = $dup
    oldConsoleHosts = $oldConsoles
    disks = $disks
    battery = $battery
    badDevices = $badDevices
    defender = $defender
    systemErrorsByProvider = $errorsByProvider
    unexpectedShutdowns = $shutdowns
    appCrashes = $appCrashes
    windowsUpdateFailures = $wuFailures
    pendingReboot = $pendingReboot
    findings = @($findings | Sort-Object { $order[$_.Severity] })
}
Save-PccJson $result (Join-Path $SessionDir 'health.json')

$label = @{ critical = '嚴重'; warn = '注意'; info = '資訊' }
"健康檢查完成：嚴重 $(@($findings | Where-Object Severity -eq 'critical').Count)、注意 $(@($findings | Where-Object Severity -eq 'warn').Count)、資訊 $(@($findings | Where-Object Severity -eq 'info').Count)"
foreach ($f in $result.findings) { "[{0}] {1}：{2}" -f $label[$f.Severity], $f.Area, $f.Title; if ($f.Advice) { "       建議：$($f.Advice)" } }
