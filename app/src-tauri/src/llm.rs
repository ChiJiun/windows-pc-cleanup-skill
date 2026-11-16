//! AI 模型轉接：Anthropic 走原生 Messages API；OpenAI、Gemini、Grok、Ollama、LM Studio 與自訂端點走 OpenAI 相容的 Chat Completions。
//! 送到雲端前（redact 開啟時）會把使用者資料夾路徑、使用者名稱、電腦名稱與電子郵件地址遮蔽掉；
//! 工具執行時再把參數中的 %USERPROFILE%、<user>、<computer> 換回真實值（見 tools::expand）。

use crate::settings::Settings;
use crate::tools;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Preset {
    pub id: &'static str,
    pub label: &'static str,
    pub needs_key: bool,
    pub local: bool,
    pub default_base_url: &'static str,
    pub default_model: &'static str,
}

pub fn presets() -> Vec<Preset> {
    vec![
        Preset { id: "anthropic", label: "Anthropic Claude", needs_key: true, local: false, default_base_url: "https://api.anthropic.com", default_model: "claude-sonnet-5-5" },
        Preset { id: "openai", label: "OpenAI ChatGPT", needs_key: true, local: false, default_base_url: "https://api.openai.com/v1", default_model: "gpt-5" },
        Preset { id: "gemini", label: "Google Gemini", needs_key: true, local: false, default_base_url: "https://generativelanguage.googleapis.com/v1beta/openai", default_model: "gemini-2.5-flash" },
        Preset { id: "xai", label: "xAI Grok", needs_key: true, local: false, default_base_url: "https://api.x.ai/v1", default_model: "grok-4" },
        // 一個帳號就能用多家模型；API key 可由設定頁的「用 OpenRouter 登入」自動取得（見 connect.rs）
        Preset { id: "openrouter", label: "OpenRouter (Claude / GPT / Gemini / Grok)", needs_key: true, local: false, default_base_url: "https://openrouter.ai/api/v1", default_model: "openrouter/auto" },
        Preset { id: "ollama", label: "Ollama (local)", needs_key: false, local: true, default_base_url: "http://localhost:11434/v1", default_model: "qwen3:8b" },
        Preset { id: "lmstudio", label: "LM Studio (local)", needs_key: false, local: true, default_base_url: "http://localhost:1234/v1", default_model: "" },
        Preset { id: "custom", label: "OpenAI-compatible (custom)", needs_key: false, local: false, default_base_url: "", default_model: "" },
    ]
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub role: String,
    #[serde(default)]
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

struct Endpoint {
    anthropic: bool,
    base: String,
    model: String,
    key: Option<String>,
    redact: bool,
}

fn is_local_url(u: &str) -> bool {
    // 用正式的網址解析取出主機名稱，避免 http://localhost:1@evil.example 這類寫法被誤判成本機
    let Some(host) = reqwest::Url::parse(u).ok().and_then(|x| x.host_str().map(str::to_ascii_lowercase)) else { return false };
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    host.trim_start_matches('[').trim_end_matches(']').parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

fn endpoint(s: &Settings, key: Option<String>, zh: bool) -> Result<Endpoint, String> {
    let p = presets().into_iter().find(|p| p.id == s.provider).ok_or("unknown provider")?;
    let base = if s.base_url.is_empty() { p.default_base_url.to_string() } else { s.base_url.clone() };
    if base.is_empty() {
        return Err(if zh { "請在設定中填入 API 網址。" } else { "Set the API URL in Settings." }.into());
    }
    if !(base.starts_with("https://") || (base.starts_with("http://") && is_local_url(&base))) {
        return Err(if zh { "API 網址必須是 https，或是本機的 http（localhost）。" } else { "The API URL must use https, or http on localhost." }.into());
    }
    if p.needs_key && key.is_none() {
        return Err(if zh { "還沒有設定這個供應商的 API key。" } else { "No API key is set for this provider." }.into());
    }
    let model = if s.model.is_empty() { p.default_model.to_string() } else { s.model.clone() };
    let local = is_local_url(&base);
    Ok(Endpoint { anthropic: p.id == "anthropic", base, model, key, redact: s.redact && !local })
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder().timeout(Duration::from_secs(180)).build().map_err(|e| e.to_string())
}

// ---- 遮蔽 ----

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    User,
    /// 常見的通用帳號名稱（見 GENERIC_USER_NAMES）
    GenericUser,
    Computer,
}

struct Name {
    /// (?i)^名稱，對「從候選位置開始的剩餘文字」比對
    head: Regex,
    kind: Kind,
    /// 名稱的第一個／最後一個字元是不是「字」的一部分：是的話，那一側緊鄰的字元不能也是字（避免 malice 裡的 alice 被遮）
    first_word: bool,
    last_word: bool,
    chars: usize,
}

pub struct Redactor {
    profile: Regex,
    /// 所有名稱合成一個 alternation，只用來快速找到候選位置；真正的判斷在 match_at
    any: Option<Regex>,
    /// 由長到短：電腦名稱常包含使用者名稱（例如 ALICE-PC7X 與 alice），要先試長的
    names: Vec<Name>,
    email_tail: Regex,
    /// 還原用：使用者名稱（依登入名稱、使用者資料夾名稱的順序）與電腦名稱
    users: Vec<String>,
    computer: Option<String>,
}

/// 常見的通用帳號名稱：直接整字遮蔽會把一般文字（例如 "User Temp folder"）一起換掉，
/// 所以這些名稱只遮蔽出現在 \ 或 / 之後的情況（例如排程工作建立者 PC\USER）
const GENERIC_USER_NAMES: [&str; 10] = ["user", "users", "admin", "administrator", "owner", "guest", "default", "public", "test", "home"];

/// 中日韓文字之間不會有空白，名稱前後緊接這些字（例如「擁有者王小明的檔案」）也要遮蔽，
/// 所以判斷字的邊界時，這些字元不算「字」的一部分
fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x1100..=0x11FF | 0x2E80..=0x2FDF | 0x3040..=0x30FF | 0x3100..=0x318F | 0x31A0..=0x31FF
        | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xA960..=0xA97F | 0xAC00..=0xD7FF | 0xF900..=0xFAFF
        | 0xFF66..=0xFFDC | 0x20000..=0x3FFFF)
}

fn is_word(c: char) -> bool {
    (c.is_alphanumeric() || c == '_') && !is_cjk(c)
}

/// 太短的名稱會誤遮一般文字：拉丁字母等至少 3 個字；含中日韓文字的名稱 2 個字就遮（例如「小明」）
fn long_enough(n: &str) -> bool {
    let k = n.chars().count();
    k >= 3 || (k == 2 && n.chars().any(is_cjk))
}

impl Redactor {
    pub fn new() -> Self {
        let home = dirs::home_dir().and_then(|h| h.file_name().map(|n| n.to_string_lossy().into_owned()));
        Self::with(std::env::var("USERNAME").ok().into_iter().chain(home).collect(), std::env::var("COMPUTERNAME").ok())
    }

    /// users：登入名稱與使用者資料夾名稱（兩者可能不同）；太短的不處理（見 long_enough）
    fn with(users: Vec<String>, computer: Option<String>) -> Self {
        // 任何磁碟上的 X:\Users\<名稱>（含 JSON 跳脫的 \\ 與 /）
        let profile = Regex::new(r#"(?i)\b[A-Z]:(\\\\|\\|/)Users(\\\\|\\|/)[^\\/"\r\n\t<>|]+"#).expect("valid regex");
        // 名稱後面接著的電子郵件其餘部分（Microsoft 帳號的 USERNAME 只是電子郵件的前 5 個字）
        let email_tail = Regex::new(r"(?i)^[a-z0-9._%+-]*@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}").expect("valid regex");
        let mut texts: Vec<(String, Kind)> = Vec::new();
        let candidates = users.into_iter().map(|u| (u, Kind::User)).chain(computer.map(|c| (c, Kind::Computer)));
        for (n, kind) in candidates {
            let n = n.trim().to_string();
            // 電腦名稱與使用者名稱相同時當成使用者名稱
            if !long_enough(&n) || texts.iter().any(|(x, _)| x.eq_ignore_ascii_case(&n)) {
                continue;
            }
            let kind = if kind == Kind::User && GENERIC_USER_NAMES.iter().any(|g| g.eq_ignore_ascii_case(&n)) { Kind::GenericUser } else { kind };
            texts.push((n, kind));
        }
        let users = texts.iter().filter(|(_, k)| *k != Kind::Computer).map(|(n, _)| n.clone()).collect();
        let computer = texts.iter().find(|(_, k)| *k == Kind::Computer).map(|(n, _)| n.clone());
        let mut names: Vec<Name> = texts
            .iter()
            .filter_map(|(n, kind)| {
                Some(Name {
                    head: Regex::new(&format!("(?i)^{}", regex::escape(n))).ok()?,
                    kind: *kind,
                    first_word: n.chars().next().is_some_and(is_word),
                    last_word: n.chars().next_back().is_some_and(is_word),
                    chars: n.chars().count(),
                })
            })
            .collect();
        names.sort_by_key(|n| std::cmp::Reverse(n.chars));
        let any = if texts.is_empty() {
            None
        } else {
            Regex::new(&format!("(?i){}", texts.iter().map(|(n, _)| regex::escape(n)).collect::<Vec<_>>().join("|"))).ok()
        };
        Redactor { profile, any, names, email_tail, users, computer }
    }

    pub fn apply(&self, s: &str) -> String {
        let replaced = self.profile.replace_all(s, "%USERPROFILE%");
        let s: &str = &replaced;
        let Some(any) = &self.any else { return s.to_string() };
        // 只掃一次：已換上的 <user>／<computer> 不會再被其他名稱比對到
        let mut out = String::with_capacity(s.len());
        let (mut last, mut pos) = (0, 0);
        while let Some(m) = any.find_at(s, pos) {
            let start = m.start();
            match self.match_at(s, start) {
                Some((end, mark)) => {
                    out.push_str(&s[last..start]);
                    out.push_str(mark);
                    (last, pos) = (end, end);
                }
                None => pos = start + s[start..].chars().next().map_or(1, char::len_utf8),
            }
        }
        out.push_str(&s[last..]);
        out
    }

    /// start 位置是否是某個名稱的完整出現；是的話回傳結束位置與要換上的代稱
    fn match_at(&self, s: &str, start: usize) -> Option<(usize, &'static str)> {
        let prev = s[..start].chars().next_back();
        let rest = &s[start..];
        self.names.iter().find_map(|n| {
            let end = start + n.head.find(rest)?.end();
            let prev_ok = match n.kind {
                Kind::GenericUser => matches!(prev, Some('\\' | '/')),
                _ => !(n.first_word && prev.is_some_and(is_word)),
            };
            if !prev_ok {
                return None;
            }
            if n.kind == Kind::User
                && let Some(t) = self.email_tail.find(&s[end..])
            {
                return Some((end + t.end(), "<email>"));
            }
            if n.last_word && s[end..].chars().next().is_some_and(is_word) {
                return None;
            }
            Some((end, if n.kind == Kind::Computer { "<computer>" } else { "<user>" }))
        })
    }

    /// 把工具參數中的 <user>／<computer>（不分大小寫）換回真實名稱。
    /// Windows 檔名不能含 < 與 >，所以真實路徑裡不會出現這兩個代稱，沒開遮蔽時換也不會誤傷。
    /// 使用者名稱可能有兩個（登入名稱與使用者資料夾名稱不同），依序試，優先回傳實際存在的路徑。
    pub fn restore(&self, s: &str) -> String {
        let user_mark = Regex::new("(?i)<user>").expect("valid regex");
        let computer_mark = Regex::new("(?i)<computer>").expect("valid regex");
        let base = match &self.computer {
            Some(c) => computer_mark.replace_all(s, regex::NoExpand(c)).into_owned(),
            None => s.to_string(),
        };
        if !user_mark.is_match(&base) {
            return base;
        }
        let candidates: Vec<String> = self.users.iter().map(|u| user_mark.replace_all(&base, regex::NoExpand(u)).into_owned()).collect();
        candidates.iter().find(|c| std::path::Path::new(c.as_str()).exists()).or(candidates.first()).cloned().unwrap_or(base)
    }
}

fn redact_value(r: &Redactor, v: &Value) -> Value {
    match v {
        Value::String(s) => Value::String(r.apply(s)),
        Value::Array(a) => Value::Array(a.iter().map(|x| redact_value(r, x)).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), redact_value(r, x))).collect()),
        other => other.clone(),
    }
}

// ---- 系統提示 ----

fn system_prompt(lang: &str) -> String {
    let zh = r#"你是 Windows PC Cleanup 桌面程式裡的助理，幫使用者掃描電腦、清理不必要的檔案、整理資料夾，並檢查軟硬體健康。
規則：
1. 先看、後問、再動。先用唯讀工具掃描，向使用者說明發現與建議（大小、風險、可不可以還原），使用者同意後才執行。
2. 會改動電腦的工具一律先試跑（apply=false），把結果摘要給使用者看；使用者同意後才用 apply=true。apply=true 會跳出 Windows 確認視窗，使用者按「確定」才會真的執行；如果使用者取消，就尊重決定，不要重試或換方式繞過。
3. clear_folder 與 clean_old_files 只能處理 scan_cleanup_targets 列出、且 Action 相符的項目；其他項目（例如套件快取、Windows Update 快取、大型檔案、開機啟動）只提供建議，請使用者自己處理。
4. 不要打開、讀取或要求查看個人敏感檔案（證件、密碼、金融、復原碼等）；看到這類檔名只提醒使用者自行處理。
5. 不要建議結束使用者正在使用的程式；若有異常程序，說明原因並讓使用者決定。
6. 使用者決定略過或待決定的項目，用 log_action 記下來；最後用 build_report 產生報告。
7. 用繁體中文（台灣用語）回答，簡潔、條列，數字要附單位。路徑中的 %USERPROFILE% 是使用者資料夾的代稱，<user>、<computer> 是遮蔽後的使用者名稱與電腦名稱，都可以直接用在工具參數裡；<email> 是遮蔽後的電子郵件地址，無法還原，不要用在工具參數中。"#;
    let en = r#"You are the assistant inside the Windows PC Cleanup desktop app. You help the user scan the PC, clean up unnecessary files, organize folders, and check hardware/software health.
Rules:
1. Look, then ask, then act. Scan with read-only tools first, explain findings and recommendations (size, risk, whether it can be undone), and act only after the user agrees.
2. Tools that change the computer always run as a dry run first (apply=false); summarize the result for the user, and use apply=true only after they agree. apply=true shows a Windows confirmation dialog and runs only if the user clicks OK. If the user cancels, respect it: do not retry or work around it.
3. clear_folder and clean_old_files can only act on items listed by scan_cleanup_targets with a matching Action. For anything else (package caches, Windows Update cache, large files, startup items) give advice and let the user do it.
4. Do not open, read, or ask to see personal sensitive files (IDs, passwords, financial documents, recovery codes). If you see such file names, only remind the user to handle them.
5. Do not suggest ending programs the user is using. If a process looks abnormal, explain why and let the user decide.
6. Record items the user skips or leaves pending with log_action; finish with build_report.
7. Reply in English, concise, with bullet points and units on numbers. %USERPROFILE% in paths stands for the user's folder, and <user> and <computer> stand for the redacted user name and computer name; all of them can be used directly in tool arguments. <email> is a redacted email address that cannot be restored; do not use it in tool arguments."#;
    if lang == "en" { en.into() } else { zh.into() }
}

// ---- 對話 ----

fn http_error(zh: bool, status: reqwest::StatusCode, body: &str) -> String {
    let body: String = body.chars().take(600).collect();
    if zh { format!("模型 API 回應錯誤（{status}）：{body}") } else { format!("Model API error ({status}): {body}") }
}

pub async fn chat(s: &Settings, key: Option<String>, messages: Vec<ChatMessage>) -> Result<ChatMessage, String> {
    let zh = s.lang != "en";
    let ep = endpoint(s, key, zh)?;
    let r = Redactor::new();
    let messages: Vec<ChatMessage> = if ep.redact {
        messages
            .into_iter()
            .map(|m| ChatMessage {
                content: r.apply(&m.content),
                tool_calls: m.tool_calls.map(|tc| tc.into_iter().map(|t| ToolCall { arguments: redact_value(&r, &t.arguments), ..t }).collect()),
                ..m
            })
            .collect()
    } else {
        messages
    };
    let specs = tools::specs();
    if ep.anthropic { chat_anthropic(&ep, &s.lang, &specs, &messages, zh).await } else { chat_openai(&ep, &s.lang, &specs, &messages, zh).await }
}

async fn chat_openai(ep: &Endpoint, lang: &str, specs: &[tools::ToolSpec], messages: &[ChatMessage], zh: bool) -> Result<ChatMessage, String> {
    let mut msgs = vec![json!({ "role": "system", "content": system_prompt(lang) })];
    for m in messages {
        match m.role.as_str() {
            "assistant" => {
                let mut o = json!({ "role": "assistant", "content": if m.content.is_empty() { Value::Null } else { Value::String(m.content.clone()) } });
                if let Some(tc) = m.tool_calls.as_ref().filter(|t| !t.is_empty()) {
                    o["tool_calls"] = Value::Array(tc.iter().map(|t| json!({ "id": t.id, "type": "function", "function": { "name": t.name, "arguments": t.arguments.to_string() } })).collect());
                }
                msgs.push(o);
            }
            "tool" => msgs.push(json!({ "role": "tool", "tool_call_id": m.tool_call_id.clone().unwrap_or_default(), "content": m.content })),
            _ => msgs.push(json!({ "role": "user", "content": m.content })),
        }
    }
    let tools: Vec<Value> = specs.iter().map(|t| json!({ "type": "function", "function": { "name": t.name, "description": t.description(lang), "parameters": t.schema } })).collect();
    let body = json!({ "model": ep.model, "messages": msgs, "tools": tools });
    let mut req = client()?.post(format!("{}/chat/completions", ep.base)).json(&body);
    if let Some(k) = &ep.key {
        req = req.bearer_auth(k);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(http_error(zh, status, &text));
    }
    let v: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let msg = &v["choices"][0]["message"];
    let content = msg["content"].as_str().unwrap_or("").to_string();
    let calls: Vec<ToolCall> = msg["tool_calls"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(i, c)| {
            let raw = &c["function"]["arguments"];
            let arguments = match raw {
                Value::String(s) => serde_json::from_str(s).unwrap_or(json!({})),
                Value::Object(_) => raw.clone(),
                _ => json!({}),
            };
            ToolCall {
                id: c["id"].as_str().map(String::from).filter(|s| !s.is_empty()).unwrap_or_else(|| format!("call_{i}")),
                name: c["function"]["name"].as_str().unwrap_or("").to_string(),
                arguments,
            }
        })
        .collect();
    Ok(ChatMessage { role: "assistant".into(), content, tool_calls: if calls.is_empty() { None } else { Some(calls) }, tool_call_id: None })
}

async fn chat_anthropic(ep: &Endpoint, lang: &str, specs: &[tools::ToolSpec], messages: &[ChatMessage], zh: bool) -> Result<ChatMessage, String> {
    let mut msgs: Vec<Value> = Vec::new();
    for m in messages {
        match m.role.as_str() {
            "assistant" => {
                let mut blocks = Vec::new();
                if !m.content.is_empty() {
                    blocks.push(json!({ "type": "text", "text": m.content }));
                }
                for t in m.tool_calls.iter().flatten() {
                    blocks.push(json!({ "type": "tool_use", "id": t.id, "name": t.name, "input": if t.arguments.is_object() { t.arguments.clone() } else { json!({}) } }));
                }
                if blocks.is_empty() {
                    blocks.push(json!({ "type": "text", "text": "…" }));
                }
                msgs.push(json!({ "role": "assistant", "content": blocks }));
            }
            "tool" => {
                let block = json!({ "type": "tool_result", "tool_use_id": m.tool_call_id.clone().unwrap_or_default(), "content": m.content });
                // 連續的工具結果要放在同一則 user 訊息裡
                let merge = msgs.last().is_some_and(|l| {
                    l["role"] == "user" && l["content"].as_array().is_some_and(|c| !c.is_empty() && c.iter().all(|b| b["type"] == "tool_result"))
                });
                if merge {
                    if let Some(arr) = msgs.last_mut().and_then(|l| l["content"].as_array_mut()) {
                        arr.push(block);
                    }
                } else {
                    msgs.push(json!({ "role": "user", "content": [block] }));
                }
            }
            _ => msgs.push(json!({ "role": "user", "content": [{ "type": "text", "text": m.content }] })),
        }
    }
    let tools: Vec<Value> = specs.iter().map(|t| json!({ "name": t.name, "description": t.description(lang), "input_schema": t.schema })).collect();
    let body = json!({ "model": ep.model, "max_tokens": 4096, "system": system_prompt(lang), "messages": msgs, "tools": tools });
    let resp = client()?
        .post(format!("{}/v1/messages", ep.base))
        .header("x-api-key", ep.key.clone().unwrap_or_default())
        .header("anthropic-version", "2023-06-01")
        .json(&body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(http_error(zh, status, &text));
    }
    let v: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let mut content = String::new();
    let mut calls = Vec::new();
    for b in v["content"].as_array().into_iter().flatten() {
        match b["type"].as_str() {
            Some("text") => content.push_str(b["text"].as_str().unwrap_or("")),
            Some("tool_use") => calls.push(ToolCall { id: b["id"].as_str().unwrap_or("").into(), name: b["name"].as_str().unwrap_or("").into(), arguments: b["input"].clone() }),
            _ => {}
        }
    }
    Ok(ChatMessage { role: "assistant".into(), content, tool_calls: if calls.is_empty() { None } else { Some(calls) }, tool_call_id: None })
}

#[derive(Deserialize)]
struct ModelList {
    data: Vec<ModelItem>,
}
#[derive(Deserialize)]
struct ModelItem {
    id: String,
}

pub async fn list_models(s: &Settings, key: Option<String>) -> Result<Vec<String>, String> {
    let zh = s.lang != "en";
    let ep = endpoint(s, key, zh)?;
    let c = client()?;
    let req = if ep.anthropic {
        c.get(format!("{}/v1/models?limit=100", ep.base)).header("x-api-key", ep.key.clone().unwrap_or_default()).header("anthropic-version", "2023-06-01")
    } else {
        let r = c.get(format!("{}/models", ep.base));
        match &ep.key {
            Some(k) => r.bearer_auth(k),
            None => r,
        }
    };
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(http_error(zh, status, &text));
    }
    let list: ModelList = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let mut ids: Vec<String> = list.data.into_iter().map(|m| m.id.trim_start_matches("models/").to_string()).collect();
    ids.sort();
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_profile_paths_in_any_form() {
        let r = Redactor::new();
        assert_eq!(r.apply(r"C:\Users\alice\Downloads\a.pdf"), r"%USERPROFILE%\Downloads\a.pdf");
        assert_eq!(r.apply(r#"{"p":"D:\\Users\\bob\\x"}"#), r#"{"p":"%USERPROFILE%\\x"}"#);
        assert_eq!(r.apply("User Temp folder"), "User Temp folder");
    }

    #[test]
    fn redacts_bare_user_and_computer_names() {
        let r = Redactor::with(vec!["alice".into(), "Alice".into(), "al".into()], Some("DESKTOP-AB12".into()));
        // 排程工作建立者 <電腦>\<使用者>
        assert_eq!(r.apply(r"Author: DESKTOP-AB12\alice"), r"Author: <computer>\<user>");
        assert_eq!(r.apply(r#"{"Author":"DESKTOP-AB12\\ALICE"}"#), r#"{"Author":"<computer>\\<user>"}"#);
        assert_eq!(r.apply("owner alice@example.com"), "owner <email>");
        // 只遮整個字，不動包含它的其他字；長度少於 3 的名稱不處理
        assert_eq!(r.apply("malice palace al"), "malice palace al");
    }

    #[test]
    fn computer_name_containing_user_name() {
        let r = Redactor::with(vec!["alice".into()], Some("ALICE-PC7X".into()));
        assert_eq!(r.apply(r"Author: ALICE-PC7X\alice"), r"Author: <computer>\<user>");
        assert_eq!(r.apply("alice-pc7xyz"), "<user>-pc7xyz");
        // 使用者名稱剛好是 computer 時，不會把已換上的 <computer> 再改掉
        let r = Redactor::with(vec!["computer".into()], Some("DESKTOP-AB12".into()));
        assert_eq!(r.apply(r"DESKTOP-AB12\computer"), r"<computer>\<user>");
    }

    #[test]
    fn cjk_and_edge_cases() {
        let r = Redactor::with(vec!["王小明".into()], None);
        assert_eq!(r.apply("擁有者王小明的檔案"), "擁有者<user>的檔案");
        let r = Redactor::with(vec!["小明".into(), "ab".into()], None);
        assert_eq!(r.apply("小明的報告 ab"), "<user>的報告 ab");
        let r = Redactor::with(vec!["alice".into()], None);
        assert_eq!(r.apply("使用者alice的檔案"), "使用者<user>的檔案");
        // 名稱開頭或結尾不是字（例如 -）時，那一側不要求邊界
        let r = Redactor::with(vec!["bob-".into()], None);
        assert_eq!(r.apply("owner bob-x"), "owner <user>x");
        assert_eq!(r.apply("kbob-"), "kbob-");
    }

    #[test]
    fn microsoft_account_email_is_redacted() {
        // Microsoft 帳號的 USERNAME 只有電子郵件前 5 個字
        let r = Redactor::with(vec!["alice".into()], None);
        assert_eq!(r.apply("Author: MicrosoftAccount\\alicewang@example.com.tw"), "Author: MicrosoftAccount\\<email>");
        assert_eq!(r.apply("alicewang 的資料"), "alicewang 的資料");
        assert_eq!(r.apply("icon@2x.png"), "icon@2x.png");
    }

    #[test]
    fn restore_placeholders_for_tool_arguments() {
        let r = Redactor::with(vec!["alice".into()], Some("ALICE-PC7X".into()));
        assert_eq!(r.restore(r"D:\<user>\Downloads"), r"D:\alice\Downloads");
        assert_eq!(r.restore(r"\\<Computer>\share\<USER>"), r"\\ALICE-PC7X\share\alice");
        assert_eq!(r.restore(r"C:\x\$1"), r"C:\x\$1");
        // 兩個名稱時優先選實際存在的路徑
        let tmp = std::env::temp_dir().join(format!("pcc-restore-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("bob")).unwrap();
        let r = Redactor::with(vec!["alice".into(), "bob".into()], None);
        let got = r.restore(&format!(r"{}\<user>", tmp.display()));
        std::fs::remove_dir(tmp.join("bob")).unwrap();
        std::fs::remove_dir(&tmp).unwrap();
        assert_eq!(got, format!(r"{}\bob", tmp.display()));
        assert_eq!(r.restore(r"Z:\nope\<user>"), r"Z:\nope\alice");
    }

    #[test]
    fn generic_user_names_only_after_separator() {
        let r = Redactor::with(vec!["USER".into()], None);
        assert_eq!(r.apply(r"Author: PC\USER"), r"Author: PC\<user>");
        assert_eq!(r.apply(r#"{"a":"PC\\User"}"#), r#"{"a":"PC\\<user>"}"#);
        assert_eq!(r.apply("User Temp folder"), "User Temp folder");
        assert_eq!(r.apply(r"C:\Users\USER\Downloads"), r"%USERPROFILE%\Downloads");
    }

    #[test]
    fn local_url_detection() {
        assert!(is_local_url("http://localhost:11434/v1"));
        assert!(is_local_url("http://127.0.0.1:1234/v1"));
        assert!(!is_local_url("https://api.openai.com/v1"));
        assert!(!is_local_url("http://localhost.evil.com/v1"));
        assert!(!is_local_url("http://localhost:1@evil.example/v1"));
        assert!(!is_local_url("http://127.0.0.1.evil.example/v1"));
        assert!(is_local_url("http://[::1]:11434/v1"));
        assert!(is_local_url("http://LOCALHOST:11434/v1"));
        assert!(!is_local_url("not a url"));
    }
}
