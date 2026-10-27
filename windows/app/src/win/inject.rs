//! 被控端：把注入动作变成 Windows 输入事件（SendInput）。
//! 注意：普通权限的进程无法向以管理员身份运行的窗口注入输入，需要的话从托盘菜单以管理员身份重启

use boundless_core::client_cursor::InjectAction;
use boundless_core::dpi::Layout;
use boundless_core::geometry::Point;
use boundless_core::keymap::{self, WinKey, EXTENDED};
use boundless_core::scroll::ToWindows;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, XBUTTON1, XBUTTON2, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

pub struct Injector {
    pub layout: Layout,
    scroll: ToWindows,
}

impl Injector {
    pub fn new(layout: Layout) -> Self {
        Injector { layout, scroll: ToWindows::default() }
    }

    pub fn perform(&mut self, action: &InjectAction) {
        match action {
            InjectAction::Warp(p) | InjectAction::Move { to: p, .. } => self.move_to(*p),
            InjectAction::Button { button, down, .. } => button_event(*button, *down),
            InjectAction::Scroll(s) => {
                let (v, h) = self.scroll.convert(s);
                if v != 0 {
                    send(&[mouse(0, 0, v as u32, MOUSEEVENTF_WHEEL)]);
                }
                if h != 0 {
                    send(&[mouse(0, 0, h as u32, MOUSEEVENTF_HWHEEL)]);
                }
            }
            InjectAction::Key { code, down, .. } => {
                if let Some(k) = keymap::mac_to_windows(*code) {
                    key_event(k, *down);
                }
            }
            InjectAction::SystemKey { data1 } => {
                if let Some((vk, down)) = keymap::media_to_windows(*data1) {
                    key_event(WinKey::Vk(vk), down);
                }
            }
        }
    }

    /// 绝对移动：逻辑点 → 物理像素 → 虚拟桌面上 0~65535 的归一化坐标
    fn move_to(&self, p: Point) {
        let phys = self.layout.to_physical(p);
        let (vx, vy, vw, vh) = unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN) as f64,
                GetSystemMetrics(SM_YVIRTUALSCREEN) as f64,
                GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2) as f64,
                GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2) as f64,
            )
        };
        let nx = ((phys.x - vx) * 65535.0 / (vw - 1.0)).round() as i32;
        let ny = ((phys.y - vy) * 65535.0 / (vh - 1.0)).round() as i32;
        send(&[mouse(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)]);
    }
}

fn button_event(button: u8, down: bool) {
    let (flags, data) = match (button, down) {
        (0, true) => (MOUSEEVENTF_LEFTDOWN, 0),
        (0, false) => (MOUSEEVENTF_LEFTUP, 0),
        (1, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
        (1, false) => (MOUSEEVENTF_RIGHTUP, 0),
        (2, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
        (2, false) => (MOUSEEVENTF_MIDDLEUP, 0),
        // macOS 的 3、4 号键是侧键（后退、前进）
        (3, d) => (if d { MOUSEEVENTF_XDOWN } else { MOUSEEVENTF_XUP }, XBUTTON1 as u32),
        (4, d) => (if d { MOUSEEVENTF_XDOWN } else { MOUSEEVENTF_XUP }, XBUTTON2 as u32),
        _ => return,
    };
    send(&[mouse(0, 0, data, flags)]);
}

fn key_event(key: WinKey, down: bool) {
    let up = if down { 0 } else { KEYEVENTF_KEYUP };
    let input = match key {
        WinKey::Scan(scan) => {
            let ext = if scan & EXTENDED != 0 { KEYEVENTF_EXTENDEDKEY } else { 0 };
            keyboard(0, scan & 0xFF, KEYEVENTF_SCANCODE | ext | up)
        }
        // 媒体键、音量键都是扩展键
        WinKey::Vk(vk) => keyboard(vk, 0, KEYEVENTF_EXTENDEDKEY | up),
    };
    send(&[input]);
}

/// 按一下未分配的虚拟键 0xE8：插在 Win 键按下和松开之间，开始菜单就不会弹出来
pub fn tap_unassigned_key() {
    send(&[keyboard(0xE8, 0, 0), keyboard(0xE8, 0, KEYEVENTF_KEYUP)]);
}

fn mouse(dx: i32, dy: i32, data: u32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

fn keyboard(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

fn send(inputs: &[INPUT]) {
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
}
