# 唯讀：盤點常見的暫存與快取位置，標出實際所在磁碟、是否有程式正在使用、風險等級。
param([Parameter(Mandatory)][string]$SessionDir, [int]$OlderThanDays = 7, [ValidateSet('zh-TW', 'en')][string]$Lang)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir

$L = $env:LOCALAPPDATA; $R = $env:APPDATA; $U = $env:USERPROFILE
# risk: A = 快取／暫存，刪除後會自動重建；B = 需要使用者判斷；method 說明建議的清理方式
$catalog = @(
    @{ id = 'user-temp';      name = (Msg '使用者 Temp（超過 N 天的檔案）' 'User Temp (files older than N days)'); path = $env:TEMP; risk = 'A'; method = (Msg 'clean-old-files.ps1，排除仍在使用的工具暫存（例如 claude）' 'clean-old-files.ps1, excluding temp folders of tools still in use (e.g. claude)'); procs = @() }
    @{ id = 'windows-temp';   name = 'Windows Temp'; path = "$env:SystemRoot\Temp"; risk = 'A'; method = (Msg '需要系統管理員；建議用「設定 > 儲存空間 > 暫存檔案」' 'Requires admin; use Settings > Storage > Temporary files'); procs = @() }
    @{ id = 'wu-download';    name = (Msg 'Windows Update 下載快取' 'Windows Update download cache'); path = "$env:SystemRoot\SoftwareDistribution\Download"; risk = 'A'; method = (Msg '需要系統管理員；建議用「設定 > 儲存空間 > 暫存檔案」' 'Requires admin; use Settings > Storage > Temporary files'); procs = @() }
    @{ id = 'crashdumps';     name = (Msg '程式當機傾印' 'App crash dumps'); path = "$L\CrashDumps"; risk = 'A'; method = 'clear-folder.ps1'; procs = @() }
    @{ id = 'chrome-cache';   name = (Msg 'Chrome 快取' 'Chrome cache'); path = "$L\Google\Chrome\User Data\Default\Cache"; risk = 'A'; method = (Msg '關閉 Chrome 後 clear-folder.ps1' 'Close Chrome, then clear-folder.ps1'); procs = @('chrome') }
    @{ id = 'chrome-code';    name = 'Chrome Code Cache'; path = "$L\Google\Chrome\User Data\Default\Code Cache"; risk = 'A'; method = (Msg '關閉 Chrome 後 clear-folder.ps1' 'Close Chrome, then clear-folder.ps1'); procs = @('chrome') }
    @{ id = 'edge-cache';     name = (Msg 'Edge 快取' 'Edge cache'); path = "$L\Microsoft\Edge\User Data\Default\Cache"; risk = 'A'; method = (Msg '關閉 Edge 後 clear-folder.ps1' 'Close Edge, then clear-folder.ps1'); procs = @('msedge') }
    @{ id = 'edge-code';      name = 'Edge Code Cache'; path = "$L\Microsoft\Edge\User Data\Default\Code Cache"; risk = 'A'; method = (Msg '關閉 Edge 後 clear-folder.ps1' 'Close Edge, then clear-folder.ps1'); procs = @('msedge') }
    @{ id = 'teams-cache';    name = (Msg 'Teams（新版）快取' 'Teams (new) cache'); path = "$L\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"; risk = 'A'; method = (Msg '關閉 Teams 後 clear-folder.ps1；下次開啟可能要重新登入' 'Close Teams, then clear-folder.ps1; you may need to sign in again'); procs = @('ms-teams') }
    @{ id = 'vscode-cache';   name = (Msg 'VS Code 快取' 'VS Code cache'); path = "$R\Code\Cache"; risk = 'A'; method = (Msg '關閉 VS Code 後 clear-folder.ps1' 'Close VS Code, then clear-folder.ps1'); procs = @('Code') }
    @{ id = 'vscode-cached';  name = 'VS Code CachedData'; path = "$R\Code\CachedData"; risk = 'A'; method = (Msg '關閉 VS Code 後 clear-folder.ps1' 'Close VS Code, then clear-folder.ps1'); procs = @('Code') }
    @{ id = 'discord-cache';  name = (Msg 'Discord 快取' 'Discord cache'); path = "$R\discord\Cache"; risk = 'A'; method = (Msg '關閉 Discord 後 clear-folder.ps1' 'Close Discord, then clear-folder.ps1'); procs = @('Discord') }
    @{ id = 'hf-cache';       name = (Msg 'Hugging Face 模型快取' 'Hugging Face model cache'); path = "$U\.cache\huggingface"; risk = 'A'; method = (Msg 'clear-folder.ps1；之後用到模型會重新下載' 'clear-folder.ps1; models are re-downloaded when needed'); procs = @() }
    @{ id = 'conda-pkgs';     name = (Msg 'conda 套件快取' 'conda package cache'); path = "$U\anaconda3\pkgs"; risk = 'A'; method = (Msg 'conda clean --all -y（官方指令）。注意：可能與環境共用硬連結，實際釋放量要以前後磁碟空間比較' 'conda clean --all -y (official command). Note: may share hard links with environments; measure actual savings by comparing free space before and after'); procs = @() }
    @{ id = 'miniconda-pkgs'; name = (Msg 'miniconda 套件快取' 'miniconda package cache'); path = "$U\miniconda3\pkgs"; risk = 'A'; method = 'conda clean --all -y'; procs = @() }
    @{ id = 'npm-cache';      name = (Msg 'npm 快取（預設位置）' 'npm cache (default location)'); path = "$L\npm-cache"; risk = 'A'; method = 'npm cache clean --force'; procs = @() }
    @{ id = 'pip-cache';      name = (Msg 'pip 快取（預設位置）' 'pip cache (default location)'); path = "$L\pip\Cache"; risk = 'A'; method = 'pip cache purge'; procs = @() }
    @{ id = 'uv-cache';       name = (Msg 'uv 快取（預設位置）' 'uv cache (default location)'); path = "$L\uv\cache"; risk = 'A'; method = 'uv cache clean'; procs = @() }
    @{ id = 'yarn-cache';     name = (Msg 'Yarn 快取' 'Yarn cache'); path = "$L\Yarn\Cache"; risk = 'A'; method = 'yarn cache clean'; procs = @() }
    @{ id = 'nuget-cache';    name = (Msg 'NuGet 套件快取' 'NuGet package cache'); path = "$U\.nuget\packages"; risk = 'B'; method = 'dotnet nuget locals all --clear'; procs = @() }
    @{ id = 'gradle-cache';   name = (Msg 'Gradle 快取' 'Gradle cache'); path = "$U\.gradle\caches"; risk = 'B'; method = (Msg '停止 Gradle daemon 後刪除' 'Stop the Gradle daemon, then delete'); procs = @('java') }
    @{ id = 'claude-temp';    name = (Msg 'Claude Code 工作暫存（Temp\claude）' 'Claude Code working temp (Temp\claude)'); path = (Join-Path $env:TEMP 'claude'); risk = 'B'; method = (Msg '只能清已結束 session 的子資料夾；正在執行的 session 一定要保留' 'Only remove subfolders of finished sessions; always keep running sessions'); procs = @() }
    @{ id = 'downloads';      name = (Msg '下載資料夾' 'Downloads folder'); path = "$U\Downloads"; risk = 'B'; method = (Msg '用 organize-plan.ps1 產生預覽，確認後再整理' 'Preview with organize-plan.ps1; organize only after confirmation'); procs = @() }
)

$cut = (Get-Date).AddDays(-$OlderThanDays)
$items = foreach ($c in $catalog) {
    if (-not $c.path -or -not (Test-Path -LiteralPath $c.path)) { continue }
    $real = Resolve-PccRealPath $c.path
    $s = Get-PccDirStats -Path $c.path -OlderThan $cut
    if ($s.Bytes -lt 1MB) { continue }
    [pscustomobject]@{
        Id = $c.id; Name = $c.name; Path = $c.path; RealPath = $real
        Drive = ($real.Substring(0, 2)).ToUpper()
        IsLink = ($real -ne (Get-Item -LiteralPath $c.path -Force).FullName)
        Bytes = $s.Bytes; Files = $s.Files; OldBytes = $s.OldBytes
        Risk = $c.risk; Method = $c.method
        RunningApps = @(Get-PccRunningProcesses $c.procs)
    }
}

# 使用者資料夾底下的 junction（例如把 anaconda3 移到 D 槽後留下的連結）
$links = @(Get-ChildItem -LiteralPath $U -Force -ErrorAction SilentlyContinue | Where-Object { (Test-PccReparsePoint $_) -and $_.PSObject.Properties['Target'] -and $_.Target } | ForEach-Object {
    [pscustomobject]@{ Path = $_.FullName; Target = (@($_.Target)[0]); LinkType = "$($_.LinkType)" }
})

# Temp 前 10 大子項目
$tempTop = @(Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $b = if ($_.PSIsContainer) { (Get-PccDirStats $_.FullName).Bytes } else { $_.Length }
    [pscustomobject]@{ Name = $_.Name; Bytes = [int64]$b; LastWrite = $_.LastWriteTime.ToString('yyyy-MM-dd') }
} | Sort-Object Bytes -Descending | Select-Object -First 10)

# 資源回收筒
$rb = (New-Object -ComObject Shell.Application).Namespace(10).Items()
$recycle = [pscustomobject]@{ Count = $rb.Count; Bytes = [int64](($rb | Measure-Object -Property Size -Sum).Sum) }

# Docker（有安裝才查）
$docker = $null
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $df = docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>$null
    if ($LASTEXITCODE -eq 0) { $docker = @($df | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ Type = $p[0]; Size = $p[1]; Reclaimable = $p[2] } }) }
}

$result = [ordered]@{
    collectedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    olderThanDays = $OlderThanDays
    targets = @($items | Sort-Object Bytes -Descending)
    userProfileLinks = $links
    tempTop = $tempTop
    recycleBin = $recycle
    docker = $docker
    isAdmin = (Test-PccIsAdmin)
}
Save-PccJson $result (Join-Path $SessionDir 'cleanup-targets.json')

"{0,-34} {1,4} {2,10} {3,10}  {4}" -f (Msg '項目' 'Item'), (Msg '風險' 'Risk'), (Msg '大小' 'Size'), (Msg "舊於${OlderThanDays}天" ">${OlderThanDays}d old"), (Msg '備註' 'Notes')
foreach ($i in $result.targets) {
    $note = @()
    if ($i.IsLink) { $note += (Msg "實際在 $($i.Drive)（$($i.RealPath)）" "actually on $($i.Drive) ($($i.RealPath))") }
    if ($i.RunningApps.Count) { $note += (Msg "使用中: $($i.RunningApps -join ',')" "in use: $($i.RunningApps -join ',')") }
    "{0,-34} {1,4} {2,10} {3,10}  {4}" -f $i.Name, $i.Risk, (Format-PccSize $i.Bytes), (Format-PccSize $i.OldBytes), ($note -join (Msg '；' '; '))
}
Msg "資源回收筒: $($recycle.Count) 項，$(Format-PccSize $recycle.Bytes)" "Recycle Bin: $($recycle.Count) items, $(Format-PccSize $recycle.Bytes)"
if ($links.Count) { Msg "使用者資料夾中的連結（大小會算在目標磁碟）:" "Links in the user profile (size counts toward the target drive):"; $links | ForEach-Object { "  $($_.Path) -> $($_.Target)" } }
if ($docker) { 'Docker:'; $docker | ForEach-Object { (Msg "  {0,-14} {1,10} 可回收 {2}" "  {0,-14} {1,10} reclaimable {2}") -f $_.Type, $_.Size, $_.Reclaimable } }
