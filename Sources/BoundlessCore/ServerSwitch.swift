import CoreGraphics

/// 主控端从事件截获层拿到的输入
public enum InputEvent: Equatable {
    case mouseMove(location: CGPoint, dx: Double, dy: Double)
    case mouseButton(button: UInt8, down: Bool, clickCount: Int32)
    case scroll(ScrollEvent)
    case key(code: UInt16, down: Bool, autorepeat: Bool, flags: UInt64)
    case systemKey(data1: Int32)
}

public enum SwitchEffect: Equatable {
    case none
    /// 锁住并隐藏本机光标
    case enterRemote
    /// 恢复本机光标，可选移动到指定位置
    case returnLocal(warpTo: CGPoint?)
    /// 点中了虚拟屏上的窗口：把显示虚拟屏的窗口提到最前
    case focusVirtual
}

public struct Decision: Equatable {
    /// 事件是否继续交给本机处理
    public var passLocally: Bool
    public var messages: [Message]
    public var effect: SwitchEffect

    public init(passLocally: Bool, messages: [Message] = [], effect: SwitchEffect = .none) {
        self.passLocally = passLocally
        self.messages = messages
        self.effect = effect
    }

    static let pass = Decision(passLocally: true)
    static let swallow = Decision(passLocally: false)
    static func forward(_ m: Message) -> Decision { Decision(passLocally: false, messages: [m]) }
}

/// 主控端的切换状态机：决定每个输入事件留在本机还是转发给被控端。
/// 按键和鼠标按键按「在哪边按下就在哪边松开」路由，避免跨机切换时卡键。
public final class ServerSwitch {
    public enum Mode: Equatable { case local, remote }

    public private(set) var mode: Mode = .local
    public private(set) var connected = false
    public var desktop: Desktop
    /// 被控端屏幕的摆放；被控端上报屏幕布局之前为 nil，此时不会通过边缘切换
    public var arrangement: Arrangement?
    /// 被控端的虚拟副屏；为 nil 时没有窗口可以拖到主控端
    public var virtualScreen: VirtualScreen? {
        didSet {
            guard virtualScreen == nil else { return }
            virtualButtons.removeAll()
            virtualFocused = false
        }
    }
    /// 主控端坐标上的点是否落在虚拟屏显示出来的某个窗口上（且没被本机窗口挡住）
    public var virtualHitTest: ((CGPoint) -> Bool)?
    /// 虚拟屏上的窗口在前台：键盘转发给被控端，鼠标照常在本机移动
    public var virtualFocused = false

    private var lastLocation = CGPoint.zero
    private var localKeys = Set<UInt16>()
    private var remoteKeys = Set<UInt16>()
    private var hotkeyKeys = Set<UInt16>()
    /// 虚拟屏窗口在前台时按下的修饰键：两边都收到，这样 ⌘Tab 之类留在本机的快捷键照常可用
    private var sharedKeys = Set<UInt16>()
    private var localButtons = Set<UInt8>()
    private var remoteButtons = Set<UInt8>()
    /// 在虚拟屏窗口上按下的鼠标键：光标留在本机，按键和位置转给被控端
    private var virtualButtons = Set<UInt8>()

    public init(desktop: Desktop, arrangement: Arrangement? = nil) {
        self.desktop = desktop
        self.arrangement = arrangement
    }

    public func handle(_ event: InputEvent) -> Decision {
        switch event {
        case let .mouseMove(location, dx, dy):
            if mode == .remote { return .forward(.mouseMove(dx: dx, dy: dy)) }
            lastLocation = location
            if !virtualButtons.isEmpty {
                // 在虚拟屏上拖着东西推过通向被控端的边：键不松，接着在被控端的真实屏幕上拖
                if let target = edgeTarget(location, dx: dx, dy: dy) {
                    remoteButtons.formUnion(virtualButtons)
                    virtualButtons.removeAll()
                    return enterRemote(at: target)
                }
                return Decision(passLocally: false, messages: [moveTo(location)])
            }
            // 拖拽中（按住鼠标键）不切换，跨机拖拽不在支持范围内；只有推进被控端屏幕所在的那段边才切换
            if localButtons.isEmpty, let target = edgeTarget(location, dx: dx, dy: dy) {
                return enterRemote(at: target)
            }
            // 吞掉本机的移动事件不影响光标移动，只是本机下面的窗口收不到悬停
            if localButtons.isEmpty, overVirtual(location) { return Decision(passLocally: false, messages: [moveTo(location)]) }
            return .pass

        case let .mouseButton(button, down, clickCount):
            let m = Message.mouseButton(button: button, down: down, clickCount: clickCount)
            if down {
                if mode == .remote {
                    remoteButtons.insert(button)
                    return .forward(m)
                }
                if localButtons.isEmpty, overVirtual(lastLocation) {
                    virtualButtons.insert(button)
                    virtualFocused = true
                    return Decision(passLocally: false, messages: [moveTo(lastLocation), m], effect: .focusVirtual)
                }
                if virtualButtons.isEmpty {
                    // 点了本机的东西，键盘回到本机
                    virtualFocused = false
                    localButtons.insert(button)
                    return .pass
                }
                virtualButtons.insert(button)
                return .forward(m)
            }
            if localButtons.remove(button) != nil { return .pass }
            if remoteButtons.remove(button) != nil { return .forward(m) }
            if virtualButtons.remove(button) != nil { return .forward(m) }
            return mode == .remote ? .forward(m) : .pass

        case let .scroll(s):
            if mode == .remote { return .forward(.scroll(s)) }
            if localButtons.isEmpty, overVirtual(lastLocation) {
                return Decision(passLocally: false, messages: [moveTo(lastLocation), .scroll(s)])
            }
            return .pass

        case let .systemKey(data1):
            return mode == .remote ? .forward(.systemKey(data1: data1)) : .pass

        case let .key(code, down, autorepeat, flags):
            return handleKey(code: code, down: down, autorepeat: autorepeat, flags: flags)
        }
    }

    /// 被控端报告光标推出了它的桌面；推出去的点落在主控端屏幕上才收回控制权。
    /// 按着鼠标键（拖着窗口）推进虚拟屏对应的那块屏幕时键不松：光标回到本机，拖动在虚拟屏上接着进行
    public func clientPushed(at clientPoint: CGPoint) -> Decision {
        guard mode == .remote, let arrangement else { return .pass }
        let point = arrangement.toServer(clientPoint)
        guard desktop.display(containing: point) != nil else { return .pass }
        if !remoteButtons.isEmpty, let virtualScreen, virtualScreen.server.contains(point) {
            mode = .local
            virtualButtons = remoteButtons
            remoteButtons.removeAll()
            virtualFocused = true
            lastLocation = point
            return Decision(passLocally: false, messages: [.leave, moveTo(point)], effect: .returnLocal(warpTo: point))
        }
        return returnLocal(warpTo: point, notifyClient: true)
    }

    public func setConnected(_ value: Bool) -> Decision {
        connected = value
        guard !value else { return .pass }
        virtualScreen = nil
        // 断线后被控端会自行松开所有键，这边不再需要把松开事件转发过去
        remoteKeys.removeAll()
        guard mode == .remote else {
            remoteButtons.removeAll()
            return .pass
        }
        let d = returnLocal(warpTo: nil, notifyClient: false)
        return Decision(passLocally: true, effect: d.effect)
    }

    /// 退出程序等场景强制收回控制权
    public func forceLocal() -> Decision {
        guard mode == .remote else { return .pass }
        return returnLocal(warpTo: nil, notifyClient: true)
    }

    private func handleKey(code: UInt16, down: Bool, autorepeat: Bool, flags: UInt64) -> Decision {
        let m = Message.key(code: code, down: down, autorepeat: autorepeat)
        let typingVirtual = mode == .local && virtualFocused && connected && virtualScreen != nil
        let forwarding = mode == .remote || typingVirtual
        // 大写锁定每按一次切换一次状态，没有成对的按下/松开，直接按当前模式路由
        if code == KeyCodes.capsLock { return forwarding ? .forward(m) : .pass }

        if down {
            if hotkeyKeys.contains(code) { return .swallow }
            // 已按住的键的自动重复，跟随首次按下的那一侧
            if localKeys.contains(code) { return .pass }
            if remoteKeys.contains(code) { return .forward(m) }
            if sharedKeys.contains(code) { return Decision(passLocally: true, messages: [m]) }

            let side = arrangement?.side(relativeTo: desktop)
            if mode == .local, connected, let arrangement, let side,
               KeyCodes.isSwitchHotkey(code, flags: flags, toward: side) {
                hotkeyKeys.insert(code)
                return enterRemote(at: arrangement.nearestClientPoint(toServer: lastLocation))
            }
            if mode == .remote, isReturnHotkey(code, flags: flags, side: side) {
                hotkeyKeys.insert(code)
                return returnLocal(warpTo: nil, notifyClient: true)
            }
            if mode == .remote {
                remoteKeys.insert(code)
                return .forward(m)
            }
            if typingVirtual {
                if KeyCodes.isModifier(code) {
                    sharedKeys.insert(code)
                    return Decision(passLocally: true, messages: [m])
                }
                if !KeyCodes.isAppSwitcher(code, flags: flags) {
                    remoteKeys.insert(code)
                    return .forward(m)
                }
            }
            localKeys.insert(code)
            return .pass
        }

        if hotkeyKeys.remove(code) != nil { return .swallow }
        if localKeys.remove(code) != nil { return .pass }
        if remoteKeys.remove(code) != nil { return .forward(m) }
        if sharedKeys.remove(code) != nil { return Decision(passLocally: true, messages: [m]) }
        return forwarding ? .forward(m) : .pass
    }

    /// 远程模式下切回本机的快捷键：朝主控端方向；排列未知时任一方向都行，保证总能切回
    private func isReturnHotkey(_ code: UInt16, flags: UInt64, side: Edge?) -> Bool {
        if let side { return KeyCodes.isSwitchHotkey(code, flags: flags, toward: side.opposite) }
        return Edge.allCases.contains { KeyCodes.isSwitchHotkey(code, flags: flags, toward: $0) }
    }

    /// 光标推过通向被控端的那段边时，在被控端的落点
    private func edgeTarget(_ location: CGPoint, dx: Double, dy: Double) -> CGPoint? {
        guard connected, let arrangement, let beyond = desktop.pointBeyond(location, dx: dx, dy: dy) else { return nil }
        return arrangement.clientPoint(atServer: beyond)
    }

    private func overVirtual(_ p: CGPoint) -> Bool {
        guard connected, let virtualScreen, virtualScreen.server.contains(p) else { return false }
        return virtualHitTest?(p) ?? false
    }

    private func moveTo(_ p: CGPoint) -> Message {
        let q = virtualScreen?.toClient(p) ?? p
        return .moveTo(x: q.x, y: q.y)
    }

    private func enterRemote(at clientPoint: CGPoint) -> Decision {
        mode = .remote
        return Decision(passLocally: false, messages: [.enter(x: clientPoint.x, y: clientPoint.y)], effect: .enterRemote)
    }

    private func returnLocal(warpTo: CGPoint?, notifyClient: Bool) -> Decision {
        mode = .local
        // 从被控端回来，键盘先归本机，点了虚拟屏上的窗口再转过去
        virtualFocused = false
        var messages = remoteButtons.sorted().map { Message.mouseButton(button: $0, down: false, clickCount: 1) }
        remoteButtons.removeAll()
        if notifyClient { messages.append(.leave) }
        return Decision(passLocally: false, messages: messages, effect: .returnLocal(warpTo: warpTo))
    }
}
