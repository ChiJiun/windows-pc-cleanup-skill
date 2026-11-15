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

/// 會改變文字顯示方式的 bidi 控制字元與行分隔字元
fn is_layout_char(c: char) -> bool {
    matches!(c, '\u{200E}' | '\u{200F}' | '\u{061C}' | '\u{2028}' | '\u{2029}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

/// 標題與每一行細節都可能含有呼叫端（AI／MCP）或檔案內容提供的文字，一律變成單行：
/// 換行等控制字元換成空白、bidi 控制字元換成「?」，避免插入看起來像正式說明的假段落，或讓路徑反向顯示。
/// 說明文字（warning）是程式內的固定字串，不處理。
pub(crate) fn one_line(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_control() { ' ' } else if is_layout_char(c) { '?' } else { c })
        .take(400)
        .collect()
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
    body.push_str(&one_line(action));
    body.push_str("\n\n");
    for d in details {
        body.push_str(&one_line(d));
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_text_becomes_one_line() {
        assert_eq!(one_line("a\r\nb\tc"), "a  b c");
        assert_eq!(one_line("x\u{202E}gpj.exe"), "x?gpj.exe");
        assert_eq!(one_line("p\u{2066}q\u{2028}r"), "p?q?r");
        assert_eq!(one_line(&"字".repeat(500)).chars().count(), 400);
        assert_eq!(one_line(r"C:\Users\a\Downloads"), r"C:\Users\a\Downloads");
    }
}
