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
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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

/// 同時等待中的連線上限；滿了就關掉最舊的那條，讓新連線（例如真正的 callback）有位置
const MAX_PENDING_CONNECTIONS: usize = 16;
/// 每個 listener 每輪最多接受的新連線數；本機程式持續大量建立連線時，迴圈仍會回頭檢查取消與逾時，
/// 而且 127.0.0.1 與 ::1 各自有額度，其中一個被灌爆時另一個仍輪得到
const MAX_ACCEPTS_PER_LISTENER: usize = 32;
/// 一條連線從接受到送完請求標頭的時間上限；瀏覽器的 callback 會立刻送出請求，閒置連線超過就關掉
const CONNECTION_READ_TIMEOUT: Duration = Duration::from_secs(2);
/// 判讀請求時最多保留的位元組數（只需要第一行，但要容得下一般大小的標頭，例如 localhost 共用的 cookie）
const MAX_REQUEST_BYTES: usize = 8192;
/// 回應前最多再讀掉（丟棄）的位元組數。Windows 關閉「還有沒讀完的資料」的連線時會送 RST，
/// 瀏覽器會顯示連線重設而看不到結果頁，所以回應前要把已送達的資料讀完
const MAX_DRAIN_BYTES: usize = 64 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// 一條還在等請求內容的連線（非阻塞）
struct PendingConn {
    stream: TcpStream,
    buf: Vec<u8>,
    since: Instant,
}

enum ConnPoll {
    /// 還沒收到完整的請求標頭，繼續等
    Waiting,
    /// 已收到完整的標頭（或達到上限、對方關閉連線），可以判讀
    Ready,
    /// 讀取錯誤，直接關掉
    Failed,
}

/// 非阻塞地讀出目前已到的資料；不會等待，所以閒置連線不會擋住其他連線
fn poll_conn(c: &mut PendingConn) -> ConnPoll {
    let mut tmp = [0u8; 4096];
    loop {
        let room = (MAX_REQUEST_BYTES - c.buf.len()).min(tmp.len());
        match c.stream.read(&mut tmp[..room]) {
            Ok(0) => return ConnPoll::Ready,
            Ok(n) => {
                c.buf.extend_from_slice(&tmp[..n]);
                if c.buf.windows(4).any(|w| w == b"\r\n\r\n") || c.buf.len() >= MAX_REQUEST_BYTES {
                    return ConnPoll::Ready;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return ConnPoll::Waiting,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return ConnPoll::Failed,
        }
    }
}

/// 把已送達、還沒讀的資料讀掉（非阻塞，有上限），避免關閉連線時送出 RST
fn drain(s: &mut TcpStream) {
    let mut tmp = [0u8; 4096];
    let mut total = 0;
    while total < MAX_DRAIN_BYTES {
        match s.read(&mut tmp) {
            Ok(0) => return,
            Ok(n) => total += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// 判讀已收到的請求並回應
fn finish_conn(c: PendingConn, expected_state: &str, zh: bool) -> CallbackResult {
    let mut s = c.stream;
    drain(&mut s);
    // 回應只有幾百 bytes，一般會立刻寫完；加上逾時，避免對方不讀資料時卡住
    let _ = s.set_nonblocking(false);
    let _ = s.set_write_timeout(Some(Duration::from_secs(1)));
    let req = String::from_utf8_lossy(&c.buf);
    let Some(params) = req.lines().next().and_then(parse_callback) else {
        let _ = write!(s, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return CallbackResult::Ignore;
    };
    let r = classify_callback(&params, expected_state);
    respond(s, matches!(r, CallbackResult::Code(_)), zh);
    r
}

/// 從一個 listener 接受目前排隊中的連線，最多 max 條（其餘留到下一輪）
fn accept_batch(l: &TcpListener, max: usize) -> Vec<TcpStream> {
    let mut out = Vec::new();
    while out.len() < max {
        match l.accept() {
            Ok((s, _)) => out.push(s),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    out
}

/// 等瀏覽器帶授權碼回來（最多 5 分鐘，可取消）。state 不符的請求一律忽略，避免其他網頁送假的授權碼。
/// 所有連線都在這個執行緒以非阻塞方式輪詢：不會因為大量連線而開出大量執行緒，閒置連線也不會擋住真正的 callback。
pub fn wait_for_code(p: &PendingLogin, zh: bool) -> Result<String, String> {
    let deadline = Instant::now() + LOGIN_TIMEOUT;
    let mut pending: VecDeque<PendingConn> = VecDeque::new();
    let decide = |r: CallbackResult| -> Option<Result<String, String>> {
        match r {
            CallbackResult::Code(code) => Some(Ok(code)),
            CallbackResult::Denied => Some(Err(msg(
                zh,
                "OpenRouter 沒有回傳授權碼（可能按了拒絕），請重新嘗試。",
                "OpenRouter returned no authorization code (access may have been denied). Please try again.",
            ))),
            CallbackResult::Ignore => None,
        }
    };
    loop {
        if CANCEL.load(Ordering::SeqCst) {
            return Err(msg(zh, "已取消登入。", "Sign-in cancelled."));
        }
        if Instant::now() > deadline {
            return Err(msg(zh, "等候登入逾時（5 分鐘），請重新嘗試。", "Timed out waiting for sign-in (5 minutes). Please try again."));
        }
        for l in &p.listeners {
            for s in accept_batch(l, MAX_ACCEPTS_PER_LISTENER) {
                if s.set_nonblocking(true).is_err() {
                    continue;
                }
                let mut c = PendingConn { stream: s, buf: Vec::new(), since: Instant::now() };
                // 接受後馬上讀一次：瀏覽器通常已經送出請求，不必等到下一輪，也不會在同一輪被後來的連線擠掉
                match poll_conn(&mut c) {
                    ConnPoll::Ready => {
                        if let Some(done) = decide(finish_conn(c, &p.state, zh)) {
                            return done;
                        }
                    }
                    ConnPoll::Failed => {}
                    ConnPoll::Waiting => {
                        if pending.len() >= MAX_PENDING_CONNECTIONS {
                            pending.pop_front();
                        }
                        pending.push_back(c);
                    }
                }
            }
        }
        for mut c in std::mem::take(&mut pending) {
            match poll_conn(&mut c) {
                ConnPoll::Ready => {
                    if let Some(done) = decide(finish_conn(c, &p.state, zh)) {
                        return done;
                    }
                }
                ConnPoll::Failed => {}
                ConnPoll::Waiting if c.since.elapsed() > CONNECTION_READ_TIMEOUT => {}
                ConnPoll::Waiting => pending.push_back(c),
            }
        }
        std::thread::sleep(POLL_INTERVAL);
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
    let backup = backup_path(&path, 0);
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
    let cfg = updated_config(existing.unwrap_or_default(), add.then(|| server_entry(&exe)));
    apply_confirmed(&path, &snapshot, &backup, &cfg, zh)?;
    Ok(true)
}

/// 備份檔名：精確到毫秒；n > 0 時加上流水號（同一毫秒已有備份時使用）
fn backup_path(path: &Path, n: u32) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let name = if n == 0 { format!("{CONFIG_FILE}.bak-{stamp}") } else { format!("{CONFIG_FILE}.bak-{stamp}-{n}") };
    path.with_file_name(name)
}

/// 寫備份，絕不覆寫已有的檔案：preferred 已存在時改用新的時間與流水號。回傳實際寫入的路徑。
fn write_backup(path: &Path, preferred: &Path, bytes: &[u8], zh: bool) -> Result<PathBuf, String> {
    let failed = |e: &dyn std::fmt::Display| {
        msg(
            zh,
            &format!("無法建立設定檔的備份（{e}），為了安全沒有修改設定檔：{}", path.display()),
            &format!("Could not back up the settings file ({e}); it was left unchanged to be safe: {}", path.display()),
        )
    };
    let mut target = preferred.to_path_buf();
    for n in 1..=100 {
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&target) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(bytes).and_then(|_| f.sync_all()) {
                    drop(f);
                    let _ = std::fs::remove_file(&target);
                    return Err(failed(&e));
                }
                return Ok(target);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => target = backup_path(path, n),
            Err(e) => return Err(failed(&e)),
        }
    }
    Err(failed(&msg(zh, "找不到可用的備份檔名", "no unused backup file name")))
}

/// 使用者按確定之後的步驟：確認期間檔案若被改過就不寫入；否則先備份原檔（有的話），再寫入新設定。
fn apply_confirmed(path: &Path, snapshot: &Option<Vec<u8>>, backup: &Path, cfg: &Map<String, Value>, zh: bool) -> Result<(), String> {
    if read_raw(path).ok().as_ref() != Some(snapshot) {
        return Err(msg(
            zh,
            "確認視窗開著的期間，Claude Desktop 的設定檔被修改了。為了不蓋掉新的內容，這次沒有寫入，請再按一次。",
            "Claude Desktop's settings file changed while the confirmation dialog was open. Nothing was written so the new content is not overwritten; please try again.",
        ));
    }
    if let Some(bytes) = snapshot {
        // 備份的內容就是剛剛比對過、要被改寫的那一版
        write_backup(path, backup, bytes, zh)?;
    } else if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let text = serde_json::to_string_pretty(&Value::Object(cfg.clone())).map_err(|e| e.to_string())?;
    write_atomic(path, &text)
}

// ---- 地端模型 ----

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalServer {
    pub provider: &'static str,
    pub label: &'static str,
    pub base_url: String,
    /// 這是使用者在設定裡填的自訂位址（不是預設的 localhost）；套用這裡的模型時要沿用這個位址
    pub custom: bool,
    /// AI 助理不能使用這個位址（非本機的 http，見 llm::base_url_allowed），所以沒有偵測
    pub unsupported: bool,
    pub running: bool,
    pub models: Vec<String>,
}

const LOCAL_DEFAULTS: [(&str, &str, &str); 2] = [("ollama", "Ollama", "http://localhost:11434/v1"), ("lmstudio", "LM Studio", "http://localhost:1234/v1")];

/// 要偵測的位址 (供應商, 名稱, 位址, 是否自訂)：每個地端供應商的預設位址；
/// 目前設定是該供應商且填了不同的自訂位址時，再加上那個自訂位址
pub(crate) fn local_targets(provider: &str, base_url: &str) -> Vec<(&'static str, &'static str, String, bool)> {
    let custom = base_url.trim().trim_end_matches('/');
    let mut out = Vec::new();
    for (p, label, default) in LOCAL_DEFAULTS {
        out.push((p, label, default.to_string(), false));
        if p == provider && !custom.is_empty() && !custom.eq_ignore_ascii_case(default) {
            out.push((p, label, custom.to_string(), true));
        }
    }
    out
}

pub async fn detect_local(provider: &str, base_url: &str) -> Vec<LocalServer> {
    let Ok(c) = reqwest::Client::builder().timeout(Duration::from_millis(1500)).build() else { return vec![] };
    let mut out = Vec::new();
    for (provider, label, base, custom) in local_targets(provider, base_url) {
        // 與對話端同一條規則：非本機的 http 不能用，就不偵測，只在畫面上說明
        if !crate::llm::base_url_allowed(&base) {
            out.push(LocalServer { provider, label, base_url: base, custom, unsupported: true, running: false, models: vec![] });
            continue;
        }
        let models = match c.get(format!("{base}/models")).send().await {
            Ok(r) if r.status().is_success() => r.json::<Value>().await.ok().map(|v| {
                let mut ids: Vec<String> = v.get("data").and_then(|d| d.as_array()).into_iter().flatten().filter_map(|m| m.get("id").and_then(|i| i.as_str()).map(String::from)).collect();
                ids.sort();
                ids
            }),
            _ => None,
        };
        out.push(LocalServer { provider, label, base_url: base, custom, unsupported: false, running: models.is_some(), models: models.unwrap_or_default() });
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
        let _t = login_test();
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
    /// 看門狗：登入測試超過這個時間就自動取消，退化時快速失敗，不會卡到 5 分鐘逾時
    const WATCHDOG: Duration = Duration::from_secs(5);

    /// 時間到就呼叫 cancel_login；提前被 drop（測試結束）時什麼都不做
    struct Watchdog(#[allow(dead_code)] std::sync::mpsc::Sender<()>);
    impl Watchdog {
        fn arm(after: Duration) -> Self {
            let (tx, rx) = std::sync::mpsc::channel::<()>();
            std::thread::spawn(move || {
                if let Err(std::sync::mpsc::RecvTimeoutError::Timeout) = rx.recv_timeout(after) {
                    cancel_login();
                }
            });
            Watchdog(tx)
        }
    }

    /// 欄位依宣告順序釋放：先解除看門狗，再結束登入流程，最後放開測試鎖
    struct LoginTest {
        _watchdog: Watchdog,
        _guard: LoginGuard,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    fn login_test() -> LoginTest {
        let lock = LOGIN_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // acquire 會把 CANCEL 歸零，所以看門狗要在之後才啟動
        let guard = LoginGuard::acquire(true).unwrap();
        LoginTest { _watchdog: Watchdog::arm(WATCHDOG), _guard: guard, _lock: lock }
    }

    #[test]
    fn large_headers_still_get_the_result_page() {
        // localhost 的 cookie 不分 port 共用，callback 請求常帶好幾 KB 的 Cookie；
        // 沒讀完的資料會讓 Windows 送 RST，瀏覽器就看不到「已連結」頁面
        for cookie_len in [500, 4000, 7000, 12000] {
            let _t = login_test();
            let p = start_login().unwrap();
            let port = p.listeners[0].local_addr().unwrap().port();
            let state = p.state.clone();
            let sender = std::thread::spawn(move || {
                let cookie = "c".repeat(cookie_len);
                let req = format!("GET /callback?code=ok&state={state} HTTP/1.1\r\nHost: localhost:{port}\r\nCookie: a={cookie}\r\nAccept: text/html\r\n\r\n");
                // 用戶端稍後才讀回應，模擬瀏覽器
                let mut s = TcpStream::connect(("127.0.0.1", port))?;
                s.write_all(req.as_bytes())?;
                std::thread::sleep(Duration::from_millis(200));
                let mut resp = String::new();
                s.read_to_string(&mut resp)?;
                Ok::<String, std::io::Error>(resp)
            });
            assert_eq!(wait_for_code(&p, true).unwrap(), "ok");
            let resp = sender.join().unwrap().unwrap_or_else(|e| panic!("Cookie {cookie_len} bytes：{e}"));
            assert!(resp.contains("已連結 OpenRouter"), "Cookie {cookie_len} bytes：{resp}");
        }
    }

    #[test]
    fn slow_callback_survives_full_queue() {
        let _t = login_test();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let state = p.state.clone();
        let sender = std::thread::spawn(move || {
            // 先用閒置連線把等待佇列塞滿
            let idle: Vec<TcpStream> = (0..MAX_PENDING_CONNECTIONS).map(|_| TcpStream::connect(("127.0.0.1", port)).unwrap()).collect();
            std::thread::sleep(Duration::from_millis(200));
            // callback 連上後過一下才送資料：它會進入已滿的等待佇列，應該擠掉最舊的閒置連線，而不是自己被關掉
            let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
            std::thread::sleep(Duration::from_millis(150));
            let r = write!(s, "GET /callback?code=ok&state={state} HTTP/1.1\r\nHost: localhost\r\n\r\n").and_then(|_| {
                let mut resp = String::new();
                s.read_to_string(&mut resp).map(|_| resp)
            });
            drop(idle);
            r
        });
        let t0 = Instant::now();
        let got = wait_for_code(&p, true);
        let resp = sender.join().unwrap();
        assert_eq!(got.unwrap(), "ok", "等了 {:?}", t0.elapsed());
        assert!(resp.unwrap().contains("已連結 OpenRouter"));
    }

    #[test]
    fn accept_batch_respects_limit() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.set_nonblocking(true).unwrap();
        let port = l.local_addr().unwrap().port();
        let total = MAX_ACCEPTS_PER_LISTENER + 8;
        let clients: Vec<TcpStream> = (0..total).map(|_| TcpStream::connect(("127.0.0.1", port)).unwrap()).collect();
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(accept_batch(&l, MAX_ACCEPTS_PER_LISTENER).len(), MAX_ACCEPTS_PER_LISTENER);
        // 剩下的留到下一輪
        assert_eq!(accept_batch(&l, MAX_ACCEPTS_PER_LISTENER).len(), 8);
        assert!(accept_batch(&l, MAX_ACCEPTS_PER_LISTENER).is_empty());
        drop(clients);
    }

    fn send(port: u16, path: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(s, "GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").unwrap();
        let mut resp = String::new();
        let _ = s.read_to_string(&mut resp);
        resp
    }

    #[test]
    fn idle_connection_does_not_block_callback() {
        let _t = login_test();
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
        let _t = login_test();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let sender = std::thread::spawn(move || send(port, "/callback?error=access_denied"));
        let t0 = Instant::now();
        assert!(wait_for_code(&p, true).unwrap_err().contains("拒絕"));
        assert!(t0.elapsed() < Duration::from_secs(3));
        assert!(sender.join().unwrap().contains("連結失敗"));
    }

    #[test]
    fn full_idle_connections_do_not_block_callback() {
        let _t = login_test();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let state = p.state.clone();
        let sender = std::thread::spawn(move || {
            // 開超過上限的閒置連線把位置佔滿，真正的 callback 仍要能被處理（會關掉最舊的閒置連線）
            let idle: Vec<TcpStream> = (0..MAX_PENDING_CONNECTIONS + 8).map(|_| TcpStream::connect(("127.0.0.1", port)).unwrap()).collect();
            std::thread::sleep(Duration::from_millis(300));
            let resp = send(port, &format!("/callback?code=ok&state={state}"));
            drop(idle);
            resp
        });
        let t0 = Instant::now();
        assert_eq!(wait_for_code(&p, true).unwrap(), "ok");
        assert!(t0.elapsed() < Duration::from_secs(3), "等了 {:?}", t0.elapsed());
        assert!(sender.join().unwrap().contains("已連結 OpenRouter"));
    }

    #[test]
    fn connection_flood_does_not_block_cancel() {
        let _t = login_test();
        let p = start_login().unwrap();
        let port = p.listeners[0].local_addr().unwrap().port();
        let stop = std::sync::Arc::new(AtomicBool::new(false));
        // 幾個執行緒不停建立連線（有的閒置、有的立刻關掉），同時在 300ms 後取消登入
        let flooders: Vec<_> = (0..4)
            .map(|i| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    let mut keep = Vec::new();
                    while !stop.load(Ordering::SeqCst) {
                        if let Ok(s) = TcpStream::connect(("127.0.0.1", port))
                            && i % 2 == 0
                            && keep.len() < 64
                        {
                            keep.push(s);
                        }
                    }
                })
            })
            .collect();
        let canceller = std::thread::spawn(|| {
            std::thread::sleep(Duration::from_millis(300));
            cancel_login();
        });
        let t0 = Instant::now();
        let r = wait_for_code(&p, true);
        let elapsed = t0.elapsed();
        stop.store(true, Ordering::SeqCst);
        canceller.join().unwrap();
        for f in flooders {
            f.join().unwrap();
        }
        assert!(r.unwrap_err().contains("取消"));
        assert!(elapsed < Duration::from_secs(3), "等了 {elapsed:?}");
    }

    /// 測試用的暫存資料夾（結束時刪除）；不會碰到使用者真正的 Claude Desktop 設定
    struct TempDir(PathBuf);
    impl TempDir {
        fn new() -> Self {
            let d = std::env::temp_dir().join(format!("pcc-connect-test-{}", random_token().unwrap()));
            std::fs::create_dir_all(&d).unwrap();
            TempDir(d)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn backups_in(dir: &Path) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(&format!("{CONFIG_FILE}.bak-")))
            .collect();
        v.sort();
        v
    }

    fn added_cfg(original: &[u8]) -> Map<String, Value> {
        updated_config(parse_config(original).unwrap(), Some(server_entry(Path::new(r"C:\a\pc-cleanup.exe"))))
    }

    #[test]
    fn apply_confirmed_refuses_when_file_changed_during_confirmation() {
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        let original = br#"{"globalShortcut":"Ctrl+Space"}"#;
        std::fs::write(&path, original).unwrap();
        let snapshot = read_raw(&path).unwrap();
        // 確認視窗開著的期間，Claude Desktop 改寫了設定檔
        let changed = br#"{"globalShortcut":"Ctrl+Alt+Space"}"#;
        std::fs::write(&path, changed).unwrap();
        let err = apply_confirmed(&path, &snapshot, &backup_path(&path, 0), &added_cfg(original), true).unwrap_err();
        assert!(err.contains("被修改"), "{err}");
        assert_eq!(std::fs::read(&path).unwrap(), changed);
        assert!(backups_in(&t.0).is_empty());

        // 確認前沒有檔案、確認期間才出現：同樣不寫入
        std::fs::remove_file(&path).unwrap();
        let none = read_raw(&path).unwrap();
        assert!(none.is_none());
        std::fs::write(&path, changed).unwrap();
        assert!(apply_confirmed(&path, &none, &backup_path(&path, 0), &added_cfg(b"{}"), true).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), changed);
    }

    #[test]
    fn apply_confirmed_backs_up_then_writes() {
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        let original = br#"{"globalShortcut":"Ctrl+Space"}"#;
        std::fs::write(&path, original).unwrap();
        let snapshot = read_raw(&path).unwrap();
        apply_confirmed(&path, &snapshot, &backup_path(&path, 0), &added_cfg(original), true).unwrap();
        let written = parse_config(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(written["globalShortcut"], "Ctrl+Space");
        assert_eq!(written["mcpServers"][SERVER_NAME]["args"][0], "--mcp");
        let b = backups_in(&t.0);
        assert_eq!(b.len(), 1);
        assert_eq!(std::fs::read(&b[0]).unwrap(), original);

        // 沒有原檔時（資料夾也還沒建立）：建立資料夾並寫入，不產生備份
        let path2 = t.0.join("new-dir").join(CONFIG_FILE);
        apply_confirmed(&path2, &None, &backup_path(&path2, 0), &added_cfg(b"{}"), true).unwrap();
        assert!(parse_config(&std::fs::read(&path2).unwrap()).unwrap()["mcpServers"][SERVER_NAME].is_object());
        assert!(backups_in(&t.0.join("new-dir")).is_empty());
    }

    #[test]
    fn backup_never_overwrites_existing_backup() {
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        let preferred = backup_path(&path, 0);
        // 同一個檔名已經有備份（例如同一毫秒內改寫兩次）
        std::fs::write(&preferred, b"first").unwrap();
        let second = write_backup(&path, &preferred, b"second", true).unwrap();
        assert_ne!(second, preferred);
        assert_eq!(std::fs::read(&preferred).unwrap(), b"first");
        assert_eq!(std::fs::read(&second).unwrap(), b"second");
        assert!(second.file_name().unwrap().to_string_lossy().starts_with(&format!("{CONFIG_FILE}.bak-")));
    }

    #[cfg(windows)]
    #[test]
    fn read_raw_reports_locked_file_as_error() {
        use std::os::windows::fs::OpenOptionsExt;
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        std::fs::write(&path, b"{}").unwrap();
        // 以不共用方式開著檔案（模擬被其他程式鎖住）：讀取失敗要回傳錯誤，不能當成「沒有檔案」
        let lock = std::fs::OpenOptions::new().read(true).write(true).share_mode(0).open(&path).unwrap();
        assert!(read_raw(&path).is_err());
        assert!(read_config(&path).is_err());
        drop(lock);
        assert_eq!(read_raw(&path).unwrap().unwrap(), b"{}");
        assert!(read_raw(&t.0.join("missing.json")).unwrap().is_none());
    }

    #[test]
    fn apply_confirmed_refuses_when_file_deleted_during_confirmation() {
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        let original = br#"{"globalShortcut":"Ctrl+Space"}"#;
        std::fs::write(&path, original).unwrap();
        let snapshot = read_raw(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        let err = apply_confirmed(&path, &snapshot, &backup_path(&path, 0), &added_cfg(original), true).unwrap_err();
        assert!(err.contains("被修改"), "{err}");
        // 不會用舊內容把檔案建回來，也不會產生備份
        assert!(!path.exists());
        assert!(backups_in(&t.0).is_empty());
    }

    #[cfg(windows)]
    #[test]
    fn apply_confirmed_refuses_when_file_unreadable() {
        use std::os::windows::fs::OpenOptionsExt;
        let t = TempDir::new();
        let path = t.0.join(CONFIG_FILE);
        let original = br#"{"globalShortcut":"Ctrl+Space"}"#;
        std::fs::write(&path, original).unwrap();
        let snapshot = read_raw(&path).unwrap();
        // 按確定的當下檔案被其他程式以不共用方式開著：讀不到就不能確定沒被改過，所以不寫入
        let lock = std::fs::OpenOptions::new().read(true).write(true).share_mode(0).open(&path).unwrap();
        let err = apply_confirmed(&path, &snapshot, &backup_path(&path, 0), &added_cfg(original), true).unwrap_err();
        drop(lock);
        assert!(err.contains("被修改"), "{err}");
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert!(backups_in(&t.0).is_empty());
    }

    #[test]
    fn non_local_http_is_not_usable_for_chat() {
        // detect_local 用這條規則決定自訂位址要不要偵測（與對話端相同）
        assert!(crate::llm::base_url_allowed("http://localhost:11434/v1"));
        assert!(crate::llm::base_url_allowed("http://127.0.0.1:1234/v1"));
        assert!(crate::llm::base_url_allowed("https://10.0.0.5:11434/v1"));
        assert!(!crate::llm::base_url_allowed("http://10.0.0.5:11434/v1"));
        assert!(!crate::llm::base_url_allowed("http://localhost:1@evil.example/v1"));
    }

    #[test]
    fn local_targets_include_custom_address() {
        let urls = |p: &str, b: &str| local_targets(p, b).into_iter().map(|(p, _, u, c)| format!("{p} {u} {c}")).collect::<Vec<_>>();
        let defaults = ["ollama http://localhost:11434/v1 false", "lmstudio http://localhost:1234/v1 false"];
        assert_eq!(urls("anthropic", ""), defaults);
        assert_eq!(urls("ollama", ""), defaults);
        // 與預設位址相同（大小寫、結尾斜線不同）時不重複列出
        assert_eq!(urls("ollama", "HTTP://localhost:11434/v1/"), defaults);
        // 別的供應商的自訂位址不會拿來偵測地端模型
        assert_eq!(urls("custom", "http://10.0.0.5:11434/v1"), defaults);
        assert_eq!(
            urls("ollama", "http://10.0.0.5:11434/v1/"),
            ["ollama http://localhost:11434/v1 false", "ollama http://10.0.0.5:11434/v1 true", "lmstudio http://localhost:1234/v1 false"]
        );
        assert_eq!(
            urls("lmstudio", "http://10.0.0.5:1234/v1"),
            ["ollama http://localhost:11434/v1 false", "lmstudio http://localhost:1234/v1 false", "lmstudio http://10.0.0.5:1234/v1 true"]
        );
    }

    #[test]
    fn url_encoding() {
        assert_eq!(urlencode("http://localhost:5/callback"), "http%3A%2F%2Flocalhost%3A5%2Fcallback");
        assert_eq!(urlencode("Windows PC Cleanup"), "Windows%20PC%20Cleanup");
    }
}
