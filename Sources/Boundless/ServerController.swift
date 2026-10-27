import AppKit
import BoundlessCore
import Network

/// 主控端：截获本机键鼠，按切换状态机转发给已连接的被控端
final class ServerController {
    var onChange: (() -> Void)?
    /// 屏幕排列变化（被控端上报新布局、屏幕增减），用于刷新排列窗口
    var onArrangementChange: (() -> Void)?

    private let settings: Settings
    private let logic: ServerSwitch
    private let capture = InputCapture()
    private let clipboard = ClipboardSync(syncInitialContents: true)
    private var listener: LinkListener?
    private var pending: [Link] = []
    private var link: Link?
    private var peerName: String?
    /// 被控端的系统；Windows 被控端没有虚拟副屏
    private(set) var peerPlatform: Platform?
    private var lastError: String?
    private var captureRetry: Timer?
    private var screenObserver: NSObjectProtocol?
    private var videoLink: Link?
    /// 向被控端要的虚拟屏（对应本机哪块屏幕、放在被控端哪里）
    private var virtualRequest: VirtualScreen?
    private var overlay: VirtualOverlay?
    private var resignObserver: NSObjectProtocol?
    /// 被控端最近一次上报的窗口列表（真实屏幕上的）
    private(set) var remoteWindows: [RemoteWindow] = []
    /// 收到新的窗口列表
    var onWindowList: (() -> Void)?
    /// 本次连接是否已按 autoMove 参数自动挪过窗口
    private var autoMoved = false
    /// 统计延迟用的对时
    private var clock = ClockOffset()
    private var clockTimer: Timer?

    init(settings: Settings) {
        self.settings = settings
        logic = ServerSwitch(desktop: .current())
        rebuildArrangement()
        logic.virtualHitTest = { [weak self] p in self?.overlay?.hit(p) ?? false }
    }

    var isConnected: Bool { link != nil }
    /// 被控端能否把窗口显示到本机（Windows 被控端不支持）
    var supportsVirtualScreen: Bool { peerPlatform != .windows }
    var isRemote: Bool { logic.mode == .remote }
    var desktop: Desktop { logic.desktop }
    var arrangement: Arrangement? { logic.arrangement }
    var clientName: String { peerName ?? settings.clientName ?? "被控端" }

    var statusText: String {
        if !capture.isRunning { return "等待授权：辅助功能、输入监控" }
        if let lastError { return lastError }
        guard link != nil else { return "等待被控端连接…" }
        let name = peerName ?? "被控端"
        let path = link?.usesWiFi == true ? "Wi-Fi" : "有线"
        return isRemote ? "正在控制 \(name) · \(path)" : "已连接 \(name) · \(path)"
    }

    func start() {
        capture.handler = { [weak self] event in self?.handle(event) ?? true }
        startCapture()
        startListener()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.logic.desktop = .current()
            self?.rebuildArrangement()
        }
        // 切到本机别的应用（点了本机窗口、⌘Tab），键盘回到本机
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.logic.virtualFocused = false }
    }

    func stop() {
        closeOverlay()
        apply(logic.forceLocal())
        link?.send(.releaseAll)
        link?.cancel()
        pending.forEach { $0.cancel() }
        listener?.cancel()
        captureRetry?.invalidate()
        capture.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// 排列窗口拖动完成后保存新位置
    func setArrangementOrigin(_ origin: CGPoint) {
        settings.arrangementOrigin = origin
        rebuildArrangement()
    }

    func resetArrangement() {
        settings.arrangementOrigin = nil
        rebuildArrangement()
    }

    /// 由保存的位置和被控端屏幕布局重建排列，并重新吸附到当前主控端屏幕上
    private func rebuildArrangement() {
        let displays = settings.clientDisplays
        guard !displays.isEmpty else {
            logic.arrangement = nil
            onArrangementChange?()
            return
        }
        if let origin = settings.arrangementOrigin {
            logic.arrangement = Arrangement(clientDisplays: displays, origin: origin).snapped(to: logic.desktop)
        } else {
            logic.arrangement = Arrangement.defaultPlacement(clientDisplays: displays, server: logic.desktop)
        }
        onArrangementChange?()
        onChange?()
        sendVirtualRequest()
    }

    /// 配对码变更后重启监听，旧连接全部断开
    func restartListener() {
        closeOverlay()
        link?.cancel()
        pending.forEach { $0.cancel() }
        listener?.cancel()
        startListener()
    }

    // MARK: - 输入

    private func startCapture() {
        guard !capture.start() else { return }
        captureRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if self.capture.start() {
                timer.invalidate()
                self.captureRetry = nil
                self.onChange?()
            }
        }
    }

    private func handle(_ event: InputEvent) -> Bool {
        let decision = logic.handle(event)
        apply(decision)
        return decision.passLocally
    }

    private func apply(_ decision: Decision) {
        for m in decision.messages { link?.send(m) }
        switch decision.effect {
        case .none:
            return
        case .enterRemote:
            capture.enterRemote()
            if settings.clipboardSync, let items = clipboard.snapshotIfChanged() { link?.send(.clipboard(items)) }
        case let .returnLocal(point):
            capture.returnLocal(warpTo: point)
            // 拖着窗口进了虚拟屏：显示窗口提到最前，键盘跟着这个窗口
            if logic.virtualFocused { overlay?.focus() }
        case .focusVirtual:
            overlay?.focus()
        }
        onChange?()
    }

    // MARK: - 网络

    private func startListener() {
        do {
            let l = try LinkListener(psk: Pairing.presharedKey(for: settings.serverCode), serviceName: SystemInfo.computerName)
            l.onConnection = { [weak self] connection in self?.accept(connection) }
            l.onFailure = { [weak self] error in
                self?.lastError = "监听失败：\(error.localizedDescription)"
                self?.onChange?()
            }
            l.start()
            listener = l
            lastError = nil
        } catch {
            lastError = "监听失败：\(error.localizedDescription)"
        }
    }

    private func accept(_ connection: NWConnection) {
        let l = Link(connection: connection)
        pending.append(l)
        l.onEvent = { [weak self, weak l] event in
            guard let self, let l else { return }
            self.linkEvent(l, event)
        }
        l.start()
    }

    private func linkEvent(_ l: Link, _ event: Link.Event) {
        switch event {
        case .ready:
            // 等对方的 hello 报明用途，再决定它是控制通道还是视频通道
            l.send(.hello(version: Transport.protocolVersion, name: SystemInfo.computerName, channel: .control))
        case let .message(m):
            if pending.contains(where: { $0 === l }) {
                if case let .hello(version, name, channel, platform) = m {
                    identify(l, version: version, name: name, channel: channel, platform: platform)
                }
                return
            }
            if l === videoLink {
                overlay?.display(m)
                return
            }
            guard l === link else { return }
            receive(m)
        case let .closed(error):
            pending.removeAll { $0 === l }
            if l === videoLink {
                videoLink = nil
                return
            }
            guard l === link else { return }
            NSLog("Boundless 主控端：被控端断开 \(error.map { "\($0)" } ?? "")")
            link = nil
            peerName = nil
            peerPlatform = nil
            remoteWindows = []
            closeOverlay()
            apply(logic.setConnected(false))
        }
        onChange?()
    }

    private func identify(_ l: Link, version: UInt16, name: String, channel: Channel, platform: Platform) {
        pending.removeAll { $0 === l }
        guard version == Transport.protocolVersion else {
            lastError = "\(name) 的无界版本不一致，请两台装同一版本"
            l.cancel()
            return
        }
        switch channel {
        case .control:
            // 只保留一个被控端，新连接顶替旧连接
            if let old = link {
                old.cancel()
                closeOverlay()
                apply(logic.setConnected(false))
            }
            link = l
            peerName = name
            peerPlatform = platform
            settings.clientName = name
            lastError = nil
            NSLog("Boundless 主控端：被控端 \(name) 已连接")
            apply(logic.setConnected(true))
            virtualRequest = nil
            sendVirtualRequest()
            autoMoved = false
            if settings.autoMove != nil { l.send(.windowListRequest) }
            startClockSync()
        case .video:
            guard link != nil else {
                l.cancel()
                return
            }
            videoLink?.cancel()
            videoLink = l
        }
    }

    private func receive(_ message: Message) {
        switch message {
        case let .layout(displays):
            settings.clientDisplays = displays
            rebuildArrangement()
        case let .edgePush(x, y):
            apply(logic.clientPushed(at: CGPoint(x: x, y: y)))
        case let .clipboard(items):
            if settings.clipboardSync { clipboard.apply(items) }
        case let .windowList(windows):
            if settings.autoMove != nil { NSLog("Boundless 主控端：收到窗口列表 \(windows.map { "\($0.app)/\($0.title)" })") }
            remoteWindows = windows
            onWindowList?()
            autoMoveIfRequested()
        case let .virtualReady(frame):
            virtualReady(frame)
        case let .clockReply(serverTime, clientTime):
            clock.add(sent: serverTime, clientTime: clientTime, received: Date().timeIntervalSince1970)
            overlay?.clockOffset = clock.offset
        default:
            break
        }
    }

    // MARK: - 虚拟副屏

    /// 有窗口在虚拟屏上（主控端正显示被控端的窗口）
    var hasVirtualWindows: Bool { overlay != nil }

    func requestWindowList() {
        link?.send(.windowListRequest)
    }

    /// 把被控端的窗口挪到虚拟屏，也就是显示到本机
    func moveToVirtual(_ remote: RemoteWindow) {
        link?.send(.moveWindowToVirtual(window: remote.id))
    }

    /// 撤掉虚拟屏，窗口全部回到被控端
    func recallWindows() {
        link?.send(.recallWindows)
    }

    /// 按当前排列告诉被控端虚拟屏该放哪；排列变了才重发
    private func sendVirtualRequest() {
        guard link != nil else { return }
        let request = logic.arrangement?.virtualScreen(for: logic.desktop)
        guard request != virtualRequest else { return }
        virtualRequest = request
        link?.send(.virtualDisplay(frame: request?.client ?? .zero))
        if let request, let screen = logic.virtualScreen, screen.server != request.server { closeOverlay() }
    }

    /// 被控端的虚拟屏就绪（或撤掉了）
    private func virtualReady(_ frame: CGRect) {
        guard !frame.isEmpty, let request = virtualRequest else { return closeOverlay() }
        logic.virtualScreen = VirtualScreen(server: request.server, client: frame)
        if overlay?.screen != request.server {
            overlay?.close()
            let o = VirtualOverlay(screen: request.server, logStats: settings.streamStats)
            o.onKeyframeNeeded = { [weak self] in self?.link?.send(.requestKeyframe(window: VirtualDisplay.streamID)) }
            o.clockOffset = clock.offset
            overlay = o
            link?.send(.requestKeyframe(window: VirtualDisplay.streamID))
        }
        NSLog("Boundless 主控端：被控端虚拟屏就绪 \(frame)")
        onChange?()
    }

    private func closeOverlay() {
        logic.virtualScreen = nil
        guard let o = overlay else { return }
        overlay = nil
        o.close()
        videoLink?.cancel()
        videoLink = nil
        onChange?()
    }

    /// 开了统计时每 2 秒对一次时，换了连接重新估
    private func startClockSync() {
        clock = ClockOffset()
        clockTimer?.invalidate()
        guard settings.streamStats else { return }
        let probe = { [weak self] in self?.link?.send(.clockProbe(serverTime: Date().timeIntervalSince1970)) }
        probe()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in probe() }
    }

    /// 调试参数 autoMove：连上后自动把第一个匹配的窗口挪过来
    private func autoMoveIfRequested() {
        guard let keyword = settings.autoMove, !autoMoved,
              let target = remoteWindows.first(where: { $0.app.localizedCaseInsensitiveContains(keyword) || $0.title.localizedCaseInsensitiveContains(keyword) })
        else { return }
        autoMoved = true
        NSLog("Boundless 主控端：自动挪过来 \(target.app) \(target.id)")
        moveToVirtual(target)
    }
}
