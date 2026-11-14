English | [繁體中文](zh-TW/safety-rules.md)

# Safety Rules and Confirmation Checkpoints

## Always ask the user first

| Action | What the confirmation must make clear |
|---|---|
| Deleting or emptying any file or folder | Path, count, size, whether it rebuilds automatically, whether it can be undone |
| Permanently deleting user data (emptying the Recycle Bin, deleting a VM, deleting user files without the Recycle Bin) | Confirm separately, and state plainly that it **cannot be undone** |
| Direct deletion of Category A temp files and caches (`clean-old-files.ps1` without `-Recycle`, `clear-folder.ps1`) | May be asked together with the rest of Category A, but you must say explicitly that it is "deleted directly and does not go to the Recycle Bin"; if you did not say so, it does not count as approval |
| Uninstalling software | Which official uninstaller will be used, and whether data inside the program goes with it (game saves, apps inside an emulator) |
| Ending a process | Who started it and whether someone might be using it; processes belonging to other sessions are left alone by default |
| Changing settings (startup, scheduled tasks, registry, power plan, services) | The original value, the new value, and how to change it back |
| Moving user files | Show a preview list first; call out sensitive files separately |
| Actions that need administrator rights | Hand them to the user to do, with steps |

Approval covers only what was asked at that moment. For example, approving "Category A" does not approve Category B, and approving deletion of the TEST1 VM does not approve deleting any other VM.

## Never do

- Delete, move, end a process, or change a setting without confirmation.
- Delete data that a junction points to on another drive and that is still in use (for example `C:\Users\<user>\anaconda3` → `D:\...\anaconda3`).
- "Uninstall" a program by deleting its install folder.
- Open or read files that look like they contain passwords, recovery codes, IDs, or financial data; or send such file names or contents to any external service.
- Try to bypass UIPI, UAC, or any other permission boundary (for example by scripting clicks on an elevated window).
- Report estimates to make the numbers look better; report only measured values, and label any estimate as such.
- Clean temp data or processes of AI tools, IDEs, or dev servers that are currently running.

## Dry runs and logging

- Every script that changes files runs as a dry run by default; `-Apply` is required to act.
- Every real action must appear in `actions.jsonl`, including skipped and pending items, so the report is complete.
- Deleting old files and organizing files must leave a per-file record (`clean-old-files-*.log`, `organize-log-*.csv`).
- A copy of the organize log and the undo script must also be kept inside the organized folder, so the changes can still be undone if the session folder is cleaned up.
