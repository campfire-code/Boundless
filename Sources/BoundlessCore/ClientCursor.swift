import CoreGraphics

/// 被控端需要注入系统的动作
public enum InjectAction: Equatable {
    case warp(CGPoint)
    case move(to: CGPoint, dx: Double, dy: Double, dragButton: UInt8?)
    case button(UInt8, down: Bool, at: CGPoint, clickCount: Int32)
    case scroll(ScrollEvent)
    case key(code: UInt16, down: Bool, autorepeat: Bool, flags: UInt64)
    case systemKey(data1: Int32)
}

/// 被控端状态机：维护虚拟光标位置、按住的键，把收到的消息翻译成注入动作
public final class ClientCursor {
    public var desktop: Desktop
    public private(set) var isActive = false
    public private(set) var position = CGPoint.zero
    /// 有虚拟副屏时，按着鼠标键推出桌面也上报，主控端据此让拖动接着在虚拟屏上进行
    public var allowsDragOut = false

    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<UInt8>()
    /// 最近注入过的光标位置。系统处理注入事件有延迟，读回的位置常是其中某一个
    private var recentPositions: [CGPoint] = []

    public init(desktop: Desktop = Desktop(displays: [])) {
        self.desktop = desktop
    }

    public var modifierFlags: UInt64 { KeyCodes.flags(forHeld: heldKeys) }

    /// 是否按着鼠标键
    public var isDragging: Bool { !heldButtons.isEmpty }

    /// 被控端本机鼠标也动过时，以系统实际光标位置为准；读回的只是还没追上的旧注入位置时忽略
    public func syncPosition(_ actual: CGPoint) {
        func near(_ p: CGPoint) -> Bool { hypot(actual.x - p.x, actual.y - p.y) <= 2 }
        guard !near(position), !recentPositions.contains(where: near) else { return }
        position = actual
        recentPositions.removeAll()
    }

    private func moved(to p: CGPoint) {
        position = p
        recentPositions.append(p)
        if recentPositions.count > 32 { recentPositions.removeFirst(recentPositions.count - 32) }
    }

    public func handle(_ message: Message) -> (actions: [InjectAction], replies: [Message]) {
        switch message {
        case let .enter(x, y):
            isActive = true
            moved(to: desktop.clamp(CGPoint(x: x, y: y)))
            // 从虚拟屏拖着窗口回来：保持拖动，不能用普通移动打断
            if let button = heldButtons.min() { return ([.move(to: position, dx: 0, dy: 0, dragButton: button)], []) }
            return ([.warp(position)], [])

        case let .moveTo(x, y):
            // 光标在虚拟屏上，主控端给的是绝对位置，不收进真实屏幕
            let p = CGPoint(x: x, y: y)
            let (dx, dy) = (p.x - position.x, p.y - position.y)
            moved(to: p)
            return ([.move(to: p, dx: dx, dy: dy, dragButton: heldButtons.min())], [])

        case .leave:
            isActive = false
            return ([], [])

        case let .mouseMove(dx, dy):
            guard isActive else { return ([], []) }
            let raw = CGPoint(x: position.x + dx, y: position.y + dy)
            let clamped = desktop.clamp(raw)
            moved(to: clamped)
            let move = InjectAction.move(to: clamped, dx: dx, dy: dy, dragButton: heldButtons.min())
            // 推出了桌面：上报推出去的点，能否回主控端由主控端按屏幕排列判断（拖拽中只有拖窗口才上报）
            if clamped != raw, heldButtons.isEmpty || allowsDragOut {
                return ([move], [.edgePush(x: raw.x, y: raw.y)])
            }
            return ([move], [])

        case let .mouseButton(button, down, clickCount):
            if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
            return ([.button(button, down: down, at: position, clickCount: clickCount)], [])

        case let .scroll(s):
            return ([.scroll(s)], [])

        case let .systemKey(data1):
            return ([.systemKey(data1: data1)], [])

        case let .key(code, down, autorepeat):
            if code == KeyCodes.capsLock {
                // 主控端每次切换大写锁定都发一次，这边还原成一次完整按键
                let f = modifierFlags
                return ([.key(code: code, down: true, autorepeat: false, flags: f),
                         .key(code: code, down: false, autorepeat: false, flags: f)], [])
            }
            if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
            return ([.key(code: code, down: down, autorepeat: autorepeat, flags: modifierFlags)], [])

        case .releaseAll:
            return (releaseAll(), [])

        case .hello, .ping, .clipboard, .layout, .edgePush,
             .windowListRequest, .windowList, .virtualDisplay, .virtualReady, .virtualWindows, .moveWindowToVirtual, .recallWindows,
             .videoFormat, .videoFrame, .requestKeyframe, .clockProbe, .clockReply:
            return ([], [])
        }
    }

    /// 松开所有按住的键和鼠标按键（断线、退出时调用），先松普通键再松修饰键
    public func releaseAll() -> [InjectAction] {
        isActive = false
        var actions: [InjectAction] = heldButtons.sorted().map { .button($0, down: false, at: position, clickCount: 1) }
        heldButtons.removeAll()
        let keys = heldKeys.sorted { a, b in
            let (ma, mb) = (KeyCodes.isModifier(a), KeyCodes.isModifier(b))
            return ma != mb ? !ma : a < b
        }
        for key in keys {
            heldKeys.remove(key)
            actions.append(.key(code: key, down: false, autorepeat: false, flags: modifierFlags))
        }
        return actions
    }
}
