//! macOS 键码 ↔ Windows 扫描码（Set 1，扩展键带 0xE000）。
//! 修饰键按「⌘ 当 Ctrl 用」对应：⌘ ↔ Ctrl，Mac 的 Control ↔ Win 键，Option ↔ Alt，
//! 这样 ⌘C/⌘V 在 Windows 上就是复制粘贴，反过来 Windows 键盘的 Ctrl+C 在 Mac 上就是 ⌘C

/// Windows 端要注入或从钩子里读到的一个键
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WinKey {
    /// 扫描码，扩展键为 0xE000 | 码
    Scan(u16),
    /// 没有稳定扫描码的键（媒体键、音量键）用虚拟键码
    Vk(u16),
}

pub const EXTENDED: u16 = 0xE000;

pub mod vk {
    pub const VOLUME_MUTE: u16 = 0xAD;
    pub const VOLUME_DOWN: u16 = 0xAE;
    pub const VOLUME_UP: u16 = 0xAF;
    pub const MEDIA_NEXT_TRACK: u16 = 0xB0;
    pub const MEDIA_PREV_TRACK: u16 = 0xB1;
    pub const MEDIA_PLAY_PAUSE: u16 = 0xB3;
    pub const SNAPSHOT: u16 = 0x2C;
    pub const SCROLL: u16 = 0x91;
    pub const PAUSE: u16 = 0x13;
    pub const NUMLOCK: u16 = 0x90;
}

/// (macOS 键码, Windows 扫描码)。同一个扫描码出现多次时，反查取第一个
const TABLE: &[(u16, u16)] = &[
    // 字母
    (0, 0x1E), (1, 0x1F), (2, 0x20), (3, 0x21), (4, 0x23), (5, 0x22), (6, 0x2C), (7, 0x2D),
    (8, 0x2E), (9, 0x2F), (11, 0x30), (12, 0x10), (13, 0x11), (14, 0x12), (15, 0x13), (16, 0x15),
    (17, 0x14), (31, 0x18), (32, 0x16), (34, 0x17), (35, 0x19), (37, 0x26), (38, 0x24), (40, 0x25),
    (45, 0x31), (46, 0x32),
    // 数字行
    (18, 0x02), (19, 0x03), (20, 0x04), (21, 0x05), (23, 0x06), (22, 0x07), (26, 0x08), (28, 0x09),
    (25, 0x0A), (29, 0x0B), (27, 0x0C), (24, 0x0D),
    // 符号
    (33, 0x1A), (30, 0x1B), (41, 0x27), (39, 0x28), (42, 0x2B), (43, 0x33), (47, 0x34), (44, 0x35),
    // 数字 1 左边的键（ANSI 的 ` 键）对应 0x29；ISO 键盘左 Shift 右边的键（kVK_ISO_Section）对应 0x56
    (50, 0x29), (10, 0x56),
    // 编辑与控制
    (36, 0x1C), (48, 0x0F), (49, 0x39), (51, 0x0E), (53, 0x01), (57, 0x3A),
    // 修饰键：⌘ → Ctrl，Control → Win，Option → Alt
    (55, 0x1D), (54, EXTENDED | 0x1D), (59, EXTENDED | 0x5B), (62, EXTENDED | 0x5C),
    (58, 0x38), (61, EXTENDED | 0x38), (56, 0x2A), (60, 0x36),
    // 功能键
    (122, 0x3B), (120, 0x3C), (99, 0x3D), (118, 0x3E), (96, 0x3F), (97, 0x40), (98, 0x41), (100, 0x42),
    (101, 0x43), (109, 0x44), (103, 0x57), (111, 0x58), (105, 0x64), (107, 0x65), (113, 0x66), (106, 0x67),
    (64, 0x68), (79, 0x69), (80, 0x6A), (90, 0x6B),
    // 导航
    (114, EXTENDED | 0x52), (117, EXTENDED | 0x53), (115, EXTENDED | 0x47), (119, EXTENDED | 0x4F),
    (116, EXTENDED | 0x49), (121, EXTENDED | 0x51),
    (123, EXTENDED | 0x4B), (124, EXTENDED | 0x4D), (125, EXTENDED | 0x50), (126, EXTENDED | 0x48),
    (110, EXTENDED | 0x5D),
    // 小键盘
    (82, 0x52), (83, 0x4F), (84, 0x50), (85, 0x51), (86, 0x4B), (87, 0x4C), (88, 0x4D), (89, 0x47),
    (91, 0x48), (92, 0x49), (65, 0x53), (67, 0x37), (69, 0x4E), (78, 0x4A), (75, EXTENDED | 0x35),
    (76, EXTENDED | 0x1C), (81, 0x0D),
    // 日文键盘：¥、_、小键盘逗号、英数（→ 無変換）、かな（→ 変換）
    (93, 0x7D), (94, 0x73), (95, 0x7E), (102, 0x7B), (104, 0x79),
];

/// macOS 键码 → Windows 要注入的键；没有对应的键（fn、小键盘 Clear 等）返回 None
pub fn mac_to_windows(code: u16) -> Option<WinKey> {
    match code {
        72 => return Some(WinKey::Vk(vk::VOLUME_UP)),
        73 => return Some(WinKey::Vk(vk::VOLUME_DOWN)),
        74 => return Some(WinKey::Vk(vk::VOLUME_MUTE)),
        _ => {}
    }
    TABLE.iter().find(|(m, _)| *m == code).map(|(_, s)| WinKey::Scan(*s))
}

/// Windows 低级键盘钩子读到的键 → macOS 键码。scan 已合并扩展位
pub fn windows_to_mac(vk_code: u16, scan: u16) -> Option<u16> {
    // 这几个键的扫描码不可靠（Pause 和 NumLock 共用 0x45 等），按虚拟键码判断。按苹果键盘的习惯对应
    match vk_code {
        vk::SNAPSHOT => return Some(105),
        vk::SCROLL => return Some(107),
        vk::PAUSE => return Some(113),
        vk::NUMLOCK => return Some(71),
        _ => {}
    }
    // 日文键盘的「カタカナ/ひらがな」键也当かな
    if scan == 0x70 {
        return Some(104);
    }
    TABLE.iter().find(|(_, s)| *s == scan).map(|(m, _)| *m)
}

// MARK: 媒体键：macOS NX_SYSDEFINED 子类型 8 的 data1 ↔ Windows 虚拟键码

const NX_SOUND_UP: i32 = 0;
const NX_SOUND_DOWN: i32 = 1;
const NX_MUTE: i32 = 7;
const NX_PLAY: i32 = 16;
const NX_NEXT: i32 = 17;
const NX_PREVIOUS: i32 = 18;
const NX_FAST: i32 = 19;
const NX_REWIND: i32 = 20;

/// data1 → (虚拟键码, 是否按下)；亮度等 Windows 没有对应的键返回 None
pub fn media_to_windows(data1: i32) -> Option<(u16, bool)> {
    let key_type = (data1 >> 16) & 0xFFFF;
    let state = (data1 >> 8) & 0xFF;
    let down = state == 0xA;
    let vk = match key_type {
        NX_SOUND_UP => vk::VOLUME_UP,
        NX_SOUND_DOWN => vk::VOLUME_DOWN,
        NX_MUTE => vk::VOLUME_MUTE,
        NX_PLAY => vk::MEDIA_PLAY_PAUSE,
        NX_NEXT | NX_FAST => vk::MEDIA_NEXT_TRACK,
        NX_PREVIOUS | NX_REWIND => vk::MEDIA_PREV_TRACK,
        _ => return None,
    };
    Some((vk, down))
}

/// Windows 媒体键 → data1；不是媒体键返回 None
pub fn windows_to_media(vk_code: u16, down: bool, autorepeat: bool) -> Option<i32> {
    let key_type = match vk_code {
        vk::VOLUME_UP => NX_SOUND_UP,
        vk::VOLUME_DOWN => NX_SOUND_DOWN,
        vk::VOLUME_MUTE => NX_MUTE,
        vk::MEDIA_PLAY_PAUSE => NX_PLAY,
        vk::MEDIA_NEXT_TRACK => NX_NEXT,
        vk::MEDIA_PREV_TRACK => NX_PREVIOUS,
        _ => return None,
    };
    let state = if down { 0xA } else { 0xB };
    Some((key_type << 16) | (state << 8) | autorepeat as i32)
}
