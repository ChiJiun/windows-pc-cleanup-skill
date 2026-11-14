# 唯讀：系統概況（硬體、磁碟、記憶體、記憶體占用前幾名的程式）。
param([Parameter(Mandatory)][string]$SessionDir, [int]$Top = 15, [ValidateSet('zh-TW', 'en')][string]$Lang)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$bios = Get-CimInstance Win32_BIOS

$procs = Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Count = $_.Count; WorkingSetBytes = [int64](($_.Group | Measure-Object WorkingSet64 -Sum).Sum) }
} | Sort-Object WorkingSetBytes -Descending | Select-Object -First $Top

$overview = [ordered]@{
    collectedAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    os             = "$($os.Caption) $($os.Version)"
    model          = "$($cs.Manufacturer) $($cs.Model)"
    bios           = "$($bios.SMBIOSBIOSVersion)"
    cpu            = $cpu.Name.Trim()
    logicalCpus    = [Environment]::ProcessorCount
    lastBoot       = $os.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:ss')
    ramTotalBytes  = [int64]$cs.TotalPhysicalMemory
    ramFreeBytes   = [int64]$os.FreePhysicalMemory * 1KB
    commitUsedBytes  = [int64]($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB
    commitLimitBytes = [int64]$os.TotalVirtualMemorySize * 1KB
    drives         = @(Get-PccDriveSnapshot)
    physicalDisks  = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.FriendlyName; MediaType = "$($_.MediaType)"; SizeBytes = [int64]$_.Size; Health = "$($_.HealthStatus)" } })
    topMemory      = @($procs)
    isAdmin        = (Test-PccIsAdmin)
}
Save-PccJson $overview (Join-Path $SessionDir 'overview.json')

(Msg '系統' 'System') + ": $($overview.os) | $($overview.model) | $($overview.cpu)"
Msg "記憶體: 總共 $(Format-PccSize $overview.ramTotalBytes)，可用 $(Format-PccSize $overview.ramFreeBytes)，已認可 $(Format-PccSize $overview.commitUsedBytes) / $(Format-PccSize $overview.commitLimitBytes)" "Memory: total $(Format-PccSize $overview.ramTotalBytes), free $(Format-PccSize $overview.ramFreeBytes), committed $(Format-PccSize $overview.commitUsedBytes) / $(Format-PccSize $overview.commitLimitBytes)"
foreach ($d in $overview.drives) { (Msg "磁碟 {0} 可用 {1} / {2}" "Drive {0} free {1} / {2}") -f $d.Drive, (Format-PccSize $d.FreeBytes), (Format-PccSize $d.SizeBytes) }
Msg "記憶體占用前 $Top 名:" "Top $Top processes by memory:"
$procs | ForEach-Object { "  {0,-28} x{1,-4} {2}" -f $_.Name, $_.Count, (Format-PccSize $_.WorkingSetBytes) }
