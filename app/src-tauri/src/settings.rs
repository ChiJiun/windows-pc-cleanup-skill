//! 使用者設定（存成 JSON）與 API key（存在 Windows 認證管理員，不寫進任何檔案）。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const KEYRING_SERVICE: &str = "windows-pc-cleanup";

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub lang: String,
    pub provider: String,
    pub model: String,
    pub base_url: String,
    pub redact: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            lang: system_lang().to_string(),
            provider: "anthropic".into(),
            model: "claude-sonnet-5-5".into(),
            base_url: String::new(),
            redact: true,
        }
    }
}

/// 系統介面語言是中文就用 zh-TW，其他用 en（與腳本的判斷一致）
pub fn system_lang() -> &'static str {
    // SAFETY：沒有參數的查詢函式
    let id = unsafe { windows_sys::Win32::Globalization::GetUserDefaultUILanguage() };
    if id & 0x3ff == 0x04 { "zh-TW" } else { "en" }
}

fn path() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("WindowsPcCleanup").join("settings.json")
}

pub fn load() -> Settings {
    let mut s: Settings = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    s.sanitize();
    s
}

impl Settings {
    pub fn sanitize(&mut self) {
        if self.lang != "en" {
            self.lang = "zh-TW".into();
        }
        if !crate::llm::presets().iter().any(|p| p.id == self.provider) {
            self.provider = "anthropic".into();
        }
        self.model = self.model.trim().to_string();
        self.base_url = self.base_url.trim().trim_end_matches('/').to_string();
    }
}

pub fn save(s: &Settings) -> Result<(), String> {
    let p = path();
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(&p, serde_json::to_string_pretty(s).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn entry(provider: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, provider).map_err(|e| e.to_string())
}

pub fn set_key(provider: &str, key: &str) -> Result<(), String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("empty key".into());
    }
    entry(provider)?.set_password(key).map_err(|e| e.to_string())
}

pub fn get_key(provider: &str) -> Option<String> {
    entry(provider).ok()?.get_password().ok().filter(|k| !k.is_empty())
}

pub fn delete_key(provider: &str) -> Result<(), String> {
    match entry(provider)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
