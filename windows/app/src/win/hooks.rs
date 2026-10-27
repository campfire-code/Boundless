//! 主控端：低级键盘、鼠标钩子。回调在安装钩子的线程（界面线程）的消息循环里调用，
//! handler 返回 false 的事件会被吞掉。回调必须很快返回，否则 Windows 会悄悄摘掉钩子

use std::cell::RefCell;
use std::ptr::null;

use windows_sys::Win32::Foundation::{LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

/// 钩子收到的原始事件
#[derive(Clone, Copy)]
pub enum Raw {
    /// msg 是 WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_MOUSEWHEEL 等；pt 为物理像素
    Mouse { msg: u32, pt: POINT, data: u32, time: u32 },
    /// msg 是 WM_KEYDOWN / WM_KEYUP / WM_SYSKEYDOWN / WM_SYSKEYUP
    Key { msg: u32, vk: u32, scan: u32, extended: bool },
}

type Handler = Box<dyn FnMut(Raw) -> bool>;

thread_local! {
    static HANDLER: RefCell<Option<Handler>> = RefCell::new(None);
    static HOOKS: RefCell<Option<(HHOOK, HHOOK)>> = const { RefCell::new(None) };
}

pub fn install(handler: Handler) -> bool {
    HANDLER.with(|h| *h.borrow_mut() = Some(handler));
    if HOOKS.with(|h| h.borrow().is_some()) {
        return true;
    }
    unsafe {
        let hinst = GetModuleHandleW(null());
        let kb = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_proc), hinst, 0);
        let ms = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), hinst, 0);
        if kb.is_null() || ms.is_null() {
            if !kb.is_null() {
                UnhookWindowsHookEx(kb);
            }
            if !ms.is_null() {
                UnhookWindowsHookEx(ms);
            }
            return false;
        }
        HOOKS.with(|h| *h.borrow_mut() = Some((kb, ms)));
    }
    true
}

pub fn uninstall() {
    if let Some((kb, ms)) = HOOKS.with(|h| h.borrow_mut().take()) {
        unsafe {
            UnhookWindowsHookEx(kb);
            UnhookWindowsHookEx(ms);
        }
    }
    HANDLER.with(|h| *h.borrow_mut() = None);
}

fn dispatch(raw: Raw) -> bool {
    // handler 正在运行时（理论上不会重入）直接放行
    HANDLER.with(|h| match h.try_borrow_mut() {
        Ok(mut guard) => guard.as_mut().is_none_or(|f| f(raw)),
        Err(_) => true,
    })
}

unsafe extern "system" fn keyboard_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lparam as *const KBDLLHOOKSTRUCT);
        // 别的程序注入的按键不转发，原样交给本机
        if k.flags & LLKHF_INJECTED == 0 {
            let raw = Raw::Key { msg: wparam as u32, vk: k.vkCode, scan: k.scanCode, extended: k.flags & LLKHF_EXTENDED != 0 };
            if !dispatch(raw) {
                return 1;
            }
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let m = &*(lparam as *const MSLLHOOKSTRUCT);
        if m.flags & LLMHF_INJECTED == 0 {
            let raw = Raw::Mouse { msg: wparam as u32, pt: m.pt, data: m.mouseData, time: m.time };
            if !dispatch(raw) {
                return 1;
            }
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}
