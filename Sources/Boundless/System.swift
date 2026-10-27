import AppKit
import BoundlessCore
import SystemConfiguration

enum Permissions {
    /// 截获（主控端）和注入（被控端）事件都需要
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// 主控端读取键盘事件需要
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// 被控端把窗口显示到主控端（采集虚拟屏）需要
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

extension Desktop {
    /// 当前所有活动的真实显示器（不含无界自己建的虚拟屏）
    static func current() -> Desktop {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Desktop(displays: ids.prefix(Int(count)).filter { !VirtualDisplay.ownedIDs.contains($0) }.map { CGDisplayBounds($0) })
    }
}

enum SystemInfo {
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
