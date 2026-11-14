# 把「不是由本 skill 腳本執行」的動作補記到 actions.jsonl，
# 例如 conda clean、docker builder prune、官方解除安裝程式、虛擬機刪除，或使用者決定略過／待決定的項目。
# 釋放空間請用執行前後的磁碟可用空間差值，不要用預估值。
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][string]$Action,
    [string]$Target = '',
    [string]$Command = '',
    [int64]$BytesFreed = 0,
    [ValidateSet('done', 'partial', 'skipped', 'failed', 'pending')][string]$Result = 'done',
    [ValidateSet('yes', 'recycle-bin', 'undo-script', 'reinstall', 'no')][string]$Reversible = 'no',
    [string]$UndoHint = '',
    [string]$Evidence = '',
    [string]$Note = '',
    [ValidateSet('zh-TW', 'en')][string]$Lang
)
. "$PSScriptRoot\common.ps1"
$SessionDir = Get-PccSessionDir $SessionDir
Write-PccAction -SessionDir $SessionDir -Category $Category -Action $Action -Target $Target -Command $Command `
    -BytesFreed $BytesFreed -Result $Result -Reversible $Reversible -UndoHint $UndoHint -Evidence $Evidence -Note $Note
Msg "已記錄：[$Result] $Category / $Action" "Logged: [$Result] $Category / $Action"
