import CoreGraphics
import Foundation

/// 滚轮事件，原样携带 CGEvent 的各滚动字段，保证触控板平滑滚动与惯性滚动在对端还原
public struct ScrollEvent: Equatable {
    public var deltaAxis1: Int32
    public var deltaAxis2: Int32
    public var pointDeltaAxis1: Int32
    public var pointDeltaAxis2: Int32
    public var fixedDeltaAxis1: Double
    public var fixedDeltaAxis2: Double
    public var isContinuous: Bool
    public var scrollPhase: Int32
    public var momentumPhase: Int32

    public init(deltaAxis1: Int32 = 0, deltaAxis2: Int32 = 0,
                pointDeltaAxis1: Int32 = 0, pointDeltaAxis2: Int32 = 0,
                fixedDeltaAxis1: Double = 0, fixedDeltaAxis2: Double = 0,
                isContinuous: Bool = false, scrollPhase: Int32 = 0, momentumPhase: Int32 = 0) {
        self.deltaAxis1 = deltaAxis1
        self.deltaAxis2 = deltaAxis2
        self.pointDeltaAxis1 = pointDeltaAxis1
        self.pointDeltaAxis2 = pointDeltaAxis2
        self.fixedDeltaAxis1 = fixedDeltaAxis1
        self.fixedDeltaAxis2 = fixedDeltaAxis2
        self.isContinuous = isContinuous
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
    }
}

/// 剪贴板中的一种数据表示（UTI + 原始数据）
public struct ClipboardItem: Equatable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// 被控端上的一个窗口
public struct RemoteWindow: Equatable {
    public var id: UInt32
    public var app: String
    public var title: String
    /// 窗口外框，被控端全局坐标（点）
    public var frame: CGRect

    public init(id: UInt32, app: String, title: String, frame: CGRect) {
        self.id = id
        self.app = app
        self.title = title
        self.frame = frame
    }
}

/// 一条连接的用途：控制通道走键鼠和剪贴板，视频通道只走虚拟屏画面，互不阻塞
public enum Channel: UInt8 {
    case control = 0
    case video = 1
}

/// 对端系统。Windows 端不支持虚拟副屏，主控端据此隐藏相关菜单
public enum Platform: UInt8 {
    case mac = 0
    case windows = 1
}

public enum VideoCodec: UInt8 {
    case h264 = 0
    case hevc = 1
}

/// 两端之间传输的全部消息
public enum Message: Equatable {
    /// 连接建立后双方互报协议版本、设备名、通道用途与系统
    case hello(version: UInt16, name: String, channel: Channel, platform: Platform = .mac)
    /// 心跳
    case ping
    /// 被控端 → 主控端：本机显示器布局（被控端坐标），连接后及屏幕变化时发送
    case layout(displays: [CGRect])
    /// 主控端 → 被控端：光标进入，落点为被控端坐标
    case enter(x: Double, y: Double)
    /// 主控端 → 被控端：控制权已收回
    case leave
    /// 被控端 → 主控端：光标被推出了被控端桌面，给出推出去的点（被控端坐标），由主控端判断能否回去
    case edgePush(x: Double, y: Double)
    case mouseMove(dx: Double, dy: Double)
    case mouseButton(button: UInt8, down: Bool, clickCount: Int32)
    case scroll(ScrollEvent)
    case key(code: UInt16, down: Bool, autorepeat: Bool)
    /// 媒体键（NX_SYSDEFINED 子类型 8）的 data1
    case systemKey(data1: Int32)
    case clipboard([ClipboardItem])
    /// 松开被控端上所有按住的键和鼠标按键
    case releaseAll

    // MARK: 虚拟副屏：被控端建一块和主控端屏幕一样大的虚拟屏，主控端按原位置显示上面的窗口

    /// 主控端 → 被控端：请求窗口列表
    case windowListRequest
    case windowList([RemoteWindow])
    /// 主控端 → 被控端：虚拟屏应放的位置（被控端坐标，大小即主控端那块屏幕的点数）；为空表示不需要虚拟屏
    case virtualDisplay(frame: CGRect)
    /// 被控端 → 主控端：虚拟屏已就绪（实际位置，被控端坐标）；为空表示已撤掉
    case virtualReady(frame: CGRect)
    /// 视频通道：画面采的是虚拟屏上哪块区域、屏上各窗口的外框（都相对虚拟屏左上角，点，窗口从前到后），
    /// 变化时在画面前发送；采集区域变了之后从下一个关键帧起生效
    case virtualWindows(capture: CGRect, windows: [CGRect])
    /// 主控端 → 被控端：把光标移到这个位置（被控端坐标），光标在虚拟屏上时用绝对位置
    case moveTo(x: Double, y: Double)
    /// 主控端 → 被控端：把窗口挪到虚拟屏上
    case moveWindowToVirtual(window: UInt32)
    /// 主控端 → 被控端：把虚拟屏上的窗口全部挪回真实屏幕
    case recallWindows
    /// 视频通道：解码参数（HEVC 为 VPS/SPS/PPS，H.264 为 SPS/PPS），每个关键帧前发送
    case videoFormat(window: UInt32, codec: VideoCodec, nalLengthSize: UInt8, parameterSets: [Data])
    /// 视频通道：一帧压缩画面（AVCC 格式，NAL 前带长度）；captureTime 是被控端采集到这帧的时刻（Unix 秒），用于统计延迟
    case videoFrame(window: UInt32, keyframe: Bool, captureTime: Double, data: Data)
    /// 主控端 → 被控端：解码出错时请求关键帧
    case requestKeyframe(window: UInt32)
    /// 对时（仅统计延迟时使用）：主控端发出自己的时间，被控端原样带回并附上自己的时间
    case clockProbe(serverTime: Double)
    case clockReply(serverTime: Double, clientTime: Double)
}

extension Message {
    private enum Tag: UInt8 {
        case hello = 1, ping, layout, enter, leave, edgePush, mouseMove, mouseButton, scroll, key, systemKey, clipboard, releaseAll
        case windowListRequest, windowList, virtualDisplay, virtualReady, virtualWindows, moveTo, moveWindowToVirtual, recallWindows
        case videoFormat, videoFrame, requestKeyframe, clockProbe, clockReply
    }

    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .hello(version, name, channel, platform):
            w.u8(Tag.hello.rawValue); w.u16(version); w.string(name); w.u8(channel.rawValue); w.u8(platform.rawValue)
        case .ping:
            w.u8(Tag.ping.rawValue)
        case let .layout(displays):
            w.u8(Tag.layout.rawValue); w.rects(displays)
        case let .enter(x, y):
            w.u8(Tag.enter.rawValue); w.f64(x); w.f64(y)
        case .leave:
            w.u8(Tag.leave.rawValue)
        case let .edgePush(x, y):
            w.u8(Tag.edgePush.rawValue); w.f64(x); w.f64(y)
        case let .mouseMove(dx, dy):
            w.u8(Tag.mouseMove.rawValue); w.f64(dx); w.f64(dy)
        case let .mouseButton(button, down, clickCount):
            w.u8(Tag.mouseButton.rawValue); w.u8(button); w.bool(down); w.i32(clickCount)
        case let .scroll(s):
            w.u8(Tag.scroll.rawValue); w.scroll(s)
        case let .key(code, down, autorepeat):
            w.u8(Tag.key.rawValue); w.u16(code); w.bool(down); w.bool(autorepeat)
        case let .systemKey(data1):
            w.u8(Tag.systemKey.rawValue); w.i32(data1)
        case let .clipboard(items):
            w.u8(Tag.clipboard.rawValue); w.u32(UInt32(items.count))
            for item in items { w.string(item.type); w.bytes(item.data) }
        case .releaseAll:
            w.u8(Tag.releaseAll.rawValue)
        case .windowListRequest:
            w.u8(Tag.windowListRequest.rawValue)
        case let .windowList(windows):
            w.u8(Tag.windowList.rawValue); w.u32(UInt32(windows.count))
            for x in windows { w.window(x) }
        case let .virtualDisplay(frame):
            w.u8(Tag.virtualDisplay.rawValue); w.rect(frame)
        case let .virtualReady(frame):
            w.u8(Tag.virtualReady.rawValue); w.rect(frame)
        case let .virtualWindows(capture, frames):
            w.u8(Tag.virtualWindows.rawValue); w.rect(capture); w.rects(frames)
        case let .moveTo(x, y):
            w.u8(Tag.moveTo.rawValue); w.f64(x); w.f64(y)
        case let .moveWindowToVirtual(window):
            w.u8(Tag.moveWindowToVirtual.rawValue); w.u32(window)
        case .recallWindows:
            w.u8(Tag.recallWindows.rawValue)
        case let .videoFormat(window, codec, nalLengthSize, parameterSets):
            w.u8(Tag.videoFormat.rawValue); w.u32(window); w.u8(codec.rawValue); w.u8(nalLengthSize)
            w.u32(UInt32(parameterSets.count))
            for p in parameterSets { w.bytes(p) }
        case let .videoFrame(window, keyframe, captureTime, data):
            w.u8(Tag.videoFrame.rawValue); w.u32(window); w.bool(keyframe); w.f64(captureTime); w.bytes(data)
        case let .requestKeyframe(window):
            w.u8(Tag.requestKeyframe.rawValue); w.u32(window)
        case let .clockProbe(serverTime):
            w.u8(Tag.clockProbe.rawValue); w.f64(serverTime)
        case let .clockReply(serverTime, clientTime):
            w.u8(Tag.clockReply.rawValue); w.f64(serverTime); w.f64(clientTime)
        }
        return w.data
    }

    init(decoding data: Data) throws {
        var r = ByteReader(data)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw WireError.unknownMessage(raw) }
        switch tag {
        case .hello:
            let version = try r.u16(), name = try r.string()
            // 旧版本的 hello 没有通道、平台字段，照样解出来，好让上层提示「版本不一致」而不是直接断开
            var channel = Channel.control, platform = Platform.mac
            if !r.isAtEnd {
                guard let c = Channel(rawValue: try r.u8()) else { throw WireError.invalidValue }
                channel = c
            }
            if !r.isAtEnd {
                guard let p = Platform(rawValue: try r.u8()) else { throw WireError.invalidValue }
                platform = p
            }
            self = .hello(version: version, name: name, channel: channel, platform: platform)
        case .ping:
            self = .ping
        case .layout:
            self = .layout(displays: try r.rects())
        case .enter:
            self = .enter(x: try r.f64(), y: try r.f64())
        case .leave:
            self = .leave
        case .edgePush:
            self = .edgePush(x: try r.f64(), y: try r.f64())
        case .mouseMove:
            self = .mouseMove(dx: try r.f64(), dy: try r.f64())
        case .mouseButton:
            self = .mouseButton(button: try r.u8(), down: try r.bool(), clickCount: try r.i32())
        case .scroll:
            self = .scroll(try r.scroll())
        case .key:
            self = .key(code: try r.u16(), down: try r.bool(), autorepeat: try r.bool())
        case .systemKey:
            self = .systemKey(data1: try r.i32())
        case .clipboard:
            let count = Int(try r.u32())
            var items: [ClipboardItem] = []
            for _ in 0..<count { items.append(ClipboardItem(type: try r.string(), data: try r.bytes())) }
            self = .clipboard(items)
        case .releaseAll:
            self = .releaseAll
        case .windowListRequest:
            self = .windowListRequest
        case .windowList:
            let count = Int(try r.u32())
            guard count <= 1024 else { throw WireError.invalidValue }
            var windows: [RemoteWindow] = []
            for _ in 0..<count {
                windows.append(try r.window())
            }
            self = .windowList(windows)
        case .virtualDisplay:
            self = .virtualDisplay(frame: try r.rect())
        case .virtualReady:
            self = .virtualReady(frame: try r.rect())
        case .virtualWindows:
            self = .virtualWindows(capture: try r.rect(), windows: try r.rects(limit: 1024))
        case .moveTo:
            self = .moveTo(x: try r.f64(), y: try r.f64())
        case .moveWindowToVirtual:
            self = .moveWindowToVirtual(window: try r.u32())
        case .recallWindows:
            self = .recallWindows
        case .videoFormat:
            let window = try r.u32()
            guard let codec = VideoCodec(rawValue: try r.u8()) else { throw WireError.invalidValue }
            let nalLengthSize = try r.u8()
            let count = Int(try r.u32())
            guard count <= 16 else { throw WireError.invalidValue }
            var sets: [Data] = []
            for _ in 0..<count { sets.append(try r.bytes()) }
            self = .videoFormat(window: window, codec: codec, nalLengthSize: nalLengthSize, parameterSets: sets)
        case .videoFrame:
            self = .videoFrame(window: try r.u32(), keyframe: try r.bool(), captureTime: try r.f64(), data: try r.bytes())
        case .requestKeyframe:
            self = .requestKeyframe(window: try r.u32())
        case .clockProbe:
            self = .clockProbe(serverTime: try r.f64())
        case .clockReply:
            self = .clockReply(serverTime: try r.f64(), clientTime: try r.f64())
        }
        guard r.isAtEnd else { throw WireError.invalidValue }
    }
}

private extension ByteWriter {
    mutating func rect(_ r: CGRect) { f64(r.minX); f64(r.minY); f64(r.width); f64(r.height) }
    mutating func window(_ x: RemoteWindow) { u32(x.id); string(x.app); string(x.title); rect(x.frame) }

    mutating func rects(_ rs: [CGRect]) {
        u32(UInt32(rs.count))
        for r in rs { rect(r) }
    }

    mutating func scroll(_ s: ScrollEvent) {
        i32(s.deltaAxis1); i32(s.deltaAxis2)
        i32(s.pointDeltaAxis1); i32(s.pointDeltaAxis2)
        f64(s.fixedDeltaAxis1); f64(s.fixedDeltaAxis2)
        bool(s.isContinuous); i32(s.scrollPhase); i32(s.momentumPhase)
    }
}

private extension ByteReader {
    mutating func rect() throws -> CGRect {
        CGRect(x: try f64(), y: try f64(), width: try f64(), height: try f64())
    }

    mutating func rects(limit: Int = 64) throws -> [CGRect] {
        let count = Int(try u32())
        guard count <= limit else { throw WireError.invalidValue }
        var rs: [CGRect] = []
        for _ in 0..<count { rs.append(try rect()) }
        return rs
    }

    mutating func window() throws -> RemoteWindow {
        RemoteWindow(id: try u32(), app: try string(), title: try string(), frame: try rect())
    }

    mutating func scroll() throws -> ScrollEvent {
        ScrollEvent(deltaAxis1: try i32(), deltaAxis2: try i32(),
                    pointDeltaAxis1: try i32(), pointDeltaAxis2: try i32(),
                    fixedDeltaAxis1: try f64(), fixedDeltaAxis2: try f64(),
                    isContinuous: try bool(), scrollPhase: try i32(), momentumPhase: try i32())
    }
}

/// 帧格式：4 字节小端长度 + 消息体
public enum Frame {
    public static let maxPayload = 64 << 20

    public static func encode(_ message: Message) -> Data {
        let payload = message.encoded()
        var w = ByteWriter()
        w.u32(UInt32(payload.count))
        return w.data + payload
    }
}

/// 从 TCP 字节流中切出完整帧
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Message] {
        buffer.append(chunk)
        var messages: [Message] = []
        while buffer.count >= 4 {
            let s = buffer.startIndex
            let length = Int(buffer[s]) | Int(buffer[s + 1]) << 8 | Int(buffer[s + 2]) << 16 | Int(buffer[s + 3]) << 24
            guard length <= Frame.maxPayload else { throw WireError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: s + 4..<s + 4 + length)
            buffer = buffer.subdata(in: s + 4 + length..<buffer.endIndex)
            messages.append(try Message(decoding: payload))
        }
        return messages
    }
}
