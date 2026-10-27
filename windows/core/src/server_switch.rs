//! 主控端的切换状态机：决定每个输入事件留在本机还是转发给被控端。
//! 按键和鼠标按键按「在哪边按下就在哪边松开」路由，避免跨机切换时卡键。
//! 移植自 Swift 版 ServerSwitch.swift，去掉了 Windows 主控端用不到的虚拟副屏部分

use std::collections::{BTreeSet, HashSet};

use crate::arrangement::Arrangement;
use crate::geometry::{Desktop, Edge, Point};
use crate::keycodes;
use crate::message::{Message, ScrollEvent};

/// 主控端从输入钩子拿到的事件（坐标是逻辑点，按键已换算成 macOS 键码）
#[derive(Debug, Clone, PartialEq)]
pub enum InputEvent {
    MouseMove { location: Point, dx: f64, dy: f64 },
    MouseButton { button: u8, down: bool, click_count: i32 },
    Scroll(ScrollEvent),
    Key { code: u16, down: bool, autorepeat: bool, flags: u64 },
    SystemKey { data1: i32 },
}

#[derive(Debug, Clone, PartialEq)]
pub enum SwitchEffect {
    None,
    /// 锁住并隐藏本机光标
    EnterRemote,
    /// 恢复本机光标，可选移动到指定位置
    ReturnLocal { warp_to: Option<Point> },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Decision {
    /// 事件是否继续交给本机处理
    pub pass_locally: bool,
    pub messages: Vec<Message>,
    pub effect: SwitchEffect,
}

impl Decision {
    pub fn pass() -> Decision {
        Decision { pass_locally: true, messages: vec![], effect: SwitchEffect::None }
    }
    pub fn swallow() -> Decision {
        Decision { pass_locally: false, messages: vec![], effect: SwitchEffect::None }
    }
    fn forward(m: Message) -> Decision {
        Decision { pass_locally: false, messages: vec![m], effect: SwitchEffect::None }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Local,
    Remote,
}

pub struct ServerSwitch {
    pub desktop: Desktop,
    /// 被控端屏幕的摆放；被控端上报屏幕布局之前为 None，此时不会通过边缘切换
    pub arrangement: Option<Arrangement>,
    mode: Mode,
    connected: bool,
    last_location: Point,
    local_keys: HashSet<u16>,
    remote_keys: HashSet<u16>,
    hotkey_keys: HashSet<u16>,
    local_buttons: BTreeSet<u8>,
    remote_buttons: BTreeSet<u8>,
}

impl ServerSwitch {
    pub fn new(desktop: Desktop, arrangement: Option<Arrangement>) -> Self {
        ServerSwitch {
            desktop,
            arrangement,
            mode: Mode::Local,
            connected: false,
            last_location: Point::ZERO,
            local_keys: HashSet::new(),
            remote_keys: HashSet::new(),
            hotkey_keys: HashSet::new(),
            local_buttons: BTreeSet::new(),
            remote_buttons: BTreeSet::new(),
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    pub fn handle(&mut self, event: &InputEvent) -> Decision {
        match *event {
            InputEvent::MouseMove { location, dx, dy } => {
                if self.mode == Mode::Remote {
                    return Decision::forward(Message::MouseMove { dx, dy });
                }
                self.last_location = location;
                // 拖拽中（按住鼠标键）不切换；只有推进被控端屏幕所在的那段边才切换
                if self.local_buttons.is_empty() {
                    if let Some(target) = self.edge_target(location, dx, dy) {
                        return self.enter_remote(target);
                    }
                }
                Decision::pass()
            }
            InputEvent::MouseButton { button, down, click_count } => {
                let m = Message::MouseButton { button, down, click_count };
                if down {
                    if self.mode == Mode::Remote {
                        self.remote_buttons.insert(button);
                        return Decision::forward(m);
                    }
                    self.local_buttons.insert(button);
                    return Decision::pass();
                }
                if self.local_buttons.remove(&button) {
                    return Decision::pass();
                }
                if self.remote_buttons.remove(&button) {
                    return Decision::forward(m);
                }
                if self.mode == Mode::Remote {
                    Decision::forward(m)
                } else {
                    Decision::pass()
                }
            }
            InputEvent::Scroll(s) => {
                if self.mode == Mode::Remote {
                    Decision::forward(Message::Scroll(s))
                } else {
                    Decision::pass()
                }
            }
            InputEvent::SystemKey { data1 } => {
                if self.mode == Mode::Remote {
                    Decision::forward(Message::SystemKey { data1 })
                } else {
                    Decision::pass()
                }
            }
            InputEvent::Key { code, down, autorepeat, flags } => self.handle_key(code, down, autorepeat, flags),
        }
    }

    /// 被控端报告光标推出了它的桌面；推出去的点落在主控端屏幕上才收回控制权
    pub fn client_pushed(&mut self, client_point: Point) -> Decision {
        if self.mode != Mode::Remote {
            return Decision::pass();
        }
        let Some(arrangement) = &self.arrangement else { return Decision::pass() };
        let point = arrangement.to_server(client_point);
        if self.desktop.display_containing(point).is_none() {
            return Decision::pass();
        }
        self.return_local(Some(point), true)
    }

    pub fn set_connected(&mut self, value: bool) -> Decision {
        self.connected = value;
        if value {
            return Decision::pass();
        }
        // 断线后被控端会自行松开所有键，这边不再需要把松开事件转发过去
        self.remote_keys.clear();
        if self.mode != Mode::Remote {
            self.remote_buttons.clear();
            return Decision::pass();
        }
        let d = self.return_local(None, false);
        Decision { pass_locally: true, messages: vec![], effect: d.effect }
    }

    /// 退出程序等场景强制收回控制权
    pub fn force_local(&mut self) -> Decision {
        if self.mode != Mode::Remote {
            return Decision::pass();
        }
        self.return_local(None, true)
    }

    fn handle_key(&mut self, code: u16, down: bool, autorepeat: bool, flags: u64) -> Decision {
        let m = Message::Key { code, down, autorepeat };
        let forwarding = self.mode == Mode::Remote;
        // 大写锁定每按一次切换一次状态，没有成对的按下/松开，直接按当前模式路由
        if code == keycodes::CAPS_LOCK {
            return if forwarding { Decision::forward(m) } else { Decision::pass() };
        }

        if down {
            if self.hotkey_keys.contains(&code) {
                return Decision::swallow();
            }
            // 已按住的键的自动重复，跟随首次按下的那一侧
            if self.local_keys.contains(&code) {
                return Decision::pass();
            }
            if self.remote_keys.contains(&code) {
                return Decision::forward(m);
            }

            let side = self.arrangement.as_ref().map(|a| a.side(&self.desktop));
            if self.mode == Mode::Local && self.connected {
                if let (Some(arrangement), Some(side)) = (&self.arrangement, side) {
                    if keycodes::is_switch_hotkey(code, flags, side) {
                        self.hotkey_keys.insert(code);
                        let target = arrangement.nearest_client_point(self.last_location);
                        return self.enter_remote(target);
                    }
                }
            }
            if self.mode == Mode::Remote && is_return_hotkey(code, flags, side) {
                self.hotkey_keys.insert(code);
                return self.return_local(None, true);
            }
            if self.mode == Mode::Remote {
                self.remote_keys.insert(code);
                return Decision::forward(m);
            }
            self.local_keys.insert(code);
            return Decision::pass();
        }

        if self.hotkey_keys.remove(&code) {
            return Decision::swallow();
        }
        if self.local_keys.remove(&code) {
            return Decision::pass();
        }
        if self.remote_keys.remove(&code) {
            return Decision::forward(m);
        }
        if forwarding {
            Decision::forward(m)
        } else {
            Decision::pass()
        }
    }

    /// 光标推过通向被控端的那段边时，在被控端的落点
    fn edge_target(&self, location: Point, dx: f64, dy: f64) -> Option<Point> {
        if !self.connected {
            return None;
        }
        let arrangement = self.arrangement.as_ref()?;
        let beyond = self.desktop.point_beyond(location, dx, dy)?;
        arrangement.client_point_at_server(beyond)
    }

    fn enter_remote(&mut self, client_point: Point) -> Decision {
        self.mode = Mode::Remote;
        Decision {
            pass_locally: false,
            messages: vec![Message::Enter { x: client_point.x, y: client_point.y }],
            effect: SwitchEffect::EnterRemote,
        }
    }

    fn return_local(&mut self, warp_to: Option<Point>, notify_client: bool) -> Decision {
        self.mode = Mode::Local;
        let mut messages: Vec<Message> = std::mem::take(&mut self.remote_buttons)
            .into_iter()
            .map(|button| Message::MouseButton { button, down: false, click_count: 1 })
            .collect();
        if notify_client {
            messages.push(Message::Leave);
        }
        Decision { pass_locally: false, messages, effect: SwitchEffect::ReturnLocal { warp_to } }
    }
}

/// 远程模式下切回本机的快捷键：朝主控端方向；排列未知时任一方向都行，保证总能切回
fn is_return_hotkey(code: u16, flags: u64, side: Option<Edge>) -> bool {
    match side {
        Some(side) => keycodes::is_switch_hotkey(code, flags, side.opposite()),
        None => Edge::ALL.iter().any(|e| keycodes::is_switch_hotkey(code, flags, *e)),
    }
}
