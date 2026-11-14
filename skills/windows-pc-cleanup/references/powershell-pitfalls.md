# PowerShell 陷阱

實際踩過、會讓清理出錯或誤判的地方：

1. **UTF-8 BOM**：Windows PowerShell 5.1 讀沒有 BOM 的 `.ps1` 時會用系統字碼頁，中文字串會變亂碼甚至語法錯誤。腳本一律存成 UTF-8 with BOM；用工具寫檔後可以這樣補上：
   ```powershell
   $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8); [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding $true))
   ```
2. **變數名稱吃到中文**：`"$R文件"` 會被解析成變數 `$R文件`（中文字是合法的變數字元），結果是空字串。要寫成 `"${R}文件"`。
3. **原生程式的 stderr**：5.1 中對原生程式用 `2>&1`，stderr 每一行都會被包成錯誤紀錄，`$?` 變成 false，即使程式成功。`conda`、`npm`、`git` 的進度訊息常走 stderr，不要依此判斷失敗，改看 `$LASTEXITCODE`。
4. **`Get-ChildItem -Recurse` 與 junction**：遞迴時可能進入 junction 指向的位置，造成重複計算或掃到別的磁碟。統計大小請用 `Get-PccDirStats`（不跟隨子層連結）。
5. **`-Recurse` 掃整顆磁碟很慢**：可能超過 10 分鐘，請在背景執行，不要阻塞對話。
6. **巢狀 `$_`**：在 `Where-Object { ... | Where-Object { $_ } }` 裡，內層的 `$_` 會蓋掉外層。外層要先存到變數。
7. **`Get-CimInstance Win32_Processor).LoadPercentage`** 是瞬間值，要取樣多次平均，或改用效能計數器。
8. **登錄的 StartupApproved**：值的第一個位元組為偶數（2、6）代表啟用，奇數（3、7）代表在「啟動應用程式」中被停用。`Win32_StartupCommand` 不會反映停用狀態。
9. **提高權限的視窗**：工作管理員、UAC、以系統管理員執行的安裝程式，computer use 無法操作（UIPI）。
10. **`param()` 預設值拿不到 `$PSScriptRoot`**：在 Windows PowerShell 5.1 用 `-File` 執行時，`param([string]$X = (Join-Path $PSScriptRoot ...))` 會得到空字串而報錯。預設值留空，在 param 區塊之後再補。
11. **字串內的 `$()` 再包雙引號**：`"... $(if ($a) { " -X `"$a`"" })"` 在 5.1 會解析失敗。先把字串組好放進變數再用。
12. **函式名稱被內建別名蓋掉**：別名的優先順序高於函式。例如自訂 `function H {}` 會被 `h`（`Get-History`）蓋掉，呼叫時出現奇怪的參數錯誤。函式名稱避開 `h`、`r`、`gc`、`ls` 這類別名，用 `Get-Alias <名稱>` 先檢查。
13. **沙箱網路**：在某些代理環境中 DNS 會被限制。連不到網路時先用 `Resolve-DnsName` 與 `Test-NetConnection` 判斷是本機網路問題還是沙箱限制，不要一直重試。
14. **`-and` / `-or` 優先順序相同**：PowerShell 由左到右計算，`A -or B -and C` 等於 `(A -or B) -and C`，跟多數語言不同。混用時一定要加括號。
15. **資源回收筒不一定會「回收」**：`SendToRecycleBin` 遇到網路或卸除式磁碟、資源回收筒被停用、項目大於上限時，會不經詢問直接永久刪除。用 `Remove-PccToRecycleBin`（會先檢查並在放不下時丟出例外），不要直接呼叫 `Microsoft.VisualBasic.FileIO.FileSystem`。
