use std::collections::HashMap;

use boundless_core::clipdata::*;
use boundless_core::dpi::{Layout, Monitor};
use boundless_core::geometry::{Point, Rect};
use boundless_core::keymap::{self, vk, WinKey, EXTENDED};
use boundless_core::message::ScrollEvent;
use boundless_core::scroll::{self, ToWindows};

// MARK: 按键

#[test]
fn modifiers_follow_command_as_control() {
    assert_eq!(keymap::mac_to_windows(55), Some(WinKey::Scan(0x1D)), "左 ⌘ → 左 Ctrl");
    assert_eq!(keymap::mac_to_windows(54), Some(WinKey::Scan(EXTENDED | 0x1D)), "右 ⌘ → 右 Ctrl");
    assert_eq!(keymap::mac_to_windows(59), Some(WinKey::Scan(EXTENDED | 0x5B)), "Control → 左 Win");
    assert_eq!(keymap::mac_to_windows(58), Some(WinKey::Scan(0x38)), "Option → Alt");
    assert_eq!(keymap::windows_to_mac(0xA2, 0x1D), Some(55), "Windows 的 Ctrl → ⌘，Ctrl+C 在 Mac 上就是 ⌘C");
    assert_eq!(keymap::windows_to_mac(0x5B, EXTENDED | 0x5B), Some(59));
    assert_eq!(keymap::mac_to_windows(63), None, "fn 不转发");
}

#[test]
fn common_keys_map_both_ways() {
    let cases: &[(u16, u16)] = &[
        (0, 0x1E),                 // A
        (8, 0x2E),                 // C
        (9, 0x2F),                 // V
        (36, 0x1C),                // Return
        (76, EXTENDED | 0x1C),     // 小键盘 Enter
        (51, 0x0E),                // Delete（退格）
        (117, EXTENDED | 0x53),    // ⌦
        (123, EXTENDED | 0x4B),    // ←
        (126, EXTENDED | 0x48),    // ↑
        (122, 0x3B),               // F1
        (111, 0x58),               // F12
        (57, 0x3A),                // Caps Lock
        (50, 0x29),                // `
    ];
    for &(mac, scan) in cases {
        assert_eq!(keymap::mac_to_windows(mac), Some(WinKey::Scan(scan)), "mac {mac}");
        assert_eq!(keymap::windows_to_mac(0, scan), Some(mac), "scan {scan:#x}");
    }
}

#[test]
fn every_mapped_scan_code_is_unique_except_keypad_equals() {
    let mut seen: HashMap<u16, u16> = HashMap::new();
    for mac in 0..=127u16 {
        if let Some(WinKey::Scan(s)) = keymap::mac_to_windows(mac) {
            if let Some(prev) = seen.insert(s, mac) {
                assert_eq!((prev, mac), (24, 81), "扫描码 {s:#x} 被 {prev} 和 {mac} 同时使用");
            }
        }
    }
    assert!(seen.len() > 100);
}

#[test]
fn windows_only_keys_use_apple_conventions() {
    assert_eq!(keymap::windows_to_mac(vk::SNAPSHOT, EXTENDED | 0x37), Some(105), "PrintScreen → F13");
    assert_eq!(keymap::windows_to_mac(vk::SCROLL, 0x46), Some(107), "ScrollLock → F14");
    assert_eq!(keymap::windows_to_mac(vk::PAUSE, 0x45), Some(113), "Pause → F15");
    assert_eq!(keymap::windows_to_mac(vk::NUMLOCK, EXTENDED | 0x45), Some(71), "NumLock → 小键盘 Clear");
}

#[test]
fn volume_keys_and_media_keys() {
    assert_eq!(keymap::mac_to_windows(72), Some(WinKey::Vk(vk::VOLUME_UP)));
    // 播放键按下：类型 16，状态 0xA
    assert_eq!(keymap::media_to_windows((16 << 16) | (0xA << 8)), Some((vk::MEDIA_PLAY_PAUSE, true)));
    assert_eq!(keymap::media_to_windows((1 << 16) | (0xB << 8)), Some((vk::VOLUME_DOWN, false)));
    assert_eq!(keymap::media_to_windows(2 << 16 | (0xA << 8)), None, "亮度键 Windows 没有对应");
    for v in [vk::VOLUME_UP, vk::VOLUME_DOWN, vk::VOLUME_MUTE, vk::MEDIA_PLAY_PAUSE, vk::MEDIA_NEXT_TRACK, vk::MEDIA_PREV_TRACK] {
        for down in [true, false] {
            let data1 = keymap::windows_to_media(v, down, false).unwrap();
            assert_eq!(keymap::media_to_windows(data1), Some((v, down)));
        }
    }
    assert_eq!(keymap::windows_to_media(0x41, true, false), None);
}

// MARK: 滚轮

#[test]
fn mac_line_scroll_becomes_whole_notches() {
    let mut t = ToWindows::default();
    let s = ScrollEvent { delta_axis1: 2, delta_axis2: -1, ..Default::default() };
    assert_eq!(t.convert(&s), (240, 120), "水平方向 macOS 正值往左、Windows 正值往右");
}

#[test]
fn mac_pixel_scroll_accumulates_fractions() {
    let mut t = ToWindows::default();
    let tiny = ScrollEvent { point_delta_axis1: 1, is_continuous: true, ..Default::default() };
    let mut total = 0;
    for _ in 0..5 {
        total += t.convert(&tiny).0;
    }
    assert_eq!(total, 6, "5 × 1.2 = 6，零头不丢");
    let s = ScrollEvent { point_delta_axis1: -100, is_continuous: true, ..Default::default() };
    assert_eq!(t.convert(&s).0, -120);
}

#[test]
fn windows_wheel_becomes_mac_scroll() {
    let notch = scroll::from_windows(120, 0, 3);
    assert!(!notch.is_continuous);
    assert_eq!(notch.delta_axis1, 3, "一格按 Windows 设置的 3 行");
    let left = scroll::from_windows(0, 120, 3);
    assert_eq!(left.delta_axis2, -3, "Windows 往右 → macOS 负值");
    let page = scroll::from_windows(-240, 0, u32::MAX);
    assert_eq!(page.delta_axis1, -6, "「一次滚动一屏」按 3 行处理");

    let smooth = scroll::from_windows(30, 0, 3);
    assert!(smooth.is_continuous, "不足一格的高精度滚轮按像素滚动");
    assert_eq!(smooth.point_delta_axis1, 25);
}

#[test]
fn scroll_round_trip_keeps_direction() {
    let mut t = ToWindows::default();
    for (v, h) in [(120, 0), (-360, 0), (0, 120), (0, -240), (40, -40)] {
        let mac = scroll::from_windows(v, h, 1);
        let (bv, bh) = t.convert(&mac);
        assert_eq!(bv.signum(), v.signum(), "{v},{h}");
        assert_eq!(bh.signum(), h.signum(), "{v},{h}");
    }
}

// MARK: 剪贴板

#[test]
fn line_endings() {
    assert_eq!(text_to_windows("a\nb\r\nc\n"), "a\r\nb\r\nc\r\n");
    assert_eq!(text_from_windows("a\r\nb\r\n"), "a\nb\n");
    assert_eq!(text_to_windows(&text_to_windows("x\ny")), "x\r\ny");
}

#[test]
fn cf_html_offsets_point_at_fragment() {
    let html = "<html><head><style>b{color:red}</style></head><body class=\"x\"><b>你好</b> world</body></html>";
    let cf = html_to_cf_html(html);
    let text = String::from_utf8(cf.clone()).unwrap();
    let field = |name: &str| -> usize {
        let at = text.find(&format!("{name}:")).unwrap() + name.len() + 1;
        text[at..at + 10].parse().unwrap()
    };
    assert_eq!(&cf[field("StartFragment")..field("EndFragment")], "<b>你好</b> world".as_bytes());
    assert_eq!(field("EndHTML"), cf.len());
    assert!(text[field("StartHTML")..].starts_with("<html><head><style>"));
    let back = cf_html_to_html(&cf).unwrap();
    assert!(back.contains("<style>b{color:red}</style>") && back.contains("<b>你好</b> world"));
}

#[test]
fn bare_fragment_is_wrapped() {
    let cf = html_to_cf_html("<i>斜体</i>");
    let back = cf_html_to_html(&cf).unwrap();
    assert_eq!(back, "<html><body><!--StartFragment--><i>斜体</i><!--EndFragment--></body></html>");
}

#[test]
fn parses_cf_html_written_by_browsers() {
    // 浏览器写的 CF_HTML 常带 SourceURL，StartHTML 可能是 -1（只给片段），末尾带 NUL
    let body = "<html><body><!--StartFragment--><a href=\"x\">链接</a><!--EndFragment--></body></html>";
    let header_len = "Version:0.9\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\nSourceURL:https://example.com/\r\n".len();
    let start = header_len + body.find("<a").unwrap();
    let end = header_len + body.find("<!--EndFragment").unwrap();
    let mut data = format!(
        "Version:0.9\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:{start:010}\r\nEndFragment:{end:010}\r\nSourceURL:https://example.com/\r\n{body}"
    )
    .into_bytes();
    data.push(0);
    assert_eq!(cf_html_to_html(&data).unwrap(), "<a href=\"x\">链接</a>");
    assert_eq!(cf_html_to_html(b"garbage"), None);
}

fn sample_png() -> Vec<u8> {
    let mut img = image::RgbaImage::new(3, 2);
    for (x, y, px) in img.enumerate_pixels_mut() {
        *px = image::Rgba([x as u8 * 80, y as u8 * 120, 200, 255]);
    }
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
    out.into_inner()
}

#[test]
fn png_dib_round_trip_keeps_pixels() {
    let png = sample_png();
    let dib = image_to_dib(&png).unwrap();
    assert_eq!(dib.len(), 40 + 3 * 2 * 4);
    let back = dib_to_png(&dib).unwrap();
    let a = image::load_from_memory(&png).unwrap().to_rgba8();
    let b = image::load_from_memory(&back).unwrap().to_rgba8();
    assert_eq!(a, b);
}

#[test]
fn dib_with_bitfield_masks_decodes() {
    // 2×1、32 位、BI_BITFIELDS，掩码紧跟在 40 字节头后面（Windows 截图工具常见）
    let mut dib = Vec::new();
    dib.extend_from_slice(&40u32.to_le_bytes());
    dib.extend_from_slice(&2i32.to_le_bytes());
    dib.extend_from_slice(&1i32.to_le_bytes());
    dib.extend_from_slice(&1u16.to_le_bytes());
    dib.extend_from_slice(&32u16.to_le_bytes());
    dib.extend_from_slice(&3u32.to_le_bytes());
    dib.extend_from_slice(&8u32.to_le_bytes());
    dib.extend_from_slice(&[0; 16]);
    for mask in [0x00FF0000u32, 0x0000FF00, 0x000000FF] {
        dib.extend_from_slice(&mask.to_le_bytes());
    }
    dib.extend_from_slice(&[0, 0, 255, 0, 0, 255, 0, 0]); // 红、绿（BGRA）
    let png = dib_to_png(&dib).unwrap();
    let img = image::load_from_memory(&png).unwrap().to_rgb8();
    assert_eq!(img.get_pixel(0, 0).0, [255, 0, 0]);
    assert_eq!(img.get_pixel(1, 0).0, [0, 255, 0]);
}

#[test]
fn tiff_converts_to_png() {
    let png = sample_png();
    let img = image::load_from_memory(&png).unwrap();
    let mut tiff = std::io::Cursor::new(Vec::new());
    img.write_to(&mut tiff, image::ImageFormat::Tiff).unwrap();
    let back = image_to_png(&tiff.into_inner()).unwrap();
    assert_eq!(image::load_from_memory(&back).unwrap().to_rgba8(), img.to_rgba8());
    assert_eq!(image_to_png(b"not an image"), None);
}

// MARK: DPI

fn mon(x: f64, y: f64, w: f64, h: f64, scale: f64) -> Monitor {
    Monitor { physical: Rect::new(x, y, w, h), scale }
}

#[test]
fn single_scaled_monitor() {
    let l = Layout::new(&[mon(0.0, 0.0, 2880.0, 1800.0, 1.5)]);
    assert_eq!(l.desktop().displays, vec![Rect::new(0.0, 0.0, 1920.0, 1200.0)]);
    assert_eq!(l.to_logical(Point::new(1500.0, 900.0)), Point::new(1000.0, 600.0));
    assert_eq!(l.to_physical(Point::new(1000.0, 600.0)), Point::new(1500.0, 900.0));
    assert_eq!(l.scale_at_physical(Point::new(10.0, 10.0)), 1.5);
}

#[test]
fn mixed_dpi_monitors_stay_adjacent() {
    // 主屏 100% 1080p，右边一块 200% 的 4K、往上错开 540 物理像素
    let l = Layout::new(&[mon(0.0, 0.0, 1920.0, 1080.0, 1.0), mon(1920.0, -540.0, 3840.0, 2160.0, 2.0)]);
    let d = l.desktop().displays;
    assert_eq!(d[1], Rect::new(1920.0, -540.0, 1920.0, 1080.0), "贴着主屏右边，不与主屏重叠");
    let p = Point::new(1920.0 + 100.0, 200.0);
    assert_eq!(l.to_logical(p), Point::new(1970.0, -540.0 + 370.0));
    assert_eq!(l.to_physical(l.to_logical(p)), p);

    // 左边一块 150% 的屏
    let l = Layout::new(&[mon(-2880.0, 0.0, 2880.0, 1620.0, 1.5), mon(0.0, 0.0, 1920.0, 1080.0, 1.0)]);
    assert_eq!(l.desktop().displays[0], Rect::new(-1920.0, 0.0, 1920.0, 1080.0));
}

#[test]
fn points_off_screen_are_clamped() {
    let l = Layout::new(&[mon(0.0, 0.0, 2000.0, 1000.0, 2.0)]);
    assert_eq!(l.to_physical(Point::new(5000.0, -10.0)), Point::new(1998.0, 0.0));
    assert_eq!(l.to_logical(Point::new(2500.0, 500.0)), Point::new(1250.0, 250.0), "屏外的点按最近的屏换算");
}
