import AppKit
import BoundlessCore

/// 被控端：把注入动作变成系统事件（需要「辅助功能」权限）。dryRun 时只打印不注入，用于联调
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let dryRun: Bool
    private var flags = CGEventFlags(rawValue: KeyCodes.Flag.nonCoalesced)

    init(dryRun: Bool) {
        self.dryRun = dryRun
        // 默认注入后会屏蔽本机键鼠 0.25 秒，关掉以免影响 Mac mini 自己的鼠标
        source?.localEventsSuppressionInterval = 0
    }

    func perform(_ action: InjectAction) {
        if dryRun {
            FileHandle.standardError.write(Data("[dry-run] \(action)\n".utf8))
            return
        }
        switch action {
        case let .warp(point):
            postMouse(.mouseMoved, at: point, button: 0)

        case let .move(point, dx, dy, dragButton):
            let type: CGEventType
            switch dragButton {
            case nil: type = .mouseMoved
            case 0?: type = .leftMouseDragged
            case 1?: type = .rightMouseDragged
            default: type = .otherMouseDragged
            }
            postMouse(type, at: point, button: dragButton ?? 0) { e in
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
            }

        case let .button(button, down, point, clickCount):
            let type: CGEventType
            switch button {
            case 0: type = down ? .leftMouseDown : .leftMouseUp
            case 1: type = down ? .rightMouseDown : .rightMouseUp
            default: type = down ? .otherMouseDown : .otherMouseUp
            }
            postMouse(type, at: point, button: button) { e in
                e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }

        case let .scroll(s):
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: s.isContinuous ? .pixel : .line, wheelCount: 2,
                                  wheel1: s.isContinuous ? s.pointDeltaAxis1 : s.deltaAxis1,
                                  wheel2: s.isContinuous ? s.pointDeltaAxis2 : s.deltaAxis2, wheel3: 0)
            else { return }
            e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(s.deltaAxis1))
            e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(s.deltaAxis2))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(s.pointDeltaAxis1))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(s.pointDeltaAxis2))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.fixedDeltaAxis1)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.fixedDeltaAxis2)
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.isContinuous ? 1 : 0)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(s.scrollPhase))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(s.momentumPhase))
            e.flags = flags
            e.post(tap: .cghidEventTap)

        case let .key(code, down, autorepeat, newFlags):
            flags = CGEventFlags(rawValue: newFlags)
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            if KeyCodes.isModifier(code) || code == KeyCodes.capsLock { e.type = .flagsChanged }
            e.flags = flags
            e.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
            e.post(tap: .cghidEventTap)

        case let .systemKey(data1):
            // data1 第 8~15 位是按键状态：0xA 按下，0xB 松开
            let state = (Int(data1) >> 8) & 0xFF
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: state == 0xA ? 0xA00 : 0xB00),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: Int(data1), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: UInt8, configure: (CGEvent) -> Void = { _ in }) {
        let cgButton: CGMouseButton = button == 0 ? .left : button == 1 ? .right : .center
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)
        else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        e.flags = flags
        configure(e)
        e.post(tap: .cghidEventTap)
    }
}
