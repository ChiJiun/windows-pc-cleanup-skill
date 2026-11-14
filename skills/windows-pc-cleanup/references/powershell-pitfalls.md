English | [繁體中文](zh-TW/powershell-pitfalls.md)

# PowerShell Pitfalls

Problems we have actually hit that can make cleanup go wrong or produce misleading results:

1. **UTF-8 BOM**: Windows PowerShell 5.1 reads a `.ps1` without a BOM using the system code page, so non-ASCII strings (such as Chinese) turn into mojibake or even syntax errors. Always save scripts as UTF-8 with BOM. If a tool wrote the file without one, add it like this:
   ```powershell
   $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8); [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding $true))
   ```
2. **Variable names swallowing CJK text**: `"$R文件"` is parsed as the variable `$R文件` (CJK characters are valid in variable names), which evaluates to an empty string. Write `"${R}文件"` instead.
3. **stderr from native programs**: in 5.1, using `2>&1` on a native program wraps every stderr line in an error record and sets `$?` to false, even when the program succeeded. `conda`, `npm`, and `git` often write progress to stderr, so do not treat that as failure; check `$LASTEXITCODE` instead.
4. **`Get-ChildItem -Recurse` and junctions**: recursion can walk into the target of a junction, causing double counting or scanning another drive. Use `Get-PccDirStats` (which does not follow links in subfolders) to measure sizes.
5. **`-Recurse` over a whole drive is slow**: it can take more than 10 minutes. Run it in the background instead of blocking the conversation.
6. **Nested `$_`**: inside `Where-Object { ... | Where-Object { $_ } }`, the inner `$_` shadows the outer one. Save the outer value to a variable first.
7. **`(Get-CimInstance Win32_Processor).LoadPercentage`** is an instantaneous value. Sample it several times and average, or use performance counters instead.
8. **StartupApproved in the registry**: if the first byte of the value is even (2, 6), the item is enabled; if odd (3, 7), it has been disabled under Startup apps. `Win32_StartupCommand` does not reflect the disabled state.
9. **Elevated windows**: computer use cannot operate Task Manager, UAC prompts, or installers running as administrator (UIPI).
10. **`param()` defaults cannot see `$PSScriptRoot`**: when running with `-File` in Windows PowerShell 5.1, `param([string]$X = (Join-Path $PSScriptRoot ...))` gets an empty string and fails. Leave the default empty and fill it in after the param block.
11. **Double quotes inside `$()` inside a string**: `"... $(if ($a) { " -X `"$a`"" })"` fails to parse in 5.1. Build the string in a variable first, then use it.
12. **Function names shadowed by built-in aliases**: aliases take precedence over functions. For example, a custom `function H {}` is shadowed by `h` (`Get-History`), and calling it gives strange parameter errors. Avoid names like `h`, `r`, `gc`, `ls`; check first with `Get-Alias <name>`.
13. **Sandboxed networking**: some proxied environments restrict DNS. If the network is unreachable, use `Resolve-DnsName` and `Test-NetConnection` to tell a local network problem from a sandbox restriction instead of retrying over and over.
14. **`-and` / `-or` have equal precedence**: PowerShell evaluates them left to right, so `A -or B -and C` means `(A -or B) -and C`, unlike most languages. Always add parentheses when mixing them.
15. **The Recycle Bin does not always "recycle"**: `SendToRecycleBin` silently deletes permanently on network or removable drives, when the Recycle Bin is disabled, or when an item exceeds the size limit. Use `Remove-PccToRecycleBin` (which checks first and throws if the item will not fit) instead of calling `Microsoft.VisualBasic.FileIO.FileSystem` directly.
16. **A path string is not the actual location**: Windows ships `C:\Documents and Settings` (a junction) and `C:\Users\All Users` (a symlink whose `Target` 5.1's `Get-Item` cannot read), and together with 8.3 short names (`PROGRA~1`) and `\\localhost\C$`, they all defeat string comparison. To decide whether a location is dangerous or which drive it is on, use `Get-PccFinalPath` (`GetFinalPathNameByHandleW`), and refuse if it cannot be resolved.
