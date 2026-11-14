//! `pc-cleanup.exe --mcp`：以 stdio 提供 MCP server，讓 Claude Desktop、Claude Code、Cursor、LM Studio、Gemini CLI 等用戶端呼叫清理工具。
//! stdout 只能輸出 JSON-RPC 訊息；會改動電腦的動作一樣會跳出 Windows 確認視窗。

use crate::confirm::Origin;
use crate::tools::{self, Core};
use serde_json::{Value, json};
use std::io::{BufRead, Write};

const DEFAULT_PROTOCOL: &str = "2025-06-18";

fn instructions(lang: &str) -> &'static str {
    if lang == "en" {
        "Windows PC Cleanup tools. Look, then ask, then act: scan with read-only tools first, explain findings to the user, and only call tools with apply=true after the user agrees. Every apply=true call shows a Windows confirmation dialog on this PC; if the user cancels, do not retry or work around it. clear_folder/clean_old_files only accept items from scan_cleanup_targets. Never open personal sensitive files."
    } else {
        "Windows 電腦清理工具。先看、後問、再動：先用唯讀工具掃描並向使用者說明，使用者同意後才用 apply=true。每個 apply=true 都會在這台電腦跳出 Windows 確認視窗；使用者取消時不要重試或繞過。clear_folder／clean_old_files 只接受 scan_cleanup_targets 列出的項目。不要開啟個人敏感檔案。"
    }
}

fn handle(core: &Core, req: &Value) -> Option<Value> {
    let id = req.get("id").cloned();
    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or(json!({}));
    // 沒有 id 的是通知，不回應
    let id = id?;
    let lang = core.lang();
    let result: Result<Value, (i64, String)> = match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or(DEFAULT_PROTOCOL),
            "capabilities": { "tools": { "listChanged": false } },
            "serverInfo": { "name": "windows-pc-cleanup", "version": env!("CARGO_PKG_VERSION") },
            "instructions": instructions(&lang),
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({
            "tools": tools::specs().iter().map(|t| json!({ "name": t.name, "description": t.description(&lang), "inputSchema": t.schema })).collect::<Vec<_>>()
        })),
        "tools/call" => {
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            if !tools::specs().iter().any(|t| t.name == name) {
                Err((-32602, format!("unknown tool: {name}")))
            } else {
                Ok(match tools::run_tool(core, &name, &args, &Origin::Mcp) {
                    Ok(r) => {
                        let mut text = r.output.clone();
                        if !r.data.is_null() {
                            let data = r.data.to_string();
                            let data: String = data.chars().take(20_000).collect();
                            text.push_str("\n\n[data]\n");
                            text.push_str(&data);
                        }
                        json!({ "content": [{ "type": "text", "text": text }], "isError": !r.ok })
                    }
                    Err(e) => json!({ "content": [{ "type": "text", "text": e }], "isError": true }),
                })
            }
        }
        "resources/list" => Ok(json!({ "resources": [] })),
        "prompts/list" => Ok(json!({ "prompts": [] })),
        _ => Err((-32601, format!("method not found: {method}"))),
    };
    Some(match result {
        Ok(r) => json!({ "jsonrpc": "2.0", "id": id, "result": r }),
        Err((code, message)) => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }),
    })
}

pub fn serve() {
    let core = Core::new();
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Array(batch)) => {
                let out: Vec<Value> = batch.iter().filter_map(|r| handle(&core, r)).collect();
                if out.is_empty() { None } else { Some(Value::Array(out)) }
            }
            Ok(req) => handle(&core, &req),
            Err(e) => Some(json!({ "jsonrpc": "2.0", "id": null, "error": { "code": -32700, "message": e.to_string() } })),
        };
        if let Some(r) = reply {
            if writeln!(stdout, "{r}").and_then(|_| stdout.flush()).is_err() {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notifications_get_no_reply_and_unknown_methods_error() {
        let core = Core::new();
        assert!(handle(&core, &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })).is_none());
        let r = handle(&core, &json!({ "jsonrpc": "2.0", "id": 1, "method": "nope" })).unwrap();
        assert_eq!(r["error"]["code"], -32601);
        let r = handle(&core, &json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" })).unwrap();
        assert!(r["result"]["tools"].as_array().unwrap().len() >= 10);
    }
}
