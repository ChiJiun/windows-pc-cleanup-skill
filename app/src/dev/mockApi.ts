// 只在開發模式、而且不在 Tauri 視窗裡時使用的假資料（見 src/backend.ts）。
// 正式建置時 import.meta.env.DEV 為 false，這個檔案不會被打包進去。
import type { Api } from "../backend";
import type { ChatMessage, LocalServer, ProviderId, ProviderPreset, Settings, ToolName, ToolResult } from "../api";

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
const GB = 1024 ** 3;
const MB = 1024 ** 2;

let settings: Settings = { lang: "zh-TW", provider: "anthropic", model: "", baseUrl: "", redact: true };
const keys = new Set<ProviderId>();
let claudeStatus = {
  found: true,
  configPath: "C:\\mock\\Claude\\claude_desktop_config.json",
  connected: false,
  pointsToThisExe: false,
  invalidJson: false,
};

const presets: ProviderPreset[] = [
  { id: "anthropic", label: "Anthropic", needsKey: true, local: false, defaultBaseUrl: "https://api.anthropic.com", defaultModel: "mock-model-a" },
  { id: "openai", label: "OpenAI", needsKey: true, local: false, defaultBaseUrl: "https://api.openai.com/v1", defaultModel: "mock-model-b" },
  { id: "openrouter", label: "OpenRouter", needsKey: true, local: false, defaultBaseUrl: "https://openrouter.ai/api/v1", defaultModel: "openrouter/auto" },
  { id: "ollama", label: "Ollama", needsKey: false, local: true, defaultBaseUrl: "http://localhost:11434", defaultModel: "mock-local" },
  { id: "custom", label: "Custom (OpenAI-compatible)", needsKey: true, local: false, defaultBaseUrl: "", defaultModel: "" },
];

function ok(data: unknown, output = "（假資料）完成"): ToolResult {
  return { ok: true, cancelled: false, exitCode: 0, output, data };
}

const mockData: Partial<Record<ToolName, () => ToolResult>> = {
  start_session: () => ok({ sessionDir: "C:\\mock\\sessions\\20261115-120000" }, "工作階段：C:\\mock\\sessions\\20261115-120000"),
  scan_overview: () =>
    ok({
      os: "Windows 11 Pro (mock)",
      model: "Mock Laptop 14",
      cpu: "Mock CPU 8 cores",
      ramTotalBytes: 16 * GB,
      drives: [
        { Drive: "C:", FreeBytes: 18 * GB, SizeBytes: 237 * GB },
        { Drive: "D:", FreeBytes: 410 * GB, SizeBytes: 931 * GB },
      ],
    }),
  scan_cleanup_targets: () =>
    ok({
      targets: [
        { Id: "user-temp", Name: "使用者暫存檔", Path: "%TEMP%", RealPath: "C:\\Users\\mock\\AppData\\Local\\Temp", Bytes: 3.2 * GB, OldBytes: 2.9 * GB, Files: 12034, Risk: "A", Method: "刪除 7 天前的暫存檔", Action: "clean-old-files", Procs: [], RunningApps: [] },
        { Id: "chrome-cache", Name: "Chrome 快取", Path: "...", RealPath: "C:\\Users\\mock\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache", Bytes: 820 * MB, OldBytes: 0, Files: 5021, Risk: "A", Method: "關閉 Chrome 後清空", Action: "clear-folder", Procs: ["chrome"], RunningApps: ["chrome"] },
        { Id: "teams-cache", Name: "Teams 快取", Path: "...", RealPath: "C:\\Users\\mock\\AppData\\Roaming\\Microsoft\\Teams\\Cache", Bytes: 410 * MB, OldBytes: 0, Files: 801, Risk: "A", Method: "關閉 Teams 後清空", Action: "clear-folder", Procs: "Teams", RunningApps: null },
        { Id: "wu-cache", Name: "Windows Update 快取", Path: "...", RealPath: "C:\\Windows\\SoftwareDistribution\\Download", Bytes: 2.1 * GB, OldBytes: 2.1 * GB, Files: 220, Risk: "A", Method: "用「磁碟清理」的「Windows Update 清理」", Action: "manual", Procs: [], RunningApps: [] },
        { Id: "downloads", Name: "下載資料夾", Path: "...", RealPath: "C:\\Users\\mock\\Downloads", Bytes: 14 * GB, OldBytes: 9 * GB, Files: 912, Risk: "B", Method: "由使用者判斷；可用「整理下載資料夾」分類", Action: "manual", Procs: [], RunningApps: [] },
      ],
      recycleBin: { Count: 42, Bytes: 1.4 * GB },
      isAdmin: false,
    }),
  scan_startup: () => ok({ items: [] }, "啟動項目 12 個"),
  health_check: () =>
    ok({
      uptimeHours: 171.4,
      findings: [
        { Severity: "info", Area: "系統", Title: "已連續開機超過 7 天", Detail: "171 小時未重新開機。", Advice: "建議重新開機以套用更新。" },
        { Severity: "critical", Area: "磁碟", Title: "C 槽可用空間不足 10%", Detail: "可用 18 GB／共 237 GB。", Advice: "先清理暫存檔與下載資料夾。" },
        { Severity: "warn", Area: "啟動", Title: "開機啟動項目偏多", Detail: "共有 12 個啟動項目。", Advice: "到工作管理員停用不需要的項目。" },
      ],
    }),
  organize_plan: () =>
    ok({
      planFile: "C:\\mock\\sessions\\plan.csv",
      rows: [
        { Source: "C:\\Users\\mock\\Downloads\\report.pdf", Action: "Move", Dest: "C:\\Users\\mock\\Downloads\\文件\\report.pdf", Reason: "副檔名 .pdf", Category: "文件", Keep: "" },
        { Source: "C:\\Users\\mock\\Downloads\\setup (1).exe", Action: "Recycle", Dest: "", Reason: "與 setup.exe 內容相同", Category: "重複", Keep: "C:\\Users\\mock\\Downloads\\setup.exe" },
        { Source: "C:\\Users\\mock\\Downloads\\photo.jpg", Action: "Move", Dest: "C:\\Users\\mock\\Downloads\\圖片\\photo.jpg", Reason: "副檔名 .jpg", Category: "圖片", Keep: "" },
      ],
    }),
  organize_apply: () => ok(null, "成功 3、失敗 0、略過 0。\n還原用的紀錄與腳本另存在：C:\\Users\\mock\\Downloads\\_整理紀錄"),
  build_report: () => ok({ reportPath: "C:\\mock\\sessions\\20261115-120000\\report.html" }, "報告已產生"),
};

let chatTurn = 0;

export const mockApi: Api = {
  appInfo: async () => ({
    version: "0.1.0-dev",
    scriptsDir: "C:\\mock\\scripts",
    sessionsRoot: "C:\\mock\\sessions",
    lang: settings.lang,
    isAdmin: false,
    exePath: "C:\\mock\\app.exe",
    currentSession: "C:\\mock\\sessions\\20261115-120000",
  }),
  runTool: async (name, args = {}) => {
    await delay(name === "health_check" ? 3000 : 600);
    if ((name === "clear_folder" || name === "clean_old_files") && !args.apply) {
      return ok(null, `（試跑）${String(args.path)}：會刪除 ${name === "clear_folder" ? "資料夾內所有檔案" : "舊檔"}`);
    }
    if (args.apply && Math.random() < 0.3) {
      return { ok: false, cancelled: true, exitCode: 1, output: "使用者取消", data: null };
    }
    const f = mockData[name];
    return f ? f() : ok(null, `（假資料）${name} ${JSON.stringify(args)}`);
  },
  getSettings: async () => ({ ...settings }),
  saveSettings: async (s) => {
    settings = { ...s };
  },
  providerPresets: async () => presets,
  setApiKey: async (p) => {
    keys.add(p);
  },
  hasApiKey: async (p) => keys.has(p),
  deleteApiKey: async (p) => {
    keys.delete(p);
  },
  listModels: async () => {
    await delay(400);
    return ["mock-model-a", "mock-model-b", "mock-model-c"];
  },
  chat: async (messages: ChatMessage[]): Promise<ChatMessage> => {
    await delay(700);
    const last = messages[messages.length - 1];
    if (last?.role === "user") {
      chatTurn++;
      return {
        role: "assistant",
        content: "好的，我先看看系統概況。",
        toolCalls: [{ id: `call-${chatTurn}`, name: "scan_overview", arguments: {} }],
      };
    }
    return {
      role: "assistant",
      content:
        "掃描完成，重點如下：\n\n- **C 槽**只剩 18 GB\n- 暫存資料夾 `%TEMP%` 有 3.2 GB\n\n建議：\n1. 先清理暫存檔\n2. 再整理下載資料夾\n\n<b>這段 HTML 不應該被解析</b>",
    };
  },
  openSessionPath: async (p) => {
    console.info("[mock] openSessionPath", p);
  },
  openUrl: async (u) => {
    console.info("[mock] openUrl", u);
  },
  mcpConfig: async () =>
    JSON.stringify({ mcpServers: { "pc-cleanup": { command: "C:\\mock\\app.exe", args: ["--mcp"] } } }, null, 2),
  openrouterLogin: async () => {
    await delay(1500);
    keys.add("openrouter");
    settings = { ...settings, provider: "openrouter", model: "openrouter/auto", baseUrl: "" };
  },
  openrouterCancel: async () => {},
  claudeDesktopStatus: async () => ({ ...claudeStatus }),
  claudeDesktopConnect: async (add) => {
    await delay(500);
    claudeStatus = { ...claudeStatus, connected: add, pointsToThisExe: add };
    return true;
  },
  detectLocalModels: async () => {
    await delay(400);
    const out: LocalServer[] = [
      { provider: "ollama", label: "Ollama", baseUrl: "http://localhost:11434/v1", custom: false, running: true, models: ["mock-local", "mock-local-2"] },
      { provider: "lmstudio", label: "LM Studio", baseUrl: "http://localhost:1234/v1", custom: false, running: false, models: [] },
    ];
    // 與後端相同：目前設定是地端供應商且填了不同的自訂位址時，多列一個自訂位址的項目（假資料：自訂位址上只有 mock-remote）
    const base = settings.baseUrl.trim().replace(/\/+$/, "");
    const i = out.findIndex((s) => s.provider === settings.provider);
    if (i >= 0 && base && base.toLowerCase() !== out[i].baseUrl.toLowerCase()) {
      out.splice(i + 1, 0, { ...out[i], baseUrl: base, custom: true, running: true, models: ["mock-remote"] });
    }
    return out;
  },
};
