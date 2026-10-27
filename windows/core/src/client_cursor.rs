//! 被控端状态机：维护虚拟光标位置、按住的键，把收到的消息翻译成注入动作。移植自 Swift 版 ClientCursor.swift

use std::collections::{BTreeSet, HashSet};

use crate::geometry::{Desktop, Point};
use crate::keycodes;
use crate::message::{Message, ScrollEvent};

/// 被控端需要注入系统的动作（坐标是逻辑点，按键是 macOS 键码，由平台层换算）
#[derive(Debug, Clone, PartialEq)]
pub enum InjectAction {
    Warp(Point),
    Move { to: Point, dx: f64, dy: f64, drag_button: Option<u8> },
    Button { button: u8, down: bool, at: Point, click_count: i32 },
    Scroll(ScrollEvent),
    Key { code: u16, down: bool, autorepeat: bool, flags: u64 },
    SystemKey { data1: i32 },
}

#[derive(Default)]
pub struct ClientCursor {
    pub desktop: Desktop,
    active: bool,
    position: Point,
    held_keys: HashSet<u16>,
    held_buttons: BTreeSet<u8>,
    /// 最近注入过的光标位置。系统处理注入事件有延迟，读回的位置常是其中某一个
    recent_positions: Vec<Point>,
}

impl ClientCursor {
    pub fn new(desktop: Desktop) -> Self {
        ClientCursor { desktop, ..Default::default() }
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn position(&self) -> Point {
        self.position
    }

    pub fn modifier_flags(&self) -> u64 {
        keycodes::flags_for_held(&self.held_keys)
    }

    pub fn is_dragging(&self) -> bool {
        !self.held_buttons.is_empty()
    }

    /// 被控端本机鼠标也动过时，以系统实际光标位置为准；读回的只是还没追上的旧注入位置时忽略
    pub fn sync_position(&mut self, actual: Point) {
        let near = |p: &Point| actual.distance(*p) <= 2.0;
        if near(&self.position) || self.recent_positions.iter().any(near) {
            return;
        }
        self.position = actual;
        self.recent_positions.clear();
    }

    fn moved(&mut self, p: Point) {
        self.position = p;
        self.recent_positions.push(p);
        if self.recent_positions.len() > 32 {
            let extra = self.recent_positions.len() - 32;
            self.recent_positions.drain(..extra);
        }
    }

    fn drag_button(&self) -> Option<u8> {
        self.held_buttons.iter().next().copied()
    }

    /// 返回 (注入动作, 回给主控端的消息)
    pub fn handle(&mut self, message: &Message) -> (Vec<InjectAction>, Vec<Message>) {
        match *message {
            Message::Enter { x, y } => {
                self.active = true;
                let p = self.desktop.clamp(Point::new(x, y));
                self.moved(p);
                if let Some(button) = self.drag_button() {
                    return (vec![InjectAction::Move { to: p, dx: 0.0, dy: 0.0, drag_button: Some(button) }], vec![]);
                }
                (vec![InjectAction::Warp(p)], vec![])
            }
            Message::Leave => {
                self.active = false;
                (vec![], vec![])
            }
            Message::MouseMove { dx, dy } => {
                if !self.active {
                    return (vec![], vec![]);
                }
                let raw = Point::new(self.position.x + dx, self.position.y + dy);
                let clamped = self.desktop.clamp(raw);
                self.moved(clamped);
                let action = InjectAction::Move { to: clamped, dx, dy, drag_button: self.drag_button() };
                // 推出了桌面：上报推出去的点，能否回主控端由主控端按屏幕排列判断（拖拽中不上报）
                if clamped != raw && self.held_buttons.is_empty() {
                    return (vec![action], vec![Message::EdgePush { x: raw.x, y: raw.y }]);
                }
                (vec![action], vec![])
            }
            Message::MouseButton { button, down, click_count } => {
                if down {
                    self.held_buttons.insert(button);
                } else {
                    self.held_buttons.remove(&button);
                }
                (vec![InjectAction::Button { button, down, at: self.position, click_count }], vec![])
            }
            Message::Scroll(s) => (vec![InjectAction::Scroll(s)], vec![]),
            Message::SystemKey { data1 } => (vec![InjectAction::SystemKey { data1 }], vec![]),
            Message::Key { code, down, autorepeat } => {
                if code == keycodes::CAPS_LOCK {
                    // 主控端每次切换大写锁定都发一次，这边还原成一次完整按键
                    let f = self.modifier_flags();
                    return (
                        vec![
                            InjectAction::Key { code, down: true, autorepeat: false, flags: f },
                            InjectAction::Key { code, down: false, autorepeat: false, flags: f },
                        ],
                        vec![],
                    );
                }
                if down {
                    self.held_keys.insert(code);
                } else {
                    self.held_keys.remove(&code);
                }
                (vec![InjectAction::Key { code, down, autorepeat, flags: self.modifier_flags() }], vec![])
            }
            Message::ReleaseAll => (self.release_all(), vec![]),
            _ => (vec![], vec![]),
        }
    }

    /// 松开所有按住的键和鼠标按键（断线、退出时调用），先松普通键再松修饰键
    pub fn release_all(&mut self) -> Vec<InjectAction> {
        self.active = false;
        let mut actions: Vec<InjectAction> = std::mem::take(&mut self.held_buttons)
            .into_iter()
            .map(|button| InjectAction::Button { button, down: false, at: self.position, click_count: 1 })
            .collect();
        let mut keys: Vec<u16> = self.held_keys.iter().copied().collect();
        keys.sort_by_key(|k| (keycodes::is_modifier(*k), *k));
        for key in keys {
            self.held_keys.remove(&key);
            actions.push(InjectAction::Key { code: key, down: false, autorepeat: false, flags: self.modifier_flags() });
        }
        actions
    }
}
