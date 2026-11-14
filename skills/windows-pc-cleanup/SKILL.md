---
name: windows-pc-cleanup
description: 在 Windows 電腦上做完整掃描、分級清理、檔案整理與軟硬體健康檢查，最後產生可溯源的 HTML 總整報告。每一個會改動電腦的步驟都要先取得使用者確認，並留下可還原的紀錄。當使用者說「清理電腦」「釋放磁碟空間」「電腦變慢」「記憶體不夠」「整理下載資料夾／桌面」「檢查電腦健康」「看工作管理員有沒有異常」，或要求 Windows 版的 disk cleanup / PC cleaner 時使用。不適用於 macOS、Linux 或伺服器。
---

# Windows 電腦清理與健康檢查

目標：讓電腦回到乾淨、順暢的狀態，同時**不弄壞任何東西、不刪掉使用者還要的資料**，而且事後能說清楚做了什麼、怎麼還原。

## 最高原則（每一步都適用）

1. **先看、後問、再動。** 掃描一律唯讀。任何刪除、搬移、解除安裝、結束程序、改設定之前，都要先把「要做什麼、影響多大、能不能還原」講清楚，等使用者明確同意。前一輪的同意不能延伸到下一批。
2. **預設試跑。** `clean-old-files.ps1`、`clear-folder.ps1`、`organize-apply.ps1`、`organize-undo.ps1` 不加 `-Apply` 只會列出結果。先跑一次試跑，把數字給使用者看，同意後才加 `-Apply`。
3. **能進資源回收筒就不要永久刪除。** 永久刪除使用者資料（清空資源回收筒、刪虛擬機、`unregistervm --delete`、不經資源回收筒刪除使用者檔案）要另外單獨確認，並明講「無法復原」。
   - **唯一的例外是 A 類的暫存與快取**（Temp 舊檔、應用程式快取、套件管理器快取）：它們會自動重建、沒有還原價值，送資源回收筒只會拖慢速度又占空間，所以 `clean-old-files.ps1`（未加 `-Recycle`）和 `clear-folder.ps1` 會直接刪除。詢問 A 類時必須明講「這些會直接刪除、不進資源回收筒」，使用者同意 A 類即視為同意這一點；沒講就不算同意。
   - 送資源回收筒的腳本會先檢查放不放得下（網路或卸除式磁碟、資源回收筒被停用、項目大於上限時，Windows 會不經詢問直接永久刪除）。放不下的項目會保留原檔並記為失敗，這時要回報使用者，改用隔離資料夾或另外詢問。
4. **每個動作都要記錄。** 用本 skill 腳本做的動作會自動寫進 `actions.jsonl`；用其他指令做的（`conda clean`、`docker builder prune`、官方解除安裝程式、手動刪虛擬機），要立刻用 `log-action.ps1` 補記，釋放量用前後 `measure-free.ps1` 的實測差值。使用者決定「不做」或「之後再說」的項目，也用 `-Result skipped` / `pending` 記下來。
5. **數字要誠實。** 估計值和實測值分開說。實測比預期少時要找原因並更正之前的說法（常見原因：硬連結重複計算、junction 讓空間其實在別的磁碟、同時有其他程式在寫入）。
6. **不碰不屬於這次任務的東西。** 其他 AI session、開發伺服器、使用者正在用的程式，就算看起來是殘留，也只回報、不結束，除非使用者明確指示。
7. **敏感檔只看檔名。** 密碼、復原碼、證件、存摺這類檔案不要打開，不要把內容或檔名送到外部服務；只提醒使用者改存到密碼管理器或安全位置。`organize-plan.ps1` 只會印出敏感檔的數量和去處，不印檔名；需要確認時請使用者自己打開計畫 CSV 查看。

詳細規則見 [references/safety-rules.md](references/safety-rules.md)。

## 執行環境

- 腳本在本檔所在資料夾底下的 `scripts/`，相容 Windows PowerShell 5.1 與 PowerShell 7。用 `powershell -ExecutionPolicy Bypass -File <腳本> ...` 執行。下面範例中的 `scripts/...` 都是相對於本 skill 資料夾；目前目錄不同時請改用完整路徑（例如 `%USERPROFILE%\.claude\skills\windows-pc-cleanup\scripts\...` 或 plugin 安裝的位置）。
- 腳本檔是 **UTF-8 with BOM**（5.1 沒有 BOM 會把中文讀成亂碼）。修改後要保留 BOM。
- 大多數掃描不需要系統管理員權限。需要權限的項目（Windows Update 快取、系統 Temp、`Optimize-VHD`）就列為「請使用者自己做」，並附上步驟。
- 常見的 PowerShell 陷阱見 [references/powershell-pitfalls.md](references/powershell-pitfalls.md)。

## 流程

### 0. 建立工作階段

```powershell
$S = powershell -ExecutionPolicy Bypass -File scripts/new-session.ps1   # 印出工作階段資料夾路徑
```

之後所有腳本都要帶 `-SessionDir $S`。`baseline.json` 會記下開始時的磁碟空間，報告用它比較前後差異。

### 1. 唯讀掃描

依序（可平行）執行：

| 腳本 | 內容 | 備註 |
|---|---|---|
| `scan-overview.ps1` | 硬體、磁碟、記憶體、記憶體占用前幾名 | 數秒 |
| `scan-cleanup-targets.ps1` | 暫存、快取、資源回收筒、Docker、使用者資料夾的 junction | 會標出實際所在磁碟與「程式使用中」 |
| `scan-startup.ps1` | 開機啟動項目（含是否已停用）、登入時執行的排程工作 | |
| `scan-large-items.ps1` | 大型檔案、磁碟根目錄資料夾大小 | **可能超過 10 分鐘，放背景執行** |
| `health-check.ps1` | CPU 拆解、記憶體、磁碟健康、電池、裝置、Defender、事件紀錄、Windows Update 錯誤、重複／殘留程序 | 見第 5 步 |

掃描期間不要對使用者說「可以清 X GB」，等全部結果出來、去掉重複計算後再說。

### 2. 分級報告，請使用者決定

把結果分成三級，用表格呈現（項目、大小、實際位置、怎麼清、能不能還原）：

- **A 類（低風險）**：快取與暫存，刪了會自動重建。例如超過 7 天的 Temp 檔、瀏覽器／Teams／VS Code 快取（程式要先關）、套件管理器快取（用官方指令）、當機傾印。
- **B 類（要使用者判斷）**：舊的 conda 環境、虛擬機、模擬器、遊戲、Downloads 裡的安裝檔與重複檔、AI 工具的舊 session 暫存。對每一項提供判斷依據（最後使用時間、用途推測、設定檔內容），不要只丟一個大小。
- **C 類（只能使用者自己做或需要權限）**：系統 Temp、Windows Update 快取、虛擬硬碟壓縮、換電池、更新驅動。

用 `AskUserQuestion`（可多選）讓使用者勾選。使用者問「這是什麼」時，先唯讀調查再回答，不要猜。

各位置的清理方式與注意事項見 [references/cleanup-catalog.md](references/cleanup-catalog.md)。

### 3. 執行使用者同意的項目

- 每個項目執行前，再確認一次相關程式沒有在執行；執行中就跳過並記錄 `skipped`。
- Temp：`clean-old-files.ps1 -Path $env:TEMP -OlderThanDays 7 -ExcludeTopLevel claude -Apply`（先不加 `-Apply` 試跑）。會直接刪除、不進資源回收筒（見最高原則第 3 條的例外）。
- 快取資料夾：`clear-folder.ps1 -Path <路徑> -ProcessNames <程式> -Apply`。同樣直接刪除。
- 套件管理器：`conda clean --all -y`、`npm cache clean --force`、`pip cache purge`、`uv cache clean`、`pnpm store prune`、`docker builder prune -f`。執行前後各跑一次 `measure-free.ps1`，再用 `log-action.ps1` 記錄實測差值。
- 軟體：一律用官方解除安裝程式（登錄檔的 `UninstallString`），不要直接刪程式資料夾。GUI 解除安裝程式要請使用者自己點完；完成後再檢查殘留（程式資料夾、`AppData`、開始功能表捷徑、開機啟動項），殘留的清除也要記錄。
- 虛擬機：先用 `VBoxManage showvminfo` 確認是關機狀態，再 `VBoxManage unregistervm <名稱> --delete`。這是永久刪除。
- 資源回收筒：只有使用者明確同意「永久刪除」才清空。

### 4. 檔案整理（例如 Downloads）

1. `organize-plan.ps1 -Root <資料夾>` 產生計畫 CSV（不搬任何東西）。規則在 `assets/organize-rules.default.json`，可複製一份修改後用 `-RulesFile` 指定。
   - 腳本會拒絕整理磁碟根目錄、使用者資料夾本身或上層、系統與程式資料夾、預設使用者設定檔、`.ssh`／`.gnupg`、`AppData`（只允許 Temp 底下的子資料夾），因為子資料夾會被整批搬走。判斷用的是最終實際位置（經過 junction、symlink、短檔名、本機系統管理共用之後），解析不出實際位置也會拒絕。只有使用者明確要求、而且了解風險時才加 `-AllowUnsafeRoot`。
2. 先跟使用者確認整理方式（依類型、類型＋主題、類型＋年份），以及安裝檔、重複檔、已解壓縮的壓縮檔、子資料夾各要怎麼處理。
3. 把預覽給使用者看：各資料夾數量、每個主題分到哪些檔案、要移除哪些檔案和原因。分錯的就調整規則重產計畫。**敏感檔要特別點出來。**
4. 使用者同意後才執行 `organize-apply.ps1 -Plan <計畫> -Apply`。紀錄和 `organize-undo.ps1` 會複製到整理目標底下的 `_整理紀錄`，就算工作階段資料夾被刪也能還原。
   - 移除項目預設送資源回收筒；放不進資源回收筒的會保留原檔並記為 `FAILED`。想要每一項都能用 `organize-undo.ps1` 還原，加 `-QuarantineDir <隔離資料夾>`。
   - 重複檔在移除前會重新確認保留的那份還在、內容仍相同，否則略過。
5. 驗證：最上層沒有散落的檔案、各資料夾數量和計畫相符、資源回收筒的數量相符。紀錄中有 `FAILED` 或 `SKIPPED` 的項目要逐一回報。
6. 還原：`organize-undo.ps1 -Log <紀錄> -Apply`。有任何項目沒有回到原位（失敗、找不到、原位置已有同名項目）時結束代碼為 1，要把這些項目告訴使用者。

### 5. 軟硬體健康檢查

1. 執行 `health-check.ps1`，它會產生 findings（嚴重／注意／資訊），每一項都附建議。
2. 使用者要求「看工作管理員」時，可以用 computer use 打開工作管理員並截圖。**注意：** 系統管理員帳號下的工作管理員是以提高的權限執行，Windows 的 UIPI 會擋掉 computer use 的點擊與按鍵，所以只能看到預設畫面。這時改用效能計數器（`health-check.ps1` 已內建）補足，並告訴使用者原因。不要嘗試繞過。
3. CPU 很高但工作管理員前幾名都很低時，代表負載被大量小程序分攤。看 `health.json` 的 `cpu.topProcesses`（依程式名稱合併）和 `duplicateProcesses`（同一個指令重複啟動 4 次以上）。
4. 解讀規則與常見誤判見 [references/health-check-guide.md](references/health-check-guide.md)。

### 6. HTML 總整報告

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-report.ps1 -SessionDir $S
```

產生 `report.html`：單一檔案、完全離線、支援深色模式和列印。內容包括：

1. 摘要：各磁碟開始時與現在的可用空間、紀錄中的釋放量、動作數、健檢發現數。
2. 清理與變更紀錄：每一筆的時間、指令、實測釋放量、結果、還原方式、明細檔。
3. 略過與待決定的項目。
4. 健康檢查的發現與關鍵數據。
5. 檔案整理的去向統計。
6. 掃描摘要。
7. 溯源方式：每個紀錄檔的用途與 SHA256，以及各種還原方式。

用瀏覽器打開報告確認能正常顯示後，把路徑告訴使用者。報告含本機路徑與檔名，提醒使用者分享前先檢查。

### 7. 收尾回報

用使用者的語言說明：

- 做了哪些事（指令、檔案），各釋放多少（實測）。
- 為什麼這樣做；哪些估計和實際不同，原因是什麼。
- 還沒做的、被跳過的、需要使用者自己處理的事（附步驟）。
- 報告與紀錄檔的位置，以及怎麼還原。

## 參考資料

- [references/safety-rules.md](references/safety-rules.md)：確認關卡與禁止事項
- [references/cleanup-catalog.md](references/cleanup-catalog.md)：各清理位置的風險、方法與陷阱
- [references/health-check-guide.md](references/health-check-guide.md)：健檢項目的解讀
- [references/powershell-pitfalls.md](references/powershell-pitfalls.md)：撰寫與執行腳本時的陷阱
- [references/prior-art.md](references/prior-art.md)：參考過的開源專案
