English | [繁體中文](zh-TW/prior-art.md)

# Prior Art

Projects reviewed before designing this skill. Only design ideas are noted here; none of their code was copied.

| Project | Type | What we borrowed |
|---|---|---|
| [BleachBit](https://www.bleachbit.org/) | Cross-platform cleaner (GPL) | Listing locations per "cleaner" and offering a preview |
| [WinDirStat](https://github.com/windirstat/windirstat) | Disk usage visualizer (GPL-2.0) | Find the large files and folders first, then let the user decide |
| [FluentCleaner](https://github.com/builtbybel/FluentCleaner) | Windows cleaner using winapp2.ini rules | Defining cleanup locations as data instead of hard-coding them |
| [sifty](https://vortrix5.github.io/sifty/) | Terminal cleaner | Deleting only to the Recycle Bin so every cleanup can be undone |
| macOS cleaner skills (e.g. `macos-cleaner` by daymade and fernandezbaptiste) | Claude Code skills | Interactive analysis and asking for confirmation before deleting |

What this skill does differently:

- Focuses on Windows and handles Windows-specific pitfalls such as junctions, hard links, UIPI, and PowerShell 5.1 encoding.
- Combines cleanup, file organization, and hardware/software health checks in one workflow, ending with a traceable HTML report.
- Every script that changes the computer runs as a dry run by default, and every action is written to `actions.jsonl` along with how to undo it.
