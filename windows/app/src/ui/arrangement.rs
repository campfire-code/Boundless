//! 主控端的「屏幕排列」窗口：把被控端的屏幕拖到它相对本机屏幕的实际位置，松手自动贴边

use std::cell::RefCell;
use std::ptr::{null, null_mut};

use boundless_core::geometry::{Point, Rect};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use super::scaled;
use crate::app;
use crate::win::wide;

const CLASS: &str = "BoundlessArrangement";

#[derive(Default)]
struct State {
    hwnd: usize,
    /// 拖动起点（窗口像素）与当时的排列原点
    drag: Option<(i32, i32, Point)>,
    /// 拖动中的临时原点
    temp_origin: Option<Point>,
    /// 上次绘制时的换算：窗口像素 = offset + 逻辑点 × scale
    scale: f64,
    offset: (f64, f64),
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    r as u32 | (g as u32) << 8 | (b as u32) << 16
}

pub fn show() {
    let existing = STATE.with(|s| s.borrow().hwnd);
    unsafe {
        if existing != 0 {
            ShowWindow(existing as HWND, SW_SHOWNORMAL);
            SetForegroundWindow(existing as HWND);
            return;
        }
        let hinst = GetModuleHandleW(null());
        let class = wide(CLASS);
        let mut wc: WNDCLASSEXW = std::mem::zeroed();
        wc.cbSize = std::mem::size_of::<WNDCLASSEXW>() as u32;
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = Some(proc);
        wc.hInstance = hinst;
        wc.hIcon = LoadIconW(hinst, 1 as _);
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.lpszClassName = class.as_ptr();
        RegisterClassExW(&wc);
        let hwnd = CreateWindowExW(
            0, class.as_ptr(), wide("无界 · 屏幕排列").as_ptr(), WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT, scaled(760), scaled(500), null_mut(), null_mut(), hinst, null(),
        );
        if hwnd.is_null() {
            return;
        }
        STATE.with(|s| s.borrow_mut().hwnd = hwnd as usize);
        ShowWindow(hwnd, SW_SHOWNORMAL);
        SetForegroundWindow(hwnd);
    }
}

/// 排列或屏幕变化后重画
pub fn refresh() {
    let hwnd = STATE.with(|s| s.try_borrow().map(|s| s.hwnd).unwrap_or(0));
    if hwnd != 0 {
        unsafe { InvalidateRect(hwnd as HWND, null(), 0) };
    }
}

fn lparam_point(lparam: LPARAM) -> (i32, i32) {
    ((lparam & 0xFFFF) as u16 as i16 as i32, ((lparam >> 16) & 0xFFFF) as u16 as i16 as i32)
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PAINT => {
            paint(hwnd);
            0
        }
        WM_ERASEBKGND => 1,
        WM_LBUTTONDOWN => {
            let (x, y) = lparam_point(lparam);
            if let Some(snap) = app::arrangement_snapshot() {
                if let Some(a) = snap.arrangement {
                    let hit = STATE.with(|s| {
                        let s = s.borrow();
                        let p = Point::new((x as f64 - s.offset.0) / s.scale, (y as f64 - s.offset.1) / s.scale);
                        s.scale > 0.0 && a.placed_displays().iter().any(|d| d.contains(p))
                    });
                    if hit {
                        SetCapture(hwnd);
                        STATE.with(|s| s.borrow_mut().drag = Some((x, y, a.origin)));
                    }
                }
            }
            0
        }
        WM_MOUSEMOVE => {
            let (x, y) = lparam_point(lparam);
            let moved = STATE.with(|s| {
                let mut s = s.borrow_mut();
                let Some((sx, sy, origin)) = s.drag else { return false };
                s.temp_origin = Some(Point::new(origin.x + (x - sx) as f64 / s.scale, origin.y + (y - sy) as f64 / s.scale));
                true
            });
            if moved {
                InvalidateRect(hwnd, null(), 0);
            }
            0
        }
        WM_LBUTTONUP => {
            let dropped = STATE.with(|s| {
                let mut s = s.borrow_mut();
                s.drag.take();
                s.temp_origin.take()
            });
            ReleaseCapture();
            if let Some(origin) = dropped {
                app::arrangement_moved(origin);
            }
            InvalidateRect(hwnd, null(), 0);
            0
        }
        WM_RBUTTONUP => {
            app::arrangement_reset();
            0
        }
        WM_DESTROY => {
            STATE.with(|s| *s.borrow_mut() = State::default());
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

unsafe fn paint(hwnd: HWND) {
    let mut ps: PAINTSTRUCT = std::mem::zeroed();
    let hdc = BeginPaint(hwnd, &mut ps);
    let mut rc: RECT = std::mem::zeroed();
    GetClientRect(hwnd, &mut rc);
    let (w, h) = (rc.right - rc.left, rc.bottom - rc.top);
    // 双缓冲，拖动时不闪
    let mem = CreateCompatibleDC(hdc);
    let bmp = CreateCompatibleBitmap(hdc, w.max(1), h.max(1));
    let old_bmp = SelectObject(mem, bmp as HGDIOBJ);
    let font = CreateFontW(
        -scaled(14), 0, 0, 0, FW_NORMAL as i32, 0, 0, 0, DEFAULT_CHARSET as u32, OUT_DEFAULT_PRECIS as u32,
        CLIP_DEFAULT_PRECIS as u32, CLEARTYPE_QUALITY as u32, (DEFAULT_PITCH | FF_DONTCARE) as u32,
        wide("Microsoft YaHei UI").as_ptr(),
    );
    let old_font = SelectObject(mem, font as HGDIOBJ);
    SetBkMode(mem, TRANSPARENT as i32);

    let fill = |r: &RECT, color: COLORREF| {
        let b = CreateSolidBrush(color);
        FillRect(mem, r, b);
        DeleteObject(b as HGDIOBJ);
    };
    let frame = |r: &RECT, color: COLORREF| {
        let b = CreateSolidBrush(color);
        FrameRect(mem, r, b);
        DeleteObject(b as HGDIOBJ);
    };
    let text = |r: &RECT, s: &str, color: COLORREF, flags: DRAW_TEXT_FORMAT| {
        let mut r = *r;
        SetTextColor(mem, color);
        let ws: Vec<u16> = s.encode_utf16().collect();
        DrawTextW(mem, ws.as_ptr(), ws.len() as i32, &mut r, flags);
    };
    let center = DT_CENTER | DT_VCENTER | DT_SINGLELINE;

    fill(&rc, rgb(245, 245, 247));
    let hint_h = scaled(44);
    let hint = RECT { left: 0, top: h - hint_h, right: w, bottom: h };

    match app::arrangement_snapshot() {
        Some(snap) if snap.arrangement.is_some() => {
            let temp = STATE.with(|s| s.borrow().temp_origin);
            let mut placed = snap.arrangement.unwrap();
            if let Some(o) = temp {
                placed.origin = o;
            }
            let bounds = snap.desktop.bounds().union(&placed.placed_bounds());
            let margin = scaled(36) as f64;
            let (aw, ah) = (w as f64 - 2.0 * margin, h as f64 - 2.0 * margin - hint_h as f64);
            let scale = (aw / bounds.w).min(ah / bounds.h).max(0.01);
            let ox = margin + (aw - bounds.w * scale) / 2.0 - bounds.x * scale;
            let oy = margin + (ah - bounds.h * scale) / 2.0 - bounds.y * scale;
            STATE.with(|s| {
                let mut s = s.borrow_mut();
                s.scale = scale;
                s.offset = (ox, oy);
            });
            let px = |r: &Rect| RECT {
                left: (ox + r.x * scale).round() as i32,
                top: (oy + r.y * scale).round() as i32,
                right: (ox + r.max_x() * scale).round() as i32,
                bottom: (oy + r.max_y() * scale).round() as i32,
            };
            for (i, d) in snap.desktop.displays.iter().enumerate() {
                let r = px(d);
                fill(&r, rgb(208, 210, 214));
                frame(&r, rgb(120, 124, 130));
                text(&r, &format!("本机 {}", i + 1), rgb(40, 40, 40), center);
            }
            for d in placed.placed_displays() {
                let r = px(&d);
                fill(&r, rgb(142, 124, 195));
                frame(&r, rgb(90, 70, 150));
                text(&r, &snap.client_name, rgb(255, 255, 255), center);
            }
            // 拖动中不画贴合边：松手吸附后才是最终位置
            if temp.is_none() {
                let t = scaled(2);
                for e in placed.shared_edges(&snap.desktop) {
                    let a = px(&Rect::new(e.from.x, e.from.y, 0.0, 0.0));
                    let b = px(&Rect::new(e.to.x, e.to.y, 0.0, 0.0));
                    let r = RECT { left: a.left.min(b.left) - t, top: a.top.min(b.top) - t, right: a.left.max(b.left) + t, bottom: a.top.max(b.top) + t };
                    fill(&r, rgb(0, 188, 212));
                }
            }
            text(&hint, "拖动紫色方块到它相对本机屏幕的实际位置，松手自动贴边；青色边是光标能穿过的地方。右键恢复默认位置", rgb(90, 90, 90), center);
        }
        _ => text(&rc, "被控端连上后即可排列屏幕", rgb(90, 90, 90), center),
    }

    BitBlt(hdc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
    SelectObject(mem, old_font);
    SelectObject(mem, old_bmp);
    DeleteObject(font as HGDIOBJ);
    DeleteObject(bmp as HGDIOBJ);
    DeleteDC(mem);
    EndPaint(hwnd, &ps);
}
