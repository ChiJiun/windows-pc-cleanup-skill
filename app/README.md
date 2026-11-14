# Windows PC Cleanup — desktop app

English | [繁體中文](#繁體中文)

A Windows desktop app (Tauri 2 + React) built on the same PowerShell scripts as the Claude Code skill in this repo.

- **Works without AI**: the Cleanup wizard runs scan → select → confirm → clean → report on its own.
- **Bring your own model**: the AI assistant tab talks to Anthropic Claude, OpenAI, Google Gemini, xAI Grok, Ollama, LM Studio, or any OpenAI-compatible endpoint. API keys are stored in Windows Credential Manager, never in a file.
- **MCP server**: `pc-cleanup.exe --mcp` exposes the same tools over stdio to MCP clients such as Claude Desktop, Claude Code, Cursor, LM Studio, and Gemini CLI. Settings → MCP shows a config snippet to paste.

## Safety model

- Every action that changes the computer (`apply: true`) shows a **Windows confirmation dialog** from the backend. The UI, the built-in AI, and MCP clients can only *request* an action; only a click on OK runs it. Cancel is the default button.
- `clear_folder` / `clean_old_files` only accept folders listed by the latest `scan_cleanup_targets` with a matching `Action`. `clean_old_files` always excludes `Temp\claude`.
- `organize_apply` only accepts plan files inside the current session; `organize_plan` never passes `-AllowUnsafeRoot`.
- With **Redact** on (the default), paths under `X:\Users\<name>` and the computer name are masked before anything is sent to a cloud model. Local models (localhost) receive the raw text.
- Scripts are embedded in the exe and re-extracted to `%LOCALAPPDATA%\WindowsPcCleanup\runtime-<version>` before every run, so an edited copy on disk is overwritten.

## Build

Requirements: Rust (stable), Node.js 22+, pnpm, WebView2 (built into Windows 11).

```bash
cd app
pnpm install
pnpm tauri dev      # development
pnpm tauri build    # release: src-tauri/target/release/pc-cleanup.exe and an NSIS installer
cd src-tauri && cargo test
```

## Release

Push a tag such as `app-v0.1.0`. `.github/workflows/release-app.yml` builds the portable exe and the installer, writes `SHA256SUMS.txt`, and creates a **draft** release for a maintainer to review and publish.

## Code signing

Releases are currently unsigned, so SmartScreen may warn about an unknown publisher. The plan is to apply for free open-source signing from the [SignPath Foundation](https://signpath.org/); once approved, add their signing step to the release workflow where it is marked.

## Sponsorship

Set your account names in `src/funding.ts` (desktop app) and `.github/FUNDING.yml` (GitHub Sponsor button).

---

## 繁體中文

這是 Windows 桌面程式（Tauri 2 + React），和這個 repo 的 Claude Code skill 共用同一套 PowerShell 腳本。

- **不接 AI 也能用**：「清理精靈」可以獨立完成「掃描 → 勾選 → 確認 → 清理 → 報告」。
- **自選模型**：「AI 助理」可以連 Anthropic Claude、OpenAI、Google Gemini、xAI Grok、Ollama、LM Studio，或任何 OpenAI 相容端點。API key 存在 Windows 認證管理員，不會寫進檔案。
- **MCP server**：`pc-cleanup.exe --mcp` 會以 stdio 提供同一套工具，給 Claude Desktop、Claude Code、Cursor、LM Studio、Gemini CLI 等 MCP 用戶端使用。「設定 → MCP」有可以直接貼上的設定片段。

### 安全設計

- **確認視窗**：任何會改動電腦的動作（`apply: true`），都由後端跳出 **Windows 確認視窗**。介面、內建 AI、MCP 用戶端都只能「提出」要求，使用者按「確定」才會執行；預設按鈕是「取消」。
- **清理範圍**：`clear_folder`／`clean_old_files` 只接受最近一次 `scan_cleanup_targets` 列出、而且 `Action` 相符的資料夾。`clean_old_files` 一定排除 `Temp\claude`。
- **整理檔案**：`organize_apply` 只接受目前工作階段內的計畫檔；`organize_plan` 不會加 `-AllowUnsafeRoot`。
- **遮蔽**：開啟「遮蔽」時（預設開啟），送到雲端模型前會把 `X:\Users\<名稱>` 底下的路徑和電腦名稱遮蔽掉。地端模型（localhost）收到的是原文。
- **腳本來源**：腳本內嵌在 exe 裡，每次執行前都會重新解壓到 `%LOCALAPPDATA%\WindowsPcCleanup\runtime-<版本>`；磁碟上的副本被改過也會被覆寫。

### 建置

需要的工具：Rust（stable）、Node.js 22 以上、pnpm、WebView2（Windows 11 已內建）。指令見上方英文段落。

### 發佈

推送 `app-v0.1.0` 這類標籤後，`.github/workflows/release-app.yml` 會：
1. 建置免安裝版 exe 與安裝檔。
2. 產生 `SHA256SUMS.txt`。
3. 建立**草稿** Release，由維護者檢查後再發佈。

### 程式碼簽章

目前發佈的是未簽章版本，所以 SmartScreen 可能會警告「未知的發行者」。預計申請 [SignPath Foundation](https://signpath.org/) 的免費開源簽章；通過後，在發佈 workflow 標示的位置加上簽章步驟。

### 贊助

- 桌面版：在 `src/funding.ts` 填入帳號名稱。
- GitHub 的 Sponsor 按鈕：在 `.github/FUNDING.yml` 填入帳號名稱。
