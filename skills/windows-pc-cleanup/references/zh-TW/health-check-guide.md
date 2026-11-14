[English](../health-check-guide.md) | 繁體中文

# 健康檢查解讀指南

| 項目 | 怎麼看 | 門檻 | 常見誤判 |
|---|---|---|---|
| CPU | `health.json` 的 `cpu.totalPercent` 與 `topProcesses`（依程式名稱合併、除以邏輯處理器數） | 持續 ≥ 70% 列為注意 | 檢查本身（WMI、工作管理員、PowerShell）會占用 10–20%；`Win32_Processor.LoadPercentage` 是瞬間值，波動很大 |
| 核心態時間 | `privilegedPercent` | 長期 > 40% 可能是驅動或防毒掃描 | 大量程序啟動、WMI 查詢期間也會偏高 |
| 記憶體 | `usedPercent`、`commitPercent` | 使用率 ≥ 85% 注意；已認可 ≥ 90% 嚴重 | 「可用」很少不一定有問題，Windows 會拿空閒記憶體當快取；已認可接近上限才會真的卡 |
| 重複程序 | `duplicateProcesses`：同一個命令列 ≥ 4 個 | — | Flask / Django 的自動重載會讓一組伺服器有 2 個程序；瀏覽器、Electron 本來就多程序（不列入） |
| 磁碟 | `Get-PhysicalDisk` 的 HealthStatus、可靠性計數器 | 非 Healthy 為嚴重 | 一般權限下可靠性計數器（溫度、磨損）常是空的，不代表異常 |
| 電池 | `powercfg /batteryreport /xml`：滿充容量 ÷ 設計容量 | < 60% 注意；< 40% 嚴重 | 循環次數 0 通常是韌體沒有回報 |
| 非預期關機 | 事件 41（Kernel-Power） | ≥ 3 次／30 天為注意 | 事件 6008 會和 41 成對出現，只算 41；使用者強制關機也會產生 |
| 藍色畫面 | 事件 1001（WER-SystemErrorReporting） | 有就列注意 | — |
| Windows Update | 事件來源 WindowsUpdateClient 的錯誤碼 | 依錯誤碼 | `0x80073D02` 只是 App 使用中無法更新，關掉就好 |
| 裝置 | `Get-PnpDevice` 狀態 Error / Degraded | 列為資訊 | VPN 的虛擬網卡（PANGP、TAP、Wintun）未連線時本來就是錯誤狀態 |
| 防毒 | `Get-MpComputerStatus` | 即時保護關閉為嚴重；病毒碼 > 7 天為注意 | 安裝其他防毒時 Defender 會自動停用 |
| 網卡驅動 | 事件來源 Netwtw*、rt640x64 等 | 列為資訊 | 偶發的「回傳無效值」影響不大，頻繁斷線才需要處理 |

## 用 computer use 看工作管理員

- 開啟方式：`request_access` 申請「工作管理員」，再 `open_application`。
- 系統管理員帳號下，工作管理員以提高的權限執行，computer use 的點擊與按鍵會被 Windows UIPI 擋下，只能截圖預設的「處理程序」分頁。看到點擊沒反應時，不要重試，也不要找其他方式繞過，直接改用效能計數器。
- 截圖可以用來確認整體 CPU、記憶體百分比與排序，和 `health-check.ps1` 的數據互相印證。
- 資源監視器（resmon）通常也需要提高權限。

## 回報方式

- 依嚴重度排序，每一項都說明「看到什麼、可能原因、建議做法、需不需要使用者動手」。
- 涉及結束程序、更新驅動、換硬體的建議，只建議、不執行。
