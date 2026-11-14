English | [繁體中文](zh-TW/cleanup-catalog.md)

# Cleanup Location Catalog

Risk levels: **A** = cache / temp, rebuilds automatically after deletion; **B** = needs the user's judgment; **C** = needs administrator rights or can only be done by the user.

| Location | Level | Recommended method | Notes |
|---|---|---|---|
| Files in `%TEMP%` older than 7 days | A | `clean-old-files.ps1 -OlderThanDays 7 -ExcludeTopLevel claude` | Exclude temp folders of tools still in use (e.g. Claude Code's `Temp\claude`); locked files are skipped automatically |
| `%TEMP%\claude` | B | Delete only subfolders of sessions that have ended | Running sessions write here; if unsure, leave it alone. **Permanent deletion: confirm separately and state that it cannot be undone** |
| Installer temp folders (e.g. random folders created by the Visual Studio installer) | B | Clean after the installation finishes | A modification time of today usually means it is still in use |
| Chrome / Edge cache, Code Cache | A | `clear-folder.ps1` after closing the browser | Skip if the browser is running |
| New Teams cache `Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams` | A | `clear-folder.ps1` after closing Teams | The reset method Microsoft recommends; the user may need to sign in again |
| VS Code `Cache`, `CachedData` | A | Clean after closing VS Code | `workspaceStorage` holds workspace state; cleaning it is not recommended |
| Hugging Face `~/.cache/huggingface` | A | `clear-folder.ps1` | Models will be re-downloaded when needed, which can be large |
| conda `pkgs` | A | `conda clean --all -y` | **Packages are often shared with environments via hard links**, so the folder size overstates what will be freed; go by the measured disk space before and after |
| Old conda environments | B | `conda env remove -n <name>` | List each environment's size and last modified date and let the user choose. **Permanent deletion: confirm separately**; suggest `conda env export -n <name> > <name>.yml` first to keep a list for rebuilding |
| npm / pip / uv / pnpm / yarn caches | A | Official commands (see [SKILL.md](../SKILL.md)) | Find the actual location first with `npm config get cache`, `pip cache dir`, `uv cache dir`; it may be configured on another drive |
| Docker | A/B | `docker builder prune -f` (A); `docker image prune -a` (B: permanently deletes unused images, confirm separately; they must be pulled or rebuilt when needed) | `docker_data.vhdx` does not shrink right away; compact it in Docker Desktop or with `Optimize-VHD` (needs admin) |
| WSL virtual disk `ext4.vhdx` | C | After `wsl --shutdown`, compact with `Optimize-VHD` or diskpart | Compare internal usage from `wsl -- df -h /` with the vhdx size first; if the gap is small, it is not worth it |
| VirtualBox VMs | B | `VBoxManage unregistervm <name> --delete` | Permanent deletion. Use `showvminfo` first to check the OS, last use, and shared folders, to help the user remember what it was for |
| Android emulators (BlueStacks, LDPlayer, etc.) | B | Official uninstaller | Apps and data inside the emulator are deleted too; BlueStacks also has BlueStacks Services, which must be removed separately |
| Games | B | Remove via the launcher (Steam, Battle.net, Riot Client) or the registered `UninstallString` | After removing VALORANT, the Riot Vanguard anti-cheat driver is still installed; ask about it separately |
| Installers, duplicates, and already-extracted archives in Downloads | B | `organize-plan.ps1` → confirm → `organize-apply.ps1` | Sent to the Recycle Bin; VPN and certificate installers are kept by default |
| Recycle Bin | B | `Clear-RecycleBin -Force` | Permanent deletion; confirm separately |
| Windows Update cache, `C:\Windows\Temp` | C | Settings > System > Storage > Temporary files | Needs administrator rights |

## Known pitfalls

- **Junctions / symbolic links**: users often move large folders to drive D and leave a junction on drive C. The size measured through the C: path is actually on D:, and cleaning it frees space on D:. `scan-cleanup-targets.ps1` flags the actual location, and `Get-PccDirStats` does not follow junctions in subfolders.
- **Last access time is unreliable**: scanning itself updates folder access times, so it cannot tell you whether something was used recently. Look at file modification times, program config files, or usage history instead.
- **Concurrent writes offset the gain**: if other programs (AI tools, downloads, builds) keep writing during cleanup, the change in free space will be smaller than what was actually removed. Mention this when reporting.
