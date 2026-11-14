[English](../prior-art.md) | 繁體中文

# 參考過的開源專案

設計本 skill 前查過的專案。這裡只記錄設計上的啟發，沒有複製它們的程式碼。

| 專案 | 類型 | 借鏡的地方 |
|---|---|---|
| [BleachBit](https://www.bleachbit.org/) | 跨平台清理工具（GPL） | 以「清理器」為單位列出位置、提供預覽 |
| [WinDirStat](https://github.com/windirstat/windirstat) | 磁碟用量視覺化（GPL-2.0） | 先找出大檔案與大資料夾，再由使用者決定 |
| [FluentCleaner](https://github.com/builtbybel/FluentCleaner) | Windows 清理工具，使用 winapp2.ini 規則 | 清理位置用資料定義，而不是寫死在程式裡 |
| [sifty](https://vortrix5.github.io/sifty/) | 終端機清理工具 | 只刪到資源回收筒，讓每次清理都能還原 |
| macOS cleaner skills（例如 daymade、fernandezbaptiste 的 `macos-cleaner`） | Claude Code skill | 互動式分析、刪除前先徵求確認的流程 |

本 skill 的不同之處：

- 專注 Windows，處理 junction、硬連結、UIPI、PowerShell 5.1 編碼等 Windows 特有陷阱。
- 清理、檔案整理、軟硬體健康檢查放在同一個流程，最後產生可溯源的 HTML 報告。
- 所有會改動電腦的腳本預設試跑，每個動作都寫入 `actions.jsonl`，並附還原方式。
