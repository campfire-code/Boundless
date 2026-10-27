//! 被控端：发现并连接主控端，把收到的键鼠注入本机。移植自 Mac 版 ClientController.swift（不含虚拟副屏）

use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use boundless_core::client_cursor::ClientCursor;
use boundless_core::discovery::{Browser, FoundService};
use boundless_core::link::{self, Link, LinkEvent};
use boundless_core::message::{Channel, Message, Platform};
use boundless_core::{pairing, PROTOCOL_VERSION};

use crate::app::{AppEvent, Ctx};
use crate::log;
use crate::settings::Settings;
use crate::win::clipboard::Clipboard;
use crate::win::inject::Injector;
use crate::win::{displays, system};

pub struct ClientController {
    browser: Option<Browser>,
    services: HashMap<String, FoundService>,
    link: Option<Link>,
    link_ready: bool,
    link_wired: bool,
    link_target: Option<String>,
    peer_name: Option<String>,
    last_error: Option<String>,
    cursor: ClientCursor,
    injector: Injector,
    clipboard: Clipboard,
    retry_at: Option<Instant>,
    /// 有线连不上时，这个时间之前不再试有线
    wired_retry_after: Instant,
    attempting_wired: bool,
    /// 主动断开换有线，不算错误
    upgrading: bool,
    last_wired_check: Instant,
    cached_key: Option<(String, [u8; 32])>,
    ctx: Ctx,
}

impl ClientController {
    pub fn new(ctx: Ctx) -> Self {
        let layout = displays::layout();
        ClientController {
            browser: None,
            services: HashMap::new(),
            link: None,
            link_ready: false,
            link_wired: false,
            link_target: None,
            peer_name: None,
            last_error: None,
            cursor: ClientCursor::new(layout.desktop()),
            injector: Injector::new(layout),
            clipboard: Clipboard::new(ctx.hwnd, false),
            retry_at: None,
            wired_retry_after: Instant::now(),
            attempting_wired: false,
            upgrading: false,
            last_wired_check: Instant::now(),
            cached_key: None,
            ctx,
        }
    }

    pub fn start(&mut self) {
        let waker = self.ctx.waker.clone();
        match Browser::start(move |services| waker.send(AppEvent::Services(services))) {
            Ok(b) => self.browser = Some(b),
            Err(e) => self.last_error = Some(format!("局域网查找失败：{e}")),
        }
    }

    pub fn stop(&mut self) {
        self.browser = None;
        if let Some(link) = self.link.take() {
            link.cancel();
        }
        for a in self.cursor.release_all() {
            self.injector.perform(&a);
        }
    }

    pub fn status_text(&self, settings: &Settings) -> String {
        if settings.client_code().is_none() {
            return "请先输入主控端的配对码".into();
        }
        if self.link_ready {
            let name = self.peer_name.as_deref().or(self.link_target.as_deref()).unwrap_or("主控端");
            let path = if self.link_wired { "有线" } else { "Wi-Fi" };
            return if self.cursor.is_active() {
                format!("正在被 {name} 控制 · {path}")
            } else {
                format!("已连接 {name} · {path}")
            };
        }
        if let Some(t) = &self.link_target {
            return format!("正在连接 {t}…");
        }
        if let Some(e) = &self.last_error {
            return e.clone();
        }
        if self.services.is_empty() {
            return "正在查找主控端…".into();
        }
        match &settings.preferred_server {
            None => "发现多台主控端，请在菜单里选择".into(),
            Some(p) => format!("未找到 {p}"),
        }
    }

    /// 菜单里列出的主控端名称
    pub fn server_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.services.keys().cloned().collect();
        names.sort();
        names
    }

    pub fn on_services(&mut self, services: HashMap<String, FoundService>, settings: &Settings) {
        self.services = services;
        self.connect_if_needed(settings);
        self.upgrade_to_wired_if_possible(settings);
    }

    /// 配对码或目标主控端变了，断开重连
    pub fn reconnect(&mut self, settings: &Settings) {
        self.last_error = None;
        match &self.link {
            Some(link) => link.cancel(),
            None => self.connect_if_needed(settings),
        }
    }

    pub fn tick(&mut self, settings: &Settings) {
        let now = Instant::now();
        if self.retry_at.is_some_and(|t| now >= t) {
            self.retry_at = None;
            self.connect_if_needed(settings);
        }
        // 退到 Wi-Fi 后定时看看有线是否又能用了
        if now.duration_since(self.last_wired_check) >= Duration::from_secs(10) {
            self.last_wired_check = now;
            self.upgrade_to_wired_if_possible(settings);
        }
    }

    pub fn displays_changed(&mut self) {
        let layout = displays::layout();
        self.cursor.desktop = layout.desktop();
        self.injector.layout = layout;
        if self.link_ready {
            if let Some(link) = &self.link {
                link.send(&Message::Layout { displays: self.cursor.desktop.displays.clone() });
            }
        }
    }

    fn target<'a>(&'a self, settings: &Settings) -> Option<(String, &'a FoundService)> {
        if let Some(p) = &settings.preferred_server {
            return self.services.get(p).map(|s| (p.clone(), s));
        }
        if self.services.len() == 1 {
            return self.services.iter().next().map(|(n, s)| (n.clone(), s));
        }
        None
    }

    fn preshared_key(&mut self, code: &str) -> [u8; 32] {
        if let Some((c, k)) = &self.cached_key {
            if c == code {
                return *k;
            }
        }
        let key = pairing::preshared_key(code);
        self.cached_key = Some((code.to_string(), key));
        key
    }

    fn connect_if_needed(&mut self, settings: &Settings) {
        if self.link.is_some() {
            return;
        }
        let Some(code) = settings.client_code() else { return };
        let Some((name, service)) = self.target(settings) else { return };
        // 能在有线网卡上找到主控端就只走有线（延迟低一两个数量级），3 秒连不上再退回全部地址
        let wired: Vec<_> = service.addrs.iter().filter(|a| a.interface.is_some_and(system::is_wired_interface)).map(|a| a.addr).collect();
        let use_wired = Instant::now() >= self.wired_retry_after && !wired.is_empty();
        let addrs = if use_wired { wired } else { service.socket_addrs() };
        self.retry_at = None;
        self.attempting_wired = use_wired;
        let key = self.preshared_key(&code);
        let timeout = Duration::from_secs(if use_wired { 3 } else { 8 });
        log!("被控端：连接 {name} {addrs:?}");
        self.link = Some(link::connect(&self.ctx.rt, addrs, key, timeout, self.ctx.sink.clone()));
        self.link_target = Some(name);
        self.link_ready = false;
    }

    /// 正走 Wi-Fi 而有线能用了：趁光标不在本机时断开重连到有线
    fn upgrade_to_wired_if_possible(&mut self, settings: &Settings) {
        if !self.link_ready || self.link_wired || self.cursor.is_active() || self.cursor.is_dragging() || self.upgrading {
            return;
        }
        if Instant::now() < self.wired_retry_after {
            return;
        }
        let has_wired = self
            .target(settings)
            .is_some_and(|(_, s)| s.addrs.iter().any(|a| a.interface.is_some_and(system::is_wired_interface)));
        if let (true, Some(link)) = (has_wired, &self.link) {
            log!("被控端：发现有线连接可用，切换到有线");
            self.upgrading = true;
            link.cancel();
        }
    }

    pub fn on_link(&mut self, id: u64, event: LinkEvent, settings: &Settings) {
        if self.link.as_ref().map(Link::id) != Some(id) {
            return;
        }
        match event {
            LinkEvent::Accepted(_) => {}
            LinkEvent::Ready => {
                self.link_ready = true;
                self.last_error = None;
                let link = self.link.as_ref().unwrap();
                self.link_wired = link.addrs().is_some_and(|(local, _)| system::is_wired_local_ip(local.ip()));
                log!("被控端：已连接，走{}", if self.link_wired { "有线" } else { " Wi-Fi" });
                link.send(&Message::Hello {
                    version: PROTOCOL_VERSION,
                    name: self.ctx.name.clone(),
                    channel: Channel::Control,
                    platform: Platform::Windows,
                });
                link.send(&Message::Layout { displays: self.cursor.desktop.displays.clone() });
            }
            LinkEvent::Message(m) => self.receive(m, settings),
            LinkEvent::Closed(error) => {
                log!("被控端：连接关闭（{}）{}", if self.link_ready { "曾连上" } else { "未连上" }, error.clone().unwrap_or_default());
                let target = self.link_target.clone().unwrap_or_else(|| "主控端".into());
                let quick = self.upgrading || (self.attempting_wired && !self.link_ready);
                if self.attempting_wired && !self.link_ready {
                    // 有线没连通，先用全部地址，30 秒后再试有线
                    self.wired_retry_after = Instant::now() + Duration::from_secs(30);
                } else if self.upgrading {
                } else if !self.link_ready {
                    self.last_error = Some(format!("连接 {target} 失败（配对码不对或网络不通），稍后重试"));
                } else if let Some(e) = error {
                    self.last_error = Some(format!("连接已断开：{e}"));
                }
                for a in self.cursor.release_all() {
                    self.injector.perform(&a);
                }
                self.link = None;
                self.link_target = None;
                self.link_ready = false;
                self.peer_name = None;
                self.upgrading = false;
                self.retry_at = Some(Instant::now() + Duration::from_millis(if quick { 100 } else { 2000 }));
            }
        }
    }

    fn send(&self, m: &Message) {
        if let Some(link) = &self.link {
            link.send(m);
        }
    }

    fn receive(&mut self, m: Message, settings: &Settings) {
        match m {
            Message::Hello { version, name, .. } => {
                if version == PROTOCOL_VERSION {
                    log!("被控端：主控端是 {name}");
                    self.peer_name = Some(name);
                } else {
                    self.last_error = Some(format!("{name} 的无界版本不一致，请两台装同一版本"));
                    if let Some(link) = &self.link {
                        link.cancel();
                    }
                }
            }
            Message::Clipboard(items) => {
                if settings.clipboard_sync {
                    self.clipboard.apply(&items);
                }
            }
            Message::ClockProbe { server_time } => {
                let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
                self.send(&Message::ClockReply { server_time, client_time: now });
            }
            // Windows 被控端不支持虚拟副屏：窗口列表回空，其余请求忽略
            Message::WindowListRequest => self.send(&Message::WindowList(Vec::new())),
            Message::VirtualDisplay { .. } | Message::MoveWindowToVirtual { .. } | Message::RecallWindows | Message::RequestKeyframe { .. } => {}
            m => {
                let was_active = self.cursor.is_active();
                if matches!(m, Message::MouseMove { .. }) {
                    self.cursor.sync_position(self.injector.layout.to_logical(system::cursor_pos()));
                }
                let (actions, replies) = self.cursor.handle(&m);
                for a in &actions {
                    self.injector.perform(a);
                }
                for r in &replies {
                    self.send(r);
                }
                // 控制权被收回（推回主控端或快捷键切回）时，把这边的剪贴板带回去
                if was_active && !self.cursor.is_active() {
                    if settings.clipboard_sync {
                        if let Some(items) = self.clipboard.snapshot_if_changed() {
                            self.send(&Message::Clipboard(items));
                        }
                    }
                    self.upgrade_to_wired_if_possible(settings);
                }
            }
        }
    }
}
