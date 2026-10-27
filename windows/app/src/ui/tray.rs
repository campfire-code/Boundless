//! 托盘图标与右键菜单

use std::ptr::null;

use windows_sys::Win32::Foundation::{HWND, POINT};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Shell::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::win::{copy_wide, wide};

pub struct Tray {
    hwnd: HWND,
    icon: HICON,
    callback: u32,
}

impl Tray {
    pub fn new(hwnd: HWND, callback: u32) -> Self {
        // 资源里编号为 1 的图标，按托盘小图标尺寸加载才清晰
        let icon = unsafe {
            LoadImageW(GetModuleHandleW(null()), 1 as _, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR)
        } as HICON;
        Tray { hwnd, icon, callback }
    }

    fn data(&self, tip: &str) -> NOTIFYICONDATAW {
        let mut d: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
        d.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        d.hWnd = self.hwnd;
        d.uID = 1;
        d.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        d.uCallbackMessage = self.callback;
        d.hIcon = self.icon;
        copy_wide(&mut d.szTip, tip);
        d
    }

    /// 添加图标（资源管理器重启后也要重新调用）
    pub fn add(&self, tip: &str) {
        let mut d = self.data(tip);
        unsafe {
            Shell_NotifyIconW(NIM_ADD, &d);
            d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIconW(NIM_SETVERSION, &d);
        }
    }

    pub fn set_tip(&self, tip: &str) {
        let d = self.data(tip);
        unsafe { Shell_NotifyIconW(NIM_MODIFY, &d) };
    }

    pub fn remove(&self) {
        let d = self.data("");
        unsafe { Shell_NotifyIconW(NIM_DELETE, &d) };
    }
}

/// 菜单项；action 是调用方自己的动作编号
pub enum Item {
    Action { title: String, action: usize, checked: bool, enabled: bool },
    Info(String),
    Separator,
    Submenu { title: String, items: Vec<Item>, enabled: bool },
}

impl Item {
    pub fn action(title: impl Into<String>, action: usize) -> Item {
        Item::Action { title: title.into(), action, checked: false, enabled: true }
    }

    pub fn check(title: impl Into<String>, action: usize, checked: bool) -> Item {
        Item::Action { title: title.into(), action, checked, enabled: true }
    }
}

unsafe fn build(menu: HMENU, items: &[Item]) {
    for item in items {
        match item {
            Item::Action { title, action, checked, enabled } => {
                let mut flags = MF_STRING;
                if *checked {
                    flags |= MF_CHECKED;
                }
                if !*enabled {
                    flags |= MF_GRAYED;
                }
                AppendMenuW(menu, flags, action + 1, wide(title).as_ptr());
            }
            Item::Info(title) => {
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, wide(title).as_ptr());
            }
            Item::Separator => {
                AppendMenuW(menu, MF_SEPARATOR, 0, null());
            }
            Item::Submenu { title, items, enabled } => {
                let sub = CreatePopupMenu();
                build(sub, items);
                let flags = MF_POPUP | if *enabled { 0 } else { MF_GRAYED };
                AppendMenuW(menu, flags, sub as usize, wide(title).as_ptr());
            }
        }
    }
}

/// 在光标处弹出菜单，返回选中的动作编号。会进入模态循环，调用时不要持有 App 的借用
pub fn popup(hwnd: HWND, items: &[Item]) -> Option<usize> {
    unsafe {
        let menu = CreatePopupMenu();
        build(menu, items);
        let mut pt = POINT { x: 0, y: 0 };
        GetCursorPos(&mut pt);
        // 不先置前，点菜单外面时菜单不会消失
        SetForegroundWindow(hwnd);
        let id = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, null());
        DestroyMenu(menu);
        PostMessageW(hwnd, WM_NULL, 0, 0);
        (id > 0).then(|| id as usize - 1)
    }
}
