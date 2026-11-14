# 建立一個工作階段資料夾，記錄開始時的磁碟空間（之後報告用來比較清理前後）與輸出語言。
# 用法：powershell -File new-session.ps1 [-Root <資料夾>] [-Lang zh-TW|en]
# 之後同一個工作階段的腳本會沿用這裡記錄的語言。
param(
    [string]$Root = (Join-Path $env:USERPROFILE 'PCCleanup'),
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"

$dir = Join-Path $Root (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$baseline = [ordered]@{
    createdAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    skillVersion = $script:PccVersion
    lang         = $script:PccLang
    isAdmin      = (Test-PccIsAdmin)
    drives       = @(Get-PccDriveSnapshot)
}
Save-PccJson $baseline (Join-Path $dir 'baseline.json')
Write-Output $dir
