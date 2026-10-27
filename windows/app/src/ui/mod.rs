pub mod arrangement;
pub mod dialog;
pub mod tray;

use windows_sys::Win32::UI::HiDpi::GetDpiForSystem;

/// 按系统 DPI 缩放界面尺寸（程序是 Per-Monitor DPI 感知的，自己画的界面要自己放大）
pub fn scaled(v: i32) -> i32 {
    let dpi = unsafe { GetDpiForSystem() }.max(96);
    v * dpi as i32 / 96
}
