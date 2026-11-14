[English](README.md) | 繁體中文

# windows-pc-cleanup-skill

給 Claude Code 使用的 Windows 電腦清理與健康檢查 skill。它會先完整掃描、分級列出建議，**每一個會改動電腦的步驟都先徵求你的確認**，所有動作都有紀錄可以溯源、可以還原，最後產生一份 HTML 總整報告。

文件與腳本輸出都支援繁體中文與英文（見下方「語言」）。

## 功能

| 階段 | 內容 |
|---|---|
| 掃描（唯讀） | 磁碟與記憶體概況、暫存／快取（會辨識 junction 實際所在磁碟、程式是否使用中）、大型檔案、開機啟動項與排程 |
| 分級建議 | A 類低風險快取、B 類要你判斷（虛擬機、模擬器、遊戲、舊環境）、C 類需系統管理員或只能你自己做 |
| 清理 | 試跑 → 確認 → 執行；能進資源回收筒就不永久刪除；用官方指令與官方解除安裝程式 |
| 檔案整理 | 依類型＋主題產生預覽、敏感檔集中並提醒、重複檔以 SHA256 判斷；附還原腳本 |
| 健康檢查 | CPU 拆解到程式層級、記憶體、SSD 健康、電池健康度、裝置、Defender、非預期關機、藍色畫面、Windows Update 錯誤碼解讀、重複啟動的殘留程序；可搭配 computer use 檢視工作管理員 |
| HTML 總整報告 | 清理前後磁碟空間、每個動作的指令／實測釋放量／還原方式、健檢發現、整理統計、所有紀錄檔的 SHA256 |

## 安裝

**方法一：Claude Code plugin marketplace**

```
/plugin marketplace add ChiJiun/windows-pc-cleanup-skill
/plugin install windows-pc-cleanup@windows-pc-cleanup-skill
```

**方法二：手動複製**

把 `skills/windows-pc-cleanup` 整個資料夾複製到 `%USERPROFILE%\.claude\skills\`。

## 使用

在 Claude Code 中直接說，例如：

- 「幫我清理電腦，釋放磁碟空間，動工前先跟我確認」
- 「整理我的下載資料夾」
- 「檢查電腦健康，看工作管理員有沒有異常」

也可以單獨執行腳本（都在 `skills/windows-pc-cleanup/scripts/`）：

```powershell
$S = powershell -ExecutionPolicy Bypass -File scripts\new-session.ps1 -Lang zh-TW
powershell -ExecutionPolicy Bypass -File scripts\scan-cleanup-targets.ps1 -SessionDir $S
powershell -ExecutionPolicy Bypass -File scripts\health-check.ps1 -SessionDir $S
powershell -ExecutionPolicy Bypass -File scripts\build-report.ps1 -SessionDir $S
```

會改動檔案的腳本（`clean-old-files.ps1`、`clear-folder.ps1`、`organize-apply.ps1`、`organize-undo.ps1`）**不加 `-Apply` 只會試跑**。

## 語言

- Claude 會用你的語言回答，並在建立工作階段時對 `new-session.ps1` 傳入對應的 `-Lang`；之後同一個工作階段的腳本會自動沿用。
- 所有腳本都接受 `-Lang zh-TW` 或 `-Lang en`，控制腳本輸出訊息與 HTML 報告的語言。沒有指定時，依序採用：
  1. 環境變數 `PCC_LANG`（例如 `$env:PCC_LANG = 'en'`）
  2. 工作階段 `baseline.json` 裡記錄的語言（由 `new-session.ps1 -Lang` 寫入）
  3. 系統介面語言（`zh*` 用 `zh-TW`，其他用 `en`）
- 檔案整理規則有兩份：`assets/organize-rules.default.json`（中文資料夾名稱，例如「文件」「圖片」）和 `assets/organize-rules.en.json`（英文資料夾名稱，例如 Documents、Images）。沒有用 `-RulesFile` 指定時依語言自動選擇。
- skill 本身以英文的 `SKILL.md` 為主，繁中對照版是 [SKILL.zh-TW.md](skills/windows-pc-cleanup/SKILL.zh-TW.md)；參考文件的繁中版在 [`references/zh-TW/`](skills/windows-pc-cleanup/references/zh-TW/)。

## 溯源與還原

- 每個工作階段的資料都在 `%USERPROFILE%\PCCleanup\<時間>\`。
- `actions.jsonl`：每個動作一行，記錄時間、指令、對象、實測釋放量、結果、還原方式。
- `clean-old-files-*.log`、`organize-plan-*.csv`、`organize-log-*.csv`：逐檔明細。
- 檔案整理另外在整理目標底下留一份紀錄資料夾（含 `organize-undo.ps1`；資料夾名稱由規則檔的 `logFolder` 決定，中文規則為 `_整理紀錄`，英文規則為 `_organize-logs`），工作階段資料夾被刪也能還原。
- 整理紀錄 CSV 中送進資源回收筒的項目，`Final` 欄標記為語言無關的 `(RecycleBin)`；`organize-undo.ps1` 仍可讀取舊版紀錄的 `(資源回收筒)` 標記。
- `report.html` 列出所有紀錄檔的 SHA256，可以用來確認紀錄沒有被改過。

> 報告與紀錄含本機路徑和檔名，分享前請先檢查。

## 需求

- Windows 10 / 11
- Windows PowerShell 5.1 或 PowerShell 7
- 大部分功能不需要系統管理員權限

## 開發

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

測試只在暫存資料夾中進行，不會動到你的檔案。腳本必須存成 **UTF-8 with BOM**（測試會檢查）。

## 參考

設計時參考了 BleachBit、WinDirStat、FluentCleaner、sifty 與幾個 macOS 清理 skill，詳見 [prior-art.md](skills/windows-pc-cleanup/references/zh-TW/prior-art.md)。

## 授權

MIT
