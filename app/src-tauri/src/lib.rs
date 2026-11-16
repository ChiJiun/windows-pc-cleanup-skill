//! Tauri 桌面程式進入點與前端可呼叫的 command。合約見 app/src/api.ts。

mod confirm;
mod connect;
mod llm;
mod mcp;
mod scripts;
mod settings;
mod tools;

use serde::Serialize;
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use tauri::State;
use tools::{Core, ToolResult};

type St<'a> = State<'a, Arc<Core>>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    version: String,
    scripts_dir: String,
    sessions_root: String,
    lang: String,
    is_admin: bool,
    exe_path: String,
    current_session: Option<String>,
}

fn is_admin() -> bool {
    // SAFETY：沒有參數的查詢函式
    unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
}

#[tauri::command]
async fn app_info(state: St<'_>) -> Result<AppInfo, String> {
    let root = scripts::ensure_extracted()?;
    Ok(AppInfo {
        version: env!("CARGO_PKG_VERSION").into(),
        scripts_dir: scripts::scripts_dir(&root).to_string_lossy().into(),
        sessions_root: tools::sessions_root().to_string_lossy().into(),
        lang: state.lang(),
        is_admin: is_admin(),
        exe_path: std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        current_session: state.session.lock().map_err(|e| e.to_string())?.as_ref().map(|p| p.to_string_lossy().into_owned()),
    })
}

#[tauri::command]
async fn run_tool(window: tauri::WebviewWindow, state: St<'_>, name: String, args: Value) -> Result<ToolResult, String> {
    let hwnd = window.hwnd().map(|h| h.0 as isize).unwrap_or(0);
    let core = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || tools::run_tool(&core, &name, &args, &confirm::Origin::Gui(hwnd)))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn get_settings(state: St<'_>) -> Result<settings::Settings, String> {
    Ok(state.settings.lock().map_err(|e| e.to_string())?.clone())
}

#[tauri::command]
async fn save_settings(state: St<'_>, settings: settings::Settings) -> Result<(), String> {
    let mut s = settings;
    s.sanitize();
    settings::save(&s)?;
    *state.settings.lock().map_err(|e| e.to_string())? = s;
    Ok(())
}

#[tauri::command]
async fn provider_presets() -> Result<Vec<llm::Preset>, String> {
    Ok(llm::presets())
}

fn known_provider(p: &str) -> Result<(), String> {
    if llm::presets().iter().any(|x| x.id == p) { Ok(()) } else { Err(format!("unknown provider: {p}")) }
}

#[tauri::command]
async fn set_api_key(provider: String, key: String) -> Result<(), String> {
    known_provider(&provider)?;
    settings::set_key(&provider, &key)
}

#[tauri::command]
async fn has_api_key(provider: String) -> Result<bool, String> {
    known_provider(&provider)?;
    Ok(settings::get_key(&provider).is_some())
}

#[tauri::command]
async fn delete_api_key(provider: String) -> Result<(), String> {
    known_provider(&provider)?;
    settings::delete_key(&provider)
}

fn current_settings(state: &St<'_>) -> Result<(settings::Settings, Option<String>), String> {
    let s = state.settings.lock().map_err(|e| e.to_string())?.clone();
    let key = settings::get_key(&s.provider);
    Ok((s, key))
}

#[tauri::command]
async fn list_models(state: St<'_>) -> Result<Vec<String>, String> {
    let (s, key) = current_settings(&state)?;
    llm::list_models(&s, key).await
}

#[tauri::command]
async fn chat(state: St<'_>, messages: Vec<llm::ChatMessage>) -> Result<llm::ChatMessage, String> {
    let (s, key) = current_settings(&state)?;
    llm::chat(&s, key, messages).await
}

/// 只允許開啟工作階段根資料夾底下的檔案或資料夾
#[tauri::command]
async fn open_session_path(path: String) -> Result<(), String> {
    let root = tools::canonical(&tools::sessions_root()).ok_or("sessions folder not found")?;
    let p = tools::canonical(Path::new(&path)).ok_or("path not found")?;
    let (pl, rl) = (p.to_string_lossy().to_lowercase(), root.to_string_lossy().to_lowercase());
    if !(pl == rl || pl.starts_with(&format!("{rl}\\"))) {
        return Err("only files inside the sessions folder can be opened".into());
    }
    let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if p.is_file() && !["html", "csv", "json", "jsonl", "log", "txt", "xml"].contains(&ext.as_str()) {
        return Err("this file type cannot be opened from the app".into());
    }
    tauri_plugin_opener::open_path(p, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") || url.chars().any(|c| c.is_whitespace() || c == '"') {
        return Err("only https URLs are allowed".into());
    }
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// 用 OpenRouter 登入：開瀏覽器 → 使用者登入並同意 → 本機接收授權碼 → 換成 API key 存進認證管理員，並切換到 OpenRouter
#[tauri::command]
async fn openrouter_login(state: St<'_>) -> Result<(), String> {
    let zh = state.lang() != "en";
    let _guard = connect::LoginGuard::acquire(zh)?;
    let pending = connect::start_login()?;
    tauri_plugin_opener::open_url(pending.auth_url.clone(), None::<&str>).map_err(|e| e.to_string())?;
    let (pending, code) = tauri::async_runtime::spawn_blocking(move || {
        let c = connect::wait_for_code(&pending, zh);
        (pending, c)
    })
    .await
    .map_err(|e| e.to_string())?;
    let key = connect::exchange_code(&pending, &code?, zh).await?;
    settings::set_key("openrouter", &key)?;
    let mut s = state.settings.lock().map_err(|e| e.to_string())?.clone();
    if s.provider != "openrouter" {
        s.provider = "openrouter".into();
        s.model = String::new();
        s.base_url = String::new();
    }
    if s.model.is_empty() {
        s.model = llm::presets().into_iter().find(|p| p.id == "openrouter").map(|p| p.default_model.to_string()).unwrap_or_default();
    }
    s.sanitize();
    settings::save(&s)?;
    *state.settings.lock().map_err(|e| e.to_string())? = s;
    Ok(())
}

#[tauri::command]
async fn openrouter_cancel() -> Result<(), String> {
    connect::cancel_login();
    Ok(())
}

#[tauri::command]
async fn claude_desktop_status() -> Result<connect::ClaudeDesktopStatus, String> {
    Ok(connect::claude_status())
}

/// 加入或移除 Claude Desktop 的 MCP 設定（會跳原生確認視窗）。回傳 false 代表使用者取消。
#[tauri::command]
async fn claude_desktop_connect(window: tauri::WebviewWindow, state: St<'_>, add: bool) -> Result<bool, String> {
    let hwnd = window.hwnd().map(|h| h.0 as isize).unwrap_or(0);
    let zh = state.lang() != "en";
    tauri::async_runtime::spawn_blocking(move || connect::claude_set(&confirm::Origin::Gui(hwnd), zh, add))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn detect_local_models(state: St<'_>) -> Result<Vec<connect::LocalServer>, String> {
    // 以已儲存的設定為準：目前用的是地端供應商且填了自訂位址時，也偵測那個位址
    let (provider, base_url) = {
        let s = state.settings.lock().map_err(|e| e.to_string())?;
        (s.provider.clone(), s.base_url.clone())
    };
    Ok(connect::detect_local(&provider, &base_url).await)
}

#[tauri::command]
async fn mcp_config() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let cfg = serde_json::json!({ "mcpServers": { "windows-pc-cleanup": { "command": exe, "args": ["--mcp"] } } });
    serde_json::to_string_pretty(&cfg).map_err(|e| e.to_string())
}

pub fn run_mcp() {
    mcp::serve();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(Core::new()))
        .invoke_handler(tauri::generate_handler![
            app_info,
            run_tool,
            get_settings,
            save_settings,
            provider_presets,
            set_api_key,
            has_api_key,
            delete_api_key,
            list_models,
            chat,
            open_session_path,
            open_url,
            mcp_config,
            openrouter_login,
            openrouter_cancel,
            claude_desktop_status,
            claude_desktop_connect,
            detect_local_models
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
