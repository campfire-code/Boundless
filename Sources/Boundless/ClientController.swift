import AppKit
import BoundlessCore
import Network

/// 被控端：发现并连接主控端，把收到的输入注入本机
final class ClientController {
    var onChange: (() -> Void)?

    private let settings: Settings
    private let cursor = ClientCursor()
    private let injector: InputInjector
    private let clipboard = ClipboardSync(syncInitialContents: false)
    private let browser = ServiceBrowser()
    private(set) var servers: [String: ServiceBrowser.Service] = [:]
    private var link: Link?
    private var linkTarget: String?
    private var linkReady = false
    private var peerName: String?
    private var lastError: String?
    private var retry: DispatchWorkItem?
    /// 本次连接是否绑定在有线网卡上
    private var attemptingWired = false
    /// 有线连不上时，这个时间之前不再尝试有线，避免反复切换
    private var wiredRetryAfter = Date.distantPast
    /// 为切到有线而主动断开，断开后立即重连
    private var upgrading = false
    private var cachedKey: (code: String, key: Data)?
    /// 控制通道连的主控端与网卡，视频通道按同样的路径再开一条连接
    private var linkEndpoint: NWEndpoint?
    private var linkInterface: NWInterface?
    /// 主控端要求的虚拟屏位置（本机坐标）；为 nil 时不能把窗口拖过去
    private var virtualRequest: CGRect?
    private var virtual: VirtualDisplay?
    /// 虚拟屏已摆好、主控端已知道它的位置
    private var virtualReady = false
    /// 虚拟屏就绪后要做的事（如把指定窗口挪过去）
    private var whenVirtualReady: [() -> Void] = []
    /// 虚拟屏连续空着的起始时刻，空够一段时间就撤掉
    private var virtualIdleSince: Date?
    private var virtualIdleTimer: Timer?
    /// 断线后虚拟屏再保留一会儿，期间重连上（如切到有线）就接着用，窗口不被弹回本机
    private var virtualGraceTimer: Timer?
    /// 按下鼠标时光标下的窗口；拖动中它的位置变了，说明在拖窗口，提前把虚拟屏建好
    private var dragCandidate: (window: RemoteWindow, pid: pid_t)?
    private var lastDragCheck = Date.distantPast
    private var videoLink: Link?
    private var screenObserver: NSObjectProtocol?
    private var wiredTimer: Timer?

    init(settings: Settings) {
        self.settings = settings
        injector = InputInjector(dryRun: settings.dryRun)
        cursor.desktop = .current()
    }

    var isConnected: Bool { linkReady }
    var isRemote: Bool { cursor.isActive }

    var statusText: String {
        if settings.clientCode == nil { return "请先输入主控端的配对码" }
        if linkReady {
            let name = peerName ?? linkTarget ?? "主控端"
            let path = link?.usesWiFi == true ? "Wi-Fi" : "有线"
            return cursor.isActive ? "正在被 \(name) 控制 · \(path)" : "已连接 \(name) · \(path)"
        }
        if let target = linkTarget { return "正在连接 \(target)…" }
        if let lastError { return lastError }
        if servers.isEmpty { return "正在查找主控端…" }
        return settings.preferredServer == nil ? "发现多台主控端，请在菜单里选择" : "未找到 \(settings.preferredServer!)"
    }

    func start() {
        browser.onChange = { [weak self] found in
            guard let self else { return }
            self.servers = found
            self.connectIfNeeded()
            self.upgradeToWiredIfPossible()
            self.onChange?()
        }
        browser.start()
        // 退到 Wi-Fi 后定时看看有线是否又能用了
        wiredTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.upgradeToWiredIfPossible() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cursor.desktop = .current()
            if self.linkReady { self.link?.send(.layout(displays: self.cursor.desktop.displays)) }
        }
    }

    func stop() {
        retry?.cancel()
        wiredTimer?.invalidate()
        browser.cancel()
        dropVirtual(notify: true)
        link?.cancel()
        cursor.releaseAll().forEach(injector.perform)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// 配对码或目标主控端变了，断开重连
    func reconnect() {
        lastError = nil
        if let link {
            link.cancel()
        } else {
            connectIfNeeded()
        }
        onChange?()
    }

    // MARK: - 网络

    private func target() -> (name: String, service: ServiceBrowser.Service)? {
        if let preferred = settings.preferredServer {
            return servers[preferred].map { (preferred, $0) }
        }
        guard servers.count == 1, let only = servers.first else { return nil }
        return (only.key, only.value)
    }

    private func presharedKey(for code: String) -> Data {
        if let cachedKey, cachedKey.code == code { return cachedKey.key }
        let key = Pairing.presharedKey(for: code)
        cachedKey = (code, key)
        return key
    }

    private func connectIfNeeded() {
        guard link == nil, let code = settings.clientCode, let target = target() else { return }
        retry?.cancel()
        // 能在有线网卡上找到主控端就只走有线（延迟低一两个数量级），3 秒连不上再退回默认路径
        let wired = Date() >= wiredRetryAfter ? target.service.wiredInterface : nil
        attemptingWired = wired != nil
        let params = Transport.parameters(psk: presharedKey(for: code), interface: wired)
        let l = Link(connection: NWConnection(to: target.service.endpoint, using: params), handshakeTimeout: wired != nil ? 3 : 8)
        link = l
        linkEndpoint = target.service.endpoint
        linkInterface = wired
        linkTarget = target.name
        linkReady = false
        l.onEvent = { [weak self, weak l] event in
            guard let self, let l, l === self.link else { return }
            self.linkEvent(event)
        }
        l.start()
    }

    private func linkEvent(_ event: Link.Event) {
        switch event {
        case .ready:
            linkReady = true
            lastError = nil
            NSLog("Boundless 被控端：已连接 \(linkTarget ?? "")，走\(link?.usesWiFi == true ? " Wi-Fi" : "有线")")
            link?.send(.hello(version: Transport.protocolVersion, name: SystemInfo.computerName, channel: .control))
            link?.send(.layout(displays: cursor.desktop.displays))
        case let .message(m):
            receive(m)
            return
        case let .closed(error):
            NSLog("Boundless 被控端：连接关闭（\(linkReady ? "曾连上" : "未连上")）\(error.map { "\($0)" } ?? "")")
            let quickRetry = upgrading || (attemptingWired && !linkReady)
            if attemptingWired && !linkReady {
                // 有线没连通，先用默认路径，30 秒后再试有线
                wiredRetryAfter = Date().addingTimeInterval(30)
            } else if upgrading {
                // 主动断开换有线，不算错误
            } else if !linkReady {
                lastError = "连接 \(linkTarget ?? "主控端") 失败（配对码不对或网络不通），稍后重试"
            } else if let error {
                lastError = "连接已断开：\(error.localizedDescription)"
            }
            cursor.releaseAll().forEach(injector.perform)
            link = nil
            linkTarget = nil
            linkReady = false
            suspendVirtual()
            peerName = nil
            upgrading = false
            scheduleRetry(after: quickRetry ? 0.1 : 2)
        }
        onChange?()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.connectIfNeeded() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 正走 Wi-Fi 而线已经接通：趁光标不在本机时断开重连到有线
    private func upgradeToWiredIfPossible() {
        // 拖动中不切；有虚拟屏时照切，断开期间虚拟屏保留，重连后画面接上
        guard linkReady, let link, link.usesWiFi, !cursor.isActive, !cursor.isDragging, !upgrading,
              Date() >= wiredRetryAfter, target()?.service.wiredInterface != nil else { return }
        NSLog("Boundless 被控端：发现有线连接可用，切换到有线")
        upgrading = true
        link.cancel()
    }

    private func receive(_ message: Message) {
        switch message {
        case let .hello(version, name, _, _):
            if version == Transport.protocolVersion {
                peerName = name
                NSLog("Boundless 被控端：主控端是 \(name)")
            } else {
                lastError = "\(name) 的无界版本不一致，请两台装同一版本"
                link?.cancel()
            }
            onChange?()
        case let .clipboard(items):
            if settings.clipboardSync { clipboard.apply(items) }
        case let .clockProbe(serverTime):
            link?.send(.clockReply(serverTime: serverTime, clientTime: Date().timeIntervalSince1970))
        case .windowListRequest:
            LocalWindows.list { [weak self] windows in self?.link?.send(.windowList(windows)) }
        case let .virtualDisplay(frame):
            setVirtualRequest(frame.isEmpty ? nil : frame)
        case let .moveWindowToVirtual(window):
            moveToVirtual(window)
        case .recallWindows:
            dropVirtual(notify: true)
        case let .requestKeyframe(window):
            if window == VirtualDisplay.streamID { virtual?.requestKeyframe() }
        default:
            let wasActive = cursor.isActive
            if case .mouseMove = message, !settings.dryRun { cursor.syncPosition(SystemInfo.cursorLocation) }
            let (actions, replies) = cursor.handle(message)
            actions.forEach(injector.perform)
            trackWindowDrag(message)
            replies.forEach { link?.send($0) }
            // 控制权被收回（推回主控端或快捷键切回）时，把这边的剪贴板带回去
            if wasActive, !cursor.isActive, settings.clipboardSync, let items = clipboard.snapshotIfChanged() {
                link?.send(.clipboard(items))
            }
            if wasActive != cursor.isActive {
                onChange?()
                if !cursor.isActive { upgradeToWiredIfPossible() }
            }
        }
    }

    // MARK: - 虚拟副屏

    /// 主控端告知虚拟屏该放哪。已有的虚拟屏大小不同就重建，位置不同就挪过去
    private func setVirtualRequest(_ frame: CGRect?) {
        let changed = frame != virtualRequest
        virtualRequest = frame
        guard let virtual else { return }
        guard let frame, frame.size == virtual.frame.size else { return dropVirtual(notify: true) }
        // 重连后主控端会重发一次：虚拟屏还在就重新上报并接上画面
        guard changed || !virtualReady else { return }
        virtualGraceTimer?.invalidate()
        virtualGraceTimer = nil
        virtual.place(at: frame.origin) { [weak self, weak virtual] actual in
            guard let self, let virtual, self.virtual === virtual, self.linkReady else { return }
            self.virtualBecameReady(virtual, at: actual)
        }
    }

    /// 控制通道断了：先停画面，保留虚拟屏 10 秒等重连
    private func suspendVirtual() {
        guard let display = virtual else { return }
        virtualReady = false
        videoLink?.cancel()
        videoLink = nil
        display.stopStream()
        virtualGraceTimer?.invalidate()
        virtualGraceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, !self.linkReady else { return }
            self.virtualRequest = nil
            self.dropVirtual(notify: false)
        }
    }

    /// 需要时才建虚拟屏（拖动窗口、菜单里挪窗口），建好后执行 then
    private func ensureVirtual(then body: (() -> Void)? = nil) {
        if virtualReady, virtual != nil {
            body?()
            return
        }
        if let body { whenVirtualReady.append(body) }
        guard virtual == nil, let request = virtualRequest, linkReady, !settings.dryRun else { return }
        guard let display = VirtualDisplay(size: request.size, logStats: settings.streamStats) else {
            NSLog("Boundless 被控端：无法创建虚拟屏")
            whenVirtualReady.removeAll()
            return
        }
        virtual = display
        display.place(at: request.origin) { [weak self, weak display] actual in
            guard let self, let display, self.virtual === display else { return }
            self.virtualBecameReady(display, at: actual)
            self.startIdleCheck()
        }
    }

    /// 新建或重连后虚拟屏摆好了：告诉主控端位置，接上画面，执行等着的事
    private func virtualBecameReady(_ display: VirtualDisplay, at frame: CGRect) {
        virtualReady = true
        cursor.allowsDragOut = true
        cursor.desktop = .current()
        link?.send(.virtualReady(frame: frame))
        if videoLink == nil { openVideoLink(for: display) }
        let pending = whenVirtualReady
        whenVirtualReady.removeAll()
        pending.forEach { $0() }
    }

    /// 撤掉虚拟屏，上面的窗口由系统挪回真实屏幕
    private func dropVirtual(notify: Bool) {
        guard let display = virtual else { return }
        virtual = nil
        virtualReady = false
        whenVirtualReady.removeAll()
        virtualIdleTimer?.invalidate()
        virtualIdleTimer = nil
        virtualGraceTimer?.invalidate()
        virtualGraceTimer = nil
        virtualIdleSince = nil
        cursor.allowsDragOut = false
        display.stop()
        videoLink?.cancel()
        videoLink = nil
        if notify { link?.send(.virtualReady(frame: .zero)) }
        upgradeToWiredIfPossible()
    }

    /// 空着（没有窗口、光标也不在上面）超过 30 秒就撤掉，免得系统把新窗口或光标放到看不见的屏上
    private func startIdleCheck() {
        virtualIdleTimer?.invalidate()
        virtualIdleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let display = self.virtual else { return }
            let busy = display.windowCount > 0 || display.contains(self.cursor.position) || display.contains(SystemInfo.cursorLocation)
            if busy {
                self.virtualIdleSince = nil
            } else if let since = self.virtualIdleSince {
                if Date().timeIntervalSince(since) > 30 { self.dropVirtual(notify: true) }
            } else {
                self.virtualIdleSince = Date()
            }
        }
    }

    private func moveToVirtual(_ window: UInt32) {
        guard let info = LocalWindows.info(window) else { return }
        NSLog("Boundless 被控端：把窗口 \(window) 挪到虚拟屏\(virtualRequest == nil ? "（主控端还没给虚拟屏位置）" : "")")
        ensureVirtual { [weak self] in self?.virtual?.moveIn(window, pid: info.pid, size: info.frame.size) }
    }

    /// 视频通道按控制通道同样的路径再开一条，连上后开始采集虚拟屏
    private func openVideoLink(for display: VirtualDisplay) {
        guard linkReady, let link, let endpoint = linkEndpoint, let code = settings.clientCode else { return }
        videoLink?.cancel()
        let params = Transport.parameters(psk: presharedKey(for: code), interface: linkInterface)
        let v = Link(connection: NWConnection(to: endpoint, using: params))
        videoLink = v
        display.wired = !link.usesWiFi
        display.sendVideo = { [weak v] m in v?.send(m) }
        display.videoBacklog = { [weak v] in v?.backlog ?? 0 }
        display.onStreamEnded = { [weak self, weak display] reason in
            guard let self, let display, self.virtual === display else { return }
            NSLog("Boundless 被控端：虚拟屏采集结束 \(reason)")
            self.dropVirtual(notify: true)
        }
        v.onEvent = { [weak self, weak v, weak display] event in
            guard let self, let v, v === self.videoLink, let display else { return }
            switch event {
            case .ready:
                v.send(.hello(version: Transport.protocolVersion, name: SystemInfo.computerName, channel: .video))
                display.startStream()
            case .message:
                break
            case let .closed(error):
                NSLog("Boundless 被控端：视频通道关闭 \(error.map { "\($0)" } ?? "")")
                self.videoLink = nil
                display.stopStream()
                // 控制通道还在就重开一条
                if self.linkReady, self.virtual === display {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.linkReady, self.virtual === display, self.videoLink == nil else { return }
                        self.openVideoLink(for: display)
                    }
                }
            }
        }
        v.start()
    }

    /// 在被控端上按住窗口拖动时提前建好虚拟屏，拖到边上就能过去
    private func trackWindowDrag(_ message: Message) {
        guard virtualRequest != nil, virtual == nil else { return }
        switch message {
        case .mouseButton(0, true, _) where cursor.isActive:
            dragCandidate = settings.dryRun ? nil : LocalWindows.topmost(at: cursor.position)
        case .mouseButton(0, false, _):
            dragCandidate = nil
        case .mouseMove where cursor.isDragging:
            // 读窗口位置有开销，拖动中每 0.1 秒看一次
            guard let candidate = dragCandidate, Date().timeIntervalSince(lastDragCheck) > 0.1 else { return }
            lastDragCheck = Date()
            if let frame = LocalWindows.info(candidate.window.id)?.frame, frame.origin != candidate.window.frame.origin {
                dragCandidate = nil
                ensureVirtual()
            }
        default:
            break
        }
    }
}
