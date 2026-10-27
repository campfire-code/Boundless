//! Windows 系统接口的薄封装

pub mod clipboard;
pub mod displays;
pub mod hooks;
pub mod inject;
pub mod system;

/// Rust 字符串 → 以 NUL 结尾的 UTF-16
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// 以 NUL 结尾（或填满）的 UTF-16 缓冲区 → Rust 字符串
pub fn from_wide(buf: &[u16]) -> String {
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..n])
}

/// 把字符串拷进定长 UTF-16 数组（托盘提示等），超长截断
pub fn copy_wide(dst: &mut [u16], s: &str) {
    let src: Vec<u16> = s.encode_utf16().take(dst.len() - 1).collect();
    dst[..src.len()].copy_from_slice(&src);
    dst[src.len()] = 0;
}

#[cfg(test)]
mod tests {
    use boundless_core::keymap::{self, WinKey};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{MapVirtualKeyW, MAPVK_VSC_TO_VK_EX};

    /// 用 Windows 自己的键盘布局表核对扫描码表（CI 上是美式布局）
    #[test]
    fn scan_codes_match_windows_layout() {
        let cases: &[(u16, u32)] = &[
            (0, 'A' as u32), (1, 'S' as u32), (2, 'D' as u32), (3, 'F' as u32), (4, 'H' as u32), (5, 'G' as u32),
            (6, 'Z' as u32), (7, 'X' as u32), (8, 'C' as u32), (9, 'V' as u32), (11, 'B' as u32), (12, 'Q' as u32),
            (13, 'W' as u32), (14, 'E' as u32), (15, 'R' as u32), (16, 'Y' as u32), (17, 'T' as u32), (31, 'O' as u32),
            (32, 'U' as u32), (34, 'I' as u32), (35, 'P' as u32), (37, 'L' as u32), (38, 'J' as u32), (40, 'K' as u32),
            (45, 'N' as u32), (46, 'M' as u32),
            (18, '1' as u32), (19, '2' as u32), (20, '3' as u32), (21, '4' as u32), (23, '5' as u32), (22, '6' as u32),
            (26, '7' as u32), (28, '8' as u32), (25, '9' as u32), (29, '0' as u32),
            (36, 0x0D), (48, 0x09), (49, 0x20), (51, 0x08), (53, 0x1B), (57, 0x14),
            (55, 0xA2), (54, 0xA3), (59, 0x5B), (62, 0x5C), (58, 0xA4), (61, 0xA5), (56, 0xA0), (60, 0xA1),
            (122, 0x70), (120, 0x71), (99, 0x72), (118, 0x73), (96, 0x74), (97, 0x75), (98, 0x76), (100, 0x77),
            (101, 0x78), (109, 0x79), (103, 0x7A), (111, 0x7B),
            (123, 0x25), (126, 0x26), (124, 0x27), (125, 0x28),
            (115, 0x24), (119, 0x23), (116, 0x21), (121, 0x22), (117, 0x2E), (114, 0x2D),
        ];
        for &(mac, expected_vk) in cases {
            let Some(WinKey::Scan(scan)) = keymap::mac_to_windows(mac) else { panic!("mac {mac} 没有扫描码") };
            // MAPVK_VSC_TO_VK_EX 接受 0xE0xx 形式的扩展扫描码，并区分左右修饰键
            let vk = unsafe { MapVirtualKeyW(scan as u32, MAPVK_VSC_TO_VK_EX) };
            assert_eq!(vk, expected_vk, "mac {mac} → 扫描码 {scan:#x} → VK {vk:#x}，应为 {expected_vk:#x}");
        }
    }

    #[test]
    fn system_queries_do_not_fail() {
        assert!(!super::system::computer_name().is_empty());
        assert!(super::system::data_dir().ends_with("Boundless"));
        assert!(!super::system::is_wired_interface(u32::MAX));
        assert!(super::system::wheel_lines() > 0);
        assert!(!super::displays::layout().is_empty(), "至少要能枚举到一块显示器");
    }
}
