---
name: windows-pc-cleanup
description: Full scan, tiered cleanup, file organization, and hardware/software health check for a Windows PC, ending with a traceable HTML report. Every step that changes the computer requires the user's explicit confirmation first and leaves a log with a way to undo it. Use when the user wants to clean up the PC, free disk space, says the PC is slow or low on memory, wants to organize the Downloads folder or desktop, check PC health, or see whether anything looks abnormal in Task Manager, or asks for a Windows disk cleanup / PC cleaner. Also use for Chinese requests such as 「清理電腦」「釋放磁碟空間」「電腦變慢」「記憶體不夠」「整理下載資料夾／桌面」「檢查電腦健康」「看工作管理員有沒有異常」. Not for macOS, Linux, or servers.
---

English | [繁體中文](SKILL.zh-TW.md)

# Windows PC Cleanup and Health Check

Goal: get the PC back to a clean, responsive state **without breaking anything or deleting data the user still wants**, and be able to explain afterwards exactly what was done and how to undo it.

## Core principles (apply to every step)

1. **Look, then ask, then act.** Scans are always read-only. Before any delete, move, uninstall, process kill, or settings change, explain what will be done, how big the impact is, and whether it can be undone, then wait for the user's explicit approval. Approval for one batch never carries over to the next.
2. **Dry run by default.** `clean-old-files.ps1`, `clear-folder.ps1`, `organize-apply.ps1`, and `organize-undo.ps1` only list what they would do unless you pass `-Apply`. Run a dry run first, show the user the numbers, and add `-Apply` only after they agree.
3. **If it can go to the Recycle Bin, do not delete it permanently.** Permanently deleting user data (emptying the Recycle Bin, deleting a VM, `unregistervm --delete`, deleting user files without going through the Recycle Bin) requires its own separate confirmation, and you must state plainly that it **cannot be undone**.
   - **The only exception is Category A temp files and caches** (old Temp files, application caches, package manager caches). They rebuild automatically and have no recovery value; sending them to the Recycle Bin only slows things down and wastes space. So `clean-old-files.ps1` (without `-Recycle`) and `clear-folder.ps1` delete them directly. When asking about Category A, you must say explicitly that "these are deleted directly and do not go to the Recycle Bin." Approving Category A counts as approving this only if you said it; if you did not, it does not count.
   - Scripts that send items to the Recycle Bin check first whether the item will actually fit (on network or removable drives, when the Recycle Bin is disabled, or when an item exceeds its size limit, Windows silently deletes it permanently). Items that will not fit are left in place and logged as failed. Report this to the user, and either use a quarantine folder or ask them again.
4. **Log every action.** Actions done with this skill's scripts are written to `actions.jsonl` automatically. Anything done with other commands (`conda clean`, `docker builder prune`, an official uninstaller, deleting a VM by hand) must be logged right away with `log-action.ps1`, using the measured difference from `measure-free.ps1` before and after as the space freed. Items the user decides not to do, or to do later, are also logged with `-Result skipped` / `pending`.
5. **Be honest with numbers.** Keep estimates and measured values separate. If the measured result is smaller than expected, find out why and correct what you said earlier (common causes: hard links counted twice, a junction meaning the space is actually on another drive, other programs writing at the same time).
6. **Do not touch anything outside this task.** Other AI sessions, dev servers, and programs the user is running are only reported, never terminated, even if they look like leftovers, unless the user explicitly says so.
7. **For sensitive files, look at file names only.** Never open files such as passwords, recovery codes, IDs, or bank statements, and never send their contents or names to an external service. Just remind the user to move them to a password manager or another safe place. `organize-plan.ps1` prints only the number of sensitive files and where they go, never their names; if they need checking, ask the user to open the plan CSV themselves.

See [references/safety-rules.md](references/safety-rules.md) for the detailed rules.

## Environment

- The scripts live in `scripts/` next to this file and work with both Windows PowerShell 5.1 and PowerShell 7. Run them with `powershell -ExecutionPolicy Bypass -File <script> ...`. The `scripts/...` paths in the examples below are relative to this skill's folder; if the current directory is different, use the full path (for example `%USERPROFILE%\.claude\skills\windows-pc-cleanup\scripts\...`, or wherever the plugin is installed).
- The scripts are saved as **UTF-8 with BOM** (without a BOM, 5.1 misreads the non-ASCII text in them). Keep the BOM when editing.
- Most scans do not need administrator rights. Items that do (Windows Update cache, system Temp, `Optimize-VHD`) are listed as "for the user to do", with steps.
- Common PowerShell pitfalls are in [references/powershell-pitfalls.md](references/powershell-pitfalls.md).

### Language

- **Reply in the user's language.** When creating the session, pass the matching `-Lang` to `new-session.ps1` (`zh-TW` if the user writes in Chinese, `en` otherwise). It is recorded in `baseline.json`, and every later script in the same session uses it automatically.
- Every script accepts `-Lang zh-TW` or `-Lang en`, which sets the language of its output messages and of the HTML report. Without `-Lang`, the language is resolved in this order:
  1. the `PCC_LANG` environment variable
  2. the language recorded in the session's `baseline.json` (written by `new-session.ps1 -Lang`)
  3. the system UI language (`zh*` uses `zh-TW`, anything else uses `en`)
- Note that `PCC_LANG` takes precedence over the session's recorded language. If `PCC_LANG` is set and differs from the user's language, pass `-Lang` explicitly to every script.
- File organization rules follow the same language when no `-RulesFile` is given: `assets/organize-rules.default.json` uses Chinese folder names (such as 文件, 圖片), and `assets/organize-rules.en.json` uses English folder names (such as Documents, Images).

## Workflow

### 0. Create a session

```powershell
$S = powershell -ExecutionPolicy Bypass -File scripts/new-session.ps1 -Lang en   # prints the session folder path; use -Lang zh-TW for Chinese-speaking users
```

Pass `-SessionDir $S` to every script after this. `baseline.json` records the starting disk space and the session language; the report uses it to compare before and after.

### 1. Read-only scan

Run these in order (they can run in parallel):

| Script | What it covers | Notes |
|---|---|---|
| `scan-overview.ps1` | Hardware, disks, memory, top memory consumers | A few seconds |
| `scan-cleanup-targets.ps1` | Temp, caches, Recycle Bin, Docker, junctions under the user folder | Flags the actual drive and whether a program is using it |
| `scan-startup.ps1` | Startup items (including whether they are disabled), scheduled tasks that run at logon | |
| `scan-large-items.ps1` | Large files, folder sizes at the drive root | **Can take over 10 minutes; run it in the background** |
| `health-check.ps1` | CPU breakdown, memory, disk health, battery, devices, Defender, event logs, Windows Update errors, duplicate / leftover processes | See step 5 |

Do not tell the user "you can free X GB" while scans are still running. Wait until all results are in and double counting has been removed.

### 2. Tiered report; let the user decide

Group the results into three categories and present them as a table (item, size, actual location, how to clean, whether it can be undone):

- **Category A (low risk)**: caches and temp files that rebuild automatically when deleted. For example: Temp files older than 7 days, browser / Teams / VS Code caches (close the program first), package manager caches (use the official commands), crash dumps.
- **Category B (user's judgment)**: old conda environments, virtual machines, emulators, games, installers and duplicates in Downloads, old session temp data from AI tools. For each item, give the user something to decide with (last used, likely purpose, what the config files say), not just a size.
- **Category C (user must do it, or needs admin rights)**: system Temp, Windows Update cache, compacting virtual disks, replacing the battery, updating drivers.

Use `AskUserQuestion` (multi-select) to let the user pick. When the user asks "what is this?", investigate read-only before answering; do not guess.

See [references/cleanup-catalog.md](references/cleanup-catalog.md) for how to clean each location and what to watch out for.

### 3. Carry out the approved items

- Right before each item, check again that the related program is not running. If it is, skip the item and log it as `skipped`.
- Temp: `clean-old-files.ps1 -Path $env:TEMP -OlderThanDays 7 -ExcludeTopLevel claude -Apply` (dry run first, without `-Apply`). Files are deleted directly, not sent to the Recycle Bin (see the exception in core principle 3).
- Cache folders: `clear-folder.ps1 -Path <path> -ProcessNames <program> -Apply`. Also deleted directly.
- Package managers: `conda clean --all -y`, `npm cache clean --force`, `pip cache purge`, `uv cache clean`, `pnpm store prune`, `docker builder prune -f`. Run `measure-free.ps1` before and after, then log the measured difference with `log-action.ps1`.
- Software: always use the official uninstaller (the `UninstallString` in the registry); never just delete the program folder. Ask the user to click through GUI uninstallers themselves. Afterwards, check for leftovers (program folder, `AppData`, Start menu shortcuts, startup items) and log any cleanup of them too.
- Virtual machines: confirm the VM is powered off with `VBoxManage showvminfo`, then run `VBoxManage unregistervm <name> --delete`. This is a permanent deletion.
- Recycle Bin: empty it only if the user has explicitly agreed to **permanent deletion**.

### 4. File organization (e.g. Downloads)

1. `organize-plan.ps1 -Root <folder>` produces a plan CSV (nothing is moved). Without `-RulesFile`, the rules file is picked by language: `zh-TW` uses `assets/organize-rules.default.json` (Chinese folder names), `en` uses `assets/organize-rules.en.json` (English folder names). To customize, copy one, edit it, and pass it with `-RulesFile`.
   - The script refuses to organize a drive root, the user profile folder itself or anything above it, system and program folders, the default user profile, `.ssh` / `.gnupg`, or `AppData` (only subfolders under Temp are allowed), because subfolders get moved wholesale. The check uses the final resolved location (after junctions, symlinks, 8.3 short names, and local admin shares), and it also refuses if the final location cannot be resolved. Add `-AllowUnsafeRoot` only when the user explicitly asks for it and understands the risk.
2. Agree with the user on how to organize (by type, type + topic, or type + year), and what to do with installers, duplicates, archives that have already been extracted, and subfolders.
3. Show the user a preview: file count per folder, which files went into each topic, and which files will be removed and why. If something is misclassified, adjust the rules and regenerate the plan. **Call out sensitive files explicitly.**
4. Only after the user agrees, run `organize-apply.ps1 -Plan <plan> -Apply`. The log and `organize-undo.ps1` are copied into a log folder inside the organized folder (named by `logFolder` in the rules file; `_整理紀錄` in the Chinese rules, `_organize-logs` in the English rules), so the changes can be undone even if the session folder is deleted.
   - Removed items go to the Recycle Bin by default; anything that will not fit is left in place and logged as `FAILED`. If every item must be restorable with `organize-undo.ps1`, add `-QuarantineDir <quarantine folder>`.
   - Items sent to the Recycle Bin are marked `(RecycleBin)` in the `Final` column of the organize log CSV; this marker is the same in every language. `organize-undo.ps1` still reads the legacy `(資源回收筒)` marker in older logs.
   - Before a duplicate is removed, the script re-checks that the copy being kept still exists and still has identical content; otherwise the duplicate is skipped.
5. Verify: no loose files left at the top level, folder counts match the plan, and the Recycle Bin count matches. Report every `FAILED` or `SKIPPED` entry in the log to the user.
6. Undo: `organize-undo.ps1 -Log <log> -Apply`. If any item does not make it back to its original location (failed, not found, or something with the same name is already there), the exit code is 1; tell the user which items those are.

### 5. Hardware and software health check

1. Run `health-check.ps1`. It produces findings (critical / warning / info), each with a recommendation.
2. If the user asks you to "look at Task Manager", you can open it with computer use and take a screenshot. **Note:** on an administrator account, Task Manager runs elevated, and Windows UIPI blocks computer use clicks and key presses, so you can only see the default view. Fall back to the performance counters (already built into `health-check.ps1`) and tell the user why. Do not try to work around it.
3. If total CPU is high but the top entries in Task Manager are all low, the load is spread across many small processes. Check `cpu.topProcesses` (grouped by program name) and `duplicateProcesses` (the same command line started 4 or more times) in `health.json`.
4. See [references/health-check-guide.md](references/health-check-guide.md) for how to interpret results and common false alarms.

### 6. HTML report

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-report.ps1 -SessionDir $S
```

This produces `report.html`: a single file that works fully offline and supports dark mode and printing. Its language follows the rules in "Language" above (normally the session language). It contains:

1. Summary: free space on each drive at the start and now, space freed according to the log, number of actions, number of health findings.
2. Cleanup and change log: time, command, measured space freed, result, how to undo, and detail file for each entry.
3. Skipped and pending items.
4. Health check findings and key figures.
5. Where organized files went.
6. Scan summary.
7. Traceability: what each log file is for and its SHA256, plus every way to undo.

Open the report in a browser to confirm it renders correctly, then give the user its path. The report contains local paths and file names; remind the user to review it before sharing.

### 7. Final summary

In the user's language, explain:

- What was done (commands, files) and how much each freed (measured).
- Why it was done that way; which estimates differed from the actual results, and why.
- What was not done, was skipped, or needs the user to handle it (with steps).
- Where the report and log files are, and how to undo.

## References

- [references/safety-rules.md](references/safety-rules.md): confirmation checkpoints and things never to do
- [references/cleanup-catalog.md](references/cleanup-catalog.md): risk, method, and pitfalls for each cleanup location
- [references/health-check-guide.md](references/health-check-guide.md): how to read health check results
- [references/powershell-pitfalls.md](references/powershell-pitfalls.md): pitfalls when writing and running the scripts
- [references/prior-art.md](references/prior-art.md): open-source projects consulted
