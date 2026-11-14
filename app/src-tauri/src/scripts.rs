//! 內嵌 skill 的 PowerShell 腳本，執行前解壓到使用者的 LocalAppData，再用 Windows PowerShell 執行。
//! 每次執行前都會比對內容、不同就覆寫，避免執行到被改過或舊版本的腳本。

use base64::Engine;
use std::fs;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

macro_rules! embed {
    ($($dir:literal / $name:literal),* $(,)?) => {
        &[ $( ($dir, $name, include_bytes!(concat!("../../../skills/windows-pc-cleanup/", $dir, "/", $name)) as &[u8]) ),* ]
    };
}

/// (子資料夾, 檔名, 內容)
static FILES: &[(&str, &str, &[u8])] = embed![
    "scripts" / "common.ps1",
    "scripts" / "new-session.ps1",
    "scripts" / "scan-overview.ps1",
    "scripts" / "scan-cleanup-targets.ps1",
    "scripts" / "scan-large-items.ps1",
    "scripts" / "scan-startup.ps1",
    "scripts" / "health-check.ps1",
    "scripts" / "measure-free.ps1",
    "scripts" / "clear-folder.ps1",
    "scripts" / "clean-old-files.ps1",
    "scripts" / "organize-plan.ps1",
    "scripts" / "organize-apply.ps1",
    "scripts" / "organize-undo.ps1",
    "scripts" / "build-report.ps1",
    "scripts" / "log-action.ps1",
    "assets" / "organize-rules.default.json",
    "assets" / "organize-rules.en.json",
];

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub fn app_data_dir() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("WindowsPcCleanup")
}

/// 解壓腳本，回傳 runtime 根目錄（底下有 scripts\ 與 assets\）。
pub fn ensure_extracted() -> Result<PathBuf, String> {
    let root = app_data_dir().join(format!("runtime-{}", env!("CARGO_PKG_VERSION")));
    for (dir, name, bytes) in FILES {
        let d = root.join(dir);
        fs::create_dir_all(&d).map_err(|e| format!("{}: {e}", d.display()))?;
        let p = d.join(name);
        if fs::read(&p).ok().as_deref() != Some(*bytes) {
            fs::write(&p, bytes).map_err(|e| format!("{}: {e}", p.display()))?;
        }
    }
    Ok(root)
}

pub fn scripts_dir(root: &Path) -> PathBuf {
    root.join("scripts")
}

pub enum PsArg {
    Str(&'static str, String),
    Int(&'static str, i64),
    Arr(&'static str, Vec<String>),
    Switch(&'static str),
}

pub struct RunOutput {
    pub exit_code: i32,
    pub output: String,
}

/// PowerShell 單引號字串。單引號（含 PowerShell 也當成引號的彎引號）一律重複一次。
pub fn ps_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

fn build_command(script: &Path, args: &[PsArg]) -> String {
    let mut cmd = String::from(
        "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $global:LASTEXITCODE=0; & ",
    );
    cmd.push_str(&ps_quote(&script.to_string_lossy()));
    for a in args {
        match a {
            PsArg::Str(n, v) => cmd.push_str(&format!(" -{n} {}", ps_quote(v))),
            PsArg::Int(n, v) => cmd.push_str(&format!(" -{n} {v}")),
            PsArg::Arr(n, v) => {
                let items: Vec<String> = v.iter().map(|x| ps_quote(x)).collect();
                cmd.push_str(&format!(" -{n} @({})", items.join(",")));
            }
            PsArg::Switch(n) => cmd.push_str(&format!(" -{n}")),
        }
    }
    // 所有串流合併成文字輸出；錯誤記錄加上前綴，方便前端與模型辨識
    cmd.push_str(
        " *>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { 'ERROR: ' + $_.ToString() } else { $_ | Out-String -Width 300 -Stream } }; exit $global:LASTEXITCODE",
    );
    cmd
}

/// PowerShell 在 stderr 輸出 CLIXML 時，只取出錯誤文字
fn clean_stderr(s: &str) -> String {
    if !s.trim_start().starts_with("#< CLIXML") {
        return s.trim().to_string();
    }
    let mut out = Vec::new();
    for part in s.split("<S S=\"Error\">").skip(1) {
        if let Some(end) = part.find("</S>") {
            out.push(
                part[..end]
                    .replace("_x000D__x000A_", "\n")
                    .replace("&lt;", "<")
                    .replace("&gt;", ">")
                    .replace("&quot;", "\"")
                    .replace("&apos;", "'")
                    .replace("&amp;", "&"),
            );
        }
    }
    out.join("").trim().to_string()
}

fn powershell_exe() -> PathBuf {
    let sys = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    sys.join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
}

pub fn run(root: &Path, script: &str, args: &[PsArg]) -> Result<RunOutput, String> {
    let path = scripts_dir(root).join(script);
    if !path.is_file() {
        return Err(format!("script not found: {}", path.display()));
    }
    let utf16: Vec<u8> = build_command(&path, args).encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    let encoded = base64::engine::general_purpose::STANDARD.encode(utf16);
    let out = Command::new(powershell_exe())
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded])
        .stdin(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("powershell.exe: {e}"))?;
    let mut output = String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n").trim_end().to_string();
    let err = clean_stderr(&String::from_utf8_lossy(&out.stderr));
    if !err.is_empty() {
        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str("ERROR: ");
        output.push_str(&err);
    }
    Ok(RunOutput { exit_code: out.status.code().unwrap_or(-1), output })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_escapes_all_single_quote_variants() {
        assert_eq!(ps_quote("a'b"), "'a''b'");
        assert_eq!(ps_quote("x\u{2019}y"), "'x\u{2019}\u{2019}y'");
        assert_eq!(ps_quote("$(rm -r C:\\)"), "'$(rm -r C:\\)'");
    }

    #[test]
    fn clixml_errors_are_extracted() {
        let s = "#< CLIXML\r\n<Objs><S S=\"Error\">bad &amp; worse_x000D__x000A_</S></Objs>";
        assert_eq!(clean_stderr(s), "bad & worse");
    }
}
