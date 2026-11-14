# 唯讀：軟硬體健康檢查。產生 health.json，內含 findings（嚴重度 + 說明 + 建議）。
# 不會結束任何程序、不會改任何設定。
param([Parameter(Mandatory)][string]$SessionDir, [int]$CpuSamples = 3, [int]$EventDays = 7, [ValidateSet('zh-TW', 'en')][string]$Lang)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding($Severity, $Area, $Title, $Detail, $Advice) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; Area = $Area; Title = $Title; Detail = $Detail; Advice = $Advice })
}
$sep = Msg '、' ', '

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$uptimeH = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)

# ---- CPU：用效能計數器拆解到程式層級 ----
$n = [Environment]::ProcessorCount
$cpu = $null
try {
    # 取樣期間有程序結束時，Get-Counter 會回報「樣本無效」；略過這些樣本，不要整個中止
    $c = Get-Counter '\Process(*)\% Processor Time' -SampleInterval 2 -MaxSamples $CpuSamples -ErrorAction SilentlyContinue
    if (-not $c) { throw (Msg '效能計數器沒有回傳任何樣本（可能是計數器被停用或名稱被在地化）' 'Performance counters returned no samples (counters may be disabled or localized)') }
    $byProc = $c.CounterSamples | Where-Object { $_.Status -eq 0 -and $_.InstanceName -notin '_total', 'idle' } |
        Group-Object { $_.InstanceName -replace '#\d+$', '' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; CpuPercent = [math]::Round((($_.Group | Measure-Object CookedValue -Sum).Sum) / $CpuSamples / $n, 1); Instances = [int]($_.Group.Count / $CpuSamples) }
        } | Sort-Object CpuPercent -Descending
    $sys = @(Get-Counter '\Processor(_Total)\% Privileged Time', '\Processor(_Total)\% User Time', '\Processor(_Total)\% Interrupt Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue)
    $last = if ($sys.Count) { $sys[-1].CounterSamples } else { @() }
    $cpu = [ordered]@{
        totalPercent = [math]::Round(($byProc | Measure-Object CpuPercent -Sum).Sum, 1)
        privilegedPercent = [math]::Round(($last | Where-Object Path -match 'privileged').CookedValue, 1)
        userPercent = [math]::Round(($last | Where-Object Path -match 'user time').CookedValue, 1)
        interruptPercent = [math]::Round(($last | Where-Object Path -match 'interrupt').CookedValue, 1)
        topProcesses = @($byProc | Select-Object -First 12)
    }
    if ($cpu.totalPercent -ge 70) {
        $top = ($cpu.topProcesses | Select-Object -First 4 | ForEach-Object { Msg "$($_.Name) $($_.CpuPercent)%（$($_.Instances) 個）" "$($_.Name) $($_.CpuPercent)% ($($_.Instances) instances)" }) -join $sep
        Add-Finding 'warn' 'CPU' (Msg "CPU 持續偏高（約 $($cpu.totalPercent)%）" "CPU usage is high (about $($cpu.totalPercent)%)") `
            (Msg "主要來源：$top。注意：檢查本身（WMI、工作管理員）也會占用一部分。" "Main sources: $top. Note: the check itself (WMI, Task Manager) also uses some CPU.") `
            (Msg '先看是否有重複啟動或殘留的程式（見「殘留的開發伺服器」），不要直接結束不確定用途的程序。' 'First look for duplicate or leftover programs (see the leftover dev server finding); do not kill processes whose purpose is unclear.')
    }
} catch { Add-Finding 'info' 'CPU' (Msg '無法讀取效能計數器' 'Cannot read performance counters') $_.Exception.Message (Msg '可改用工作管理員或資源監視器人工檢查。' 'Check manually with Task Manager or Resource Monitor.') }

# ---- 記憶體 ----
$areaMem = Msg '記憶體' 'Memory'
$memUsedPct = [math]::Round((1 - ($os.FreePhysicalMemory * 1KB) / $cs.TotalPhysicalMemory) * 100, 1)
$commitPct = [math]::Round((($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize) * 100, 1)
if ($commitPct -ge 90) { Add-Finding 'critical' $areaMem (Msg "已認可記憶體 $commitPct%，接近上限" "Committed memory at $commitPct%, near the limit") (Msg "實體記憶體使用 $memUsedPct%。" "Physical memory in use: $memUsedPct%.") (Msg '關閉不用的瀏覽器分頁與程式，必要時重新開機。' 'Close unused browser tabs and apps; restart if needed.') }
elseif ($memUsedPct -ge 85) { Add-Finding 'warn' $areaMem (Msg "記憶體使用率 $memUsedPct%" "Memory usage $memUsedPct%") (Msg "已認可 $commitPct%。" "Committed: $commitPct%.") (Msg '關閉不用的瀏覽器分頁與程式；Chrome 可開啟「記憶體節省」。' 'Close unused browser tabs and apps; consider Chrome Memory Saver.') }

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
    $exe = [System.IO.Path]::GetFileName((($d.CommandLine -replace '^"', '') -split '"| ')[0])
    Add-Finding 'warn' (Msg '程序' 'Processes') (Msg "同一個指令有 $($d.Count) 個 $exe 程序在跑" "$($d.Count) $exe processes running the same command") `
        (Msg "$($d.CommandLine)（最早 $($d.FirstStart) 啟動，共 $(Format-PccSize $d.WorkingSetBytes)）" "$($d.CommandLine) (first started $($d.FirstStart), $(Format-PccSize $d.WorkingSetBytes) total)") `
        (Msg '很可能是重複啟動後沒關的開發伺服器。先確認沒有人在用，再由使用者決定要不要結束。' 'Likely a dev server started repeatedly and never stopped. Confirm nobody is using it, then let the user decide whether to stop it.')
}
$oldConsoles = @($all | Where-Object { $_.Name -eq 'conhost.exe' -and $_.CreationDate -lt (Get-Date).AddDays(-1) }).Count

# ---- 磁碟 ----
$areaDisk = Msg '磁碟' 'Disk'
$disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    $r = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    [pscustomobject]@{ Name = $_.FriendlyName; Health = "$($_.HealthStatus)"; Status = "$($_.OperationalStatus)"; Temperature = $r.Temperature; Wear = $r.Wear; ReadErrorsUncorrected = $r.ReadErrorsUncorrected; PowerOnHours = $r.PowerOnHours }
})
foreach ($d in $disks) { if ($d.Health -ne 'Healthy') { Add-Finding 'critical' $areaDisk (Msg "$($d.Name) 健康狀態：$($d.Health)" "$($d.Name) health: $($d.Health)") (Msg "運作狀態 $($d.Status)" "Operational status $($d.Status)") (Msg '立即備份重要資料，並檢查或更換硬碟。' 'Back up important data now and check or replace the disk.') } }
foreach ($v in Get-PccDriveSnapshot) {
    $pct = [math]::Round($v.FreeBytes / $v.SizeBytes * 100, 1)
    if ($pct -lt 10) { Add-Finding 'warn' $areaDisk (Msg "$($v.Drive) 可用空間只剩 $pct%" "$($v.Drive) has only $pct% free") "$(Format-PccSize $v.FreeBytes) / $(Format-PccSize $v.SizeBytes)" (Msg '依清理建議釋放空間。' 'Free up space following the cleanup suggestions.') }
}

# ---- 電池 ----
$areaBat = Msg '電池' 'Battery'
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
            $capDetail = Msg "設計 $($b.DesignCapacity) mWh，目前滿充 $($b.FullChargeCapacity) mWh" "Design $($b.DesignCapacity) mWh, full charge now $($b.FullChargeCapacity) mWh"
            if ($health -lt 40) { Add-Finding 'critical' $areaBat (Msg "電池健康度只剩 $health%" "Battery health only $health%") $capDetail (Msg '建議更換電池；拔掉電源時可能突然斷電。' 'Replace the battery; the laptop may shut down suddenly when unplugged.') }
            elseif ($health -lt 60) { Add-Finding 'warn' $areaBat (Msg "電池健康度 $health%" "Battery health $health%") $capDetail (Msg '電池明顯老化，可考慮更換；非預期關機可能與此有關。' 'The battery is noticeably worn; consider replacing it. Unexpected shutdowns may be related.') }
        }
    }
}

# ---- 裝置 ----
$badDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded' } | ForEach-Object { [pscustomobject]@{ Status = "$($_.Status)"; Class = "$($_.Class)"; Name = $_.FriendlyName } })
foreach ($d in $badDevices) {
    $advice = if ($d.Name -match 'PANGP|VPN|Virtual|TAP|Wintun') { Msg 'VPN 或虛擬網卡在未連線時常顯示錯誤，通常可忽略。' 'VPN or virtual adapters often show errors while disconnected; usually safe to ignore.' } else { Msg '到裝置製造商網站更新驅動程式。' 'Update the driver from the device manufacturer''s website.' }
    Add-Finding 'info' (Msg '裝置' 'Devices') (Msg "裝置異常：$($d.Name)" "Device problem: $($d.Name)") (Msg "類別 $($d.Class)，狀態 $($d.Status)" "Class $($d.Class), status $($d.Status)") $advice
}

# ---- 防毒 ----
$areaSec = Msg '安全' 'Security'
$defender = $null
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp) {
    $defender = [ordered]@{ realTime = $mp.RealTimeProtectionEnabled; signatureVersion = $mp.AntivirusSignatureVersion; signatureUpdated = $mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd'); recentThreats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { "$($_.InitialDetectionTime) $($_.Resources -join ';')" }) }
    if (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'critical' $areaSec (Msg 'Defender 即時保護已關閉' 'Defender real-time protection is off') '' (Msg '確認是否有其他防毒軟體；若沒有請開啟即時保護。' 'Check whether another antivirus is installed; if not, turn real-time protection on.') }
    if ($mp.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-7)) { Add-Finding 'warn' $areaSec (Msg '病毒碼超過 7 天未更新' 'Virus definitions are more than 7 days old') (Msg "最後更新 $($defender.signatureUpdated)" "Last updated $($defender.signatureUpdated)") (Msg '執行 Windows Update 或在 Windows 安全性中更新。' 'Run Windows Update or update from Windows Security.') }
    if ($defender.recentThreats.Count) { Add-Finding 'warn' $areaSec (Msg "Defender 近期偵測到 $($defender.recentThreats.Count) 筆威脅" "Defender recently detected $($defender.recentThreats.Count) threats") ($defender.recentThreats -join ' | ') (Msg '到 Windows 安全性 > 保護歷程記錄確認是否已隔離。' 'Check Windows Security > Protection history to confirm they were quarantined.') }
}

# ---- 事件紀錄 ----
$areaStab = Msg '穩定性' 'Stability'
$since = (Get-Date).AddDays(-$EventDays)
$sysErrors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -ErrorAction SilentlyContinue)
$errorsByProvider = @($sysErrors | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Count = $_.Count } })
$shutdowns = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') })
if ($shutdowns.Count) { Add-Finding $(if ($shutdowns.Count -ge 3) { 'warn' } else { 'info' }) $areaStab (Msg "近 30 天有 $($shutdowns.Count) 次非預期關機" "$($shutdowns.Count) unexpected shutdowns in the last 30 days") ($shutdowns -join $sep) (Msg '可能是強制關機、電池耗盡或當機。若沒有強制關機的印象，請檢查電池與溫度。' 'Could be forced power-offs, a drained battery or crashes. If you don''t remember forcing a shutdown, check the battery and temperatures.') }
$bugchecks = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
if ($bugchecks.Count) { Add-Finding 'warn' $areaStab (Msg "近 30 天有 $($bugchecks.Count) 次藍色畫面" "$($bugchecks.Count) blue screens in the last 30 days") '' (Msg '記下停止代碼，檢查最近更新的驅動程式。' 'Note the stop code and check recently updated drivers.') }
$appCrashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Properties[0].Value)" } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ App = $_.Name; Count = $_.Count } })
foreach ($a in $appCrashes) { if ($a.Count -ge 3) { Add-Finding 'info' $areaStab (Msg "$($a.App) 近 $EventDays 天當機 $($a.Count) 次" "$($a.App) crashed $($a.Count) times in the last $EventDays days") '' (Msg '更新或重新安裝該程式。' 'Update or reinstall the app.') } }

$wuCodes = @{
    '0x80073D02' = (Msg 'App 正在執行，無法更新；關閉該 App 後會自動重試' 'The app is running and cannot be updated; it retries automatically after the app is closed')
    '0x80070002' = (Msg '更新檔案遺失；可執行 Windows Update 疑難排解' 'Update files are missing; run the Windows Update troubleshooter')
    '0x800F0922' = (Msg '系統保留分割區空間不足或 VPN 干擾' 'System Reserved partition is too small, or a VPN is interfering')
    '0x80070643' = (Msg '安裝程式失敗，常見於 .NET 或 Defender 平台更新' 'Installer failure, common with .NET or Defender platform updates')
    '0x8024402C' = (Msg '連線或代理伺服器設定問題' 'Connection or proxy configuration problem')
    '0x80240034' = (Msg '下載失敗，通常稍後重試即可' 'Download failed; usually succeeds on retry')
}
$wuFailures = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue | ForEach-Object {
    $m = $_.Message
    $code = if ($m -match '0x[0-9A-Fa-f]{8}') { $Matches[0].ToUpper().Replace('0X', '0x') } else { '' }
    $upd = if ($m -match ':\s*(.+?)\.?\s*$') { $Matches[1] } else { '' }
    [pscustomobject]@{ Code = $code; Update = $upd }
} | Group-Object Code, Update | ForEach-Object { $f = $_.Group[0]; [pscustomobject]@{ Code = $f.Code; Update = $f.Update; Count = $_.Count; Meaning = $(if ($wuCodes.ContainsKey($f.Code)) { $wuCodes[$f.Code] } else { Msg '未知錯誤碼，請以錯誤碼搜尋微軟說明' 'Unknown error code; search Microsoft documentation for it' }) } })
$areaUpd = Msg '更新' 'Updates'
if ($wuFailures.Count) {
    $onlyInUse = -not ($wuFailures | Where-Object Code -ne '0x80073D02')
    $total = ($wuFailures | Measure-Object Count -Sum).Sum
    Add-Finding $(if ($onlyInUse) { 'info' } else { 'warn' }) $areaUpd (Msg "Windows Update 近 $EventDays 天有 $total 次安裝失敗" "Windows Update had $total failed installs in the last $EventDays days") `
        (($wuFailures | ForEach-Object { "$($_.Code) x$($_.Count): $($_.Meaning)" } | Select-Object -Unique) -join ' | ') `
        $(if ($onlyInUse) { Msg '都是「App 使用中」造成，關閉相關 App 後會自動更新，不需處理。' 'All caused by apps being in use; they update automatically once closed. No action needed.' } else { Msg '依錯誤碼說明處理，或執行 Windows Update 疑難排解。' 'Follow the error code guidance or run the Windows Update troubleshooter.' })
}
$netDriverErrors = @($sysErrors | Where-Object { $_.ProviderName -match '^(Netwtw|Netw|rt640x64|e1d|e1i|Netr|athw|mrvlpcie)' } | Group-Object ProviderName | ForEach-Object { [pscustomobject]@{ Provider = $_.Name; Count = $_.Count; Sample = (($_.Group[0].Message -replace '\s+', ' ')) } })
foreach ($e in $netDriverErrors) { Add-Finding 'info' (Msg '網路' 'Network') (Msg "網卡驅動 $($e.Provider) 有 $($e.Count) 筆錯誤" "Network driver $($e.Provider) logged $($e.Count) errors") $e.Sample (Msg '到筆電或網卡製造商網站更新網路驅動程式。' 'Update the network driver from the laptop or adapter manufacturer''s website.') }

$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($pendingReboot) { Add-Finding 'info' $areaUpd (Msg '有更新在等待重新開機' 'Updates are waiting for a restart') '' (Msg '找時間重新開機完成更新。' 'Restart when convenient to finish updating.') }
if ($uptimeH -gt 24 * 7) { Add-Finding 'info' (Msg '系統' 'System') (Msg "已連續開機 $uptimeH 小時" "Up for $uptimeH hours without a restart") '' (Msg '定期重新開機可以釋放記憶體並完成更新。' 'Restarting regularly frees memory and completes updates.') }

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

$label = @{ critical = (Msg '嚴重' 'CRITICAL'); warn = (Msg '注意' 'WARN'); info = (Msg '資訊' 'INFO') }
$cCount = @($findings | Where-Object Severity -eq 'critical').Count; $wCount = @($findings | Where-Object Severity -eq 'warn').Count; $iCount = @($findings | Where-Object Severity -eq 'info').Count
Msg "健康檢查完成：嚴重 $cCount、注意 $wCount、資訊 $iCount" "Health check done: $cCount critical, $wCount warnings, $iCount info"
foreach ($f in $result.findings) { "[{0}] {1}: {2}" -f $label[$f.Severity], $f.Area, $f.Title; if ($f.Advice) { (Msg '       建議：' '       Advice: ') + $f.Advice } }
