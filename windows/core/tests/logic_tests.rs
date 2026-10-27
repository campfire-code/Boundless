//! 移植自 Swift 版 CoreTests.swift 的几何、排列、键码、切换状态机与被控端光标测试，保证两边行为一致

use std::collections::HashSet;

use boundless_core::arrangement::{Arrangement, Segment};
use boundless_core::client_cursor::{ClientCursor, InjectAction};
use boundless_core::geometry::{Desktop, Edge, Point, Rect};
use boundless_core::keycodes::{self, flag};
use boundless_core::message::{Message, ScrollEvent};
use boundless_core::server_switch::{Decision, InputEvent, Mode, ServerSwitch, SwitchEffect};

fn p(x: f64, y: f64) -> Point {
    Point::new(x, y)
}

const LAPTOP: Rect = Rect { x: 0.0, y: 0.0, w: 1512.0, h: 982.0 };
const MONITOR: Rect = Rect { x: 0.0, y: 0.0, w: 2560.0, h: 1440.0 };

// MARK: 几何

#[test]
fn edges_of_single_display() {
    let d = Desktop::new(vec![LAPTOP]);
    assert!(d.is_at_edge(p(1511.0, 400.0), Edge::Right));
    assert!(d.is_at_edge(p(1511.6, 400.0), Edge::Right));
    assert!(!d.is_at_edge(p(1500.0, 400.0), Edge::Right));
    assert!(d.is_at_edge(p(0.0, 400.0), Edge::Left));
    assert_eq!(d.clamp(p(-20.0, 5000.0)), p(0.0, 981.0));
}

#[test]
fn inner_edge_between_two_displays_is_not_an_exit() {
    let external = Rect::new(1512.0, -200.0, 2560.0, 1440.0);
    let d = Desktop::new(vec![LAPTOP, external]);
    assert!(!d.is_at_edge(p(1511.0, 400.0), Edge::Right), "右边还有外接屏，不算桌面外沿");
    assert!(d.is_at_edge(p(4071.0, 400.0), Edge::Right));
    assert_eq!(d.bounds(), Rect::new(0.0, -200.0, 4072.0, 1440.0));
    assert_eq!(d.main(), Some(LAPTOP));
}

#[test]
fn point_beyond_only_when_pushing_out_of_desktop() {
    let d = Desktop::new(vec![LAPTOP]);
    assert_eq!(d.point_beyond(p(1511.0, 400.0), 0.3, 0.0), Some(p(1512.0, 400.0)), "小位移也要推到边外");
    assert_eq!(d.point_beyond(p(0.0, 400.0), -5.0, 0.0), Some(p(-5.0, 400.0)));
    assert_eq!(d.point_beyond(p(1511.0, 400.0), -3.0, 0.0), None, "往回走不算");
    assert_eq!(d.point_beyond(p(800.0, 400.0), 30.0, 0.0), None, "不在边上不算");
}

// MARK: 排列

#[test]
fn default_placement_is_right_of_main_display_centered() {
    let server = Desktop::new(vec![MONITOR]);
    let a = Arrangement::default_placement(vec![LAPTOP], &server);
    assert_eq!(a.placed_bounds(), Rect::new(2560.0, 229.0, 1512.0, 982.0));
    assert_eq!(a.side(&server), Edge::Right);
}

#[test]
fn dropped_block_snaps_to_nearest_side_keeping_offset() {
    let server = Desktop::new(vec![MONITOR]);
    let snapped = Arrangement::new(vec![LAPTOP], p(-1600.0, 700.0)).snapped(&server, 40.0);
    assert_eq!(snapped.origin, p(-1512.0, 700.0));
    assert_eq!(snapped.side(&server), Edge::Left);
    assert_eq!(snapped.shared_edges(&server), vec![Segment { from: p(0.0, 700.0), to: p(0.0, 1440.0) }]);
}

#[test]
fn snap_keeps_minimum_overlap_and_never_overlaps_server() {
    let server = Desktop::new(vec![MONITOR]);
    let far_below = Arrangement::new(vec![LAPTOP], p(-1500.0, 3000.0)).snapped(&server, 40.0);
    let overlap = far_below.shared_edges(&server)[0];
    assert!((overlap.to.x - overlap.from.x).abs() + (overlap.to.y - overlap.from.y).abs() >= 40.0);

    let inside = Arrangement::new(vec![LAPTOP], p(1000.0, 200.0)).snapped(&server, 40.0);
    let i = inside.placed_displays()[0].intersection(&MONITOR.inset(1.0, 1.0));
    assert!(i.is_none_or(|r| r.w <= 0.0 || r.h <= 0.0), "丢在主控端屏幕中间也要推到边外");
}

#[test]
fn coordinate_mapping_uses_client_bounds() {
    let client = vec![LAPTOP, Rect::new(-1920.0, -100.0, 1920.0, 1080.0)];
    let a = Arrangement::new(client, p(2560.0, 0.0));
    assert_eq!(a.to_server(p(-1920.0, -100.0)), p(2560.0, 0.0));
    assert_eq!(a.to_client(a.to_server(p(700.0, 300.0))), p(700.0, 300.0));
    assert_eq!(a.client_point_at_server(p(2561.0, 50.0)), Some(p(-1919.0, -50.0)));
    assert_eq!(a.client_point_at_server(p(2561.0, 1100.0)), None, "落在外接屏下方的空白处");
}

// MARK: 键码

#[test]
fn modifier_down_detection() {
    let left_cmd = flag::COMMAND | 0x08;
    assert!(keycodes::is_modifier_down(55, left_cmd));
    assert!(!keycodes::is_modifier_down(54, left_cmd), "按左 ⌘ 时右 ⌘ 不算按下");
    assert!(!keycodes::is_modifier_down(55, 0x100));
    assert!(keycodes::is_modifier_down(56, flag::SHIFT), "不报左右位的键盘按通用位判断");
}

#[test]
fn flags_for_held_keys_and_hotkey() {
    let flags = keycodes::flags_for_held(&HashSet::from([55, 58, 59, 0]));
    assert!(keycodes::is_switch_hotkey(keycodes::RIGHT_ARROW, flags, Edge::Right));
    assert!(!keycodes::is_switch_hotkey(keycodes::LEFT_ARROW, flags, Edge::Right));
    assert!(!keycodes::is_switch_hotkey(keycodes::RIGHT_ARROW, keycodes::flags_for_held(&HashSet::from([55, 58])), Edge::Right));
}

// MARK: 主控端切换状态机

const SCREEN: Rect = Rect { x: 0.0, y: 0.0, w: 1512.0, h: 982.0 };
const CLIENT: Rect = Rect { x: 0.0, y: 0.0, w: 2560.0, h: 1440.0 };
const HOTKEY: u64 = flag::CONTROL | flag::OPTION | flag::COMMAND;

/// 被控端放在右侧，顶部对齐
fn make_switch(connected: bool, origin_y: f64) -> ServerSwitch {
    let mut s = ServerSwitch::new(Desktop::new(vec![SCREEN]), Some(Arrangement::new(vec![CLIENT], p(1512.0, origin_y))));
    if connected {
        s.set_connected(true);
    }
    s
}

fn push_right(s: &mut ServerSwitch, y: f64) -> Decision {
    s.handle(&InputEvent::MouseMove { location: p(1511.0, y), dx: 4.0, dy: 0.0 })
}

fn key(code: u16, down: bool, autorepeat: bool, flags: u64) -> InputEvent {
    InputEvent::Key { code, down, autorepeat, flags }
}

#[test]
fn pushing_into_client_screen_enters_remote_at_matching_point() {
    let mut s = make_switch(true, 0.0);
    assert!(s.handle(&InputEvent::MouseMove { location: p(1400.0, 491.0), dx: 4.0, dy: 0.0 }).pass_locally);
    let d = push_right(&mut s, 491.0);
    assert_eq!(s.mode(), Mode::Remote);
    assert!(!d.pass_locally);
    assert_eq!(d.effect, SwitchEffect::EnterRemote);
    assert_eq!(d.messages, vec![Message::Enter { x: 3.0, y: 491.0 }], "按真实位置对齐，不按比例拉伸");
}

#[test]
fn only_the_overlapping_segment_crosses() {
    let mut s = make_switch(true, 600.0);
    assert!(push_right(&mut s, 300.0).pass_locally);
    assert_eq!(s.mode(), Mode::Local);
    assert_eq!(push_right(&mut s, 800.0).messages, vec![Message::Enter { x: 3.0, y: 200.0 }]);
}

#[test]
fn other_edges_do_not_cross() {
    let mut s = make_switch(true, 0.0);
    assert!(s.handle(&InputEvent::MouseMove { location: p(0.0, 400.0), dx: -5.0, dy: 0.0 }).pass_locally);
    assert_eq!(s.mode(), Mode::Local);
}

#[test]
fn no_switch_when_disconnected_dragging_or_layout_unknown() {
    let mut off = make_switch(false, 0.0);
    assert!(push_right(&mut off, 491.0).pass_locally);

    let mut dragging = make_switch(true, 0.0);
    dragging.handle(&InputEvent::MouseButton { button: 0, down: true, click_count: 1 });
    assert!(push_right(&mut dragging, 491.0).pass_locally);

    let mut unknown = ServerSwitch::new(Desktop::new(vec![SCREEN]), None);
    unknown.set_connected(true);
    assert!(push_right(&mut unknown, 491.0).pass_locally);
    assert_eq!(unknown.mode(), Mode::Local);
}

#[test]
fn remote_mode_forwards_and_swallows_everything() {
    let mut s = make_switch(true, 0.0);
    push_right(&mut s, 491.0);
    assert_eq!(
        s.handle(&InputEvent::MouseMove { location: p(1511.0, 491.0), dx: -2.0, dy: 3.0 }),
        Decision { pass_locally: false, messages: vec![Message::MouseMove { dx: -2.0, dy: 3.0 }], effect: SwitchEffect::None }
    );
    assert_eq!(
        s.handle(&InputEvent::MouseButton { button: 0, down: true, click_count: 2 }).messages,
        vec![Message::MouseButton { button: 0, down: true, click_count: 2 }]
    );
    assert_eq!(s.handle(&key(0, true, false, 0)).messages, vec![Message::Key { code: 0, down: true, autorepeat: false }]);
    assert!(!s.handle(&InputEvent::Scroll(ScrollEvent { delta_axis1: 1, ..Default::default() })).pass_locally);
    assert!(!s.handle(&InputEvent::SystemKey { data1: 0x000A_0A00 }).pass_locally);
}

#[test]
fn key_held_before_switch_is_released_locally() {
    let mut s = make_switch(true, 0.0);
    assert!(s.handle(&key(56, true, false, flag::SHIFT)).pass_locally);
    push_right(&mut s, 491.0);
    assert!(s.handle(&key(56, false, false, 0)).pass_locally, "本机按下的 Shift 必须在本机松开，否则本机卡键");
}

#[test]
fn autorepeat_follows_the_side_where_key_went_down() {
    let mut s = make_switch(true, 0.0);
    s.handle(&key(2, true, false, 0));
    push_right(&mut s, 491.0);
    assert!(s.handle(&key(2, true, true, 0)).pass_locally);
    assert!(s.handle(&key(2, false, false, 0)).pass_locally);
}

#[test]
fn hotkeys_follow_arrangement_side_and_route_modifier_releases() {
    let mut s = make_switch(true, 0.0);
    for code in [59, 58, 55] {
        s.handle(&key(code, true, false, HOTKEY));
    }
    assert!(s.handle(&key(keycodes::LEFT_ARROW, true, false, HOTKEY)).pass_locally, "被控端在右侧，⌃⌥⌘← 不切换");
    let go = s.handle(&key(keycodes::RIGHT_ARROW, true, false, HOTKEY));
    assert_eq!(go.effect, SwitchEffect::EnterRemote);
    assert!(!s.handle(&key(keycodes::RIGHT_ARROW, true, true, HOTKEY)).pass_locally);
    assert_eq!(s.handle(&key(keycodes::RIGHT_ARROW, false, false, HOTKEY)), Decision::swallow());
    for code in [59, 58, 55] {
        assert!(s.handle(&key(code, false, false, 0)).pass_locally);
    }

    for code in [59, 58, 55] {
        s.handle(&key(code, true, false, HOTKEY));
    }
    s.handle(&key(keycodes::LEFT_ARROW, false, false, HOTKEY));
    let back = s.handle(&key(keycodes::LEFT_ARROW, true, false, HOTKEY));
    assert_eq!(s.mode(), Mode::Local);
    assert_eq!(back.effect, SwitchEffect::ReturnLocal { warp_to: None });
    assert_eq!(back.messages.last(), Some(&Message::Leave), "快捷键切回要通知被控端");
    for code in [59, 58, 55] {
        let d = s.handle(&key(code, false, false, 0));
        assert_eq!(d.messages, vec![Message::Key { code, down: false, autorepeat: false }]);
    }
}

#[test]
fn hotkey_enters_at_nearest_client_point() {
    let mut s = make_switch(true, 600.0);
    s.handle(&InputEvent::MouseMove { location: p(700.0, 100.0), dx: 1.0, dy: 0.0 });
    let go = s.handle(&key(keycodes::RIGHT_ARROW, true, false, HOTKEY));
    assert_eq!(go.messages, vec![Message::Enter { x: 0.0, y: 0.0 }]);
}

#[test]
fn client_push_back_into_server_screen_returns_control() {
    let mut s = make_switch(true, 600.0);
    push_right(&mut s, 800.0);
    let d = s.client_pushed(p(-3.0, 300.0));
    assert_eq!(s.mode(), Mode::Local);
    assert_eq!(d.effect, SwitchEffect::ReturnLocal { warp_to: Some(p(1509.0, 900.0)) });
    assert_eq!(d.messages, vec![Message::Leave]);
}

#[test]
fn client_push_outside_overlap_is_ignored() {
    let mut s = make_switch(true, 600.0);
    push_right(&mut s, 800.0);
    assert_eq!(s.client_pushed(p(-3.0, 800.0)), Decision::pass());
    assert_eq!(s.mode(), Mode::Remote);
}

#[test]
fn disconnect_while_remote_returns_control() {
    let mut s = make_switch(true, 0.0);
    push_right(&mut s, 491.0);
    s.handle(&key(0, true, false, 0));
    let d = s.set_connected(false);
    assert_eq!(s.mode(), Mode::Local);
    assert_eq!(d.effect, SwitchEffect::ReturnLocal { warp_to: None });
    assert!(s.handle(&key(0, false, false, 0)).pass_locally);
}

#[test]
fn remote_buttons_released_when_hotkey_returns() {
    let mut s = make_switch(true, 0.0);
    push_right(&mut s, 491.0);
    s.handle(&InputEvent::MouseButton { button: 1, down: true, click_count: 1 });
    let back = s.handle(&key(keycodes::LEFT_ARROW, true, false, HOTKEY));
    assert_eq!(back.messages, vec![Message::MouseButton { button: 1, down: false, click_count: 1 }, Message::Leave]);
}

// MARK: 被控端光标

fn make_cursor() -> ClientCursor {
    let mut c = ClientCursor::new(Desktop::new(vec![MONITOR]));
    c.handle(&Message::Enter { x: 3.0, y: 719.5 });
    c
}

#[test]
fn enter_warps_to_given_point_clamped() {
    let mut c = ClientCursor::new(Desktop::new(vec![MONITOR]));
    assert_eq!(c.handle(&Message::Enter { x: -10.0, y: 500.0 }).0, vec![InjectAction::Warp(p(0.0, 500.0))]);
    assert!(c.is_active());
}

#[test]
fn moves_are_clamped_inside_screen() {
    let mut c = make_cursor();
    let (actions, replies) = c.handle(&Message::MouseMove { dx: 100.0, dy: 10.0 });
    assert!(replies.is_empty());
    assert_eq!(actions, vec![InjectAction::Move { to: p(103.0, 729.5), dx: 100.0, dy: 10.0, drag_button: None }]);
}

#[test]
fn pushing_out_reports_raw_point_but_stays_active() {
    let mut c = make_cursor();
    let (actions, replies) = c.handle(&Message::MouseMove { dx: -10.0, dy: 0.0 });
    assert_eq!(replies, vec![Message::EdgePush { x: -7.0, y: 719.5 }]);
    assert_eq!(actions, vec![InjectAction::Move { to: p(0.0, 719.5), dx: -10.0, dy: 0.0, drag_button: None }]);
    assert!(c.is_active(), "由主控端决定是否收回");
    c.handle(&Message::Leave);
    assert!(!c.is_active());
    assert!(c.handle(&Message::MouseMove { dx: 5.0, dy: 0.0 }).0.is_empty(), "收回后忽略移动");
}

#[test]
fn no_push_report_while_dragging() {
    let mut c = make_cursor();
    c.handle(&Message::MouseButton { button: 0, down: true, click_count: 1 });
    let (actions, replies) = c.handle(&Message::MouseMove { dx: -10.0, dy: 0.0 });
    assert!(replies.is_empty());
    assert_eq!(actions, vec![InjectAction::Move { to: p(0.0, 719.5), dx: -10.0, dy: 0.0, drag_button: Some(0) }]);
}

#[test]
fn modifier_flags_follow_held_keys() {
    let mut c = make_cursor();
    let cmd = keycodes::flags_for_held(&HashSet::from([55]));
    assert_eq!(
        c.handle(&Message::Key { code: 55, down: true, autorepeat: false }).0,
        vec![InjectAction::Key { code: 55, down: true, autorepeat: false, flags: cmd }]
    );
    assert_eq!(
        c.handle(&Message::Key { code: 8, down: true, autorepeat: false }).0,
        vec![InjectAction::Key { code: 8, down: true, autorepeat: false, flags: cmd }]
    );
    assert_eq!(
        c.handle(&Message::Key { code: 55, down: false, autorepeat: false }).0,
        vec![InjectAction::Key { code: 55, down: false, autorepeat: false, flags: flag::NON_COALESCED }]
    );
}

#[test]
fn release_all_lets_go_of_everything() {
    let mut c = make_cursor();
    c.handle(&Message::Key { code: 55, down: true, autorepeat: false });
    c.handle(&Message::Key { code: 8, down: true, autorepeat: false });
    c.handle(&Message::MouseButton { button: 0, down: true, click_count: 1 });
    let actions = c.release_all();
    assert_eq!(actions.len(), 3);
    assert_eq!(
        actions.last(),
        Some(&InjectAction::Key { code: 55, down: false, autorepeat: false, flags: flag::NON_COALESCED }),
        "修饰键最后松开"
    );
    assert!(c.release_all().is_empty());
    assert!(!c.is_active());
}

#[test]
fn lagging_system_cursor_does_not_pull_position_back() {
    let mut c = make_cursor();
    let mut posted = vec![c.position(), c.position()];
    for _ in 0..20 {
        c.sync_position(posted[posted.len() - 2]);
        if let Some(InjectAction::Move { to, .. }) = c.handle(&Message::MouseMove { dx: 5.0, dy: 0.0 }).0.first() {
            posted.push(*to);
        }
    }
    assert!((c.position().x - 103.0).abs() < 0.001, "移动 20 次 × 5 点，应到 x=103");
}

#[test]
fn real_local_mouse_movement_is_still_followed() {
    let mut c = make_cursor();
    c.handle(&Message::MouseMove { dx: 5.0, dy: 0.0 });
    c.sync_position(p(900.0, 300.0));
    assert_eq!(
        c.handle(&Message::MouseMove { dx: 1.0, dy: 0.0 }).0,
        vec![InjectAction::Move { to: p(901.0, 300.0), dx: 1.0, dy: 0.0, drag_button: None }]
    );
}

#[test]
fn caps_lock_becomes_full_press() {
    let mut c = make_cursor();
    let actions = c.handle(&Message::Key { code: keycodes::CAPS_LOCK, down: false, autorepeat: false }).0;
    let downs: Vec<bool> = actions
        .iter()
        .filter_map(|a| if let InjectAction::Key { down, .. } = a { Some(*down) } else { None })
        .collect();
    assert_eq!(downs, vec![true, false]);
    assert!(c.release_all().is_empty(), "大写锁定不计入按住的键");
}
