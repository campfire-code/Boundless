//! 两端之间传输的全部消息，编码与 Swift 版 Message.swift 逐字节一致

use crate::geometry::Rect;
use crate::wire::{ByteReader, ByteWriter, WireError};

/// 滚轮事件，字段与 macOS CGEvent 的滚动字段一一对应（Windows 端收发时换算，见 scroll 模块）
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ScrollEvent {
    pub delta_axis1: i32,
    pub delta_axis2: i32,
    pub point_delta_axis1: i32,
    pub point_delta_axis2: i32,
    pub fixed_delta_axis1: f64,
    pub fixed_delta_axis2: f64,
    pub is_continuous: bool,
    pub scroll_phase: i32,
    pub momentum_phase: i32,
}

/// 剪贴板中的一种数据表示（UTI + 原始数据）
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardItem {
    pub kind: String,
    pub data: Vec<u8>,
}

/// 被控端上的一个窗口
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteWindow {
    pub id: u32,
    pub app: String,
    pub title: String,
    pub frame: Rect,
}

/// 一条连接的用途：控制通道走键鼠和剪贴板，视频通道只走虚拟屏画面
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    Control = 0,
    Video = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264 = 0,
    Hevc = 1,
}

/// 对端系统。Windows 端不支持虚拟副屏，Mac 主控端据此隐藏相关菜单
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Mac = 0,
    Windows = 1,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Hello { version: u16, name: String, channel: Channel, platform: Platform },
    Ping,
    Layout { displays: Vec<Rect> },
    Enter { x: f64, y: f64 },
    Leave,
    EdgePush { x: f64, y: f64 },
    MouseMove { dx: f64, dy: f64 },
    MouseButton { button: u8, down: bool, click_count: i32 },
    Scroll(ScrollEvent),
    Key { code: u16, down: bool, autorepeat: bool },
    SystemKey { data1: i32 },
    Clipboard(Vec<ClipboardItem>),
    ReleaseAll,
    WindowListRequest,
    WindowList(Vec<RemoteWindow>),
    VirtualDisplay { frame: Rect },
    VirtualReady { frame: Rect },
    VirtualWindows { capture: Rect, windows: Vec<Rect> },
    MoveTo { x: f64, y: f64 },
    MoveWindowToVirtual { window: u32 },
    RecallWindows,
    VideoFormat { window: u32, codec: VideoCodec, nal_length_size: u8, parameter_sets: Vec<Vec<u8>> },
    VideoFrame { window: u32, keyframe: bool, capture_time: f64, data: Vec<u8> },
    RequestKeyframe { window: u32 },
    ClockProbe { server_time: f64 },
    ClockReply { server_time: f64, client_time: f64 },
}

mod tag {
    pub const HELLO: u8 = 1;
    pub const PING: u8 = 2;
    pub const LAYOUT: u8 = 3;
    pub const ENTER: u8 = 4;
    pub const LEAVE: u8 = 5;
    pub const EDGE_PUSH: u8 = 6;
    pub const MOUSE_MOVE: u8 = 7;
    pub const MOUSE_BUTTON: u8 = 8;
    pub const SCROLL: u8 = 9;
    pub const KEY: u8 = 10;
    pub const SYSTEM_KEY: u8 = 11;
    pub const CLIPBOARD: u8 = 12;
    pub const RELEASE_ALL: u8 = 13;
    pub const WINDOW_LIST_REQUEST: u8 = 14;
    pub const WINDOW_LIST: u8 = 15;
    pub const VIRTUAL_DISPLAY: u8 = 16;
    pub const VIRTUAL_READY: u8 = 17;
    pub const VIRTUAL_WINDOWS: u8 = 18;
    pub const MOVE_TO: u8 = 19;
    pub const MOVE_WINDOW_TO_VIRTUAL: u8 = 20;
    pub const RECALL_WINDOWS: u8 = 21;
    pub const VIDEO_FORMAT: u8 = 22;
    pub const VIDEO_FRAME: u8 = 23;
    pub const REQUEST_KEYFRAME: u8 = 24;
    pub const CLOCK_PROBE: u8 = 25;
    pub const CLOCK_REPLY: u8 = 26;
}

impl Message {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::default();
        match self {
            Message::Hello { version, name, channel, platform } => {
                w.u8(tag::HELLO);
                w.u16(*version);
                w.string(name);
                w.u8(*channel as u8);
                w.u8(*platform as u8);
            }
            Message::Ping => w.u8(tag::PING),
            Message::Layout { displays } => {
                w.u8(tag::LAYOUT);
                write_rects(&mut w, displays);
            }
            Message::Enter { x, y } => {
                w.u8(tag::ENTER);
                w.f64(*x);
                w.f64(*y);
            }
            Message::Leave => w.u8(tag::LEAVE),
            Message::EdgePush { x, y } => {
                w.u8(tag::EDGE_PUSH);
                w.f64(*x);
                w.f64(*y);
            }
            Message::MouseMove { dx, dy } => {
                w.u8(tag::MOUSE_MOVE);
                w.f64(*dx);
                w.f64(*dy);
            }
            Message::MouseButton { button, down, click_count } => {
                w.u8(tag::MOUSE_BUTTON);
                w.u8(*button);
                w.bool(*down);
                w.i32(*click_count);
            }
            Message::Scroll(s) => {
                w.u8(tag::SCROLL);
                w.i32(s.delta_axis1);
                w.i32(s.delta_axis2);
                w.i32(s.point_delta_axis1);
                w.i32(s.point_delta_axis2);
                w.f64(s.fixed_delta_axis1);
                w.f64(s.fixed_delta_axis2);
                w.bool(s.is_continuous);
                w.i32(s.scroll_phase);
                w.i32(s.momentum_phase);
            }
            Message::Key { code, down, autorepeat } => {
                w.u8(tag::KEY);
                w.u16(*code);
                w.bool(*down);
                w.bool(*autorepeat);
            }
            Message::SystemKey { data1 } => {
                w.u8(tag::SYSTEM_KEY);
                w.i32(*data1);
            }
            Message::Clipboard(items) => {
                w.u8(tag::CLIPBOARD);
                w.u32(items.len() as u32);
                for i in items {
                    w.string(&i.kind);
                    w.bytes(&i.data);
                }
            }
            Message::ReleaseAll => w.u8(tag::RELEASE_ALL),
            Message::WindowListRequest => w.u8(tag::WINDOW_LIST_REQUEST),
            Message::WindowList(windows) => {
                w.u8(tag::WINDOW_LIST);
                w.u32(windows.len() as u32);
                for x in windows {
                    w.u32(x.id);
                    w.string(&x.app);
                    w.string(&x.title);
                    write_rect(&mut w, &x.frame);
                }
            }
            Message::VirtualDisplay { frame } => {
                w.u8(tag::VIRTUAL_DISPLAY);
                write_rect(&mut w, frame);
            }
            Message::VirtualReady { frame } => {
                w.u8(tag::VIRTUAL_READY);
                write_rect(&mut w, frame);
            }
            Message::VirtualWindows { capture, windows } => {
                w.u8(tag::VIRTUAL_WINDOWS);
                write_rect(&mut w, capture);
                write_rects(&mut w, windows);
            }
            Message::MoveTo { x, y } => {
                w.u8(tag::MOVE_TO);
                w.f64(*x);
                w.f64(*y);
            }
            Message::MoveWindowToVirtual { window } => {
                w.u8(tag::MOVE_WINDOW_TO_VIRTUAL);
                w.u32(*window);
            }
            Message::RecallWindows => w.u8(tag::RECALL_WINDOWS),
            Message::VideoFormat { window, codec, nal_length_size, parameter_sets } => {
                w.u8(tag::VIDEO_FORMAT);
                w.u32(*window);
                w.u8(*codec as u8);
                w.u8(*nal_length_size);
                w.u32(parameter_sets.len() as u32);
                for p in parameter_sets {
                    w.bytes(p);
                }
            }
            Message::VideoFrame { window, keyframe, capture_time, data } => {
                w.u8(tag::VIDEO_FRAME);
                w.u32(*window);
                w.bool(*keyframe);
                w.f64(*capture_time);
                w.bytes(data);
            }
            Message::RequestKeyframe { window } => {
                w.u8(tag::REQUEST_KEYFRAME);
                w.u32(*window);
            }
            Message::ClockProbe { server_time } => {
                w.u8(tag::CLOCK_PROBE);
                w.f64(*server_time);
            }
            Message::ClockReply { server_time, client_time } => {
                w.u8(tag::CLOCK_REPLY);
                w.f64(*server_time);
                w.f64(*client_time);
            }
        }
        w.data
    }

    pub fn decode(data: &[u8]) -> Result<Message, WireError> {
        let mut r = ByteReader::new(data);
        let raw = r.u8()?;
        let m = match raw {
            tag::HELLO => {
                let version = r.u16()?;
                let name = r.string()?;
                // 旧版本的 hello 没有通道和平台字段，照样解出来，好让上层提示「版本不一致」而不是直接断开
                let channel = if r.is_at_end() {
                    Channel::Control
                } else {
                    match r.u8()? {
                        0 => Channel::Control,
                        1 => Channel::Video,
                        _ => return Err(WireError::InvalidValue),
                    }
                };
                let platform = if r.is_at_end() {
                    Platform::Mac
                } else {
                    match r.u8()? {
                        0 => Platform::Mac,
                        1 => Platform::Windows,
                        _ => return Err(WireError::InvalidValue),
                    }
                };
                Message::Hello { version, name, channel, platform }
            }
            tag::PING => Message::Ping,
            tag::LAYOUT => Message::Layout { displays: read_rects(&mut r, 64)? },
            tag::ENTER => Message::Enter { x: r.f64()?, y: r.f64()? },
            tag::LEAVE => Message::Leave,
            tag::EDGE_PUSH => Message::EdgePush { x: r.f64()?, y: r.f64()? },
            tag::MOUSE_MOVE => Message::MouseMove { dx: r.f64()?, dy: r.f64()? },
            tag::MOUSE_BUTTON => Message::MouseButton { button: r.u8()?, down: r.bool()?, click_count: r.i32()? },
            tag::SCROLL => Message::Scroll(ScrollEvent {
                delta_axis1: r.i32()?,
                delta_axis2: r.i32()?,
                point_delta_axis1: r.i32()?,
                point_delta_axis2: r.i32()?,
                fixed_delta_axis1: r.f64()?,
                fixed_delta_axis2: r.f64()?,
                is_continuous: r.bool()?,
                scroll_phase: r.i32()?,
                momentum_phase: r.i32()?,
            }),
            tag::KEY => Message::Key { code: r.u16()?, down: r.bool()?, autorepeat: r.bool()? },
            tag::SYSTEM_KEY => Message::SystemKey { data1: r.i32()? },
            tag::CLIPBOARD => {
                let count = r.u32()? as usize;
                let mut items = Vec::new();
                for _ in 0..count {
                    items.push(ClipboardItem { kind: r.string()?, data: r.bytes()? });
                }
                Message::Clipboard(items)
            }
            tag::RELEASE_ALL => Message::ReleaseAll,
            tag::WINDOW_LIST_REQUEST => Message::WindowListRequest,
            tag::WINDOW_LIST => {
                let count = r.u32()? as usize;
                if count > 1024 {
                    return Err(WireError::InvalidValue);
                }
                let mut windows = Vec::with_capacity(count);
                for _ in 0..count {
                    windows.push(RemoteWindow { id: r.u32()?, app: r.string()?, title: r.string()?, frame: read_rect(&mut r)? });
                }
                Message::WindowList(windows)
            }
            tag::VIRTUAL_DISPLAY => Message::VirtualDisplay { frame: read_rect(&mut r)? },
            tag::VIRTUAL_READY => Message::VirtualReady { frame: read_rect(&mut r)? },
            tag::VIRTUAL_WINDOWS => Message::VirtualWindows { capture: read_rect(&mut r)?, windows: read_rects(&mut r, 1024)? },
            tag::MOVE_TO => Message::MoveTo { x: r.f64()?, y: r.f64()? },
            tag::MOVE_WINDOW_TO_VIRTUAL => Message::MoveWindowToVirtual { window: r.u32()? },
            tag::RECALL_WINDOWS => Message::RecallWindows,
            tag::VIDEO_FORMAT => {
                let window = r.u32()?;
                let codec = match r.u8()? {
                    0 => VideoCodec::H264,
                    1 => VideoCodec::Hevc,
                    _ => return Err(WireError::InvalidValue),
                };
                let nal_length_size = r.u8()?;
                let count = r.u32()? as usize;
                if count > 16 {
                    return Err(WireError::InvalidValue);
                }
                let mut parameter_sets = Vec::with_capacity(count);
                for _ in 0..count {
                    parameter_sets.push(r.bytes()?);
                }
                Message::VideoFormat { window, codec, nal_length_size, parameter_sets }
            }
            tag::VIDEO_FRAME => Message::VideoFrame { window: r.u32()?, keyframe: r.bool()?, capture_time: r.f64()?, data: r.bytes()? },
            tag::REQUEST_KEYFRAME => Message::RequestKeyframe { window: r.u32()? },
            tag::CLOCK_PROBE => Message::ClockProbe { server_time: r.f64()? },
            tag::CLOCK_REPLY => Message::ClockReply { server_time: r.f64()?, client_time: r.f64()? },
            other => return Err(WireError::UnknownMessage(other)),
        };
        if !r.is_at_end() {
            return Err(WireError::InvalidValue);
        }
        Ok(m)
    }
}

fn write_rect(w: &mut ByteWriter, r: &Rect) {
    w.f64(r.x);
    w.f64(r.y);
    w.f64(r.w);
    w.f64(r.h);
}

fn write_rects(w: &mut ByteWriter, rs: &[Rect]) {
    w.u32(rs.len() as u32);
    for r in rs {
        write_rect(w, r);
    }
}

fn read_rect(r: &mut ByteReader) -> Result<Rect, WireError> {
    Ok(Rect::new(r.f64()?, r.f64()?, r.f64()?, r.f64()?))
}

fn read_rects(r: &mut ByteReader, limit: usize) -> Result<Vec<Rect>, WireError> {
    let count = r.u32()? as usize;
    if count > limit {
        return Err(WireError::InvalidValue);
    }
    (0..count).map(|_| read_rect(r)).collect()
}

/// 帧格式：4 字节小端长度 + 消息体
pub const MAX_PAYLOAD: usize = 64 << 20;

pub fn encode_frame(message: &Message) -> Vec<u8> {
    let payload = message.encode();
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&payload);
    out
}

/// 从 TCP 字节流中切出完整帧
#[derive(Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn append(&mut self, chunk: &[u8]) -> Result<Vec<Message>, WireError> {
        self.buffer.extend_from_slice(chunk);
        let mut messages = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let length = u32::from_le_bytes(self.buffer[start..start + 4].try_into().unwrap()) as usize;
            if length > MAX_PAYLOAD {
                return Err(WireError::FrameTooLarge(length));
            }
            if self.buffer.len() - start < 4 + length {
                break;
            }
            messages.push(Message::decode(&self.buffer[start + 4..start + 4 + length])?);
            start += 4 + length;
        }
        self.buffer.drain(..start);
        Ok(messages)
    }
}
