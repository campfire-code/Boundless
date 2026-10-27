//! macOS 虚拟键码与修饰键标志位。协议里的按键一律用 macOS 键码，Windows 端收发时换算（见 keymap 模块）

use std::collections::HashSet;

use crate::geometry::Edge;

pub const CAPS_LOCK: u16 = 57;
pub const TAB: u16 = 48;
pub const LEFT_ARROW: u16 = 123;
pub const RIGHT_ARROW: u16 = 124;
pub const DOWN_ARROW: u16 = 125;
pub const UP_ARROW: u16 = 126;

pub mod flag {
    pub const CAPS_LOCK: u64 = 0x10000;
    pub const SHIFT: u64 = 0x20000;
    pub const CONTROL: u64 = 0x40000;
    pub const OPTION: u64 = 0x80000;
    pub const COMMAND: u64 = 0x100000;
    pub const FN: u64 = 0x800000;
    pub const NON_COALESCED: u64 = 0x100;
}

/// 修饰键码 → (通用标志位, 区分左右的设备标志位)
fn modifier(code: u16) -> Option<(u64, u64)> {
    Some(match code {
        55 => (flag::COMMAND, 0x08),
        54 => (flag::COMMAND, 0x10),
        56 => (flag::SHIFT, 0x02),
        60 => (flag::SHIFT, 0x04),
        58 => (flag::OPTION, 0x20),
        61 => (flag::OPTION, 0x40),
        59 => (flag::CONTROL, 0x01),
        62 => (flag::CONTROL, 0x2000),
        63 => (flag::FN, 0),
        _ => return None,
    })
}

/// 通用标志位 → 左右两侧设备标志位之和
fn device_bits(general: u64) -> Option<u64> {
    match general {
        flag::COMMAND => Some(0x18),
        flag::SHIFT => Some(0x06),
        flag::OPTION => Some(0x60),
        flag::CONTROL => Some(0x2001),
        _ => None,
    }
}

pub fn is_modifier(code: u16) -> bool {
    modifier(code).is_some()
}

/// flagsChanged 事件里某个修饰键此刻是否处于按下状态
pub fn is_modifier_down(code: u16, flags: u64) -> bool {
    let Some((general, device)) = modifier(code) else { return false };
    if flags & general == 0 {
        return false;
    }
    // 键盘上报了左右区分位时按设备位判断；部分第三方键盘不报，只能按通用位判断
    match device_bits(general) {
        Some(both) if flags & both != 0 => flags & device != 0,
        _ => true,
    }
}

/// 由当前按住的修饰键推算事件 flags
pub fn flags_for_held(codes: &HashSet<u16>) -> u64 {
    codes.iter().fold(flag::NON_COALESCED, |acc, code| match modifier(*code) {
        Some((general, device)) => acc | general | device,
        None => acc,
    })
}

pub fn arrow_toward(edge: Edge) -> u16 {
    match edge {
        Edge::Left => LEFT_ARROW,
        Edge::Right => RIGHT_ARROW,
        Edge::Top => UP_ARROW,
        Edge::Bottom => DOWN_ARROW,
    }
}

/// 切换快捷键：⌃⌥⌘ + 朝向 edge 的方向键（Windows 键盘上是 Win+Alt+Ctrl + 方向键）
pub fn is_switch_hotkey(code: u16, flags: u64, toward: Edge) -> bool {
    let required = flag::CONTROL | flag::OPTION | flag::COMMAND;
    code == arrow_toward(toward) && flags & required == required
}
