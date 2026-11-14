# 唯讀：盤點常見的暫存與快取位置，標出實際所在磁碟、是否有程式正在使用、風險等級。
param([Parameter(Mandatory)][string]$SessionDir, [int]$OlderThanDays = 7)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir

$L = $env:LOCALAPPDATA; $R = $env:APPDATA; $U = $env:USERPROFILE
# risk: A = 快取／暫存，刪除後會自動重建；B = 需要使用者判斷；method 說明建議的清理方式
$catalog = @(
    @{ id = 'user-temp';      name = '使用者 Temp（超過 N 天的檔案）'; path = $env:TEMP; risk = 'A'; method = 'clean-old-files.ps1，排除仍在使用的工具暫存（例如 claude）'; procs = @() }
    @{ id = 'windows-temp';   name = 'Windows Temp'; path = "$env:SystemRoot\Temp"; risk = 'A'; method = '需要系統管理員；建議用「設定 > 儲存空間 > 暫存檔案」'; procs = @() }
    @{ id = 'wu-download';    name = 'Windows Update 下載快取'; path = "$env:SystemRoot\SoftwareDistribution\Download"; risk = 'A'; method = '需要系統管理員；建議用「設定 > 儲存空間 > 暫存檔案」'; procs = @() }
    @{ id = 'crashdumps';     name = '程式當機傾印'; path = "$L\CrashDumps"; risk = 'A'; method = 'clear-folder.ps1'; procs = @() }
    @{ id = 'chrome-cache';   name = 'Chrome 快取'; path = "$L\Google\Chrome\User Data\Default\Cache"; risk = 'A'; method = '關閉 Chrome 後 clear-folder.ps1'; procs = @('chrome') }
    @{ id = 'chrome-code';    name = 'Chrome Code Cache'; path = "$L\Google\Chrome\User Data\Default\Code Cache"; risk = 'A'; method = '關閉 Chrome 後 clear-folder.ps1'; procs = @('chrome') }
    @{ id = 'edge-cache';     name = 'Edge 快取'; path = "$L\Microsoft\Edge\User Data\Default\Cache"; risk = 'A'; method = '關閉 Edge 後 clear-folder.ps1'; procs = @('msedge') }
    @{ id = 'edge-code';      name = 'Edge Code Cache'; path = "$L\Microsoft\Edge\User Data\Default\Code Cache"; risk = 'A'; method = '關閉 Edge 後 clear-folder.ps1'; procs = @('msedge') }
    @{ id = 'teams-cache';    name = 'Teams（新版）快取'; path = "$L\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"; risk = 'A'; method = '關閉 Teams 後 clear-folder.ps1；下次開啟可能要重新登入'; procs = @('ms-teams') }
    @{ id = 'vscode-cache';   name = 'VS Code 快取'; path = "$R\Code\Cache"; risk = 'A'; method = '關閉 VS Code 後 clear-folder.ps1'; procs = @('Code') }
    @{ id = 'vscode-cached';  name = 'VS Code CachedData'; path = "$R\Code\CachedData"; risk = 'A'; method = '關閉 VS Code 後 clear-folder.ps1'; procs = @('Code') }
    @{ id = 'discord-cache';  name = 'Discord 快取'; path = "$R\discord\Cache"; risk = 'A'; method = '關閉 Discord 後 clear-folder.ps1'; procs = @('Discord') }
    @{ id = 'hf-cache';       name = 'Hugging Face 模型快取'; path = "$U\.cache\huggingface"; risk = 'A'; method = 'clear-folder.ps1；之後用到模型會重新下載'; procs = @() }
    @{ id = 'conda-pkgs';     name = 'conda 套件快取'; path = "$U\anaconda3\pkgs"; risk = 'A'; method = 'conda clean --all -y（官方指令）。注意：可能與環境共用硬連結，實際釋放量要以前後磁碟空間比較'; procs = @() }
    @{ id = 'miniconda-pkgs'; name = 'miniconda 套件快取'; path = "$U\miniconda3\pkgs"; risk = 'A'; method = 'conda clean --all -y'; procs = @() }
    @{ id = 'npm-cache';      name = 'npm 快取（預設位置）'; path = "$L\npm-cache"; risk = 'A'; method = 'npm cache clean --force'; procs = @() }
    @{ id = 'pip-cache';      name = 'pip 快取（預設位置）'; path = "$L\pip\Cache"; risk = 'A'; method = 'pip cache purge'; procs = @() }
    @{ id = 'uv-cache';       name = 'uv 快取（預設位置）'; path = "$L\uv\cache"; risk = 'A'; method = 'uv cache clean'; procs = @() }
    @{ id = 'yarn-cache';     name = 'Yarn 快取'; path = "$L\Yarn\Cache"; risk = 'A'; method = 'yarn cache clean'; procs = @() }
    @{ id = 'nuget-cache';    name = 'NuGet 套件快取'; path = "$U\.nuget\packages"; risk = 'B'; method = 'dotnet nuget locals all --clear'; procs = @() }
    @{ id = 'gradle-cache';   name = 'Gradle 快取'; path = "$U\.gradle\caches"; risk = 'B'; method = '停止 Gradle daemon 後刪除'; procs = @('java') }
    @{ id = 'claude-temp';    name = 'Claude Code 工作暫存（Temp\claude）'; path = (Join-Path $env:TEMP 'claude'); risk = 'B'; method = '只能清已結束 session 的子資料夾；正在執行的 session 一定要保留'; procs = @() }
    @{ id = 'downloads';      name = '下載資料夾'; path = "$U\Downloads"; risk = 'B'; method = '用 organize-plan.ps1 產生預覽，確認後再整理'; procs = @() }
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

"{0,-34} {1,4} {2,10} {3,10}  {4}" -f '項目', '風險', '大小', "舊於${OlderThanDays}天", '備註'
foreach ($i in $result.targets) {
    $note = @()
    if ($i.IsLink) { $note += "實際在 $($i.Drive)（$($i.RealPath)）" }
    if ($i.RunningApps.Count) { $note += "使用中: $($i.RunningApps -join ',')" }
    "{0,-34} {1,4} {2,10} {3,10}  {4}" -f $i.Name, $i.Risk, (Format-PccSize $i.Bytes), (Format-PccSize $i.OldBytes), ($note -join '；')
}
"資源回收筒: $($recycle.Count) 項，$(Format-PccSize $recycle.Bytes)"
if ($links.Count) { "使用者資料夾中的連結（大小會算在目標磁碟）:"; $links | ForEach-Object { "  $($_.Path) -> $($_.Target)" } }
if ($docker) { 'Docker:'; $docker | ForEach-Object { "  {0,-14} {1,10} 可回收 {2}" -f $_.Type, $_.Size, $_.Reclaimable } }
