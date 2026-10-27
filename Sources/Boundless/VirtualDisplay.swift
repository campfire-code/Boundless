import AppKit
import BoundlessCore
import ScreenCaptureKit
import VirtualDisplayAPI

/// 被控端：虚拟副屏。按主控端屏幕的大小建一块看不见的 HiDPI 屏幕，摆在主控端所在的一侧，
/// 窗口拖过去就是系统原生地挪到了这块屏上；采集编码发给主控端，并上报屏上各窗口的位置。
/// 静止时只采窗口所在的区域、用原生倍率（和本机一样清楚），拖动窗口时改采整屏
final class VirtualDisplay: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 视频消息里虚拟屏画面用的编号
    static let streamID: UInt32 = 0
    /// 本程序建的虚拟屏，计算本机屏幕布局时排除
    private(set) static var ownedIDs = Set<CGDirectDisplayID>()

    let displayID: CGDirectDisplayID
    /// 当前位置（本机坐标，点）
    private(set) var frame: CGRect
    /// 走视频通道的消息，在采集线程调用
    var sendVideo: ((Message) -> Void)?
    /// 视频通道当前积压的消息数
    var videoBacklog: (() -> Int)?
    /// 走有线：码率可以给高些（换了线路会重连、重开采集，按新线路重建编码器）
    var wired = false
    /// 采集中断，参数是原因
    var onStreamEnded: ((String) -> Void)?
    /// 屏上当前有几个窗口
    private(set) var windowCount = 0

    private let display: CGVirtualDisplay
    private let queue = DispatchQueue(label: "boundless.virtual")
    private var stream: SCStream?
    private var target: SCDisplay?
    /// 当前这路采集的区域（相对虚拟屏左上角，点）
    private var captureRect: CGRect?
    private var stopped = false
    private var regionTimer: Timer?
    // 以下只在采集线程访问
    private var encoder: VideoEncoder?
    /// 采集线程认的当前那路采集；换区域重启后旧的那路还会送来几帧，丢掉
    private var activeStream: SCStream?
    private var activeCapture = CGRect.zero
    private var captureFrame = CGRect.zero
    private var regions: [CGRect] = []
    private var lastRegionChange = 0.0
    private var excludedPIDs: [pid_t: Bool] = [:]
    /// 最后一帧画面：画面停下后再编几遍，把滚动时为守码率降下去的画质补回来
    private var lastPixels: CVPixelBuffer?
    private var frameSerial = 0

    /// 每帧最多采集这么多像素（2880×1620）：再大采集和编码就跟不上 60fps
    private static let maxPixels = 2880 * 1620
    /// 积压超过这么多帧就丢帧，宁可跳帧也不让延迟越攒越大
    private static let maxBacklog = 2
    /// 不算作「窗口」的系统进程：程序坞、控制中心、通知中心等
    private static let systemBundles: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.WindowManager", "com.apple.systemuiserver",
    ]

    private var stats: FrameStats?
    /// 系统交出这一帧时已过去多久（采集排队），与编码耗时分开看
    private var waitStats: FrameStats?
    private let statsLock = NSLock()
    private var statsTimer: Timer?

    /// size 为点数，实际像素是两倍
    init?(size: CGSize, logStats: Bool) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "无界副屏"
        descriptor.maxPixelsWide = UInt32(size.width * 2)
        descriptor.maxPixelsHigh = UInt32(size.height * 2)
        // 按 Retina 约 220 ppi 估物理尺寸
        descriptor.sizeInMillimeters = CGSize(width: size.width * 2 / 220 * 25.4, height: size.height * 2 / 220 * 25.4)
        descriptor.vendorID = 0x426C
        descriptor.productID = 0x4E4A
        descriptor.serialNum = 1
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(size.width), height: UInt32(size.height), refreshRate: 60)]
        guard display.apply(settings) else { return nil }
        self.display = display
        displayID = display.displayID
        frame = CGRect(origin: .zero, size: size)
        stats = logStats ? FrameStats() : nil
        waitStats = logStats ? FrameStats() : nil
        super.init()
        VirtualDisplay.ownedIDs.insert(displayID)
        NSLog("Boundless 被控端：已创建虚拟屏 \(displayID) \(Int(size.width))×\(Int(size.height))")
    }

    /// 等系统把虚拟屏加进来，再挪到指定位置（系统会自动吸附到贴边），完成后回报实际位置
    func place(at origin: CGPoint, completion: @escaping (CGRect) -> Void) {
        waitUntilOnline(tries: 40) { [weak self] in
            guard let self, !self.stopped else { return }
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayOrigin(config, self.displayID, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
            let error = CGCompleteDisplayConfiguration(config, .forAppOnly)
            if error != .success { NSLog("Boundless 被控端：摆放虚拟屏失败 \(error.rawValue)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.stopped else { return }
                self.frame = CGDisplayBounds(self.displayID)
                completion(self.frame)
            }
        }
    }

    private func waitUntilOnline(tries: Int, then body: @escaping () -> Void) {
        if CGDisplayBounds(displayID).width > 0 || tries <= 0 { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitUntilOnline(tries: tries - 1, then: body) }
    }

    /// 撤掉虚拟屏：系统会把上面的窗口挪回真实屏幕
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopStream()
        VirtualDisplay.ownedIDs.remove(displayID)
        NSLog("Boundless 被控端：撤掉虚拟屏 \(displayID)")
    }

    func requestKeyframe() {
        queue.async { self.encoder?.requestKeyframe() }
    }

    /// 本机坐标上的点是否在虚拟屏上
    func contains(_ p: CGPoint) -> Bool {
        frame.contains(p)
    }

    /// 把窗口挪到虚拟屏中间，顶部留出菜单栏
    func moveIn(_ id: UInt32, pid: pid_t, size: CGSize) {
        let x = frame.minX + max((frame.width - size.width) / 2, 0)
        let y = frame.minY + max(min((frame.height - size.height) / 2, frame.height - size.height), 40)
        LocalWindows.move(id, pid: pid, to: CGPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: - 采集

    func startStream() {
        guard !stopped, stream == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onStreamEnded?("被控端未授予「屏幕录制」权限，请在被控端授权后重试")
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.stream == nil else { return }
                guard let target = content?.displays.first(where: { $0.displayID == self.displayID }) else {
                    self.onStreamEnded?(error.map { "无法采集虚拟屏：\($0.localizedDescription)" } ?? "找不到虚拟屏")
                    return
                }
                self.startStream(target)
            }
        }
    }

    private func startStream(_ target: SCDisplay) {
        self.target = target
        let frame = self.frame
        queue.async { self.captureFrame = frame }
        // 画面不变时不出帧，窗口关掉、挪走也要及时告诉主控端；顺带按窗口动没动决定采集区域
        regionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.adjustCapture() }
        if stats != nil {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.logStats() }
        }
        let windows = queue.sync { windowRegions() }
        begin(StreamGeometry.captureRect(windows: windows, screen: frame.size, moving: false, current: nil))
    }

    /// 窗口在动（最近 0.6 秒外框变过）就采整屏，停下来再收紧到窗口所在区域
    private func adjustCapture() {
        guard !stopped, stream != nil else { return }
        let (windows, changed) = queue.sync { () -> ([CGRect], Double) in
            updateRegions()
            return (regions, lastRegionChange)
        }
        let moving = CACurrentMediaTime() - changed < 0.6
        let desired = StreamGeometry.captureRect(windows: windows, screen: frame.size, moving: moving, current: captureRect)
        if desired != captureRect { begin(desired) }
    }

    /// 按新区域开一路采集，旧的那路停掉。新的一路用新编码器，第一帧是关键帧，主控端收到它时换到新区域
    private func begin(_ rect: CGRect) {
        guard let target else { return }
        let native = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 2
        // 4K 整屏采集时系统交帧和编码都跟不上 60fps（实测约 45fps、延迟 50ms），像素超出预算时降倍率；
        // 调试参数 streamScale 可强制倍率
        let forced = UserDefaults.standard.double(forKey: "streamScale")
        let scale = forced > 0 ? forced : StreamGeometry.captureScale(points: rect.size, native: native, maxPixels: VirtualDisplay.maxPixels)
        let size = StreamGeometry.pixelSize(points: rect.size, scale: scale)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        // 留一帧给补清晰用
        config.queueDepth = 5
        let next = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: config, delegate: self)
        do {
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            onStreamEnded?("无法采集虚拟屏：\(error.localizedDescription)")
            return
        }
        stream?.stopCapture { _ in }
        stream = next
        captureRect = rect
        queue.async {
            self.activeStream = next
            self.activeCapture = rect
            self.encoder = nil
            self.lastPixels = nil
            // 带着新区域重发一次窗口外框
            self.regions = []
            self.updateRegions()
        }
        next.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onStreamEnded?("无法采集虚拟屏：\(error.localizedDescription)") }
        }
        NSLog("Boundless 被控端：采集区域 \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)) → \(size.width)×\(size.height)")
    }

    func stopStream() {
        regionTimer?.invalidate()
        regionTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        captureRect = nil
        queue.async {
            self.activeStream = nil
            self.encoder = nil
            self.lastPixels = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === activeStream, let pixels = CMSampleBufferGetImageBuffer(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let wait = CACurrentMediaTime() - CMSampleBufferGetPresentationTimeStamp(sample).seconds
        withStats { _ in waitStats?.record(at: CACurrentMediaTime(), bytes: 0, latency: wait) }
        if (videoBacklog?() ?? 0) > VirtualDisplay.maxBacklog {
            withStats { $0.drop() }
            return
        }
        // 窗口位置和这一帧一起走，主控端的遮罩才对得上画面
        updateRegions()

        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if encoder?.width != width || encoder?.height != height {
            encoder = VideoEncoder(window: VirtualDisplay.streamID, width: width, height: height, wired: wired)
            encoder?.onOutput = { [weak self] format, frame, age in
                if let format { self?.sendVideo?(format) }
                self?.sendVideo?(frame)
                if case let .videoFrame(_, _, _, data) = frame {
                    self?.withStats { $0.record(at: CACurrentMediaTime(), bytes: data.count, latency: age) }
                }
            }
            if encoder == nil {
                DispatchQueue.main.async { self.onStreamEnded?("本机不支持硬件视频编码") }
                return
            }
        }
        encoder?.encode(pixels, at: CMSampleBufferGetPresentationTimeStamp(sample))
        lastPixels = pixels
        frameSerial += 1
        scheduleRefine(serial: frameSerial, remaining: 3, after: 0.15)
    }

    /// 画面停下（这段时间没有新帧）后把最后一帧再编几遍，码率空出来，编码器会把画质补上去
    private func scheduleRefine(serial: Int, remaining: Int, after delay: Double) {
        guard remaining > 0 else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, serial == self.frameSerial, let pixels = self.lastPixels, let encoder = self.encoder,
                  (self.videoBacklog?() ?? 0) == 0 else { return }
            encoder.encode(pixels, at: CMClockGetTime(CMClockGetHostTimeClock()))
            self.scheduleRefine(serial: serial, remaining: remaining - 1, after: 0.1)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamEnded?("采集中断：\(error.localizedDescription)") }
    }

    /// 采集线程：重新取屏上的窗口外框，变了就发给主控端
    private func updateRegions() {
        let current = windowRegions()
        guard current != regions else { return }
        if !regions.isEmpty { lastRegionChange = CACurrentMediaTime() }
        regions = current
        sendVideo?(.virtualWindows(capture: activeCapture, windows: current))
        DispatchQueue.main.async { self.windowCount = current.count }
    }

    /// 虚拟屏上看得见的窗口（相对虚拟屏左上角，从前到后），不含菜单栏、程序坞这类系统层
    private func windowRegions() -> [CGRect] {
        let screen = captureFrame
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        else { return [] }
        var rects: [CGRect] = []
        for entry in list {
            let layer = entry[kCGWindowLayer] as? Int ?? 0
            guard layer >= 0, layer < 1000, layer != Int(CGWindowLevelForKey(.mainMenuWindow)), layer != Int(CGWindowLevelForKey(.statusWindow)),
                  (entry[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  let pid = entry[kCGWindowOwnerPID] as? pid_t else { continue }
            let r = frame.intersection(screen)
            // 盖满整块屏的透明层（如程序坞）不算
            guard !r.isNull, r.width >= 2, r.height >= 2, !(r.width >= screen.width - 1 && r.height >= screen.height - 1),
                  !isSystemProcess(pid, owner: entry[kCGWindowOwnerName] as? String) else { continue }
            rects.append(r.offsetBy(dx: -screen.minX, dy: -screen.minY))
        }
        return rects
    }

    /// 没有包标识的普通程序（命令行工具开的窗口）照样算窗口，只排除 WindowServer 自己
    private func isSystemProcess(_ pid: pid_t, owner: String?) -> Bool {
        if let cached = excludedPIDs[pid] { return cached }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let excluded = pid == getpid() || owner == "Window Server" || bundle.map { VirtualDisplay.systemBundles.contains($0) } ?? false
        excludedPIDs[pid] = excluded
        return excluded
    }

    private func withStats(_ body: (inout FrameStats) -> Void) {
        statsLock.lock()
        defer { statsLock.unlock() }
        if stats != nil { body(&stats!) }
    }

    /// 被控端这一侧：采集到编码完成的帧率、码率和耗时，以及因网络积压丢掉的帧
    private func logStats() {
        var snapshot: FrameStats.Snapshot?, wait: FrameStats.Snapshot?
        withStats {
            snapshot = $0.take(now: CACurrentMediaTime())
            wait = waitStats?.take(now: CACurrentMediaTime())
        }
        if let snapshot, let wait {
            NSLog("Boundless 被控端统计：采集→编码 \(snapshot.summary) 窗口 \(windowCount) 个；其中采集排队 平均 %.1f / P95 %.1f ms",
                  wait.latencyAvgMs, wait.latencyP95Ms)
        }
    }
}
