//! 會改動電腦的動作，一律在這裡用 Windows 原生對話框向使用者確認。
//! 前端與 AI 都只能「提出」要求，按下確定的只能是使用者本人。預設按鈕是「取消」。

use windows_sys::Win32::UI::WindowsAndMessaging::{
    IDOK, MB_DEFBUTTON2, MB_ICONWARNING, MB_OKCANCEL, MB_SETFOREGROUND, MB_TOPMOST, MessageBoxW,
};

pub enum Origin {
    /// 桌面程式本身（附上主視窗 HWND，讓對話框成為它的子視窗）
    Gui(isize),
    /// 外部 MCP 用戶端
    Mcp,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn ask(origin: &Origin, zh: bool, action: &str, details: &[String], warning: &str) -> bool {
    let mut body = String::new();
    if matches!(origin, Origin::Mcp) {
        body.push_str(if zh {
            "這個要求來自外部 AI 用戶端（MCP）。\n\n"
        } else {
            "This request comes from an external AI client (MCP).\n\n"
        });
    }
    body.push_str(action);
    body.push_str("\n\n");
    for d in details {
        let line: String = d.chars().take(400).collect();
        body.push_str(&line);
        body.push('\n');
    }
    if !warning.is_empty() {
        body.push('\n');
        body.push_str(warning);
        body.push('\n');
    }
    body.push_str(if zh {
        "\n按「確定」執行，按「取消」放棄。"
    } else {
        "\nClick OK to run it, or Cancel to skip."
    });
    let title = if zh { "Windows PC Cleanup：確認執行" } else { "Windows PC Cleanup: confirm" };
    let hwnd = match origin {
        Origin::Gui(h) => *h as *mut core::ffi::c_void,
        Origin::Mcp => std::ptr::null_mut(),
    };
    let (b, t) = (wide(&body), wide(title));
    let style = MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 | MB_TOPMOST | MB_SETFOREGROUND;
    // SAFETY：兩個字串都以 0 結尾，並在呼叫期間保持存活
    let r = unsafe { MessageBoxW(hwnd, b.as_ptr(), t.as_ptr(), style) };
    r == IDOK
}
