//! 简单的模态对话框：输入一行文字，或在几个按钮里选一个。
//! 会进入自己的消息循环（期间钩子和网络事件照常处理），调用时不要持有 App 的借用

use std::cell::RefCell;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use super::scaled;
use crate::win::{from_wide, wide};

const CLASS: &str = "BoundlessDialog";
const ID_EDIT: usize = 100;
/// 编辑框全选（Win32_UI_Controls 里的常量，只用这一个就不引入整个模块）
const EM_SETSEL: u32 = 0x00B1;
const ID_BUTTON0: usize = 200;

struct State {
    done: bool,
    choice: Option<usize>,
    text: String,
    edit: HWND,
}

thread_local! {
    static STATE: RefCell<State> = const { RefCell::new(State { done: false, choice: None, text: String::new(), edit: null_mut() }) };
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_COMMAND => {
            let id = wparam & 0xFFFF;
            // IsDialogMessage 把回车映射成 IDOK、Esc 映射成 IDCANCEL
            let choice = match id {
                x if x == IDOK as usize => Some(0),
                x if x == IDCANCEL as usize => None,
                x if x >= ID_BUTTON0 => Some(x - ID_BUTTON0),
                _ => return 0,
            };
            STATE.with(|s| {
                let mut s = s.borrow_mut();
                if !s.edit.is_null() {
                    let mut buf = [0u16; 256];
                    GetWindowTextW(s.edit, buf.as_mut_ptr(), buf.len() as i32);
                    s.text = from_wide(&buf);
                }
                s.choice = choice;
                s.done = true;
            });
            0
        }
        WM_CLOSE => {
            STATE.with(|s| {
                let mut s = s.borrow_mut();
                s.choice = None;
                s.done = true;
            });
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn font() -> HFONT {
    unsafe {
        CreateFontW(
            -scaled(15), 0, 0, 0, FW_NORMAL as i32, 0, 0, 0, DEFAULT_CHARSET as u32, OUT_DEFAULT_PRECIS as u32,
            CLIP_DEFAULT_PRECIS as u32, CLEARTYPE_QUALITY as u32, (DEFAULT_PITCH | FF_DONTCARE) as u32,
            wide("Microsoft YaHei UI").as_ptr(),
        )
    }
}

/// 显示对话框，返回 (按下的按钮序号, 输入框内容)；关闭或按 Esc 返回 None
fn run(title: &str, prompt: &str, initial: Option<&str>, buttons: &[&str]) -> Option<(usize, String)> {
    unsafe {
        let hinst = GetModuleHandleW(null());
        let class = wide(CLASS);
        let mut wc: WNDCLASSEXW = std::mem::zeroed();
        wc.cbSize = std::mem::size_of::<WNDCLASSEXW>() as u32;
        wc.lpfnWndProc = Some(proc);
        wc.hInstance = hinst;
        wc.hIcon = LoadIconW(hinst, 1 as _);
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.hbrBackground = (COLOR_WINDOW + 1) as usize as HBRUSH;
        wc.lpszClassName = class.as_ptr();
        RegisterClassExW(&wc); // 重复注册会失败，不影响

        let pad = scaled(16);
        let width = scaled(420);
        let label_h = scaled(22) * (prompt.lines().count().max(1) as i32) + scaled(8);
        let edit_h = if initial.is_some() { scaled(28) } else { 0 };
        let button_h = scaled(30);
        let client_h = pad + label_h + if edit_h > 0 { edit_h + scaled(12) } else { 0 } + button_h + pad;
        let style = WS_CAPTION | WS_SYSMENU | WS_POPUP;
        let mut rect = RECT { left: 0, top: 0, right: width, bottom: client_h };
        AdjustWindowRectEx(&mut rect, style, 0, WS_EX_DLGMODALFRAME);
        let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);
        let x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
        let y = (GetSystemMetrics(SM_CYSCREEN) - h) / 3;
        let hwnd = CreateWindowExW(
            WS_EX_DLGMODALFRAME | WS_EX_TOPMOST, class.as_ptr(), wide(title).as_ptr(), style,
            x, y, w, h, null_mut(), null_mut(), hinst, null(),
        );
        if hwnd.is_null() {
            return None;
        }
        let font = font();
        let child = |class: &str, text: &str, style: u32, x: i32, y: i32, w: i32, h: i32, id: usize| -> HWND {
            let c = CreateWindowExW(
                if class == "EDIT" { WS_EX_CLIENTEDGE } else { 0 }, wide(class).as_ptr(), wide(text).as_ptr(),
                WS_CHILD | WS_VISIBLE | style, x, y, w, h, hwnd, id as HMENU, hinst, null(),
            );
            SendMessageW(c, WM_SETFONT, font as WPARAM, 1);
            c
        };
        child("STATIC", prompt, 0, pad, pad, width - 2 * pad, label_h, 0);
        let mut y = pad + label_h;
        let edit = if let Some(initial) = initial {
            let e = child("EDIT", initial, WS_TABSTOP | ES_AUTOHSCROLL as u32, pad, y, width - 2 * pad, edit_h, ID_EDIT);
            y += edit_h + scaled(12);
            e
        } else {
            null_mut()
        };
        let bw = scaled(if buttons.len() > 2 { 112 } else { 96 });
        let gap = scaled(8);
        let mut bx = width - pad - (bw + gap) * buttons.len() as i32 + gap;
        for (i, b) in buttons.iter().enumerate() {
            let style = WS_TABSTOP | if i == 0 { BS_DEFPUSHBUTTON as u32 } else { BS_PUSHBUTTON as u32 };
            child("BUTTON", b, style, bx, y, bw, button_h, ID_BUTTON0 + i);
            bx += bw + gap;
        }

        STATE.with(|s| *s.borrow_mut() = State { done: false, choice: None, text: String::new(), edit });
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
        if !edit.is_null() {
            SetFocus(edit);
            SendMessageW(edit, EM_SETSEL, 0, -1);
        }
        let mut msg: MSG = std::mem::zeroed();
        while !STATE.with(|s| s.borrow().done) {
            if GetMessageW(&mut msg, null_mut(), 0, 0) <= 0 {
                // 收到 WM_QUIT：放回去让主循环退出
                PostQuitMessage(msg.wParam as i32);
                break;
            }
            if IsDialogMessageW(hwnd, &msg) == 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        EnableWindow(hwnd, 0);
        DestroyWindow(hwnd);
        DeleteObject(font as HGDIOBJ);
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            s.edit = null_mut();
            s.choice.map(|c| (c, std::mem::take(&mut s.text)))
        })
    }
}

/// 输入一行文字；取消返回 None
pub fn ask_text(title: &str, prompt: &str, initial: &str) -> Option<String> {
    match run(title, prompt, Some(initial), &["确定", "取消"]) {
        Some((0, text)) => Some(text),
        _ => None,
    }
}

/// 在几个按钮里选一个；关闭返回 None
pub fn ask_choice(title: &str, prompt: &str, buttons: &[&str]) -> Option<usize> {
    run(title, prompt, None, buttons).map(|(i, _)| i)
}

pub fn info(title: &str, text: &str) {
    unsafe { MessageBoxW(null_mut(), wide(text).as_ptr(), wide(title).as_ptr(), MB_OK | MB_ICONINFORMATION | MB_TOPMOST) };
}

pub fn confirm(title: &str, text: &str) -> bool {
    unsafe {
        MessageBoxW(null_mut(), wide(text).as_ptr(), wide(title).as_ptr(), MB_YESNO | MB_ICONQUESTION | MB_TOPMOST) == IDYES
    }
}
