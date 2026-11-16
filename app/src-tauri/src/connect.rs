//! 一鍵連結：
//! - OpenRouter 登入（OAuth PKCE）：開瀏覽器讓使用者登入並同意，由本機 localhost 接收授權碼，換成 API key 存進 Windows 認證管理員。
//!   一個 OpenRouter 帳號就能使用 Claude、GPT、Gemini、Grok 等模型，費用由使用者自己的 OpenRouter 額度支付。
//! - 加入／移除 Claude Desktop：把本程式的 MCP 設定寫進 Claude Desktop 的 claude_desktop_config.json。
//!   寫入前一律跳原生確認視窗，並先備份原檔；原檔不是合法 JSON 時不動它。
//! - 偵測地端模型：檢查 Ollama 與 LM Studio 是否在執行，列出已安裝的模型。

use crate::confirm::{self, Origin};
use base64::Engine;
use serde::Serialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn msg(zh: bool, z: &str, e: &str) -> String {
    if zh { z.to_string() } else { e.to_string() }
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn random_token() -> Result<String, String> {
    let mut buf = [0u8; 32];
    getrandom::fill(&mut buf).map_err(|e| e.to_string())?;
    Ok(b64url(&buf))
}

/// PKCE S256：code_challenge = base64url(SHA-256(code_verifier))，不加 padding
pub(crate) fn pkce_challenge(verifier: &str) -> String {
    b64url(&Sha256::digest(verifier.as_bytes()))
}

// ---- OpenRouter 登入 ----

pub const OPENROUTER_AUTH: &str = "https://openrouter.ai/auth";
pub const OPENROUTER_KEYS: &str = "https://openrouter.ai/api/v1/auth/keys";
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

static CANCEL: AtomicBool = AtomicBool::new(false);
static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn cancel_login() {
    CANCEL.store(true, Ordering::SeqCst);
}

/// 同一時間只允許一個登入流程；結束時（含錯誤）自動解除
pub struct LoginGuard;
impl LoginGuard {
    pub fn acquire(zh: bool) -> Result<Self, String> {
        if RUNNING.swap(true, Ordering::SeqCst) {
            return Err(msg(zh, "已經有一個登入流程在進行中。", "A sign-in is already in progress."));
        }
        CANCEL.store(false, Ordering::SeqCst);
        Ok(LoginGuard)
    }
}
impl Drop for LoginGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::SeqCst);
    }
}

pub struct PendingLogin {
    listeners: Vec<TcpListener>,
    pub auth_url: String,
    verifier: String,
    state: String,
}

/// 只聽本機迴路位址（127.0.0.1 與 ::1，同一個 port），callback 用 localhost
pub fn start_login() -> Result<PendingLogin, String> {
    let v4 = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = v4.local_addr().map_err(|e| e.to_string())?.port();
    let mut listeners = vec![v4];
    if let Ok(v6) = TcpListener::bind(("::1", port)) {
        listeners.push(v6);
    }
    for l in &listeners {
        l.set_nonblocking(true).map_err(|e| e.to_string())?;
    }
    let verifier = random_token()?;
    let state = random_token()?;
    let callback = format!("http://localhost:{port}/callback");
    let auth_url = format!(
        "{OPENROUTER_AUTH}?callback_url={}&code_challenge={}&code_challenge_method=S256&state={}&key_label={}",
        urlencode(&callback),
        pkce_challenge(&verifier),
        state,
        urlencode("Windows PC Cleanup")
    );
    Ok(PendingLogin { listeners, auth_url, verifier, state })
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn urldecode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                match u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or(""), 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 從 HTTP 請求第一行（GET /callback?code=..&state=.. HTTP/1.1）取出查詢參數
pub(crate) fn parse_callback(request_line: &str) -> Option<Vec<(String, String)>> {
    let mut parts = request_line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?;
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    if path != "/callback" {
        return None;
    }
    Some(
        query
            .split('&')
            .filter(|kv| !kv.is_empty())
            .map(|kv| {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                (urldecode(k), urldecode(v))
            })
            .collect(),
    )
}

fn respond(mut s: TcpStream, ok: bool, zh: bool) {
    let (title, body) = if ok {
        (msg(zh, "已連結 OpenRouter", "Connected to OpenRouter"), msg(zh, "可以關閉這個分頁，回到 Windows PC Cleanup。", "You can close this tab and go back to Windows PC Cleanup."))
    } else {
        (msg(zh, "連結失敗", "Connection failed"), msg(zh, "請回到 Windows PC Cleanup 重新嘗試。", "Go back to Windows PC Cleanup and try again."))
    };
    let html = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>{title}</title></head><body style=\"font-family:system-ui;padding:40px\"><h1>{title}</h1><p>{body}</p></body></html>"
    );
    let _ = write!(
        s,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{html}",
        html.len()
    );
}

/// 一條 callback 連線的判讀結果
#[derive(Debug, PartialEq)]
pub(crate) enum CallbackResult {
    /// state 相符且帶有授權碼
    Code(String),
    /// 使用者在 OpenRouter 按了拒絕：state 相符但沒有授權碼，或完全沒有 state 也沒有授權碼（OpenRouter 拒絕時不會帶回 state）
    Denied,
    /// 不採用（state 不符等），繼續等
    Ignore,
}

/// 依查詢參數判讀 callback。
/// 注意：「沒有 state 也沒有授權碼」會當成拒絕而結束流程，所以其他網頁可以送這種請求中止登入；
/// 這只會讓使用者需要重新登入，拿不到也塞不進授權碼（授權碼一定要 state 相符才採用）。
pub(crate) fn classify_callback(params: &[(String, String)], expected_state: &str) -> CallbackResult {
    let get = |k: &str| params.iter().find(|(x, _)| x == k).map(|(_, v)| v.as_str());
    let code = get("code").filter(|c| !c.is_empty());
    match get("state") {
        Some(s) if s == expected_state => match code {
            Some(c) => CallbackResult::Code(c.to_string()),
            None => CallbackResult::Denied,
        },
        Some(_) => CallbackResult::Ignore,
        None if code.is_none() => CallbackResult::Denied,
        None => CallbackResult::Ignore,
    }
}

/// 同時處理中的連線上限；超過時直接關掉新連線，避免被大量閒置連線耗盡資源
const MAX_ACTIVE_CONNECTIONS: usize = 16;

/// 在獨立執行緒讀一條連線並回應；閒置不送資料的連線只會卡住自己的執行緒，不會擋住真正的 callback
fn handle_connection(mut s: TcpStream, expected_state: &str, zh: bool) -> CallbackResult {
    let _ = s.set_nonblocking(false);
    let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
    let mut buf = [0u8; 8192];
    let n = s.read(&mut buf).unwrap_or(0);
    let req = String::from_utf8_lossy(&buf[..n]);
    let Some(params) = req.lines().next().and_then(parse_callback) else {
        let _ = write!(s, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return CallbackResult::Ignore;
    };
    let r = classify_callback(&params, expected_state);
    respond(s, matches!(r, CallbackResult::Code(_)), zh);
    r
}

/// 等瀏覽器帶授權碼回來（最多 5 分鐘，可取消）。state 不符的請求一律忽略，避免其他網頁送假的授權碼。
pub fn wait_for_code(p: &PendingLogin, zh: bool) -> Result<String, String> {
    let deadline = Instant::now() + LOGIN_TIMEOUT;
    let (tx, rx) = mpsc::channel::<CallbackResult>();
    let active = Arc::new(AtomicUsize::new(0));
    loop {
        while let Ok(r) = rx.try_recv() {
            match r {
                CallbackResult::Code(code) => return Ok(code),
                CallbackResult::Denied => {
                    return Err(msg(zh, "OpenRouter 沒有回傳授權碼（可能按了拒絕），請重新嘗試。", "OpenRouter returned no authorization code (access may have been denied). Please try again."));
                }
                CallbackResult::Ignore => {}
            }
        }
        if CANCEL.load(Ordering::SeqCst) {
            return Err(msg(zh, "已取消登入。", "Sign-in cancelled."));
        }
        if Instant::now() > deadline {
            return Err(msg(zh, "等候登入逾時（5 分鐘），請重新嘗試。", "Timed out waiting for sign-in (5 minutes). Please try again."));
        }
        for l in &p.listeners {
            while let Ok((s, _)) = l.accept() {
                if active.load(Ordering::SeqCst) >= MAX_ACTIVE_CONNECTIONS {
                    drop(s);
                    continue;
                }
                active.fetch_add(1, Ordering::SeqCst);
                let (tx, active, state) = (tx.clone(), active.clone(), p.state.clone());
                std::thread::spawn(move || {
                    let r = handle_connection(s, &state, zh);
                    active.fetch_sub(1, Ordering::SeqCst);
                    let _ = tx.send(r);
                });
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

pub async fn exchange_code(p: &PendingLogin, code: &str, zh: bool) -> Result<String, String> {
    let c = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().map_err(|e| e.to_string())?;
    let resp = c
        .post(OPENROUTER_KEYS)
        .json(&json!({ "code": code, "code_verifier": p.verifier, "code_challenge_method": "S256" }))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    if !status.is_success() {
        // 只顯示狀態碼，不帶回伺服器的回應內容（內容不受本程式控制）
        let code = status.as_u16();
        return Err(msg(
            zh,
            &format!("換取 API key 失敗（HTTP {code}）。授權碼可能已過期（10 分鐘）或已使用過，請重新登入。"),
            &format!("Failed to get the API key (HTTP {code}). The authorization code may have expired (10 minutes) or already been used. Please sign in again."),
        ));
    }
    let text = resp.text().await.map_err(|e| e.to_string())?;
    serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v.get("key").and_then(|k| k.as_str()).map(String::from))
        .filter(|k| !k.trim().is_empty())
        .ok_or_else(|| msg(zh, "OpenRouter 的回應裡沒有 API key。", "OpenRouter's response did not include an API key."))
}

// ---- Claude Desktop ----

pub const SERVER_NAME: &str = "windows-pc-cleanup";
const CONFIG_FILE: &str = "claude_desktop_config.json";
/// Microsoft Store（MSIX）版 Claude Desktop 的套件資料夾名稱
const MSIX_PACKAGE: &str = "Claude_pzs8sxrjxfjjc";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeDesktopStatus {
    /// 找得到 Claude Desktop 的設定資料夾
    pub found: bool,
    pub config_path: String,
    /// 設定檔裡已經有本程式的項目
    pub connected: bool,
    /// 已有的項目指向目前這個 exe（exe 被移動或換版本後會變成 false）
    pub points_to_this_exe: bool,
    /// 設定檔存在但不是合法 JSON（這時不會修改它）
    pub invalid_json: bool,
}

/// Claude Desktop 設定檔位置：Microsoft Store（MSIX）版在套件的 LocalCache 裡，一般安裝版在 %APPDATA%\Claude。
/// 已有設定檔的位置優先；都沒有時，有 MSIX 套件就用 MSIX 的位置，否則用 %APPDATA%\Claude（資料夾要存在）。
pub fn claude_config_path() -> Option<PathBuf> {
    // 只有 debug 建置可用：測試時改寫暫存資料夾裡的設定檔，不碰使用者真正的 Claude Desktop 設定
    #[cfg(debug_assertions)]
    if let Some(d) = std::env::var_os("PCC_CLAUDE_CONFIG_DIR").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return Some(d.join(CONFIG_FILE));
    }
    let mut candidates = Vec::new();
    if let Some(local) = dirs::data_local_dir() {
        if let Ok(rd) = std::fs::read_dir(local.join("Packages")) {
            for e in rd.flatten() {
                // 只比對 Claude Desktop 的完整套件名稱（名稱後半是發行者雜湊），不會誤選其他以 Claude_ 開頭的套件
                if e.file_name().to_string_lossy().eq_ignore_ascii_case(MSIX_PACKAGE) && e.path().is_dir() {
                    candidates.push(e.path().join(r"LocalCache\Roaming\Claude"));
                }
            }
        }
    }
    if let Some(roaming) = dirs::config_dir() {
        candidates.push(roaming.join("Claude"));
    }
    if let Some(c) = candidates.iter().find(|d| d.join(CONFIG_FILE).is_file()) {
        return Some(c.join(CONFIG_FILE));
    }
    // MSIX 套件存在時，設定資料夾可能還沒建立，直接用它
    if let Some(c) = candidates.iter().find(|d| d.to_string_lossy().contains(r"\Packages\")) {
        return Some(c.join(CONFIG_FILE));
    }
    candidates.into_iter().find(|d| d.is_dir()).map(|d| d.join(CONFIG_FILE))
}

/// 讀取設定檔原始內容。檔案不存在 → Ok(None)；其他讀取錯誤（權限、被鎖住等）→ Err，避免把「讀不到」誤當成「沒有檔案」而覆寫掉。
fn read_raw(path: &Path) -> Result<Option<Vec<u8>>, ()> {
    match std::fs::read(path) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
    }
}

/// 解析設定檔內容；不是 UTF-8 或不是 JSON 物件時回傳 Err（這時不會修改它）
pub(crate) fn parse_config(bytes: &[u8]) -> Result<Map<String, Value>, ()> {
    let text = std::str::from_utf8(bytes).map_err(|_| ())?;
    let t = text.trim_start_matches('\u{feff}').trim();
    if t.is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(t) {
        Ok(Value::Object(m)) => Ok(m),
        _ => Err(()),
    }
}

fn read_config(path: &Path) -> Result<Option<Map<String, Value>>, ()> {
    match read_raw(path)? {
        None => Ok(None),
        Some(b) => parse_config(&b).map(Some),
    }
}

fn this_exe() -> Result<PathBuf, String> {
    std::env::current_exe().map_err(|e| e.to_string())
}

pub fn server_entry(exe: &Path) -> Value {
    json!({ "command": exe.to_string_lossy(), "args": ["--mcp"] })
}

pub fn claude_status() -> ClaudeDesktopStatus {
    let Some(path) = claude_config_path() else {
        return ClaudeDesktopStatus { found: false, config_path: String::new(), connected: false, points_to_this_exe: false, invalid_json: false };
    };
    let exe = this_exe().map(|p| p.to_string_lossy().to_lowercase()).unwrap_or_default();
    let (connected, points, invalid) = match read_config(&path) {
        Err(()) => (false, false, true),
        Ok(None) => (false, false, false),
        Ok(Some(m)) => match m.get("mcpServers").and_then(|s| s.get(SERVER_NAME)) {
            Some(entry) => (true, entry.get("command").and_then(|c| c.as_str()).is_some_and(|c| c.to_lowercase() == exe), false),
            None => (false, false, false),
        },
    };
    ClaudeDesktopStatus { found: true, config_path: path.to_string_lossy().into(), connected, points_to_this_exe: points, invalid_json: invalid }
}

/// 回傳新的設定內容；add = false 時移除本程式的項目。其他設定一律保留。
pub(crate) fn updated_config(mut cfg: Map<String, Value>, entry: Option<Value>) -> Map<String, Value> {
    let servers = cfg.entry("mcpServers").or_insert_with(|| Value::Object(Map::new()));
    if !servers.is_object() {
        *servers = Value::Object(Map::new());
    }
    let m = servers.as_object_mut().expect("object");
    match entry {
        Some(e) => {
            m.insert(SERVER_NAME.into(), e);
        }
        None => {
            // preserve_order 下 remove 等於 swap_remove，會打亂其他項目的順序，所以用 shift_remove
            m.shift_remove(SERVER_NAME);
        }
    }
    cfg
}

fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("json.pcc-tmp");
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })
}

/// 加入（add = true）或移除本程式的 MCP 設定。回傳 Ok(false) 代表使用者在確認視窗按了取消。
pub fn claude_set(origin: &Origin, zh: bool, add: bool) -> Result<bool, String> {
    let path = claude_config_path().ok_or_else(|| msg(zh, "找不到 Claude Desktop 的設定資料夾，請先安裝並開啟一次 Claude Desktop。", "Claude Desktop's settings folder was not found. Install Claude Desktop and open it once first."))?;
    let unreadable = || {
        msg(
            zh,
            &format!("Claude Desktop 的設定檔無法讀取或不是合法的 JSON，為了避免弄壞它，沒有做任何修改：{}", path.display()),
            &format!("Claude Desktop's settings file could not be read or is not valid JSON; it was left untouched to avoid breaking it: {}", path.display()),
        )
    };
    // 保留確認前讀到的原始內容，按確定後要比對，避免確認視窗開著時檔案被改、卻用舊內容蓋回去
    let snapshot = read_raw(&path).map_err(|_| unreadable())?;
    let existing = match &snapshot {
        None => None,
        Some(b) => Some(parse_config(b).map_err(|_| unreadable())?),
    };
    if !add && existing.as_ref().and_then(|m| m.get("mcpServers")).and_then(|s| s.get(SERVER_NAME)).is_none() {
        return Ok(true);
    }
    let exe = this_exe()?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let backup = path.with_file_name(format!("{CONFIG_FILE}.bak-{stamp}"));
    let mut details = vec![msg(zh, &format!("設定檔：{}", path.display()), &format!("Settings file: {}", path.display()))];
    if add {
        details.push(msg(zh, &format!("加入項目「{SERVER_NAME}」：{} --mcp", exe.display()), &format!("Add entry \"{SERVER_NAME}\": {} --mcp", exe.display())));
    } else {
        details.push(msg(zh, &format!("移除項目「{SERVER_NAME}」"), &format!("Remove entry \"{SERVER_NAME}\"")));
    }
    if existing.is_some() {
        details.push(msg(zh, &format!("原檔先備份為：{}", backup.display()), &format!("The original is backed up first as: {}", backup.display())));
    }
    let warning = if add {
        msg(
            zh,
            "重新啟動 Claude Desktop 後生效。之後 Claude 可以呼叫這些清理工具；會改動檔案的動作仍會跳出這個確認視窗。注意：透過 MCP 交給 Claude 的掃描結果不會經過遮蔽。若之後移動或刪除這個 exe，需要重新連結。",
            "Takes effect after you restart Claude Desktop. Claude can then call these cleanup tools; anything that changes files still shows this confirmation dialog. Note: scan results passed to Claude over MCP are not redacted. If you move or delete this exe later, connect again.",
        )
    } else {
        msg(zh, "重新啟動 Claude Desktop 後生效。", "Takes effect after you restart Claude Desktop.")
    };
    let action = if add { msg(zh, "把 Windows PC Cleanup 加入 Claude Desktop", "Add Windows PC Cleanup to Claude Desktop") } else { msg(zh, "從 Claude Desktop 移除 Windows PC Cleanup", "Remove Windows PC Cleanup from Claude Desktop") };
    if !confirm::ask(origin, zh, &action, &details, &warning) {
        return Ok(false);
    }
    if read_raw(&path).ok() != Some(snapshot.clone()) {
        return Err(msg(
            zh,
            "確認視窗開著的期間，Claude Desktop 的設定檔被修改了。為了不蓋掉新的內容，這次沒有寫入，請再按一次。",
            "Claude Desktop's settings file changed while the confirmation dialog was open. Nothing was written so the new content is not overwritten; please try again.",
        ));
    }
    if let Some(bytes) = &snapshot {
        // 備份的內容就是剛剛比對過、要被改寫的那一版
        std::fs::write(&backup, bytes).map_err(|e| e.to_string())?;
    } else if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let cfg = updated_config(existing.unwrap_or_default(), add.then(|| server_entry(&exe)));
    let text = serde_json::to_string_pretty(&Value::Object(cfg)).map_err(|e| e.to_string())?;
    write_atomic(&path, &text)?;
    Ok(true)
}

// ---- 地端模型 ----

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalServer {
    pub provider: &'static str,
    pub label: &'static str,
    pub base_url: &'static str,
    pub running: bool,
    pub models: Vec<String>,
}

pub async fn detect_local() -> Vec<LocalServer> {
    let servers = [("ollama", "Ollama", "http://localhost:11434/v1"), ("lmstudio", "LM Studio", "http://localhost:1234/v1")];
    let Ok(c) = reqwest::Client::builder().timeout(Duration::from_millis(1500)).build() else { return vec![] };
    let mut out = Vec::new();
    for (provider, label, base) in servers {
        let models = match c.get(format!("{base}/models")).send().await {
            Ok(r) if r.status().is_success() => r.json::<Value>().await.ok().map(|v| {
                let mut ids: Vec<String> = v.get("data").and_then(|d| d.as_array()).into_iter().flatten().filter_map(|m| m.get("id").and_then(|i| i.as_str()).map(String::from)).collect();
                ids.sort();
                ids
            }),
            _ => None,
        };
        out.push(LocalServer { provider, label, base_url: base, running: models.is_some(), models: models.unwrap_or_default() });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_matches_rfc7636_example() {
        // RFC 7636 附錄 B 的範例
        assert_eq!(pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn callback_parsing() {
        let p = parse_callback("GET /callback?code=ab%2Bc&state=xyz HTTP/1.1").unwrap();
        assert_eq!(p, vec![("code".to_string(), "ab+c".to_string()), ("state".to_string(), "xyz".to_string())]);
        assert!(parse_callback("GET /other?code=1 HTTP/1.1").is_none());
        assert!(parse_callback("POST /callback?code=1 HTTP/1.1").is_none());
        assert_eq!(parse_callback("GET /callback HTTP/1.1").unwrap(), vec![]);
        assert_eq!(urldecode("%E4%B8%AD%zz%"), "中%zz%");
    }

    #[test]
    fn config_update_keeps_other_settings() {
        let cfg: Map<String, Value> = serde_json::from_str(r#"{"globalShortcut":"Ctrl+Space","mcpServers":{"other":{"command":"x"}}}"#).unwrap();
        let added = updated_config(cfg, Some(server_entry(Path::new(r"C:\a\pc-cleanup.exe"))));
        assert_eq!(added["globalShortcut"], "Ctrl+Space");
        assert_eq!(added["mcpServers"]["other"]["command"], "x");
        assert_eq!(added["mcpServers"][SERVER_NAME]["args"][0], "--mcp");
        let removed = updated_config(added, None);
        assert!(removed["mcpServers"].get(SERVER_NAME).is_none());
        assert_eq!(removed["mcpServers"]["other"]["command"], "x");
        // mcpServers 不是物件時改成物件
        let weird: Map<String, Value> = serde_json::from_str(r#"{"mcpServers":[]}"#).unwrap();
        assert!(updated_config(weird, Some(json!({})))["mcpServers"].is_object());
    }

    #[test]
    fn callback_requires_matching_state() {
        let _l = LOGIN_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _g = LoginGuard::acquire(true).unwrap();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let state = p.state.clone();
        let sender = std::thread::spawn(move || {
            // 不相關的路徑 → 404；state 錯誤 → 顯示失敗頁但不採用；最後送正確的
            assert!(send(port, "/favicon.ico").starts_with("HTTP/1.1 404"));
            assert!(send(port, "/callback?code=evil&state=wrong").contains("連結失敗"));
            send(port, &format!("/callback?code=good-code&state={state}"));
        });
        assert_eq!(wait_for_code(&p, true).unwrap(), "good-code");
        sender.join().unwrap();
        assert!(p.auth_url.starts_with("https://openrouter.ai/auth?callback_url=http%3A%2F%2Flocalhost%3A"));
        assert!(p.auth_url.contains("&code_challenge_method=S256&"));
        // 同時只能有一個登入流程
        assert!(LoginGuard::acquire(true).is_err());
    }

    #[test]
    fn remove_keeps_order_of_other_servers() {
        let cfg: Map<String, Value> =
            serde_json::from_str(&format!(r#"{{"mcpServers":{{"a":{{}},"{SERVER_NAME}":{{}},"b":{{}},"c":{{}}}},"z":1,"y":2}}"#)).unwrap();
        let removed = updated_config(cfg, None);
        let keys: Vec<&String> = removed["mcpServers"].as_object().unwrap().keys().collect();
        assert_eq!(keys, ["a", "b", "c"]);
        let top: Vec<&String> = removed.keys().collect();
        assert_eq!(top, ["mcpServers", "z", "y"]);
    }

    #[test]
    fn config_parsing_rejects_non_utf8_and_non_objects() {
        assert!(parse_config(b"\xff\xfe{\x00}\x00").is_err()); // UTF-16
        assert!(parse_config(b"[]").is_err());
        assert!(parse_config(b"{ broken").is_err());
        assert!(parse_config(b"").unwrap().is_empty());
        assert_eq!(parse_config("\u{feff}{\"a\":1}".as_bytes()).unwrap()["a"], 1);
    }

    #[test]
    fn classify_callback_cases() {
        let p = |q: &str| parse_callback(&format!("GET /callback{q} HTTP/1.1")).unwrap();
        assert_eq!(classify_callback(&p("?code=c&state=s"), "s"), CallbackResult::Code("c".into()));
        assert_eq!(classify_callback(&p("?state=s"), "s"), CallbackResult::Denied);
        assert_eq!(classify_callback(&p("?error=access_denied"), "s"), CallbackResult::Denied);
        assert_eq!(classify_callback(&p(""), "s"), CallbackResult::Denied);
        assert_eq!(classify_callback(&p("?code=evil&state=x"), "s"), CallbackResult::Ignore);
        assert_eq!(classify_callback(&p("?code=evil"), "s"), CallbackResult::Ignore);
        assert_eq!(classify_callback(&p("?state=x"), "s"), CallbackResult::Ignore);
    }

    /// 登入流程用到全域的 RUNNING／CANCEL，相關測試要依序執行
    static LOGIN_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn send(port: u16, path: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(s, "GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        let mut resp = String::new();
        let _ = s.read_to_string(&mut resp);
        resp
    }

    #[test]
    fn idle_connection_does_not_block_callback() {
        let _l = LOGIN_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _g = LoginGuard::acquire(true).unwrap();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let state = p.state.clone();
        let sender = std::thread::spawn(move || {
            // 先開一條完全不送資料的連線，再送正確的 callback
            let idle = TcpStream::connect(("127.0.0.1", port)).unwrap();
            std::thread::sleep(Duration::from_millis(200));
            send(port, &format!("/callback?code=ok&state={state}"));
            drop(idle);
        });
        let t0 = Instant::now();
        assert_eq!(wait_for_code(&p, true).unwrap(), "ok");
        assert!(t0.elapsed() < Duration::from_secs(3), "等了 {:?}", t0.elapsed());
        sender.join().unwrap();
    }

    #[test]
    fn denied_callback_ends_login() {
        let _l = LOGIN_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _g = LoginGuard::acquire(true).unwrap();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let sender = std::thread::spawn(move || send(port, "/callback?error=access_denied"));
        let t0 = Instant::now();
        assert!(wait_for_code(&p, true).unwrap_err().contains("拒絕"));
        assert!(t0.elapsed() < Duration::from_secs(3));
        assert!(sender.join().unwrap().contains("連結失敗"));
    }

    #[test]
    fn url_encoding() {
        assert_eq!(urlencode("http://localhost:5/callback"), "http%3A%2F%2Flocalhost%3A5%2Fcallback");
        assert_eq!(urlencode("Windows PC Cleanup"), "Windows%20PC%20Cleanup");
    }
}
