# 輸出各磁碟目前可用空間（位元組）。在外部指令前後各跑一次，用差值當作實際釋放量。
# 注意：同時有其他程式在寫入時，差值會被抵銷，報告中要註明。
. "$PSScriptRoot\common.ps1"
Get-PccDriveSnapshot | ForEach-Object { "{0}`t{1}`t{2}" -f $_.Drive, $_.FreeBytes, (Format-PccSize $_.FreeBytes) }
