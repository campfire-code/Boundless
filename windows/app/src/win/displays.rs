//! 枚举显示器，换算成逻辑点布局（见 boundless_core::dpi）

use std::ptr::{null, null_mut};

use boundless_core::dpi::{Layout, Monitor};
use boundless_core::geometry::Rect;
use windows_sys::Win32::Foundation::{BOOL, LPARAM, RECT};
use windows_sys::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO};
use windows_sys::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};

pub fn layout() -> Layout {
    unsafe extern "system" fn each(monitor: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let list = &mut *(data as *mut Vec<Monitor>);
        let mut info: MONITORINFO = std::mem::zeroed();
        info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
        if GetMonitorInfoW(monitor, &mut info) != 0 {
            let (mut dpi_x, mut dpi_y) = (96u32, 96u32);
            if GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) != 0 || dpi_x == 0 {
                dpi_x = 96;
            }
            let r = info.rcMonitor;
            list.push(Monitor {
                physical: Rect::new(r.left as f64, r.top as f64, (r.right - r.left) as f64, (r.bottom - r.top) as f64),
                scale: dpi_x as f64 / 96.0,
            });
        }
        1
    }
    let mut list: Vec<Monitor> = Vec::new();
    unsafe { EnumDisplayMonitors(null_mut(), null(), Some(each), &mut list as *mut _ as LPARAM) };
    Layout::new(&list)
}
