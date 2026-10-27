import AppKit
import AVFoundation
import BoundlessCore

/// 主控端：在虚拟屏对应的那块屏幕上，按原位置显示被控端虚拟屏上的窗口。
/// 用一个铺满屏幕、透明、不接收鼠标的窗口：只在有窗口的地方露出画面，键鼠由主控端的事件截获层判断后转发
final class VirtualOverlay {
    /// 对应的主控端屏幕（全局坐标，y 向下）
    let screen: CGRect
    var onKeyframeNeeded: (() -> Void)?
    /// 被控端时钟减本机时钟，用来把采集时间换算到本机；未知时按 0
    var clockOffset: Double?

    private let window: OverlayWindow
    private let view: OverlayView
    /// 虚拟屏上各窗口的外框（主控端坐标）
    private var regions: [CGRect] = []
    /// 盖在显示窗口上面的本机窗口、菜单栏、程序坞（主控端坐标），这些地方留给本机
    private var covering: [CGRect] = []
    private var coverTimer: Timer?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var waitingForKeyframe = true
    private var stats: FrameStats?
    private var statsTimer: Timer?

    init(screen: CGRect, logStats: Bool) {
        self.screen = screen
        stats = logStats ? FrameStats() : nil
        view = OverlayView()
        window = OverlayWindow(contentRect: VirtualOverlay.cocoa(screen), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = view
        window.setFrame(VirtualOverlay.cocoa(screen), display: false)
        window.orderFrontRegardless()
        coverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshCovering() }
        if stats != nil {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, let snapshot = self.stats?.take(now: CACurrentMediaTime()) else { return }
                let clock = self.clockOffset.map { String(format: "已按时钟差 %+.1fms 校正", $0 * 1000) } ?? "未校正时钟差"
                NSLog("Boundless 主控端统计：采集→显示 \(snapshot.summary)（\(clock)）窗口 \(self.regions.count) 个")
            }
        }
    }

    func close() {
        coverTimer?.invalidate()
        statsTimer?.invalidate()
        window.close()
    }

    /// 点中了上面的窗口：提到本机所有窗口之前，并让无界成为前台应用，本机其他应用不再显示为激活
    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        covering = []
    }

    /// 主控端坐标上的点是否落在显示出来的某个窗口上，且没被本机的东西挡住
    func hit(_ p: CGPoint) -> Bool {
        regions.contains { $0.contains(p) } && !covering.contains { $0.contains(p) }
    }

    /// 画面采集区域变了要等新的关键帧到了再换，在那之前收到的还是旧区域的画面
    private var pendingCapture: CGRect?

    private func setRegions(_ rects: [CGRect], capture: CGRect) {
        regions = rects.map { $0.offsetBy(dx: screen.minX, dy: screen.minY) }
        if capture != view.capture { pendingCapture = capture }
        view.setMask(rects)
    }

    /// 在显示窗口上面的本机窗口。程序坞是一个盖满屏幕的透明层，它占的地方按屏幕可用区域算
    private func refreshCovering() {
        let own = getpid()
        var rects: [CGRect] = []
        if let list = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(window.windowNumber)) as? [[CFString: Any]] {
            for entry in list {
                guard (entry[kCGWindowAlpha] as? Double ?? 1) > 0, (entry[kCGWindowOwnerPID] as? pid_t) != own,
                      let bounds = entry[kCGWindowBounds] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds), frame.intersects(screen),
                      !(frame.width >= screen.width && frame.height >= screen.height) else { continue }
                rects.append(frame)
            }
        }
        if let ns = NSScreen.screens.first(where: { VirtualOverlay.cocoa(screen) == $0.frame }) {
            let v = VirtualOverlay.global(ns.visibleFrame)
            if v.minY > screen.minY { rects.append(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: v.minY - screen.minY)) }
            if v.maxY < screen.maxY { rects.append(CGRect(x: screen.minX, y: v.maxY, width: screen.width, height: screen.maxY - v.maxY)) }
            if v.minX > screen.minX { rects.append(CGRect(x: screen.minX, y: screen.minY, width: v.minX - screen.minX, height: screen.height)) }
            if v.maxX < screen.maxX { rects.append(CGRect(x: v.maxX, y: screen.minY, width: screen.maxX - v.maxX, height: screen.height)) }
        }
        covering = rects
    }

    /// 全局坐标（y 向下，主屏左上角为原点）↔ Cocoa 坐标（y 向上，主屏左下角为原点）
    private static func cocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY, width: r.width, height: r.height)
    }

    private static func global(_ r: CGRect) -> CGRect { cocoa(r) }

    // MARK: - 解码显示

    func display(_ message: Message) {
        switch message {
        case let .virtualWindows(capture, rects):
            setRegions(rects, capture: capture)
        case let .videoFormat(id, codec, nalLengthSize, sets) where id == VirtualDisplay.streamID:
            guard sets != parameterSets else { return }
            guard let desc = VirtualOverlay.makeFormat(codec: codec, nalLengthSize: Int32(nalLengthSize), sets: sets) else {
                NSLog("Boundless 主控端：无法解析视频参数")
                return
            }
            parameterSets = sets
            format = desc
            view.renderer.flush()
            waitingForKeyframe = true
        case let .videoFrame(id, keyframe, captureTime, data) where id == VirtualDisplay.streamID:
            enqueue(data, keyframe: keyframe)
            stats?.record(at: CACurrentMediaTime(), bytes: data.count,
                          latency: Date().timeIntervalSince1970 - (captureTime - (clockOffset ?? 0)))
        default:
            break
        }
    }

    private func enqueue(_ data: Data, keyframe: Bool) {
        if view.renderer.status == .failed {
            NSLog("Boundless 主控端：解码失败 \(view.renderer.error.map { "\($0)" } ?? "")，请求关键帧")
            view.renderer.flush()
            waitingForKeyframe = true
            onKeyframeNeeded?()
        }
        guard let format else { return }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }
        if keyframe, let capture = pendingCapture {
            pendingCapture = nil
            view.capture = capture
        }
        guard let sample = VirtualOverlay.makeSample(data, format: format) else { return }
        view.renderer.enqueue(sample)
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        // 不按时间戳排队，收到就显示
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private static func makeFormat(codec: VideoCodec, nalLengthSize: Int32, sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        // 参数集指针在调用期间必须一直有效，先拷到连续分配的内存里
        let buffers = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(d.count, 1))
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var desc: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: nalLengthSize, extensions: nil, formatDescriptionOut: &desc)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: nalLengthSize, formatDescriptionOut: &desc)
        }
        return status == noErr ? desc : nil
    }
}

/// 无边框窗口默认不能成为主窗口，这里放开，好让无界在前台时本机其他应用显示为未激活
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 整块屏的画面，用遮罩只露出有窗口的地方
private final class OverlayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let mask = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        displayLayer.videoGravity = .resize
        displayLayer.mask = mask
        mask.path = CGPath(rect: .zero, transform: nil)
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 创建") }

    var renderer: SampleRenderer { SampleRenderer(layer: displayLayer) }

    /// 画面对应虚拟屏上的哪块区域（相对左上角，点）；画面只铺在这块上
    var capture = CGRect.zero {
        didSet { needsLayout = true }
    }
    private var rects: [CGRect] = []

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 视图 y 向上，采集区域 y 向下，翻过来
        let c = capture.isEmpty ? CGRect(origin: .zero, size: bounds.size) : capture
        displayLayer.frame = CGRect(x: c.minX, y: bounds.height - c.maxY, width: c.width, height: c.height)
        mask.frame = displayLayer.bounds
        mask.path = maskPath()
        CATransaction.commit()
    }

    /// rects 相对屏幕左上角（y 向下）；遮罩画在画面图层里，换算到采集区域内、y 向上。窗口是圆角的，遮罩也按圆角裁
    func setMask(_ rects: [CGRect]) {
        self.rects = rects
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = maskPath()
        CATransaction.commit()
    }

    private func maskPath() -> CGPath {
        let path = CGMutablePath()
        let c = capture.isEmpty ? CGRect(origin: .zero, size: bounds.size) : capture
        for r in rects {
            let flipped = CGRect(x: r.minX - c.minX, y: c.maxY - r.maxY, width: r.width, height: r.height)
            let radius = min(r.width, r.height) >= 120 ? OverlayView.windowCornerRadius : 6
            path.addRoundedRect(in: flipped, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2))
        }
        return path
    }

    /// 系统窗口的圆角半径（点），macOS 26 起明显变大
    private static let windowCornerRadius: CGFloat = {
        if #available(macOS 26, *) { return 16 }
        return 10
    }()
}

/// AVSampleBufferDisplayLayer 在 macOS 14 起把入队接口挪到了 sampleBufferRenderer，这里统一一下
struct SampleRenderer {
    let layer: AVSampleBufferDisplayLayer

    var status: AVQueuedSampleBufferRenderingStatus {
        if #available(macOS 14, *) { return layer.sampleBufferRenderer.status }
        return layer.status
    }

    var error: Error? {
        if #available(macOS 14, *) { return layer.sampleBufferRenderer.error }
        return layer.error
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if #available(macOS 14, *) { layer.sampleBufferRenderer.enqueue(sample) } else { layer.enqueue(sample) }
    }

    func flush() {
        if #available(macOS 14, *) { layer.sampleBufferRenderer.flush() } else { layer.flush() }
    }
}
