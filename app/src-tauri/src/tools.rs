//! 工具清單：桌面介面、內建 AI 聊天與 MCP 共用同一套。
//! 安全規則（由這裡強制，不依賴呼叫端）：
//! - apply = true 的動作一律先跳原生確認視窗（confirm::ask）。
//! - clear_folder／clean_old_files 只能處理最近一次 scan_cleanup_targets 列出、且標示可自動處理的資料夾。
//! - clean_old_files 一定排除 Temp\claude（執行中的 AI 工具暫存）。
//! - organize_apply 只接受目前工作階段內的計畫檔；organize_plan 不開放 -AllowUnsafeRoot。
//! - organize_undo 只接受工作階段資料夾內的紀錄檔。計畫與紀錄的來源都必須在同一個資料夾，
//!   搬移目的地必須在那個資料夾底下，確認視窗會顯示這個資料夾。

use crate::confirm::{self, Origin};
use crate::scripts::{self, PsArg, RunOutput};
use crate::settings::Settings;
use regex::Regex;
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ToolResult {
    pub ok: bool,
    pub cancelled: bool,
    pub exit_code: i32,
    pub output: String,
    pub data: Value,
}

pub struct Core {
    pub session: Mutex<Option<PathBuf>>,
    pub settings: Mutex<Settings>,
}

impl Core {
    pub fn new() -> Self {
        Core { session: Mutex::new(None), settings: Mutex::new(crate::settings::load()) }
    }
    pub fn lang(&self) -> String {
        self.settings.lock().map(|s| s.lang.clone()).unwrap_or_else(|_| "en".into())
    }
}

pub fn sessions_root() -> PathBuf {
    // 測試用：可用環境變數改到暫存資料夾，避免寫進使用者的 PCCleanup
    if let Some(p) = std::env::var_os("PCC_SESSIONS_ROOT").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return p;
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join("PCCleanup")
}

pub struct ToolSpec {
    pub name: &'static str,
    pub zh: &'static str,
    pub en: &'static str,
    pub schema: Value,
}

impl ToolSpec {
    pub fn description(&self, lang: &str) -> &'static str {
        if lang == "en" { self.en } else { self.zh }
    }
}

fn obj(props: Value, required: &[&str]) -> Value {
    json!({ "type": "object", "properties": props, "required": required, "additionalProperties": false })
}

pub fn specs() -> Vec<ToolSpec> {
    let apply = json!({ "type": "boolean", "description": "false (default) = dry run only. true = actually run it; the user must approve a Windows confirmation dialog first." });
    vec![
        ToolSpec { name: "start_session", zh: "建立新的工作階段（記錄目前磁碟空間，之後的動作與報告都記在這裡）。", en: "Start a new session (records current free space; later actions and the report are stored in it).", schema: obj(json!({}), &[]) },
        ToolSpec { name: "scan_overview", zh: "掃描系統概況：作業系統、硬體、記憶體、各磁碟空間、記憶體用量前幾名的程式。唯讀。", en: "Scan system overview: OS, hardware, memory, drive space, top processes by memory. Read-only.", schema: obj(json!({ "top": { "type": "integer" } }), &[]) },
        ToolSpec { name: "scan_cleanup_targets", zh: "掃描可清理的快取與暫存（風險 A＝刪除後會自動重建；B＝需要使用者判斷），並列出資源回收筒大小。唯讀。之後 clear_folder／clean_old_files 只能處理這裡列出的項目。", en: "Scan caches and temp files that can be cleaned (risk A = rebuilt automatically; B = needs the user's judgment) and the Recycle Bin size. Read-only. clear_folder/clean_old_files can only act on items listed here.", schema: obj(json!({ "olderThanDays": { "type": "integer" } }), &[]) },
        ToolSpec { name: "scan_large_items", zh: "找出大型檔案與資料夾。唯讀。", en: "Find large files and folders. Read-only.", schema: obj(json!({ "roots": { "type": "array", "items": { "type": "string" } }, "minSizeMB": { "type": "integer" }, "top": { "type": "integer" } }), &[]) },
        ToolSpec { name: "scan_startup", zh: "列出開機啟動項目與登入時執行的排程工作。唯讀。", en: "List startup items and scheduled tasks that run at logon. Read-only.", schema: obj(json!({}), &[]) },
        ToolSpec { name: "health_check", zh: "軟硬體健康檢查：CPU、記憶體、磁碟健康、電池、事件記錄、Defender、異常程序。約 30 秒。唯讀。", en: "Hardware/software health check: CPU, memory, disk health, battery, event logs, Defender, abnormal processes. About 30 seconds. Read-only.", schema: obj(json!({}), &[]) },
        ToolSpec { name: "measure_free", zh: "量測各磁碟目前可用空間。唯讀。", en: "Measure current free space on each drive. Read-only.", schema: obj(json!({}), &[]) },
        ToolSpec { name: "clear_folder", zh: "清空一個快取資料夾的內容（保留資料夾本身，直接刪除、不進資源回收筒）。path 必須是 scan_cleanup_targets 結果中 Action 為 clear-folder 的 RealPath。相關程式執行中時會中止。", en: "Empty a cache folder (keeps the folder; deletes directly, not to the Recycle Bin). path must be the RealPath of a scan_cleanup_targets item whose Action is clear-folder. Aborts if related apps are running.", schema: obj(json!({ "path": { "type": "string" }, "processNames": { "type": "array", "items": { "type": "string" } }, "apply": apply }), &["path"]) },
        ToolSpec { name: "clean_old_files", zh: "刪除資料夾中超過 N 天的舊檔（預設直接刪除；recycle=true 改送資源回收筒）。path 必須是 scan_cleanup_targets 結果中 Action 為 clean-old-files 的 RealPath。", en: "Delete files older than N days in a folder (deleted directly by default; recycle=true sends them to the Recycle Bin). path must be the RealPath of a scan_cleanup_targets item whose Action is clean-old-files.", schema: obj(json!({ "path": { "type": "string" }, "olderThanDays": { "type": "integer" }, "excludeTopLevel": { "type": "array", "items": { "type": "string" } }, "recycle": { "type": "boolean" }, "apply": apply }), &["path"]) },
        ToolSpec { name: "organize_plan", zh: "為一個資料夾（預設是下載資料夾）產生整理計畫：依類型與主題分類、找出重複檔與已解壓縮的壓縮檔。只產生計畫，不搬動任何檔案。系統與使用者根資料夾會被拒絕。", en: "Create an organization plan for a folder (Downloads by default): sort by type and topic, find duplicates and extracted archives. Only creates a plan; moves nothing. System and user root folders are refused.", schema: obj(json!({ "root": { "type": "string" } }), &[]) },
        ToolSpec { name: "organize_apply", zh: "依整理計畫搬移檔案（plan 是 organize_plan 回傳的 planFile；省略時用目前工作階段最新的計畫）。要移除的項目送資源回收筒，或指定 quarantineDir 隔離。會留下還原腳本與紀錄。", en: "Move files according to an organization plan (plan = the planFile returned by organize_plan; defaults to the latest plan in this session). Items to remove go to the Recycle Bin, or to quarantineDir. Leaves an undo script and a log.", schema: obj(json!({ "plan": { "type": "string" }, "quarantineDir": { "type": "string" }, "apply": apply }), &[]) },
        ToolSpec { name: "organize_undo", zh: "依整理紀錄把搬過的檔案搬回原位。log 必須是工作階段資料夾內的 organize-log-*.csv（organize_apply 回傳的 logFile）。", en: "Move files back according to an organize log. log must be an organize-log-*.csv inside the sessions folder (the logFile returned by organize_apply).", schema: obj(json!({ "log": { "type": "string" }, "apply": apply }), &["log"]) },
        ToolSpec { name: "build_report", zh: "產生這個工作階段的 HTML 總整報告（清理成果、健檢、整理、待決定事項、溯源與還原方式）。", en: "Build the HTML report for this session (results, health, organization, pending items, traceability and undo).", schema: obj(json!({}), &[]) },
        ToolSpec { name: "log_action", zh: "記錄一筆動作到工作階段（例如使用者決定略過或待決定的項目），會出現在報告中。", en: "Record an action in the session (e.g. items the user skipped or left pending); it appears in the report.", schema: obj(json!({ "category": { "type": "string" }, "action": { "type": "string" }, "target": { "type": "string" }, "result": { "type": "string", "enum": ["done", "partial", "skipped", "failed", "pending"] }, "reversible": { "type": "string", "enum": ["yes", "recycle-bin", "undo-script", "reinstall", "no"] }, "note": { "type": "string" }, "bytesFreed": { "type": "integer" } }), &["category", "action"]) },
    ]
}

// ---- 參數 ----

fn expand(s: &str) -> String {
    let mut out = s.trim().to_string();
    if let Some(rest) = out.strip_prefix("~\\").or_else(|| out.strip_prefix("~/")) {
        if let Some(h) = dirs::home_dir() {
            out = h.join(rest).to_string_lossy().into_owned();
        }
    }
    for var in ["USERPROFILE", "LOCALAPPDATA", "APPDATA", "TEMP", "TMP", "SystemRoot", "ProgramData", "SystemDrive"] {
        if let Ok(v) = std::env::var(var) {
            let re = Regex::new(&format!("(?i)%{var}%")).expect("valid regex");
            out = re.replace_all(&out, regex::NoExpand(&v)).into_owned();
        }
    }
    out
}

fn arg_s(a: &Value, k: &str) -> Option<String> {
    a.get(k).and_then(|v| v.as_str()).map(expand).filter(|x| !x.is_empty())
}
fn arg_raw(a: &Value, k: &str) -> Option<String> {
    a.get(k).and_then(|v| v.as_str()).map(|x| x.trim().to_string()).filter(|x| !x.is_empty())
}
fn arg_i(a: &Value, k: &str) -> Option<i64> {
    a.get(k).and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
}
fn arg_b(a: &Value, k: &str) -> bool {
    a.get(k).and_then(|v| v.as_bool().or_else(|| v.as_str().map(|s| s.eq_ignore_ascii_case("true")))).unwrap_or(false)
}
fn arg_arr(a: &Value, k: &str) -> Vec<String> {
    match a.get(k) {
        Some(Value::Array(v)) => v.iter().filter_map(|x| x.as_str()).map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect(),
        Some(Value::String(s)) => s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect(),
        _ => vec![],
    }
}

// ---- 路徑 ----

/// 解析成最終實際路徑（展開 junction、符號連結與 8.3 短檔名），去掉 \\?\ 前綴
pub fn canonical(p: &Path) -> Option<PathBuf> {
    let c = std::fs::canonicalize(p).ok()?;
    let s = c.to_string_lossy();
    Some(match s.strip_prefix(r"\\?\UNC\") {
        Some(rest) => PathBuf::from(format!(r"\\{rest}")),
        None => PathBuf::from(s.strip_prefix(r"\\?\").unwrap_or(&s)),
    })
}

fn same_path(a: &Path, b: &Path) -> bool {
    a.to_string_lossy().trim_end_matches('\\').eq_ignore_ascii_case(b.to_string_lossy().trim_end_matches('\\'))
}

fn is_inside(child: &Path, parent: &Path) -> bool {
    let (c, p) = (child.to_string_lossy().to_lowercase(), parent.to_string_lossy().to_lowercase());
    let p = p.trim_end_matches('\\');
    c.len() > p.len() + 1 && c.starts_with(p) && c.as_bytes()[p.len()] == b'\\'
}

/// 必須是完整路徑，而且不能含 . 或 .. 這類相對路徑片段（避免字串比對被 ..\ 繞過）
fn plain_abs(p: &Path) -> bool {
    p.is_absolute() && !p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir))
}

fn row_str<'a>(r: &'a Value, k: &str) -> &'a str {
    r.get(k).and_then(|v| v.as_str()).map(str::trim).unwrap_or("")
}

/// 從每一列的 Source 推出整理根目錄：organize-plan 產生的來源一定都是同一個資料夾的直接子項目，
/// 有任何一列不是就拒絕（例如被竄改或不是本程式產生的計畫／紀錄）。
fn common_root<'a>(sources: impl Iterator<Item = &'a str>, zh: bool) -> Result<PathBuf, String> {
    let bad = |s: &str| msg(zh, &format!("計畫或紀錄中的路徑不合法：{s}"), &format!("Invalid path in the plan or log: {s}"));
    let mut root: Option<PathBuf> = None;
    for s in sources {
        let p = Path::new(s);
        if !plain_abs(p) {
            return Err(bad(s));
        }
        let parent = p.parent().filter(|x| x.parent().is_some()).ok_or_else(|| bad(s))?;
        match &root {
            None => root = Some(parent.to_path_buf()),
            Some(r) if same_path(r, parent) => {}
            Some(_) => {
                return Err(msg(
                    zh,
                    "計畫或紀錄中的來源不在同一個資料夾裡，拒絕執行。",
                    "The sources in the plan or log are not all in one folder; refusing to run it.",
                ));
            }
        }
    }
    root.ok_or_else(|| msg(zh, "計畫或紀錄沒有任何項目。", "The plan or log has no entries."))
}

/// 清單太長時只列前幾項，其餘以「等 N 項」表示
fn short_list(items: &[String], zh: bool) -> String {
    const MAX: usize = 8;
    let mut s = items.iter().take(MAX).cloned().collect::<Vec<_>>().join(if zh { "、" } else { ", " });
    if items.len() > MAX {
        s.push_str(&msg(zh, &format!(" 等 {} 項", items.len()), &format!(" and {} more", items.len() - MAX)));
    }
    s
}

pub(crate) struct PlanSummary {
    root: PathBuf,
    moves: usize,
    removes: usize,
    dest_folders: Vec<String>,
}

/// 檢查整理計畫並整理出確認視窗要顯示的內容：
/// 所有來源必須在同一個資料夾，搬移目的地必須在那個資料夾底下。
pub(crate) fn summarize_plan(rows: &[Value], zh: bool) -> Result<PlanSummary, String> {
    let root = common_root(rows.iter().map(|r| row_str(r, "Source")), zh)?;
    let (mut moves, mut removes, mut dest_folders) = (0, 0, Vec::<String>::new());
    for r in rows {
        match row_str(r, "Action") {
            "Move" => {
                let dest = Path::new(row_str(r, "Dest"));
                let dir = dest.parent().unwrap_or(dest);
                if !plain_abs(dest) || (!is_inside(dir, &root) && !same_path(dir, &root)) {
                    return Err(msg(zh, &format!("搬移目的地不在整理資料夾內：{}", dest.display()), &format!("A move destination is outside the organized folder: {}", dest.display())));
                }
                // 上面已確認 dir 在 root 底下（不分大小寫），這裡取出相對部分顯示
                let (ds, rs) = (dir.to_string_lossy(), root.to_string_lossy());
                let rel = ds.get(rs.trim_end_matches('\\').len()..).unwrap_or("").trim_start_matches('\\').to_string();
                if !rel.is_empty() && !dest_folders.iter().any(|d| d.eq_ignore_ascii_case(&rel)) {
                    dest_folders.push(rel);
                }
                moves += 1;
            }
            "Recycle" => removes += 1,
            other => return Err(msg(zh, &format!("計畫中有不認得的動作：{other}"), &format!("Unknown action in the plan: {other}"))),
        }
    }
    dest_folders.sort_by_key(|d| d.to_lowercase());
    Ok(PlanSummary { root, moves, removes, dest_folders })
}

pub(crate) struct LogSummary {
    root: PathBuf,
    restorable: usize,
    in_bin: usize,
}

const BIN_MARKERS: [&str; 2] = ["(RecycleBin)", "(資源回收筒)"];

/// 檢查整理紀錄：會被搬回去的位置（Source）都必須在同一個整理資料夾內
pub(crate) fn summarize_log(rows: &[Value], zh: bool) -> Result<LogSummary, String> {
    let root = common_root(rows.iter().map(|r| row_str(r, "Source")).filter(|s| !s.is_empty()), zh)?;
    let ok = |r: &&Value| row_str(r, "Status") == "OK";
    let in_bin = rows.iter().filter(ok).filter(|r| BIN_MARKERS.contains(&row_str(r, "Final"))).count();
    let restorable = rows.iter().filter(ok).filter(|r| !row_str(r, "Final").is_empty() && !BIN_MARKERS.contains(&row_str(r, "Final"))).count();
    Ok(LogSummary { root, restorable, in_bin })
}

fn read_json(p: &Path) -> Value {
    std::fs::read_to_string(p)
        .ok()
        .and_then(|t| serde_json::from_str(t.trim_start_matches('\u{feff}')).ok())
        .unwrap_or(Value::Null)
}

fn read_csv(p: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(p) else { return Value::Null };
    let mut rdr = csv::ReaderBuilder::new().from_reader(text.trim_start_matches('\u{feff}').as_bytes());
    let Ok(headers) = rdr.headers().cloned() else { return Value::Null };
    let rows: Vec<Value> = rdr
        .records()
        .filter_map(Result::ok)
        .map(|r| {
            let mut m = Map::new();
            for (h, v) in headers.iter().zip(r.iter()) {
                m.insert(h.to_string(), Value::String(v.to_string()));
            }
            Value::Object(m)
        })
        .collect();
    Value::Array(rows)
}

fn list_files(dir: &Path, prefix: &str, ext: &str) -> Vec<(PathBuf, SystemTime)> {
    let mut v: Vec<(PathBuf, SystemTime)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|e| {
            let n = e.file_name().to_string_lossy().to_lowercase();
            n.starts_with(prefix) && n.ends_with(ext) && e.path().is_file()
        })
        .map(|e| (e.path(), e.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH)))
        .collect();
    v.sort_by_key(|x| x.1);
    v
}

fn newest_new(before: &[(PathBuf, SystemTime)], after: Vec<(PathBuf, SystemTime)>) -> Option<PathBuf> {
    after.into_iter().rev().find(|(p, _)| !before.iter().any(|(b, _)| b == p)).map(|x| x.0)
}

// ---- 執行 ----

fn msg(zh: bool, z: &str, e: &str) -> String {
    if zh { z.to_string() } else { e.to_string() }
}

fn finish(out: RunOutput, data: Value) -> ToolResult {
    ToolResult { ok: out.exit_code == 0, cancelled: false, exit_code: out.exit_code, output: out.output, data }
}

fn cancelled(zh: bool) -> ToolResult {
    ToolResult {
        ok: false,
        cancelled: true,
        exit_code: -1,
        output: msg(zh, "使用者在確認視窗按了取消，沒有執行。", "The user clicked Cancel in the confirmation dialog; nothing was done."),
        data: Value::Null,
    }
}

fn new_session(core: &Core, root: &Path, lang: &str) -> Result<PathBuf, String> {
    let sroot = sessions_root();
    let out = scripts::run(root, "new-session.ps1", &[PsArg::Str("Root", sroot.to_string_lossy().into()), PsArg::Str("Lang", lang.into())])?;
    let dir = out.output.lines().map(str::trim).filter(|l| !l.is_empty()).last().map(PathBuf::from).unwrap_or_default();
    if out.exit_code != 0 || !dir.is_dir() || !is_inside(&dir, &sroot) {
        return Err(format!("new-session failed: {}", out.output));
    }
    *core.session.lock().map_err(|e| e.to_string())? = Some(dir.clone());
    Ok(dir)
}

fn ensure_session(core: &Core, root: &Path, lang: &str) -> Result<PathBuf, String> {
    let cur = core.session.lock().map_err(|e| e.to_string())?.clone();
    match cur {
        Some(s) if s.join("baseline.json").is_file() => Ok(s),
        _ => new_session(core, root, lang),
    }
}

/// 找出 scan_cleanup_targets 中路徑相符、且 Action 相符的項目
fn catalog_target(session: &Path, requested: Option<String>, action: &str, zh: bool) -> Result<(PathBuf, Value), String> {
    let data = read_json(&session.join("cleanup-targets.json"));
    let Some(targets) = data.get("targets").and_then(|t| t.as_array()) else {
        return Err(msg(zh, "請先執行 scan_cleanup_targets。", "Run scan_cleanup_targets first."));
    };
    let requested = requested.ok_or_else(|| msg(zh, "缺少 path。", "Missing path."))?;
    let req = canonical(Path::new(&requested)).ok_or_else(|| msg(zh, &format!("找不到路徑：{requested}"), &format!("Path not found: {requested}")))?;
    for t in targets {
        if t.get("Action").and_then(|a| a.as_str()) != Some(action) {
            continue;
        }
        let Some(rp) = t.get("RealPath").and_then(|p| p.as_str()) else { continue };
        if let Some(c) = canonical(Path::new(rp)) {
            if same_path(&c, &req) {
                return Ok((c, t.clone()));
            }
        }
    }
    Err(msg(
        zh,
        &format!("這個路徑不在可自動清理的清單裡（只能處理 scan_cleanup_targets 中 Action 為 {action} 的項目）：{requested}"),
        &format!("This path is not on the list of folders that can be cleaned automatically (only scan_cleanup_targets items whose Action is {action}): {requested}"),
    ))
}

pub fn run_tool(core: &Core, name: &str, args: &Value, origin: &Origin) -> Result<ToolResult, String> {
    let lang = core.lang();
    let zh = lang != "en";
    let root = scripts::ensure_extracted()?;
    let lang_arg = || PsArg::Str("Lang", lang.clone());

    // 不需要工作階段的工具
    match name {
        "start_session" => {
            let dir = new_session(core, &root, &lang)?;
            return Ok(ToolResult { ok: true, output: dir.to_string_lossy().into(), data: json!({ "sessionDir": dir }), ..Default::default() });
        }
        "measure_free" => return Ok(finish(scripts::run(&root, "measure-free.ps1", &[lang_arg()])?, Value::Null)),
        "organize_undo" => {
            let log = arg_s(args, "log").ok_or_else(|| msg(zh, "缺少 log。", "Missing log."))?;
            let lp = canonical(Path::new(&log)).ok_or_else(|| msg(zh, "找不到紀錄檔。", "Log file not found."))?;
            let fname = lp.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
            if !lp.is_file() || !fname.starts_with("organize-log-") || !fname.ends_with(".csv") {
                return Err(msg(zh, "只接受 organize-log-*.csv 紀錄檔。", "Only organize-log-*.csv files are accepted."));
            }
            // 只接受本程式工作階段資料夾內的紀錄（organize_apply 一定會在工作階段留一份），
            // 避免下載來的或 AI 指定的任意 CSV 被拿來把檔案搬到任意位置
            let sroot = sessions_root();
            if !canonical(&sroot).is_some_and(|r| is_inside(&lp, &r)) {
                return Err(msg(
                    zh,
                    &format!("只接受工作階段資料夾（{}）內的整理紀錄。整理資料夾裡的副本請直接執行同一個資料夾中的 organize-undo.ps1。", sroot.display()),
                    &format!("Only organize logs inside the sessions folder ({}) are accepted. For the copy in the organized folder, run the organize-undo.ps1 next to it.", sroot.display()),
                ));
            }
            let rows = read_csv(&lp).as_array().cloned().unwrap_or_default();
            let sum = summarize_log(&rows, zh)?;
            let apply = arg_b(args, "apply");
            if apply
                && !confirm::ask(
                    origin,
                    zh,
                    &msg(zh, "依整理紀錄把檔案搬回原位", "Move files back according to the organize log"),
                    &[
                        msg(zh, &format!("還原到：{}", sum.root.display()), &format!("Restore into: {}", sum.root.display())),
                        msg(zh, &format!("搬回 {} 項；另有 {} 項在資源回收筒", sum.restorable, sum.in_bin), &format!("Move back {} items; {} more are in the Recycle Bin", sum.restorable, sum.in_bin)),
                        msg(zh, &format!("紀錄檔：{}", lp.display()), &format!("Log file: {}", lp.display())),
                    ],
                    &msg(zh, "送進資源回收筒的項目需要從資源回收筒手動還原。", "Items in the Recycle Bin must be restored from the Recycle Bin by hand."),
                )
            {
                return Ok(cancelled(zh));
            }
            let mut a = vec![PsArg::Str("Log", lp.to_string_lossy().into()), lang_arg()];
            if apply {
                a.push(PsArg::Switch("Apply"));
            }
            return Ok(finish(scripts::run(&root, "organize-undo.ps1", &a)?, Value::Null));
        }
        _ => {}
    }

    let session = ensure_session(core, &root, &lang)?;
    let sd = || PsArg::Str("SessionDir", session.to_string_lossy().into());

    match name {
        "scan_overview" => {
            let mut a = vec![sd(), lang_arg()];
            if let Some(t) = arg_i(args, "top") {
                a.push(PsArg::Int("Top", t.clamp(1, 100)));
            }
            Ok(finish(scripts::run(&root, "scan-overview.ps1", &a)?, read_json(&session.join("overview.json"))))
        }
        "scan_cleanup_targets" => {
            let mut a = vec![sd(), lang_arg()];
            if let Some(d) = arg_i(args, "olderThanDays") {
                a.push(PsArg::Int("OlderThanDays", d.clamp(1, 3650)));
            }
            Ok(finish(scripts::run(&root, "scan-cleanup-targets.ps1", &a)?, read_json(&session.join("cleanup-targets.json"))))
        }
        "scan_large_items" => {
            let mut a = vec![sd(), lang_arg()];
            let roots: Vec<String> = arg_arr(args, "roots").iter().map(|r| expand(r)).collect();
            if !roots.is_empty() {
                a.push(PsArg::Arr("Roots", roots));
            }
            if let Some(m) = arg_i(args, "minSizeMB") {
                a.push(PsArg::Int("MinSizeMB", m.clamp(1, 1_000_000)));
            }
            if let Some(t) = arg_i(args, "top") {
                a.push(PsArg::Int("Top", t.clamp(1, 500)));
            }
            Ok(finish(scripts::run(&root, "scan-large-items.ps1", &a)?, read_json(&session.join("large-items.json"))))
        }
        "scan_startup" => Ok(finish(scripts::run(&root, "scan-startup.ps1", &[sd(), lang_arg()])?, read_json(&session.join("startup.json")))),
        "health_check" => Ok(finish(scripts::run(&root, "health-check.ps1", &[sd(), lang_arg()])?, read_json(&session.join("health.json")))),
        "clear_folder" => {
            let (path, target) = catalog_target(&session, arg_s(args, "path"), "clear-folder", zh)?;
            // 確認視窗與紀錄用掃描清單裡的名稱，不用呼叫端提供的文字（避免誤導使用者）
            let label = target.get("Name").and_then(|n| n.as_str()).map(String::from).unwrap_or_default();
            // 目錄裡登記的相關程式一定要檢查，呼叫端只能再加，不能拿掉
            let mut procs = arg_arr(args, "processNames");
            for p in target.get("Procs").and_then(|p| p.as_array()).into_iter().flatten().filter_map(|p| p.as_str()) {
                if !procs.iter().any(|x| x.eq_ignore_ascii_case(p)) {
                    procs.push(p.to_string());
                }
            }
            let apply = arg_b(args, "apply");
            if apply
                && !confirm::ask(
                    origin,
                    zh,
                    &msg(zh, &format!("清空快取資料夾：{label}"), &format!("Empty cache folder: {label}")),
                    &[path.to_string_lossy().into()],
                    &msg(zh, "資料夾內容會直接刪除，不會進資源回收筒；快取會由程式自動重建。", "The folder contents are deleted directly, not sent to the Recycle Bin; apps rebuild their caches automatically."),
                )
            {
                return Ok(cancelled(zh));
            }
            let mut a = vec![sd(), PsArg::Str("Path", path.to_string_lossy().into()), PsArg::Str("Label", label), PsArg::Arr("ProcessNames", procs), lang_arg()];
            if apply {
                a.push(PsArg::Switch("Apply"));
            }
            Ok(finish(scripts::run(&root, "clear-folder.ps1", &a)?, Value::Null))
        }
        "clean_old_files" => {
            let (path, _) = catalog_target(&session, arg_s(args, "path"), "clean-old-files", zh)?;
            let days = arg_i(args, "olderThanDays").unwrap_or(7).clamp(1, 3650);
            let mut exclude = arg_arr(args, "excludeTopLevel");
            if !exclude.iter().any(|x| x.eq_ignore_ascii_case("claude")) {
                exclude.push("claude".into());
            }
            let recycle = arg_b(args, "recycle");
            let apply = arg_b(args, "apply");
            if apply
                && !confirm::ask(
                    origin,
                    zh,
                    &msg(zh, &format!("刪除超過 {days} 天的舊檔"), &format!("Delete files older than {days} days")),
                    &[path.to_string_lossy().into(), msg(zh, &format!("排除：{}", exclude.join("、")), &format!("Excluded: {}", exclude.join(", ")))],
                    &if recycle {
                        msg(zh, "檔案會送進資源回收筒。", "Files are sent to the Recycle Bin.")
                    } else {
                        msg(zh, "檔案會直接刪除，不會進資源回收筒。", "Files are deleted directly, not sent to the Recycle Bin.")
                    },
                )
            {
                return Ok(cancelled(zh));
            }
            let mut a = vec![sd(), PsArg::Str("Path", path.to_string_lossy().into()), PsArg::Int("OlderThanDays", days), PsArg::Arr("ExcludeTopLevel", exclude), lang_arg()];
            if recycle {
                a.push(PsArg::Switch("Recycle"));
            }
            if apply {
                a.push(PsArg::Switch("Apply"));
            }
            Ok(finish(scripts::run(&root, "clean-old-files.ps1", &a)?, Value::Null))
        }
        "organize_plan" => {
            let before = list_files(&session, "organize-plan-", ".csv");
            let mut a = vec![sd(), lang_arg()];
            if let Some(r) = arg_s(args, "root") {
                a.push(PsArg::Str("Root", r));
            }
            let out = scripts::run(&root, "organize-plan.ps1", &a)?;
            let data = match newest_new(&before, list_files(&session, "organize-plan-", ".csv")) {
                Some(p) => json!({ "planFile": p, "rows": read_csv(&p) }),
                None => Value::Null,
            };
            Ok(finish(out, data))
        }
        "organize_apply" => {
            let plan = match arg_s(args, "plan") {
                Some(p) => canonical(Path::new(&p)).ok_or_else(|| msg(zh, "找不到計畫檔。", "Plan file not found."))?,
                None => list_files(&session, "organize-plan-", ".csv").pop().map(|x| x.0).ok_or_else(|| msg(zh, "請先執行 organize_plan。", "Run organize_plan first."))?,
            };
            let csess = canonical(&session).unwrap_or(session.clone());
            let fname = plan.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
            if !plan.parent().is_some_and(|p| same_path(p, &csess)) || !fname.starts_with("organize-plan-") || !fname.ends_with(".csv") {
                return Err(msg(zh, "只接受目前工作階段內的 organize-plan-*.csv。", "Only organize-plan-*.csv files in the current session are accepted."));
            }
            let quarantine = arg_s(args, "quarantineDir");
            if let Some(q) = &quarantine {
                if !Path::new(q).is_absolute() {
                    return Err(msg(zh, "quarantineDir 必須是完整路徑。", "quarantineDir must be an absolute path."));
                }
            }
            // 試跑也先檢查，讓 AI 在要求使用者確認前就知道計畫有問題
            let rows = read_csv(&plan).as_array().cloned().unwrap_or_default();
            let sum = summarize_plan(&rows, zh)?;
            let apply = arg_b(args, "apply");
            if apply {
                let where_ = match &quarantine {
                    Some(q) => msg(zh, &format!("隔離資料夾 {q}"), &format!("quarantine folder {q}")),
                    None => msg(zh, "資源回收筒", "the Recycle Bin"),
                };
                let (moves, removes) = (sum.moves, sum.removes);
                let folders = if sum.dest_folders.is_empty() { msg(zh, "（無）", "(none)") } else { short_list(&sum.dest_folders, zh) };
                if !confirm::ask(
                    origin,
                    zh,
                    &msg(zh, "依整理計畫搬移檔案", "Move files according to the organization plan"),
                    &[
                        msg(zh, &format!("整理的資料夾：{}", sum.root.display()), &format!("Folder to organize: {}", sum.root.display())),
                        msg(zh, &format!("搬移 {moves} 項；{removes} 項移到{where_}"), &format!("Move {moves} items; {removes} items go to {where_}")),
                        msg(zh, &format!("搬到這些子資料夾：{folders}"), &format!("Into these subfolders: {folders}")),
                        msg(zh, &format!("計畫檔：{}", plan.display()), &format!("Plan file: {}", plan.display())),
                    ],
                    &msg(zh, "整理後會在目標資料夾留下紀錄與還原腳本，可以搬回原位。", "A log and an undo script are left in the organized folder so the changes can be undone."),
                ) {
                    return Ok(cancelled(zh));
                }
            }
            let before = list_files(&session, "organize-log-", ".csv");
            let mut a = vec![sd(), PsArg::Str("Plan", plan.to_string_lossy().into()), lang_arg()];
            if let Some(q) = quarantine {
                a.push(PsArg::Str("QuarantineDir", q));
            }
            if apply {
                a.push(PsArg::Switch("Apply"));
            }
            let out = scripts::run(&root, "organize-apply.ps1", &a)?;
            let data = newest_new(&before, list_files(&session, "organize-log-", ".csv")).map(|p| json!({ "logFile": p })).unwrap_or(Value::Null);
            Ok(finish(out, data))
        }
        "build_report" => {
            let out = scripts::run(&root, "build-report.ps1", &[sd(), lang_arg()])?;
            let rp = session.join("report.html");
            let data = if rp.is_file() { json!({ "reportPath": rp }) } else { Value::Null };
            Ok(finish(out, data))
        }
        "log_action" => {
            let category = arg_raw(args, "category").ok_or_else(|| msg(zh, "缺少 category。", "Missing category."))?;
            let action = arg_raw(args, "action").ok_or_else(|| msg(zh, "缺少 action。", "Missing action."))?;
            let mut a = vec![sd(), PsArg::Str("Category", category), PsArg::Str("Action", action), lang_arg()];
            for (k, p) in [("target", "Target"), ("note", "Note"), ("undoHint", "UndoHint"), ("evidence", "Evidence"), ("command", "Command")] {
                if let Some(v) = arg_raw(args, k) {
                    a.push(PsArg::Str(p, v));
                }
            }
            if let Some(r) = arg_raw(args, "result").filter(|r| ["done", "partial", "skipped", "failed", "pending"].contains(&r.as_str())) {
                a.push(PsArg::Str("Result", r));
            }
            if let Some(r) = arg_raw(args, "reversible").filter(|r| ["yes", "recycle-bin", "undo-script", "reinstall", "no"].contains(&r.as_str())) {
                a.push(PsArg::Str("Reversible", r));
            }
            if let Some(b) = arg_i(args, "bytesFreed") {
                a.push(PsArg::Int("BytesFreed", b.max(0)));
            }
            Ok(finish(scripts::run(&root, "log-action.ps1", &a)?, Value::Null))
        }
        _ => Err(format!("unknown tool: {name}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inside_requires_separator() {
        assert!(is_inside(Path::new(r"C:\Users\a\PCCleanup\x"), Path::new(r"C:\Users\a\PCCleanup")));
        assert!(!is_inside(Path::new(r"C:\Users\a\PCCleanupEvil"), Path::new(r"C:\Users\a\PCCleanup")));
        assert!(!is_inside(Path::new(r"C:\Users\a\PCCleanup"), Path::new(r"C:\Users\a\PCCleanup")));
    }

    #[test]
    fn expand_known_variables_only() {
        let up = std::env::var("USERPROFILE").unwrap();
        assert_eq!(expand(r"%userprofile%\Downloads"), format!(r"{up}\Downloads"));
        assert_eq!(expand(r"%NOPE%\x"), r"%NOPE%\x");
    }

    fn rows(v: Value) -> Vec<Value> {
        v.as_array().cloned().unwrap()
    }

    #[test]
    fn arg_b_only_accepts_true() {
        assert!(arg_b(&json!({ "apply": true }), "apply"));
        assert!(arg_b(&json!({ "apply": "TRUE" }), "apply"));
        assert!(!arg_b(&json!({ "apply": "1" }), "apply"));
        assert!(!arg_b(&json!({ "apply": 1 }), "apply"));
        assert!(!arg_b(&json!({}), "apply"));
    }

    #[test]
    fn plan_summary_shows_root_and_folders() {
        let s = summarize_plan(
            &rows(json!([
                { "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Move", "Dest": r"C:\U\a\Downloads\文件\課業\x.pdf" },
                { "Source": r"C:\U\a\Downloads\y.jpg", "Action": "Move", "Dest": r"C:\U\a\downloads\圖片\y.jpg" },
                { "Source": r"C:\U\a\Downloads\z.exe", "Action": "Recycle", "Dest": "" }
            ])),
            true,
        )
        .unwrap();
        assert!(same_path(&s.root, Path::new(r"C:\U\a\Downloads")));
        assert_eq!((s.moves, s.removes), (2, 1));
        assert_eq!(s.dest_folders, vec![r"圖片".to_string(), r"文件\課業".to_string()]);
    }

    #[test]
    fn plan_rejects_mixed_roots_and_outside_dest() {
        let mixed = rows(json!([
            { "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Recycle" },
            { "Source": r"C:\U\a\Documents\y.pdf", "Action": "Recycle" }
        ]));
        assert!(summarize_plan(&mixed, true).is_err());
        let outside = rows(json!([{ "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Move", "Dest": r"C:\U\a\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\x.pdf" }]));
        assert!(summarize_plan(&outside, true).is_err());
        let dotdot = rows(json!([{ "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Move", "Dest": r"C:\U\a\Downloads\..\Startup\x.pdf" }]));
        assert!(summarize_plan(&dotdot, true).is_err());
        let relative = rows(json!([{ "Source": r"x.pdf", "Action": "Recycle" }]));
        assert!(summarize_plan(&relative, true).is_err());
        let drive_root = rows(json!([{ "Source": r"C:\x.pdf", "Action": "Recycle" }]));
        assert!(summarize_plan(&drive_root, true).is_err());
        let unknown = rows(json!([{ "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Delete" }]));
        assert!(summarize_plan(&unknown, true).is_err());
        assert!(summarize_plan(&[], true).is_err());
    }

    #[test]
    fn log_summary_counts_and_checks_sources() {
        let ok = summarize_log(
            &rows(json!([
                { "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Move", "Final": r"C:\U\a\Downloads\文件\x.pdf", "Status": "OK" },
                { "Source": r"C:\U\a\Downloads\z.exe", "Action": "Recycle", "Final": "(RecycleBin)", "Status": "OK" },
                { "Source": r"C:\U\a\Downloads\w.exe", "Action": "Recycle", "Final": "(資源回收筒)", "Status": "OK" },
                { "Source": r"C:\U\a\Downloads\v.pdf", "Action": "Move", "Final": "", "Status": "FAILED: x" }
            ])),
            true,
        )
        .unwrap();
        assert!(same_path(&ok.root, Path::new(r"C:\U\a\Downloads")));
        assert_eq!((ok.restorable, ok.in_bin), (1, 2));
        // 來源（還原目的地）分散在不同資料夾的紀錄一律拒絕
        let evil = rows(json!([
            { "Source": r"C:\U\a\Downloads\x.pdf", "Action": "Move", "Final": r"C:\U\a\Downloads\文件\x.pdf", "Status": "OK" },
            { "Source": r"C:\U\a\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\evil.exe", "Action": "Move", "Final": r"C:\U\a\Downloads\evil.exe", "Status": "OK" }
        ]));
        assert!(summarize_log(&evil, true).is_err());
    }

    #[test]
    fn every_tool_has_object_schema() {
        for s in specs() {
            assert_eq!(s.schema["type"], "object", "{}", s.name);
        }
    }
}
