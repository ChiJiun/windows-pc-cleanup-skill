# 建立一個工作階段資料夾，記錄開始時的磁碟空間（之後報告用來比較清理前後）。
# 用法：powershell -File new-session.ps1 [-Root <資料夾>]
param([string]$Root = (Join-Path $env:USERPROFILE 'PCCleanup'))
. "$PSScriptRoot\common.ps1"

$dir = Join-Path $Root (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$baseline = [ordered]@{
    createdAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    skillVersion = $script:PccVersion
    isAdmin      = (Test-PccIsAdmin)
    drives       = @(Get-PccDriveSnapshot)
}
Save-PccJson $baseline (Join-Path $dir 'baseline.json')
Write-Output $dir
