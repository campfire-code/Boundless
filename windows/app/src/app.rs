//! 程序主体：隐藏窗口 + 托盘 + 消息循环。所有状态都在界面线程上；网络事件经通道转过来。
//! 钩子回调、窗口过程都会访问 App，统一用 try_borrow_mut：借不到（重入）就放行。
//! 会进入模态循环的操作（弹菜单、对话框）一律在释放借用之后再调用，期间钩子照常工作

use std::cell::RefCell;
use std::collections::HashMap;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{mpsc, Arc, Mutex};

use boundless_core::arrangement::Arrangement;
use boundless_core::discovery::FoundService;
use boundless_core::geometry::{Desktop, Point};
use boundless_core::link::{LinkEvent, Sink};
use boundless_core::pairing;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows_sys::Win32::UI::Shell::{NINF_KEY, NIN_SELECT};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::client::ClientController;
use crate::log;
use crate::server::ServerController;
use crate::settings::{Role, Settings};
use crate::ui::tray::{self, Item, Tray};
use crate::ui::{arrangement, dialog};
use crate::win::hooks::Raw;
use crate::win::{clipboard, system, wide};

pub const WM_APP_WAKE: u32 = WM_APP + 1;
pub const WM_APP_TRAY: u32 = WM_APP + 2;
pub const WM_APP_CLIPBOARD: u32 = WM_APP + 3;
pub const WM_APP_REFRESH: u32 = WM_APP + 4;
const WM_APP_ASK_ROLE: u32 = WM_APP + 5;
const WM_APP_ASK_CODE: u32 = WM_APP + 6;
const TIMER_TICK: usize = 1;
const NIN_KEYSELECT: u32 = NIN_SELECT | NINF_KEY;

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

pub enum AppEvent {
    Link(u64, LinkEvent),
    Services(HashMap<String, FoundService>),
}

/// 网络线程 → 界面线程：放进通道，再发一条消息唤醒
pub struct Waker {
    tx: Mutex<mpsc::Sender<AppEvent>>,
    hwnd: usize,
}

impl Waker {
    pub fn send(&self, event: AppEvent) {
        if self.tx.lock().unwrap().send(event).is_ok() {
            unsafe { PostMessageW(self.hwnd as HWND, WM_APP_WAKE, 0, 0) };
        }
    }
}

/// 控制器需要的公共环境
#[derive(Clone)]
pub struct Ctx {
    pub hwnd: HWND,
    pub rt: tokio::runtime::Handle,
    pub sink: Sink,
    pub waker: Arc<Waker>,
    /// 本机名称，显示在对端的菜单和排列窗口里
    pub name: String,
}

enum Controller {
    None,
    Server(ServerController),
    Client(ClientController),
}

struct App {
    ctx: Ctx,
    _rt: tokio::runtime::Runtime,
    rx: mpsc::Receiver<AppEvent>,
    settings: Settings,
    role: Controller,
    tray: Tray,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|a| a.try_borrow_mut().ok().and_then(|mut g| g.as_mut().map(f)))
}

pub fn run() {
    let dir = system::data_dir();
    log::init(&dir);
    log!("无界 {} 启动", env!("CARGO_PKG_VERSION"));
    unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    if !system::acquire_single_instance() {
        dialog::info("无界", "无界已经在运行了，请在任务栏右下角的托盘里找到它。");
        return;
    }
    // 上次若在远程模式下异常退出，光标可能还是透明的
    system::restore_cursors();
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        system::restore_cursors();
        log!("程序崩溃：{info}");
        default_hook(info);
    }));

    let hwnd = create_hidden_window();
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("创建网络线程失败");
    let (tx, rx) = mpsc::channel();
    let waker = Arc::new(Waker { tx: Mutex::new(tx), hwnd: hwnd as usize });
    let sink_waker = waker.clone();
    let sink: Sink = Arc::new(move |id, event| sink_waker.send(AppEvent::Link(id, event)));
    let ctx = Ctx { hwnd, rt: rt.handle().clone(), sink, waker, name: system::computer_name() };

    let settings = Settings::load(&dir);
    let tray = Tray::new(hwnd, WM_APP_TRAY);
    tray.add("无界");
    let ask_role = settings.role.is_none();
    APP.with(|a| *a.borrow_mut() = Some(App { ctx, _rt: rt, rx, settings, role: Controller::None, tray }));
    with_app(|a| a.start_role());

    unsafe {
        SetTimer(hwnd, TIMER_TICK, 200, None);
        if ask_role {
            PostMessageW(hwnd, WM_APP_ASK_ROLE, 0, 0);
        }
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    with_app(|a| a.shutdown());
    APP.with(|a| a.borrow_mut().take());
    log!("无界退出");
}

fn create_hidden_window() -> HWND {
    unsafe {
        let hinst = GetModuleHandleW(null());
        let class = wide("BoundlessHidden");
        let mut wc: WNDCLASSEXW = std::mem::zeroed();
        wc.cbSize = std::mem::size_of::<WNDCLASSEXW>() as u32;
        wc.lpfnWndProc = Some(wnd_proc);
        wc.hInstance = hinst;
        wc.lpszClassName = class.as_ptr();
        RegisterClassExW(&wc);
        TASKBAR_CREATED.store(RegisterWindowMessageW(wide("TaskbarCreated").as_ptr()), Ordering::Relaxed);
        // 普通的顶层窗口（从不显示），这样才收得到 WM_DISPLAYCHANGE 等广播
        CreateWindowExW(
            WS_EX_TOOLWINDOW, class.as_ptr(), wide("无界").as_ptr(), WS_POPUP,
            0, 0, 0, 0, null_mut(), null_mut(), hinst, null(),
        )
    }
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_APP_WAKE => {
            with_app(|a| a.drain());
        }
        WM_APP_TRAY => {
            let event = (lparam & 0xFFFF) as u32;
            if event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT {
                show_menu(hwnd);
            }
        }
        WM_APP_CLIPBOARD => {
            with_app(|a| {
                if let Controller::Server(s) = &mut a.role {
                    s.send_clipboard(&a.settings);
                }
            });
        }
        WM_APP_REFRESH => {
            with_app(|a| a.refresh_tray());
        }
        WM_APP_ASK_ROLE => ask_role(),
        WM_APP_ASK_CODE => run_action(Action::EnterCode),
        WM_TIMER => {
            with_app(|a| a.tick());
        }
        WM_DISPLAYCHANGE => {
            with_app(|a| a.displays_changed());
        }
        WM_ENDSESSION if wparam != 0 => {
            with_app(|a| a.shutdown());
        }
        m if m != 0 && m == TASKBAR_CREATED.load(Ordering::Relaxed) => {
            // 资源管理器重启后托盘图标会消失，要重新加
            with_app(|a| a.tray.add(&a.tip()));
        }
        _ => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    0
}

/// 钩子回调入口
pub fn on_raw_input(raw: Raw) -> bool {
    with_app(|a| match &mut a.role {
        Controller::Server(s) => s.on_raw(raw),
        _ => true,
    })
    .unwrap_or(true)
}

/// 状态变化后刷新托盘提示（异步，避免在钩子回调里做多余的事）
pub fn refresh_tray_later(hwnd: HWND) {
    unsafe { PostMessageW(hwnd, WM_APP_REFRESH, 0, 0) };
}

// MARK: 排列窗口的数据接口

pub struct Snapshot {
    pub desktop: Desktop,
    pub arrangement: Option<Arrangement>,
    pub client_name: String,
}

pub fn arrangement_snapshot() -> Option<Snapshot> {
    with_app(|a| match &a.role {
        Controller::Server(s) => Some(Snapshot {
            desktop: s.desktop().clone(),
            arrangement: s.arrangement().cloned(),
            client_name: a.settings.client_name.clone().unwrap_or_else(|| "被控端".into()),
        }),
        _ => None,
    })
    .flatten()
}

pub fn arrangement_moved(origin: Point) {
    with_app(|a| {
        if let Controller::Server(s) = &mut a.role {
            s.set_arrangement_origin(origin, &mut a.settings);
        }
    });
}

pub fn arrangement_reset() {
    with_app(|a| {
        if let Controller::Server(s) = &mut a.role {
            s.reset_arrangement(&mut a.settings);
        }
    });
}

impl App {
    fn start_role(&mut self) {
        self.role = match self.settings.role {
            Some(Role::Server) => {
                let mut s = ServerController::new(self.ctx.clone(), &mut self.settings);
                s.start(&mut self.settings);
                Controller::Server(s)
            }
            Some(Role::Client) => {
                let mut c = ClientController::new(self.ctx.clone());
                c.start();
                Controller::Client(c)
            }
            None => Controller::None,
        };
        log!("角色：{:?}", self.settings.role);
        self.refresh_tray();
    }

    fn stop_role(&mut self) {
        match std::mem::replace(&mut self.role, Controller::None) {
            Controller::Server(mut s) => s.stop(),
            Controller::Client(mut c) => c.stop(),
            Controller::None => {}
        }
    }

    fn set_role(&mut self, role: Role) {
        if self.settings.role == Some(role) {
            return;
        }
        self.stop_role();
        self.settings.role = Some(role);
        self.settings.save();
        self.start_role();
        if role == Role::Client && self.settings.client_code().is_none() {
            unsafe { PostMessageW(self.ctx.hwnd, WM_APP_ASK_CODE, 0, 0) };
        }
    }

    fn shutdown(&mut self) {
        self.stop_role();
        self.tray.remove();
        system::restore_cursors();
    }

    fn drain(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                AppEvent::Link(id, e) => match &mut self.role {
                    Controller::Server(s) => s.on_link(id, e, &mut self.settings),
                    Controller::Client(c) => c.on_link(id, e, &self.settings),
                    Controller::None => {
                        if let LinkEvent::Accepted(l) = e {
                            l.cancel();
                        }
                    }
                },
                AppEvent::Services(services) => {
                    if let Controller::Client(c) = &mut self.role {
                        c.on_services(services, &self.settings);
                    }
                }
            }
        }
        self.refresh_tray();
    }

    fn tick(&mut self) {
        if let Controller::Client(c) = &mut self.role {
            c.tick(&self.settings);
        }
    }

    fn displays_changed(&mut self) {
        match &mut self.role {
            Controller::Server(s) => s.displays_changed(&self.settings),
            Controller::Client(c) => c.displays_changed(),
            Controller::None => {}
        }
    }

    fn status_text(&self) -> String {
        match &self.role {
            Controller::Server(s) => s.status_text(),
            Controller::Client(c) => c.status_text(&self.settings),
            Controller::None => "请在菜单里选择这台电脑的角色".into(),
        }
    }

    fn tip(&self) -> String {
        format!("无界 · {}", self.status_text())
    }

    fn refresh_tray(&self) {
        self.tray.set_tip(&self.tip());
    }

    fn build_menu(&mut self) -> (Vec<Item>, Vec<Action>) {
        let mut actions: Vec<Action> = Vec::new();
        let mut act = |a: Action| {
            actions.push(a);
            actions.len() - 1
        };
        let mut items = vec![Item::Info(self.status_text()), Item::Separator];
        match &self.role {
            Controller::Server(s) => {
                let code = self.settings.server_code();
                items.push(Item::action(format!("配对码：{code}（点击复制）"), act(Action::CopyCode(code))));
                items.push(Item::action("屏幕排列…", act(Action::ShowArrangement)));
                items.push(Item::action("重新生成配对码…", act(Action::RegenerateCode)));
                items.push(Item::Info(s.hotkey_text().unwrap_or_else(|| "被控端连上后即可排列屏幕、使用快捷键".into())));
            }
            Controller::Client(c) => {
                let preferred = self.settings.preferred_server.clone();
                let mut servers = vec![Item::check("自动（只发现一台时）", act(Action::ChooseServer(None)), preferred.is_none())];
                let mut names = c.server_names();
                if let Some(p) = &preferred {
                    if !names.contains(p) {
                        names.push(p.clone());
                    }
                }
                for n in names {
                    let checked = preferred.as_deref() == Some(n.as_str());
                    servers.push(Item::check(n.clone(), act(Action::ChooseServer(Some(n))), checked));
                }
                items.push(Item::Submenu { title: "连接到哪台主控端".into(), items: servers, enabled: true });
                items.push(Item::action("输入配对码…", act(Action::EnterCode)));
            }
            Controller::None => {}
        }
        items.push(Item::Separator);
        let role = self.settings.role;
        items.push(Item::Submenu {
            title: "这台电脑的角色".into(),
            items: vec![
                Item::check("主控端（共享本机键鼠）", act(Action::SetRole(Role::Server)), role == Some(Role::Server)),
                Item::check("被控端（被另一台控制）", act(Action::SetRole(Role::Client)), role == Some(Role::Client)),
            ],
            enabled: true,
        });
        items.push(Item::check("同步剪贴板", act(Action::ToggleClipboard), self.settings.clipboard_sync));
        items.push(Item::check("开机自动启动", act(Action::ToggleAutostart), system::launch_at_login()));
        if !system::is_elevated() {
            items.push(Item::action("以管理员身份重新启动（控制管理员窗口时需要）", act(Action::RestartElevated)));
        }
        items.push(Item::action("打开日志", act(Action::OpenLog)));
        items.push(Item::Separator);
        items.push(Item::action("退出无界", act(Action::Quit)));
        (items, actions)
    }
}

enum Action {
    CopyCode(String),
    RegenerateCode,
    ShowArrangement,
    ChooseServer(Option<String>),
    EnterCode,
    ToggleClipboard,
    ToggleAutostart,
    RestartElevated,
    SetRole(Role),
    OpenLog,
    Quit,
}

fn show_menu(hwnd: HWND) {
    let Some((items, mut actions)) = with_app(|a| a.build_menu()) else { return };
    if let Some(i) = tray::popup(hwnd, &items) {
        if i < actions.len() {
            run_action(actions.swap_remove(i));
        }
    }
}

fn ask_role() {
    let choice = dialog::ask_choice(
        "欢迎使用无界",
        "这台电脑要怎么用？\n主控端：用这台的键盘鼠标控制另一台电脑\n被控端：被另一台电脑的键盘鼠标控制",
        &["主控端", "被控端"],
    );
    let role = match choice {
        Some(0) => Role::Server,
        Some(1) => Role::Client,
        _ => return,
    };
    with_app(|a| a.set_role(role));
}

/// 执行菜单动作。需要弹窗的先弹窗（不持有借用），再进 App 改状态
fn run_action(action: Action) {
    match action {
        Action::CopyCode(code) => {
            with_app(|a| clipboard::set_text(a.ctx.hwnd, &code));
        }
        Action::RegenerateCode => {
            if dialog::confirm("重新生成配对码", "旧配对码会立即失效，被控端需要输入新的配对码才能连接。继续吗？") {
                with_app(|a| {
                    a.settings.regenerate_server_code();
                    if let Controller::Server(s) = &mut a.role {
                        s.restart_listener(&mut a.settings);
                    }
                });
            }
        }
        Action::ShowArrangement => arrangement::show(),
        Action::ChooseServer(name) => {
            with_app(|a| {
                a.settings.preferred_server = name;
                a.settings.save();
                if let Controller::Client(c) = &mut a.role {
                    c.reconnect(&a.settings);
                }
            });
        }
        Action::EnterCode => {
            let initial = with_app(|a| a.settings.client_code().unwrap_or_default()).unwrap_or_default();
            while let Some(text) = dialog::ask_text(
                "输入配对码",
                "在主控端的无界菜单里查看配对码（Mac 在菜单栏，Windows 在托盘）：",
                &initial,
            ) {
                match pairing::normalize(&text) {
                    Some(code) => {
                        with_app(|a| {
                            a.settings.set_client_code(Some(code));
                            if let Controller::Client(c) = &mut a.role {
                                c.reconnect(&a.settings);
                            }
                        });
                        break;
                    }
                    None => dialog::info("配对码不正确", "配对码是 12 位字母和数字，形如 ABCD-EFGH-JKMN（不区分大小写）。"),
                }
            }
        }
        Action::ToggleClipboard => {
            with_app(|a| {
                a.settings.clipboard_sync = !a.settings.clipboard_sync;
                a.settings.save();
            });
        }
        Action::ToggleAutostart => system::set_launch_at_login(!system::launch_at_login()),
        Action::RestartElevated => {
            if system::restart_elevated() {
                with_app(|a| a.shutdown());
                unsafe { PostQuitMessage(0) };
            }
        }
        Action::SetRole(role) => {
            with_app(|a| a.set_role(role));
        }
        Action::OpenLog => system::open(&system::data_dir().join("boundless.log").to_string_lossy()),
        Action::Quit => {
            with_app(|a| a.shutdown());
            unsafe { PostQuitMessage(0) };
        }
    }
    with_app(|a| a.refresh_tray());
}
