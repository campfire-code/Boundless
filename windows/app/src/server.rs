//! 主控端：截获本机键鼠，按切换状态机转发给已连接的被控端。移植自 Mac 版 ServerController.swift

use std::collections::HashSet;
use std::time::{Duration, Instant};

use boundless_core::arrangement::Arrangement;
use boundless_core::discovery::Advertiser;
use boundless_core::dpi::Layout;
use boundless_core::geometry::{Desktop, Edge, Point};
use boundless_core::keycodes;
use boundless_core::keymap;
use boundless_core::link::{Link, LinkEvent, Listener};
use boundless_core::message::{Channel, Message, Platform};
use boundless_core::server_switch::{Decision, InputEvent, Mode, ServerSwitch, SwitchEffect};
use boundless_core::{pairing, scroll, PROTOCOL_VERSION};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::app::{Ctx, WM_APP_CLIPBOARD};
use crate::log;
use crate::settings::Settings;
use crate::win::clipboard::Clipboard;
use crate::win::hooks::{self, Raw};
use crate::win::{displays, inject, system};

pub struct ServerController {
    logic: ServerSwitch,
    layout: Layout,
    input: InputTranslator,
    clipboard: Clipboard,
    listener: Option<Listener>,
    advertiser: Option<Advertiser>,
    pending: Vec<Link>,
    link: Option<Link>,
    link_wired: bool,
    peer_name: Option<String>,
    last_error: Option<String>,
    hooks_ok: bool,
    ctx: Ctx,
}

impl ServerController {
    pub fn new(ctx: Ctx, settings: &mut Settings) -> Self {
        let layout = displays::layout();
        let mut s = ServerController {
            logic: ServerSwitch::new(layout.desktop(), None),
            layout,
            input: InputTranslator::new(),
            clipboard: Clipboard::new(ctx.hwnd, true),
            listener: None,
            advertiser: None,
            pending: Vec::new(),
            link: None,
            link_wired: false,
            peer_name: None,
            last_error: None,
            hooks_ok: false,
            ctx,
        };
        s.rebuild_arrangement(settings);
        s
    }

    pub fn start(&mut self, settings: &mut Settings) {
        self.hooks_ok = hooks::install(Box::new(crate::app::on_raw_input));
        if !self.hooks_ok {
            log!("主控端：安装键鼠钩子失败");
        }
        self.start_listener(settings);
    }

    pub fn stop(&mut self) {
        let d = self.logic.force_local();
        self.apply(d);
        if let Some(link) = &self.link {
            link.send(&Message::ReleaseAll);
            // 给 ReleaseAll 一点时间发出去
            std::thread::sleep(Duration::from_millis(50));
            link.cancel();
        }
        self.pending.iter().for_each(Link::cancel);
        self.listener = None;
        self.advertiser = None;
        hooks::uninstall();
        system::restore_cursors();
    }

    fn start_listener(&mut self, settings: &mut Settings) {
        let psk = pairing::preshared_key(&settings.server_code());
        match Listener::bind(&self.ctx.rt, psk, Duration::from_secs(8), self.ctx.sink.clone()) {
            Ok(listener) => {
                match Advertiser::start(&self.ctx.name, listener.port()) {
                    Ok(a) => {
                        self.advertiser = Some(a);
                        self.last_error = None;
                    }
                    Err(e) => self.last_error = Some(format!("局域网广播失败：{e}")),
                }
                log!("主控端：监听端口 {}", listener.port());
                self.listener = Some(listener);
            }
            Err(e) => self.last_error = Some(format!("监听失败：{e}")),
        }
    }

    /// 配对码变更后重启监听，旧连接全部断开
    pub fn restart_listener(&mut self, settings: &mut Settings) {
        if let Some(link) = self.link.take() {
            link.cancel();
            let d = self.logic.set_connected(false);
            self.apply(d);
        }
        self.pending.drain(..).for_each(|l| l.cancel());
        self.listener = None;
        self.advertiser = None;
        self.start_listener(settings);
    }

    pub fn status_text(&self) -> String {
        if !self.hooks_ok {
            return "无法截获键鼠（钩子安装失败），请重启无界".into();
        }
        if let Some(e) = &self.last_error {
            return e.clone();
        }
        let Some(_) = &self.link else { return "等待被控端连接…".into() };
        let name = self.peer_name.as_deref().unwrap_or("被控端");
        let path = if self.link_wired { "有线" } else { "Wi-Fi" };
        if self.logic.mode() == Mode::Remote {
            format!("正在控制 {name} · {path}")
        } else {
            format!("已连接 {name} · {path}")
        }
    }

    pub fn desktop(&self) -> &Desktop {
        &self.logic.desktop
    }

    pub fn arrangement(&self) -> Option<&Arrangement> {
        self.logic.arrangement.as_ref()
    }

    /// 切换快捷键说明。Mac 的 ⌃⌥⌘ 在 Windows 键盘上是 Win+Alt+Ctrl
    pub fn hotkey_text(&self) -> Option<String> {
        let side = self.logic.arrangement.as_ref()?.side(&self.logic.desktop);
        Some(format!("快捷键：Win+Alt+Ctrl+{} 过去，Win+Alt+Ctrl+{} 回来", arrow(side), arrow(side.opposite())))
    }

    // MARK: 屏幕排列

    pub fn set_arrangement_origin(&mut self, origin: Point, settings: &mut Settings) {
        settings.set_arrangement_origin(Some(origin));
        self.rebuild_arrangement(settings);
    }

    pub fn reset_arrangement(&mut self, settings: &mut Settings) {
        settings.set_arrangement_origin(None);
        self.rebuild_arrangement(settings);
    }

    /// 由保存的位置和被控端屏幕布局重建排列，并重新吸附到当前主控端屏幕上
    fn rebuild_arrangement(&mut self, settings: &Settings) {
        let displays = settings.client_displays();
        self.logic.arrangement = if displays.is_empty() {
            None
        } else if let Some(origin) = settings.arrangement_origin() {
            Some(Arrangement::new(displays, origin).snapped(&self.logic.desktop, 40.0))
        } else {
            Some(Arrangement::default_placement(displays, &self.logic.desktop))
        };
        crate::ui::arrangement::refresh();
    }

    pub fn displays_changed(&mut self, settings: &Settings) {
        self.layout = displays::layout();
        self.logic.desktop = self.layout.desktop();
        self.rebuild_arrangement(settings);
    }

    // MARK: 输入

    /// 钩子回调：返回 false 表示吞掉这个事件
    pub fn on_raw(&mut self, raw: Raw) -> bool {
        let remote = self.logic.mode() == Mode::Remote;
        match self.input.translate(raw, &self.layout, &self.logic.desktop) {
            Translated::Event(e) => {
                let d = self.logic.handle(&e);
                let pass = d.pass_locally;
                self.apply(d);
                pass
            }
            // 不转发的键：远程模式下吞掉（免得本机也收到），本机模式照常
            Translated::Ignore => !remote,
            Translated::Pass => true,
        }
    }

    fn apply(&mut self, d: Decision) {
        if let Some(link) = &self.link {
            for m in &d.messages {
                link.send(m);
            }
        }
        if d.effect != SwitchEffect::None {
            crate::app::refresh_tray_later(self.ctx.hwnd);
        }
        match d.effect {
            SwitchEffect::None => {}
            SwitchEffect::EnterRemote => {
                // 光标停在屏幕边上的话，再往外推时钩子读到的位置可能被截住、位移变 0；
                // 挪到主屏中央（反正已隐藏），四个方向都有余量
                let entered_at = system::cursor_pos();
                let center = self.layout.to_physical(self.logic.desktop.main().map_or(Point::ZERO, |m| Point::new(m.mid_x(), m.mid_y())));
                system::set_cursor_pos(center);
                self.input.entered_at = Some(entered_at);
                self.input.anchor = Some(Point::new(center.x.round(), center.y.round()));
                system::hide_cursors();
                // 用 Win+Alt+Ctrl+方向键切过去时，最后松开 Win 键会弹出开始菜单，补一个空按键压住
                if self.input.holds_windows_key() {
                    inject::tap_unassigned_key();
                }
                // 读剪贴板（可能要把大图转成 PNG）放到钩子回调之外做，免得钩子超时被系统摘掉
                unsafe { PostMessageW(self.ctx.hwnd, WM_APP_CLIPBOARD, 0, 0) };
            }
            SwitchEffect::ReturnLocal { warp_to } => {
                self.input.anchor = None;
                // 没给落点（快捷键切回、断线）时回到当初离开的位置
                let target = warp_to.map(|p| self.layout.to_physical(p)).or(self.input.entered_at.take());
                if let Some(phys) = target {
                    system::set_cursor_pos(phys);
                    self.input.last = Some(Point::new(phys.x.round(), phys.y.round()));
                }
                // 刚切回来时不补推边位移，免得落点贴边又被立刻弹回被控端
                self.input.settle_until = Some(Instant::now() + Duration::from_millis(300));
                system::restore_cursors();
            }
        }
    }

    /// 进入被控端后把本机剪贴板带过去
    pub fn send_clipboard(&mut self, settings: &Settings) {
        if !settings.clipboard_sync || self.logic.mode() != Mode::Remote {
            return;
        }
        if let (Some(link), Some(items)) = (&self.link, self.clipboard.snapshot_if_changed()) {
            link.send(&Message::Clipboard(items));
        }
    }

    // MARK: 网络

    pub fn on_link(&mut self, id: u64, event: LinkEvent, settings: &mut Settings) {
        match event {
            LinkEvent::Accepted(l) => self.pending.push(l),
            LinkEvent::Ready => {
                // 等对方的 hello 报明用途
                if let Some(l) = self.pending.iter().find(|l| l.id() == id) {
                    l.send(&Message::Hello {
                        version: PROTOCOL_VERSION,
                        name: self.ctx.name.clone(),
                        channel: Channel::Control,
                        platform: Platform::Windows,
                    });
                }
            }
            LinkEvent::Message(m) => {
                if let Some(i) = self.pending.iter().position(|l| l.id() == id) {
                    if let Message::Hello { version, name, channel, .. } = m {
                        let l = self.pending.remove(i);
                        self.identify(l, version, name, channel, settings);
                    }
                } else if self.link.as_ref().is_some_and(|l| l.id() == id) {
                    self.receive(m, settings);
                }
            }
            LinkEvent::Closed(error) => {
                self.pending.retain(|l| l.id() != id);
                if self.link.as_ref().is_some_and(|l| l.id() == id) {
                    log!("主控端：被控端断开 {}", error.unwrap_or_default());
                    self.link = None;
                    self.peer_name = None;
                    let d = self.logic.set_connected(false);
                    self.apply(d);
                }
            }
        }
    }

    fn identify(&mut self, l: Link, version: u16, name: String, channel: Channel, settings: &mut Settings) {
        if version != PROTOCOL_VERSION {
            self.last_error = Some(format!("{name} 的无界版本不一致，请两台装同一版本"));
            l.cancel();
            return;
        }
        // Windows 主控端没有虚拟副屏，不会有视频通道
        if channel != Channel::Control {
            l.cancel();
            return;
        }
        // 只保留一个被控端，新连接顶替旧连接
        if let Some(old) = self.link.take() {
            old.cancel();
            let d = self.logic.set_connected(false);
            self.apply(d);
        }
        log!("主控端：被控端 {name} 已连接");
        self.link_wired = l.addrs().is_some_and(|(local, _)| system::is_wired_local_ip(local.ip()));
        self.link = Some(l);
        self.peer_name = Some(name.clone());
        settings.client_name = Some(name);
        settings.save();
        self.last_error = None;
        let d = self.logic.set_connected(true);
        self.apply(d);
    }

    fn receive(&mut self, m: Message, settings: &mut Settings) {
        match m {
            Message::Layout { displays } => {
                settings.set_client_displays(&displays);
                self.rebuild_arrangement(settings);
            }
            Message::EdgePush { x, y } => {
                let d = self.logic.client_pushed(Point::new(x, y));
                self.apply(d);
            }
            Message::Clipboard(items) if settings.clipboard_sync => self.clipboard.apply(&items),
            _ => {}
        }
    }
}

fn arrow(edge: Edge) -> &'static str {
    match edge {
        Edge::Left => "←",
        Edge::Right => "→",
        Edge::Top => "↑",
        Edge::Bottom => "↓",
    }
}

// MARK: 钩子事件 → 状态机输入

enum Translated {
    Event(InputEvent),
    /// 不转发的键（AltGr 附带的假 Ctrl、Mac 上没有对应的键等）
    Ignore,
    /// 与切换无关的事件，交给本机
    Pass,
}

struct InputTranslator {
    /// 上一次光标位置（物理像素），本机模式下用来算位移
    last: Option<Point>,
    /// 远程模式下光标停留的位置（物理像素）；事件全被吞掉，光标不会动，位移 = 钩子报的位置 - 这里
    anchor: Option<Point>,
    /// 进入远程模式前光标所在的位置，没指定落点地切回时放回这里
    entered_at: Option<Point>,
    /// 这个时间之前不补推边位移
    settle_until: Option<Instant>,
    held: HashSet<u16>,
    caps_down: bool,
    last_click: Option<(u8, u32, Point)>,
    click_counts: [i32; 5],
    wheel_lines: u32,
    double_click: (u32, i32, i32),
}

impl InputTranslator {
    fn new() -> Self {
        InputTranslator {
            last: None,
            anchor: None,
            entered_at: None,
            settle_until: None,
            held: HashSet::new(),
            caps_down: false,
            last_click: None,
            click_counts: [1; 5],
            wheel_lines: system::wheel_lines(),
            double_click: system::double_click_metrics(),
        }
    }

    /// 是否按着 Win 键（对应 Mac 的 Control）
    fn holds_windows_key(&self) -> bool {
        self.held.contains(&59) || self.held.contains(&62)
    }

    fn translate(&mut self, raw: Raw, layout: &Layout, desktop: &Desktop) -> Translated {
        match raw {
            Raw::Key { msg, vk, scan, extended } => self.key(msg, vk, scan, extended),
            Raw::Mouse { msg, pt, data, time } => {
                let p = Point::new(pt.x as f64, pt.y as f64);
                match msg {
                    WM_MOUSEMOVE => Translated::Event(self.mouse_move(p, layout, desktop)),
                    WM_LBUTTONDOWN | WM_LBUTTONUP => self.button(0, msg == WM_LBUTTONDOWN, p, time),
                    WM_RBUTTONDOWN | WM_RBUTTONUP => self.button(1, msg == WM_RBUTTONDOWN, p, time),
                    WM_MBUTTONDOWN | WM_MBUTTONUP => self.button(2, msg == WM_MBUTTONDOWN, p, time),
                    WM_XBUTTONDOWN | WM_XBUTTONUP => {
                        let b = if (data >> 16) as u16 == 2 { 4 } else { 3 };
                        self.button(b, msg == WM_XBUTTONDOWN, p, time)
                    }
                    WM_MOUSEWHEEL => {
                        let v = (data >> 16) as u16 as i16 as i32;
                        Translated::Event(InputEvent::Scroll(scroll::from_windows(v, 0, self.wheel_lines)))
                    }
                    WM_MOUSEHWHEEL => {
                        let h = (data >> 16) as u16 as i16 as i32;
                        Translated::Event(InputEvent::Scroll(scroll::from_windows(0, h, self.wheel_lines)))
                    }
                    _ => Translated::Pass,
                }
            }
        }
    }

    fn mouse_move(&mut self, p: Point, layout: &Layout, desktop: &Desktop) -> InputEvent {
        if let Some(anchor) = self.anchor {
            let s = layout.scale_at_physical(anchor);
            return InputEvent::MouseMove {
                location: layout.to_logical(anchor),
                dx: (p.x - anchor.x) / s,
                dy: (p.y - anchor.y) / s,
            };
        }
        let last = self.last.unwrap_or(p);
        self.last = Some(p);
        let location = layout.to_logical(p);
        let s = layout.scale_at_physical(p);
        let (mut dx, mut dy) = ((p.x - last.x) / s, (p.y - last.y) / s);
        // 光标顶在屏幕边上继续推时，系统可能把位置截在边上，位移变成 0：按所在的边补一个往外的位移
        let settling = self.settle_until.is_some_and(|t| Instant::now() < t);
        if dx == 0.0 && dy == 0.0 && !settling {
            for (edge, sx, sy) in [(Edge::Right, 1.0, 0.0), (Edge::Left, -1.0, 0.0), (Edge::Bottom, 0.0, 1.0), (Edge::Top, 0.0, -1.0)] {
                if desktop.is_at_edge(location, edge) {
                    (dx, dy) = (sx, sy);
                    break;
                }
            }
        }
        InputEvent::MouseMove { location, dx, dy }
    }

    /// macOS 靠 clickCount 识别双击，这里按 Windows 的双击设置自己数
    fn button(&mut self, button: u8, down: bool, p: Point, time: u32) -> Translated {
        let i = button as usize;
        if down {
            let (ms, cx, cy) = self.double_click;
            let count = match self.last_click {
                Some((b, t, q)) if b == button
                    && time.wrapping_sub(t) <= ms
                    && (p.x - q.x).abs() <= cx as f64 / 2.0
                    && (p.y - q.y).abs() <= cy as f64 / 2.0 => self.click_counts[i] + 1,
                _ => 1,
            };
            self.click_counts[i] = count;
            self.last_click = Some((button, time, p));
        }
        Translated::Event(InputEvent::MouseButton { button, down, click_count: self.click_counts[i] })
    }

    fn key(&mut self, msg: u32, vk: u32, scan: u32, extended: bool) -> Translated {
        let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        // AltGr 会附带一个扫描码为 0x21D 的假左 Ctrl，转发出去会变成 ⌘
        if scan & 0x200 != 0 {
            return Translated::Ignore;
        }
        let vk = vk as u16;
        if let Some(data1) = keymap::windows_to_media(vk, down, false) {
            return Translated::Event(InputEvent::SystemKey { data1 });
        }
        let full = (scan as u16 & 0xFF) | if extended { keymap::EXTENDED } else { 0 };
        let Some(code) = keymap::windows_to_mac(vk, full) else { return Translated::Ignore };
        if code == keycodes::CAPS_LOCK {
            // 每按一次切换一次：只在按下时发，与 Mac 版一致（对端收到后还原成一次完整按键）
            if down && !self.caps_down {
                self.caps_down = true;
                return Translated::Event(InputEvent::Key { code, down: true, autorepeat: false, flags: 0 });
            }
            if !down {
                self.caps_down = false;
            }
            return Translated::Ignore;
        }
        let autorepeat = down && self.held.contains(&code);
        if down {
            self.held.insert(code);
        } else {
            self.held.remove(&code);
        }
        Translated::Event(InputEvent::Key { code, down, autorepeat, flags: keycodes::flags_for_held(&self.held) })
    }
}

#[cfg(test)]
mod tests {
    use boundless_core::dpi::Monitor;
    use boundless_core::geometry::Rect;
    use windows_sys::Win32::Foundation::POINT;

    use super::*;

    fn key(t: &mut InputTranslator, msg: u32, vk: u32, scan: u32, extended: bool) -> Translated {
        t.translate(Raw::Key { msg, vk, scan, extended }, &Layout::default(), &Desktop::default())
    }

    fn event(t: Translated) -> InputEvent {
        match t {
            Translated::Event(e) => e,
            _ => panic!("应得到事件"),
        }
    }

    #[test]
    fn keys_track_autorepeat_and_modifier_flags() {
        let mut t = InputTranslator::new();
        assert_eq!(event(key(&mut t, WM_KEYDOWN, 0xA2, 0x1D, false)), InputEvent::Key { code: 55, down: true, autorepeat: false, flags: keycodes::flags_for_held(&HashSet::from([55])) });
        assert_eq!(event(key(&mut t, WM_KEYDOWN, 'C' as u32, 0x2E, false)), InputEvent::Key { code: 8, down: true, autorepeat: false, flags: keycodes::flags_for_held(&HashSet::from([55, 8])) });
        assert!(matches!(event(key(&mut t, WM_KEYDOWN, 'C' as u32, 0x2E, false)), InputEvent::Key { code: 8, autorepeat: true, .. }), "再次按下是自动重复");
        assert!(matches!(event(key(&mut t, WM_KEYUP, 'C' as u32, 0x2E, false)), InputEvent::Key { code: 8, down: false, autorepeat: false, .. }));
        assert!(matches!(event(key(&mut t, WM_KEYDOWN, 0x25, 0x4B, true)), InputEvent::Key { code: 123, .. }), "扩展扫描码 → 方向键");
    }

    #[test]
    fn caps_lock_altgr_and_media_keys() {
        let mut t = InputTranslator::new();
        assert!(matches!(event(key(&mut t, WM_KEYDOWN, 0x14, 0x3A, false)), InputEvent::Key { code: 57, down: true, .. }));
        assert!(matches!(key(&mut t, WM_KEYDOWN, 0x14, 0x3A, false), Translated::Ignore), "按住不放不重复切换");
        assert!(matches!(key(&mut t, WM_KEYUP, 0x14, 0x3A, false), Translated::Ignore));
        assert!(matches!(key(&mut t, WM_KEYDOWN, 0xA2, 0x21D, false), Translated::Ignore), "AltGr 附带的假 Ctrl 不转发");
        assert!(matches!(event(key(&mut t, WM_KEYDOWN, 0xAF, 0x30, true)), InputEvent::SystemKey { .. }), "音量键走媒体键");
    }

    fn mouse(t: &mut InputTranslator, msg: u32, x: i32, y: i32, time: u32, layout: &Layout) -> InputEvent {
        let desktop = layout.desktop();
        event(t.translate(Raw::Mouse { msg, pt: POINT { x, y }, data: 0, time }, layout, &desktop))
    }

    #[test]
    fn clicks_are_counted_for_double_click() {
        let mut t = InputTranslator::new();
        let l = Layout::default();
        assert!(matches!(mouse(&mut t, WM_LBUTTONDOWN, 10, 10, 1000, &l), InputEvent::MouseButton { click_count: 1, .. }));
        assert!(matches!(mouse(&mut t, WM_LBUTTONUP, 10, 10, 1050, &l), InputEvent::MouseButton { click_count: 1, down: false, .. }));
        assert!(matches!(mouse(&mut t, WM_LBUTTONDOWN, 11, 10, 1150, &l), InputEvent::MouseButton { click_count: 2, .. }));
        assert!(matches!(mouse(&mut t, WM_LBUTTONUP, 11, 10, 1200, &l), InputEvent::MouseButton { click_count: 2, down: false, .. }));
        assert!(matches!(mouse(&mut t, WM_LBUTTONDOWN, 11, 10, 9000, &l), InputEvent::MouseButton { click_count: 1, .. }), "隔太久重新数");
    }

    #[test]
    fn moves_use_logical_points_and_push_at_clipped_edge() {
        let mut t = InputTranslator::new();
        let l = Layout::new(&[Monitor { physical: Rect::new(0.0, 0.0, 2880.0, 1800.0), scale: 1.5 }]);
        mouse(&mut t, WM_MOUSEMOVE, 2870, 900, 0, &l);
        assert_eq!(mouse(&mut t, WM_MOUSEMOVE, 2879, 903, 0, &l), InputEvent::MouseMove { location: Point::new(2879.0 / 1.5, 602.0), dx: 6.0, dy: 2.0 });
        // 光标被截在右边缘、位置不变：补一个往右的位移
        assert!(matches!(mouse(&mut t, WM_MOUSEMOVE, 2879, 903, 0, &l), InputEvent::MouseMove { dx, .. } if dx == 1.0));
        // 远程模式：位移相对停留点
        t.anchor = Some(Point::new(1440.0, 900.0));
        assert!(matches!(mouse(&mut t, WM_MOUSEMOVE, 1443, 894, 0, &l), InputEvent::MouseMove { dx, dy, .. } if dx == 2.0 && dy == -4.0));
    }
}
