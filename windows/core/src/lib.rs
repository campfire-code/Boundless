//! 无界的跨平台部分。这里的代码不依赖 Windows，能在 macOS 上跑测试，并与 Swift 版做互通测试

pub mod arrangement;
pub mod client_cursor;
pub mod clipdata;
pub mod discovery;
pub mod dpi;
pub mod geometry;
pub mod keycodes;
pub mod keymap;
pub mod link;
pub mod message;
pub mod pairing;
pub mod scroll;
pub mod server_switch;
pub mod wire;

/// 与 Mac 版 Transport.protocolVersion 保持一致，两端不同则拒绝连接
pub const PROTOCOL_VERSION: u16 = 8;
/// Bonjour / mDNS 服务类型
pub const SERVICE_TYPE: &str = "_boundless._tcp.local.";
