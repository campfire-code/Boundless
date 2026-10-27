//! 切换机器时同步剪贴板：文本、RTF、HTML、图片。不同步文件，不同步密码管理器标记为不监视的内容

use boundless_core::clipdata::{self, UTI_HTML, UTI_PNG, UTI_RTF, UTI_TEXT, UTI_TIFF};
use boundless_core::message::ClipboardItem;
use windows_sys::Win32::Foundation::{GlobalFree, HANDLE, HWND};
use windows_sys::Win32::System::DataExchange::*;
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::Ole::{CF_DIB, CF_DIBV5, CF_UNICODETEXT};

use super::wide;

pub struct Clipboard {
    hwnd: HWND,
    synced: Option<u32>,
}

fn format(name: &str) -> u32 {
    unsafe { RegisterClipboardFormatW(wide(name).as_ptr()) }
}

/// 打开剪贴板；别的程序正占着时稍等重试
fn open(hwnd: HWND) -> bool {
    for _ in 0..10 {
        if unsafe { OpenClipboard(hwnd) } != 0 {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    false
}

unsafe fn read(format: u32) -> Option<Vec<u8>> {
    let h = GetClipboardData(format);
    if h.is_null() {
        return None;
    }
    let p = GlobalLock(h) as *const u8;
    if p.is_null() {
        return None;
    }
    let data = std::slice::from_raw_parts(p, GlobalSize(h)).to_vec();
    GlobalUnlock(h);
    Some(data)
}

unsafe fn write(format: u32, data: &[u8]) {
    let h = GlobalAlloc(GMEM_MOVEABLE, data.len().max(1));
    if h.is_null() {
        return;
    }
    let p = GlobalLock(h) as *mut u8;
    if p.is_null() {
        GlobalFree(h);
        return;
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), p, data.len());
    GlobalUnlock(h);
    // 设置成功后内存归系统所有，失败才需要自己释放
    if SetClipboardData(format, h as HANDLE).is_null() {
        GlobalFree(h);
    }
}

impl Clipboard {
    /// sync_initial：首次切换时是否同步启动前就已存在的剪贴板内容
    pub fn new(hwnd: HWND, sync_initial: bool) -> Self {
        let synced = if sync_initial { None } else { Some(unsafe { GetClipboardSequenceNumber() }) };
        Clipboard { hwnd, synced }
    }

    /// 自上次同步后本机剪贴板有变化才返回内容
    pub fn snapshot_if_changed(&mut self) -> Option<Vec<ClipboardItem>> {
        let seq = unsafe { GetClipboardSequenceNumber() };
        if self.synced == Some(seq) {
            return None;
        }
        self.synced = Some(seq);
        if !open(self.hwnd) {
            return None;
        }
        let items = unsafe { self.collect() };
        unsafe { CloseClipboard() };
        let total: usize = items.iter().map(|i| i.data.len()).sum();
        (!items.is_empty() && total <= clipdata::MAX_BYTES).then_some(items)
    }

    unsafe fn collect(&self) -> Vec<ClipboardItem> {
        // 密码管理器等用这两个格式标记「不要被剪贴板工具读取」
        for marker in ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"] {
            if IsClipboardFormatAvailable(format(marker)) != 0 {
                return Vec::new();
            }
        }
        let mut items = Vec::new();
        if let Some(data) = read(CF_UNICODETEXT as u32) {
            let units: Vec<u16> = data.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
            let text = super::from_wide(&units);
            items.push(ClipboardItem { kind: UTI_TEXT.into(), data: clipdata::text_from_windows(&text).into_bytes() });
        }
        if let Some(html) = read(format("HTML Format")).and_then(|d| clipdata::cf_html_to_html(&d)) {
            items.push(ClipboardItem { kind: UTI_HTML.into(), data: html.into_bytes() });
        }
        if let Some(mut rtf) = read(format("Rich Text Format")) {
            while rtf.last() == Some(&0) {
                rtf.pop();
            }
            items.push(ClipboardItem { kind: UTI_RTF.into(), data: rtf });
        }
        let png = read(format("PNG"))
            .or_else(|| read(CF_DIBV5 as u32).and_then(|d| clipdata::dib_to_png(&d)))
            .or_else(|| read(CF_DIB as u32).and_then(|d| clipdata::dib_to_png(&d)));
        if let Some(png) = png {
            items.push(ClipboardItem { kind: UTI_PNG.into(), data: png });
        }
        items
    }

    pub fn apply(&mut self, items: &[ClipboardItem]) {
        if items.is_empty() || !open(self.hwnd) {
            return;
        }
        unsafe {
            EmptyClipboard();
            let has_png = items.iter().any(|i| i.kind == UTI_PNG);
            for item in items {
                match item.kind.as_str() {
                    UTI_TEXT => {
                        let text = clipdata::text_to_windows(&String::from_utf8_lossy(&item.data));
                        let bytes: Vec<u8> = text.encode_utf16().chain(Some(0)).flat_map(u16::to_le_bytes).collect();
                        write(CF_UNICODETEXT as u32, &bytes);
                    }
                    UTI_HTML => {
                        let mut cf = clipdata::html_to_cf_html(&String::from_utf8_lossy(&item.data));
                        cf.push(0);
                        write(format("HTML Format"), &cf);
                    }
                    UTI_RTF => write(format("Rich Text Format"), &item.data),
                    UTI_PNG => {
                        write(format("PNG"), &item.data);
                        if let Some(dib) = clipdata::image_to_dib(&item.data) {
                            write(CF_DIB as u32, &dib);
                        }
                    }
                    UTI_TIFF if !has_png => {
                        if let Some(png) = clipdata::image_to_png(&item.data) {
                            write(format("PNG"), &png);
                        }
                        if let Some(dib) = clipdata::image_to_dib(&item.data) {
                            write(CF_DIB as u32, &dib);
                        }
                    }
                    _ => {}
                }
            }
            CloseClipboard();
            self.synced = Some(GetClipboardSequenceNumber());
        }
    }
}

/// 把一段文字放进剪贴板（菜单里「复制配对码」用）
pub fn set_text(hwnd: HWND, text: &str) {
    if !open(hwnd) {
        return;
    }
    unsafe {
        EmptyClipboard();
        let bytes: Vec<u8> = text.encode_utf16().chain(Some(0)).flat_map(u16::to_le_bytes).collect();
        write(CF_UNICODETEXT as u32, &bytes);
        CloseClipboard();
    }
}

#[cfg(test)]
mod tests {
    use std::ptr::{null, null_mut};

    use boundless_core::clipdata;
    use boundless_core::message::ClipboardItem;
    use windows_sys::Win32::UI::WindowsAndMessaging::{CreateWindowExW, DestroyWindow, HWND_MESSAGE};

    use super::*;

    /// 2×1 的 32 位 DIB（红、绿）转成 PNG，作为测试图片
    fn sample_png() -> Vec<u8> {
        let mut dib = Vec::new();
        for v in [40u32, 2, 1] {
            dib.extend_from_slice(&v.to_le_bytes());
        }
        dib.extend_from_slice(&1u16.to_le_bytes());
        dib.extend_from_slice(&32u16.to_le_bytes());
        dib.extend_from_slice(&[0; 24]);
        dib.extend_from_slice(&[0, 0, 255, 255, 0, 255, 0, 255]);
        clipdata::dib_to_png(&dib).unwrap()
    }

    #[test]
    fn round_trip_text_html_and_image() {
        let hwnd = unsafe { CreateWindowExW(0, wide("STATIC").as_ptr(), null(), 0, 0, 0, 0, 0, HWND_MESSAGE, null_mut(), null_mut(), null()) };
        assert!(!hwnd.is_null());
        let png = sample_png();
        let mut writer = Clipboard::new(hwnd, false);
        writer.apply(&[
            ClipboardItem { kind: UTI_TEXT.into(), data: "第一行\n第二行".as_bytes().to_vec() },
            ClipboardItem { kind: UTI_HTML.into(), data: "<b>粗体</b>".as_bytes().to_vec() },
            ClipboardItem { kind: UTI_PNG.into(), data: png.clone() },
        ]);
        assert!(writer.snapshot_if_changed().is_none(), "自己刚写进去的内容不算变化");

        let mut reader = Clipboard::new(hwnd, true);
        let items = reader.snapshot_if_changed().expect("应读到内容");
        let get = |kind: &str| items.iter().find(|i| i.kind == kind).map(|i| i.data.clone());
        assert_eq!(get(UTI_TEXT).unwrap(), "第一行\n第二行".as_bytes(), "换行在 Windows 上是 CRLF，读回来要还原成 LF");
        assert!(String::from_utf8(get(UTI_HTML).unwrap()).unwrap().contains("<b>粗体</b>"));
        assert_eq!(clipdata::image_to_dib(&get(UTI_PNG).unwrap()), clipdata::image_to_dib(&png));
        assert!(reader.snapshot_if_changed().is_none(), "没有变化时不重复同步");

        set_text(hwnd, "ABCD-EFGH-JKMN");
        let items = reader.snapshot_if_changed().unwrap();
        assert_eq!(items, vec![ClipboardItem { kind: UTI_TEXT.into(), data: b"ABCD-EFGH-JKMN".to_vec() }]);
        unsafe { DestroyWindow(hwnd) };
    }
}
