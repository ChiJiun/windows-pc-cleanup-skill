English | [繁體中文](zh-TW/health-check-guide.md)

# Health Check Interpretation Guide

| Item | What to look at | Threshold | Common false alarms |
|---|---|---|---|
| CPU | `cpu.totalPercent` and `topProcesses` in `health.json` (grouped by program name, divided by the number of logical processors) | Sustained ≥ 70% is a warning | The check itself (WMI, Task Manager, PowerShell) uses 10–20%; `Win32_Processor.LoadPercentage` is an instantaneous value and fluctuates a lot |
| Kernel time | `privilegedPercent` | Consistently > 40% may point to a driver or antivirus scanning | Also high while many processes are starting or during WMI queries |
| Memory | `usedPercent`, `commitPercent` | Usage ≥ 85% is a warning; commit ≥ 90% is critical | Little "available" memory is not necessarily a problem, since Windows uses free memory as cache; things only really slow down when commit nears its limit |
| Duplicate processes | `duplicateProcesses`: the same command line ≥ 4 times | — | Flask / Django auto-reload gives each server 2 processes; browsers and Electron apps are multi-process by design (not counted) |
| Disk | `Get-PhysicalDisk` HealthStatus, reliability counters | Anything other than Healthy is critical | Without admin rights the reliability counters (temperature, wear) are often empty; that is not a fault |
| Battery | `powercfg /batteryreport /xml`: full charge capacity ÷ design capacity | < 60% warning; < 40% critical | A cycle count of 0 usually means the firmware does not report it |
| Unexpected shutdowns | Event 41 (Kernel-Power) | ≥ 3 in 30 days is a warning | Event 6008 appears in pairs with 41, so count only 41; forced shutdowns by the user also produce it |
| Blue screens | Event 1001 (WER-SystemErrorReporting) | Any occurrence is a warning | — |
| Windows Update | Error codes from the WindowsUpdateClient event source | Depends on the code | `0x80073D02` just means an app was in use and could not be updated; closing it fixes it |
| Devices | `Get-PnpDevice` with status Error / Degraded | Info | VPN virtual adapters (PANGP, TAP, Wintun) are normally in an error state while disconnected |
| Antivirus | `Get-MpComputerStatus` | Real-time protection off is critical; signatures > 7 days old is a warning | Defender disables itself automatically when another antivirus is installed |
| Network adapter driver | Event sources Netwtw*, rt640x64, etc. | Info | An occasional "returned an invalid value" has little impact; only frequent disconnects need attention |

## Looking at Task Manager with computer use

- To open it: request access to Task Manager with `request_access`, then call `open_application`.
- On an administrator account, Task Manager runs elevated, and Windows UIPI blocks computer use clicks and key presses, so you can only screenshot the default Processes tab. If clicks have no effect, do not retry and do not look for another way around it; switch to the performance counters.
- Screenshots are useful to confirm overall CPU and memory percentages and the sort order, and to cross-check the `health-check.ps1` data.
- Resource Monitor (resmon) usually needs elevation as well.

## How to report

- Sort by severity. For each item, explain what was seen, the likely cause, the recommended fix, and whether the user needs to do anything.
- Recommendations that involve ending processes, updating drivers, or replacing hardware are recommendations only; do not carry them out.
