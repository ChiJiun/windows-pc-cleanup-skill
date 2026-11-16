// 前端與 Rust 後端之間的合約。所有 Tauri command 都經過這裡，前端元件不要直接呼叫 invoke。
// 安全設計：任何會改動電腦的動作（apply = true）一律由後端跳出 Windows 原生確認視窗，
// 使用者按「確定」才會執行；前端與 AI 都無法略過這一關。
import { invoke } from "@tauri-apps/api/core";

export type Lang = "zh-TW" | "en";

export interface AppInfo {
  version: string;
  scriptsDir: string;
  sessionsRoot: string;
  lang: Lang;
  isAdmin: boolean;
  exePath: string;
  currentSession: string | null;
}

/** 腳本執行結果。data 是腳本寫出的 JSON（依工具不同，見下方各型別），沒有時為 null。 */
export interface ToolResult {
  ok: boolean;
  /** 使用者在確認視窗按了取消 */
  cancelled: boolean;
  exitCode: number;
  /** 腳本的文字輸出（已是 UTF-8） */
  output: string;
  data: unknown;
}

export type ToolName =
  | "start_session"
  | "scan_overview"
  | "scan_cleanup_targets"
  | "scan_large_items"
  | "scan_startup"
  | "health_check"
  | "measure_free"
  | "clear_folder"
  | "clean_old_files"
  | "organize_plan"
  | "organize_apply"
  | "organize_undo"
  | "build_report"
  | "log_action";

// ---- 各工具 data 的型別（只列前端會用到的欄位） ----
export interface Overview {
  os: string;
  model: string;
  cpu: string;
  ramTotalBytes: number;
  drives?: { Drive: string; FreeBytes: number; SizeBytes?: number }[];
}
export interface CleanupTarget {
  Id: string;
  Name: string;
  Path: string;
  RealPath: string;
  Bytes: number;
  OldBytes: number;
  Files: number;
  Risk: "A" | "B";
  Method: string;
  /** 後端判斷可用的清理方式：clear-folder、clean-old-files，或 manual（只能手動處理） */
  Action: "clear-folder" | "clean-old-files" | "manual";
  /** 清理前要先關閉的程式（傳給 clear_folder 的 processNames） */
  Procs: string[];
  RunningApps: string[];
}
export interface CleanupTargets {
  targets: CleanupTarget[];
  recycleBin: { Count: number; Bytes: number };
  isAdmin: boolean;
}
export interface Finding {
  Severity: "critical" | "warn" | "info";
  Area: string;
  Title: string;
  Detail: string;
  Advice: string;
}
export interface Health {
  findings: Finding[];
  uptimeHours: number;
}
export interface PlanRow {
  Source: string;
  Action: "Move" | "Recycle";
  Dest: string;
  Reason: string;
  Category: string;
  Keep: string;
}
export interface OrganizePlan {
  planFile: string;
  rows: PlanRow[];
}
export interface ReportData {
  reportPath: string;
}

export type ProviderId = "anthropic" | "openai" | "gemini" | "xai" | "openrouter" | "ollama" | "lmstudio" | "custom";

/** Claude Desktop 的 MCP 連結狀態 */
export interface ClaudeDesktopStatus {
  /** 找得到 Claude Desktop 的設定資料夾 */
  found: boolean;
  configPath: string;
  /** 設定檔裡已經有本程式的項目 */
  connected: boolean;
  /** 已有的項目指向目前這個 exe（exe 被移動後會變成 false，需要重新連結） */
  pointsToThisExe: boolean;
  /** 設定檔不是合法 JSON，不會修改它 */
  invalidJson: boolean;
}

/** 偵測到的地端模型服務 */
export interface LocalServer {
  provider: "ollama" | "lmstudio";
  label: string;
  baseUrl: string;
  running: boolean;
  models: string[];
}

export interface ProviderPreset {
  id: ProviderId;
  label: string;
  /** 是否需要 API key（地端模型不需要） */
  needsKey: boolean;
  /** 是否為地端（不會把資料送到網路上） */
  local: boolean;
  defaultBaseUrl: string;
  defaultModel: string;
}

export interface Settings {
  lang: Lang;
  provider: ProviderId;
  model: string;
  /** 空字串代表使用預設網址 */
  baseUrl: string;
  /** 送到雲端模型前，把使用者名稱、使用者資料夾與電腦名稱遮蔽掉 */
  redact: boolean;
}

/** 聊天訊息。tool 訊息是工具執行結果，assistant 訊息可能帶 toolCalls。 */
export interface ChatMessage {
  role: "user" | "assistant" | "tool";
  content: string;
  toolCalls?: ToolCall[];
  toolCallId?: string;
}
export interface ToolCall {
  id: string;
  name: ToolName;
  /** JSON 物件 */
  arguments: Record<string, unknown>;
}

export const api = {
  appInfo: () => invoke<AppInfo>("app_info"),
  /** 執行工具。需要工作階段的工具會自動帶入目前的工作階段（沒有時後端會先建立一個）。 */
  runTool: (name: ToolName, args: Record<string, unknown> = {}) => invoke<ToolResult>("run_tool", { name, args }),
  getSettings: () => invoke<Settings>("get_settings"),
  saveSettings: (settings: Settings) => invoke<void>("save_settings", { settings }),
  providerPresets: () => invoke<ProviderPreset[]>("provider_presets"),
  /** API key 存在 Windows 認證管理員，前端拿不回明文，只能知道有沒有設定。 */
  setApiKey: (provider: ProviderId, key: string) => invoke<void>("set_api_key", { provider, key }),
  hasApiKey: (provider: ProviderId) => invoke<boolean>("has_api_key", { provider }),
  deleteApiKey: (provider: ProviderId) => invoke<void>("delete_api_key", { provider }),
  listModels: () => invoke<string[]>("list_models"),
  /** 送出對話，回傳模型的下一則 assistant 訊息（可能含 toolCalls）。系統提示與工具定義由後端加上。 */
  chat: (messages: ChatMessage[]) => invoke<ChatMessage>("chat", { messages }),
  /** 用系統預設程式開啟工作階段資料夾內的檔案（例如 report.html）或資料夾本身 */
  openSessionPath: (path: string) => invoke<void>("open_session_path", { path }),
  /** 只允許 https 網址（贊助頁、GitHub） */
  openUrl: (url: string) => invoke<void>("open_url", { url }),
  /** 給 Claude Desktop 等 MCP 用戶端的設定片段 */
  mcpConfig: () => invoke<string>("mcp_config"),
  /** 開瀏覽器用 OpenRouter 登入，完成後 API key 存進認證管理員並切換到 OpenRouter。最多等 5 分鐘。 */
  openrouterLogin: () => invoke<void>("openrouter_login"),
  /** 取消進行中的 OpenRouter 登入 */
  openrouterCancel: () => invoke<void>("openrouter_cancel"),
  claudeDesktopStatus: () => invoke<ClaudeDesktopStatus>("claude_desktop_status"),
  /** 加入（add = true）或移除 Claude Desktop 的 MCP 設定；會跳原生確認視窗，回傳 false 代表使用者取消 */
  claudeDesktopConnect: (add: boolean) => invoke<boolean>("claude_desktop_connect", { add }),
  /** 偵測 Ollama 與 LM Studio 是否在執行，以及已安裝的模型 */
  detectLocalModels: () => invoke<LocalServer[]>("detect_local_models"),
};
