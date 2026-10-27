import AppKit
import BoundlessCore

/// 主控端：用 CGEventTap 截获本机键鼠事件，handler 返回 false 的事件会被吞掉
final class InputCapture {
    var handler: ((InputEvent) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cursorHidden = false
    /// 移动光标用的事件源：屏蔽时长设为 0，移动后不会屏蔽真实鼠标
    private let moveSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    private static let systemDefinedType: UInt32 = 14 // NX_SYSDEFINED，媒体键
    private static let mediaKeySubtype: Int16 = 8

    var isRunning: Bool { tap != nil }

    /// 需要「辅助功能」权限，未授权时返回 false
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        var mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        mask |= 1 << CGEventMask(InputCapture.systemDefinedType)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let capture = Unmanaged<InputCapture>.fromOpaque(refcon!).takeUnretainedValue()
                return capture.process(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        InputCapture.allowCursorHidingInBackground()
        return true
    }

    func stop() {
        returnLocal(warpTo: nil)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// 进入远程模式：光标与鼠标解耦（原地不动但照样上报位移）并隐藏
    func enterRemote() {
        CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden {
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHidden = true
        }
    }

    func returnLocal(warpTo point: CGPoint?) {
        CGAssociateMouseAndMouseCursorPosition(1)
        if let point { moveCursor(to: point) }
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
    }

    /// 发一个移动事件来移动光标。不用 CGWarpMouseCursorPosition：它会让系统屏蔽真实鼠标约 250ms，切回时光标先卡住不动
    private func moveCursor(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: moveSource, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            CGWarpMouseCursorPosition(point)
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let input = translate(type, event) else { return Unmanaged.passUnretained(event) }
        let pass = handler?(input) ?? true
        return pass ? Unmanaged.passUnretained(event) : nil
    }

    private func translate(_ type: CGEventType, _ event: CGEvent) -> InputEvent? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .mouseMove(location: event.location,
                              dx: event.getDoubleValueField(.mouseEventDeltaX),
                              dy: event.getDoubleValueField(.mouseEventDeltaY))

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            return .mouseButton(button: UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber)),
                                down: down,
                                clickCount: Int32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventClickState)))

        case .scrollWheel:
            return .scroll(InputCapture.scrollEvent(event))

        case .keyDown, .keyUp:
            return .key(code: keyCode(event), down: type == .keyDown,
                        autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        flags: event.flags.rawValue)

        case .flagsChanged:
            let code = keyCode(event)
            let flags = event.flags.rawValue
            if code == KeyCodes.capsLock {
                return .key(code: code, down: flags & KeyCodes.Flag.capsLock != 0, autorepeat: false, flags: flags)
            }
            guard KeyCodes.isModifier(code) else { return nil }
            return .key(code: code, down: KeyCodes.isModifierDown(code, flags: flags), autorepeat: false, flags: flags)

        default:
            guard type.rawValue == InputCapture.systemDefinedType,
                  let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == InputCapture.mediaKeySubtype
            else { return nil }
            return .systemKey(data1: Int32(truncatingIfNeeded: ns.data1))
        }
    }

    private func keyCode(_ event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// 原样取出滚轮事件的各滚动字段
    static func scrollEvent(_ event: CGEvent) -> ScrollEvent {
        ScrollEvent(
            deltaAxis1: int32(event, .scrollWheelEventDeltaAxis1),
            deltaAxis2: int32(event, .scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: int32(event, .scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: int32(event, .scrollWheelEventPointDeltaAxis2),
            fixedDeltaAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedDeltaAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: int32(event, .scrollWheelEventScrollPhase),
            momentumPhase: int32(event, .scrollWheelEventMomentumPhase))
    }

    private static func int32(_ event: CGEvent, _ field: CGEventField) -> Int32 {
        Int32(truncatingIfNeeded: event.getIntegerValueField(field))
    }

    /// 后台应用默认无法隐藏光标，这里打开 WindowServer 连接的 SetsCursorInBackground 属性（私有接口，失败则光标保持可见）
    private static func allowCursorHidingInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
