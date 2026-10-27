use boundless_core::geometry::Rect;
use boundless_core::message::*;
use boundless_core::pairing;
use boundless_core::wire::WireError;

pub fn samples() -> Vec<Message> {
    vec![
        Message::Hello { version: 8, name: "Windows 书房".into(), channel: Channel::Control, platform: Platform::Windows },
        Message::Hello { version: 3, name: "MacBook".into(), channel: Channel::Video, platform: Platform::Mac },
        Message::Ping,
        Message::Layout { displays: vec![Rect::new(0.0, 0.0, 1512.0, 982.0), Rect::new(-1920.0, -98.5, 1920.0, 1080.0)] },
        Message::Enter { x: 12.5, y: -3.0 },
        Message::Leave,
        Message::EdgePush { x: 1512.0, y: 400.25 },
        Message::MouseMove { dx: -1.5, dy: 2.0 },
        Message::MouseButton { button: 1, down: true, click_count: 2 },
        Message::Scroll(ScrollEvent {
            delta_axis1: -3,
            delta_axis2: 1,
            point_delta_axis1: -30,
            point_delta_axis2: 10,
            fixed_delta_axis1: -2.75,
            fixed_delta_axis2: 0.5,
            is_continuous: true,
            scroll_phase: 2,
            momentum_phase: 0,
        }),
        Message::Key { code: 55, down: true, autorepeat: false },
        Message::SystemKey { data1: 0x000A_0A00 },
        Message::Clipboard(vec![
            ClipboardItem { kind: "public.utf8-plain-text".into(), data: "你好".as_bytes().to_vec() },
            ClipboardItem { kind: "public.png".into(), data: vec![0x89, 0x50, 0x4E, 0x47] },
        ]),
        Message::ReleaseAll,
        Message::WindowListRequest,
        Message::WindowList(vec![RemoteWindow { id: 42, app: "记事本".into(), title: "无标题".into(), frame: Rect::new(10.0, 20.0, 300.0, 200.0) }]),
        Message::VirtualDisplay { frame: Rect::new(1512.0, 0.0, 1920.0, 1080.0) },
        Message::VirtualReady { frame: Rect::ZERO },
        Message::VirtualWindows { capture: Rect::new(0.0, 0.0, 800.0, 600.0), windows: vec![Rect::new(1.0, 2.0, 3.0, 4.0)] },
        Message::MoveTo { x: 100.0, y: 200.0 },
        Message::MoveWindowToVirtual { window: 7 },
        Message::RecallWindows,
        Message::VideoFormat { window: 1, codec: VideoCodec::Hevc, nal_length_size: 4, parameter_sets: vec![vec![1, 2], vec![3]] },
        Message::VideoFrame { window: 1, keyframe: true, capture_time: 1_700_000_000.25, data: vec![0, 0, 0, 1, 9] },
        Message::RequestKeyframe { window: 1 },
        Message::ClockProbe { server_time: 1.5 },
        Message::ClockReply { server_time: 1.5, client_time: 2.25 },
    ]
}

#[test]
fn every_message_round_trips() {
    for m in samples() {
        assert_eq!(Message::decode(&m.encode()).unwrap(), m, "{m:?}");
    }
}

#[test]
fn golden_bytes_match_swift_layout() {
    // 与 Swift 版 ByteWriter 手算一致：tag 7 + 两个小端 f64
    let mut expected = vec![7u8];
    expected.extend_from_slice(&(-1.5f64).to_bits().to_le_bytes());
    expected.extend_from_slice(&2.0f64.to_bits().to_le_bytes());
    assert_eq!(Message::MouseMove { dx: -1.5, dy: 2.0 }.encode(), expected);

    // key：tag 10 + u16 + 两个 bool
    assert_eq!(Message::Key { code: 0x1234, down: true, autorepeat: false }.encode(), vec![10, 0x34, 0x12, 1, 0]);

    // hello v8：tag + u16 版本 + u32 长度 + UTF-8 名字 + 通道 + 平台
    assert_eq!(
        Message::Hello { version: 8, name: "PC".into(), channel: Channel::Video, platform: Platform::Windows }.encode(),
        vec![1, 8, 0, 2, 0, 0, 0, b'P', b'C', 1, 1]
    );
}

#[test]
fn old_hello_without_channel_or_platform_still_decodes() {
    // v1~v6：没有通道字段
    let v2 = vec![1, 2, 0, 6, 0, 0, 0, 0xE6, 0x97, 0xA7, 0xE7, 0x89, 0x88];
    assert_eq!(
        Message::decode(&v2).unwrap(),
        Message::Hello { version: 2, name: "旧版".into(), channel: Channel::Control, platform: Platform::Mac }
    );
    // v7：有通道没有平台
    let v7 = vec![1, 7, 0, 1, 0, 0, 0, b'M', 1];
    assert_eq!(
        Message::decode(&v7).unwrap(),
        Message::Hello { version: 7, name: "M".into(), channel: Channel::Video, platform: Platform::Mac }
    );
}

#[test]
fn rejects_malformed_messages() {
    assert_eq!(Message::decode(&[200]), Err(WireError::UnknownMessage(200)));
    assert_eq!(Message::decode(&[7, 0, 0]), Err(WireError::Truncated));
    assert_eq!(Message::decode(&[5, 0]), Err(WireError::InvalidValue));
    let mut too_many = vec![15];
    too_many.extend_from_slice(&2000u32.to_le_bytes());
    assert_eq!(Message::decode(&too_many), Err(WireError::InvalidValue));
}

#[test]
fn frame_decoder_handles_split_and_merged_chunks() {
    let msgs = samples();
    let stream: Vec<u8> = msgs.iter().flat_map(encode_frame).collect();
    for chunk_size in [1, 3, 7, 64, stream.len()] {
        let mut decoder = FrameDecoder::default();
        let mut out = Vec::new();
        for chunk in stream.chunks(chunk_size) {
            out.extend(decoder.append(chunk).unwrap());
        }
        assert_eq!(out, msgs, "chunk size {chunk_size}");
    }
}

#[test]
fn frame_decoder_rejects_oversized_frame() {
    let mut decoder = FrameDecoder::default();
    let len = (MAX_PAYLOAD as u32 + 1).to_le_bytes();
    assert_eq!(decoder.append(&len), Err(WireError::FrameTooLarge(MAX_PAYLOAD + 1)));
}

#[test]
fn pairing_codes() {
    let code = pairing::generate_code();
    assert_eq!(code.len(), 14);
    assert_eq!(pairing::normalize(&code), Some(code.clone()));
    assert_eq!(pairing::normalize(" abcd efgh-jkmn "), Some("ABCD-EFGH-JKMN".into()));
    assert_eq!(pairing::normalize("ABCD-EFGH-JKM0"), None);
    assert_eq!(pairing::normalize("ABCD-EFGH-JK"), None);
    assert_eq!(pairing::normalize("ABCD-EFGH-JKMNé"), None);
    // 同一个码大小写、分隔符不同，派生出的密钥相同
    assert_eq!(pairing::preshared_key("abcd efgh jkmn"), pairing::preshared_key("ABCD-EFGH-JKMN"));
    assert_ne!(pairing::preshared_key("ABCD-EFGH-JKMN"), pairing::preshared_key("ABCD-EFGH-JKMP"));
}
