[English](../cleanup-catalog.md) | 繁體中文

# 清理位置目錄

風險等級：**A** = 快取／暫存，刪除後會自動重建；**B** = 需要使用者判斷；**C** = 需要系統管理員或只能使用者自己做。

| 位置 | 等級 | 建議方法 | 注意事項 |
|---|---|---|---|
| `%TEMP%` 超過 7 天的檔案 | A | `clean-old-files.ps1 -OlderThanDays 7 -ExcludeTopLevel claude` | 排除仍在使用的工具暫存（例如 Claude Code 的 `Temp\claude`）；被占用的檔案會自動略過 |
| `%TEMP%\claude` | B | 只刪已結束 session 的子資料夾 | 正在執行的 session 在這裡寫入；不確定就不要動。**永久刪除，要單獨確認並明講無法復原** |
| 安裝程式暫存（例如 Visual Studio 安裝時的隨機資料夾） | B | 等安裝完成再清 | 修改時間是今天的通常代表還在用 |
| Chrome / Edge 快取、Code Cache | A | 關閉瀏覽器後 `clear-folder.ps1` | 瀏覽器執行中就跳過 |
| 新版 Teams 快取 `Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams` | A | 關閉 Teams 後 `clear-folder.ps1` | 微軟官方建議的重設方式；可能需要重新登入 |
| VS Code `Cache`、`CachedData` | A | 關閉 VS Code 後清 | `workspaceStorage` 存有工作區狀態，不建議清 |
| Hugging Face `~/.cache/huggingface` | A | `clear-folder.ps1` | 之後用到模型會重新下載，可能很大 |
| conda `pkgs` | A | `conda clean --all -y` | **套件常以硬連結與環境共用**，資料夾大小會高估實際釋放量；以前後磁碟空間實測為準 |
| conda 舊環境 | B | `conda env remove -n <名稱>` | 列出各環境大小與最後修改日期讓使用者選。**永久刪除，要單獨確認**；建議先 `conda env export -n <名稱> > <名稱>.yml` 留下重建用的清單 |
| npm / pip / uv / pnpm / yarn 快取 | A | 官方指令（見 [SKILL.zh-TW.md](../../SKILL.zh-TW.md)） | 先用 `npm config get cache`、`pip cache dir`、`uv cache dir` 找實際位置，可能被設定到其他磁碟 |
| Docker | A/B | `docker builder prune -f`（A）；`docker image prune -a`（B，永久刪除未使用的映像，要單獨確認；需要時得重新 pull 或 build） | 清完 `docker_data.vhdx` 檔案大小不會馬上變小，要在 Docker Desktop 內或用 `Optimize-VHD`（需系統管理員）壓縮 |
| WSL 虛擬硬碟 `ext4.vhdx` | C | `wsl --shutdown` 後用 `Optimize-VHD` 或 diskpart 壓縮 | 先用 `wsl -- df -h /` 比較內部用量與 vhdx 大小，差距小就不值得做 |
| VirtualBox 虛擬機 | B | `VBoxManage unregistervm <名稱> --delete` | 永久刪除。先用 `showvminfo` 看作業系統、最後使用時間、共享資料夾，協助使用者回想用途 |
| Android 模擬器（BlueStacks、LDPlayer 等） | B | 官方解除安裝程式 | 模擬器內的 App 與資料會一起刪除；BlueStacks 另有 BlueStacks Services 要分開移除 |
| 遊戲 | B | 從啟動器（Steam、Battle.net、Riot Client）或登錄的 `UninstallString` 移除 | 移除 VALORANT 後，Riot Vanguard 反作弊驅動仍在，要另外詢問 |
| Downloads 安裝檔、重複檔、已解壓縮的壓縮檔 | B | `organize-plan.ps1` → 確認 → `organize-apply.ps1` | 送資源回收筒；VPN、憑證類安裝檔預設保留 |
| 資源回收筒 | B | `Clear-RecycleBin -Force` | 永久刪除，單獨確認 |
| Windows Update 快取、`C:\Windows\Temp` | C | 設定 > 系統 > 儲存空間 > 暫存檔案 | 需要系統管理員 |

## 已知陷阱

- **Junction／符號連結**：使用者常把大資料夾搬到 D 槽，在 C 槽留下 junction。從 C 槽路徑量到的大小其實在 D 槽，清掉釋放的也是 D 槽。`scan-cleanup-targets.ps1` 會標出實際位置，`Get-PccDirStats` 不會跟隨子層 junction。
- **最後存取時間不可靠**：掃描本身會更新資料夾的存取時間，不能用來判斷「最近有沒有在用」。改看檔案的最後修改時間、程式設定檔或使用紀錄。
- **同時寫入抵銷**：清理期間其他程式（AI 工具、下載、編譯）持續寫入時，磁碟可用空間的差值會小於實際清掉的量。報告時要說明。
