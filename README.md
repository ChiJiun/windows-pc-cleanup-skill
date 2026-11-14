English | [繁體中文](README.zh-TW.md)

# windows-pc-cleanup-skill

A Claude Code skill for cleaning up and health-checking a Windows PC. It runs a full read-only scan first and presents tiered recommendations, **asks for your confirmation before every step that changes your computer**, logs every action so it can be traced and undone, and finishes with a self-contained HTML report.

Docs and script output are available in English and Traditional Chinese (see [Language](#language)).

## Features

| Stage | What it does |
|---|---|
| Scan (read-only) | Disk and memory overview; temp files and caches (detects which drive a junction really points to, and whether a program is using it); large files; startup items and scheduled tasks |
| Tiered recommendations | Category A: low-risk caches. Category B: your call (VMs, emulators, games, old environments). Category C: needs admin rights or only you can do it |
| Cleanup | Dry run → confirm → apply. Uses the Recycle Bin instead of permanent deletion whenever possible. Uses official commands and official uninstallers |
| File organization | Previews a by-type + by-topic layout, gathers sensitive files in one place and flags them, detects duplicates by SHA256; comes with an undo script |
| Health check | CPU broken down by program, memory, SSD health, battery wear, devices, Defender, unexpected shutdowns, blue screens, Windows Update error codes explained, duplicated leftover processes; can use computer use to look at Task Manager |
| HTML report | Disk space before and after, the command / measured space freed / undo method for every action, health findings, organization stats, and SHA256 of every log file |

## Desktop app (preview)

A standalone Windows app built on the same scripts lives in [`app/`](app/README.md): a cleanup wizard that works without AI, an optional AI assistant (Claude, ChatGPT, Gemini, Grok, Ollama, LM Studio), and an MCP server mode (`pc-cleanup.exe --mcp`). Every change still requires a Windows confirmation dialog. Builds are published as draft GitHub Releases.

## Installation

**Option 1: Claude Code plugin marketplace**

```
/plugin marketplace add ChiJiun/windows-pc-cleanup-skill
/plugin install windows-pc-cleanup@windows-pc-cleanup-skill
```

**Option 2: Copy manually**

Copy the whole `skills/windows-pc-cleanup` folder into `%USERPROFILE%\.claude\skills\`.

## Usage

Just ask in Claude Code, for example:

- "Clean up my PC and free some disk space. Check with me before changing anything."
- "Organize my Downloads folder."
- "Check my PC's health and see if anything in Task Manager looks wrong."

Requests in Chinese work too, e.g. 「幫我清理電腦」「整理我的下載資料夾」「檢查電腦健康」.

You can also run the scripts on their own (all in `skills/windows-pc-cleanup/scripts/`):

```powershell
$S = powershell -ExecutionPolicy Bypass -File scripts\new-session.ps1 -Lang en
powershell -ExecutionPolicy Bypass -File scripts\scan-cleanup-targets.ps1 -SessionDir $S
powershell -ExecutionPolicy Bypass -File scripts\health-check.ps1 -SessionDir $S
powershell -ExecutionPolicy Bypass -File scripts\build-report.ps1 -SessionDir $S
```

Scripts that change files (`clean-old-files.ps1`, `clear-folder.ps1`, `organize-apply.ps1`, `organize-undo.ps1`) **only do a dry run unless you add `-Apply`**.

## Language

- Claude replies in your language and passes the matching `-Lang` to `new-session.ps1` when it creates the session; later scripts in the same session pick it up automatically.
- Every script accepts `-Lang zh-TW` or `-Lang en`, which sets the language of its output messages and of the HTML report. Without `-Lang`, the language is resolved in this order:
  1. the `PCC_LANG` environment variable (e.g. `$env:PCC_LANG = 'en'`)
  2. the language recorded in the session's `baseline.json` (written by `new-session.ps1 -Lang`)
  3. the system UI language (`zh*` uses `zh-TW`, anything else uses `en`)
- There are two sets of file organization rules: `assets/organize-rules.default.json` (Chinese folder names such as 文件, 圖片) and `assets/organize-rules.en.json` (English folder names such as Documents, Images). If you do not pass `-RulesFile`, the one matching the language is used.
- The skill's main instructions are the English [SKILL.md](skills/windows-pc-cleanup/SKILL.md), with a Traditional Chinese counterpart in [SKILL.zh-TW.md](skills/windows-pc-cleanup/SKILL.zh-TW.md). Reference docs are in [`references/`](skills/windows-pc-cleanup/references/) (English) and [`references/zh-TW/`](skills/windows-pc-cleanup/references/zh-TW/) (Traditional Chinese).

## Traceability and undo

- Each session's data is stored in `%USERPROFILE%\PCCleanup\<timestamp>\`.
- `actions.jsonl`: one line per action, recording the time, command, target, measured space freed, result, and how to undo it.
- `clean-old-files-*.log`, `organize-plan-*.csv`, `organize-log-*.csv`: per-file details.
- File organization also leaves a log folder inside the organized folder (including `organize-undo.ps1`; the folder name comes from `logFolder` in the rules file, `_整理紀錄` in the Chinese rules, `_organize-logs` in the English rules), so changes can be undone even if the session folder is deleted.
- In the organize log CSV, items sent to the Recycle Bin are marked `(RecycleBin)` in the `Final` column, regardless of language. `organize-undo.ps1` still reads the legacy `(資源回收筒)` marker in older logs.
- `report.html` lists the SHA256 of every log file, so you can verify the logs have not been altered.

> Reports and logs contain local paths and file names. Review them before sharing.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 or PowerShell 7
- Most features do not need administrator rights

## Development

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Tests run only inside a temp folder and never touch your files. Scripts must be saved as **UTF-8 with BOM** (the tests check this).

## Prior art

The design draws on BleachBit, WinDirStat, FluentCleaner, sifty, and a few macOS cleaner skills. See [prior-art.md](skills/windows-pc-cleanup/references/prior-art.md).

## License

MIT
