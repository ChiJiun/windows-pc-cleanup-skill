// release 版不要多開一個主控台視窗（不能拿掉）
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // pc-cleanup.exe --mcp：以 stdio MCP server 模式執行，不開視窗
    if std::env::args().skip(1).any(|a| a == "--mcp") {
        pc_cleanup_lib::run_mcp();
    } else {
        pc_cleanup_lib::run();
    }
}
