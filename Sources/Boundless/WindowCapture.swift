import AppKit
import BoundlessCore
import ScreenCaptureKit

/// 被控端：查询、挪动本机窗口（需要「辅助功能」和「屏幕录制」权限）
enum LocalWindows {
    /// 真实屏幕上的普通窗口（可以挪到主控端的）：排除菜单栏、Dock、太小的窗口、无界自己和已在虚拟屏上的
    static func list(completion: @escaping ([RemoteWindow]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            if let error {
                NSLog("Boundless 被控端：读取窗口列表失败 \(error)")
                // 缺「屏幕录制」权限时主控端只能看到空列表，这边主动弹出授权，让用户知道去哪里开
                if !CGPreflightScreenCaptureAccess() { DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() } }
            }
            let all = content?.windows ?? []
            DispatchQueue.main.async {
                let own = Bundle.main.bundleIdentifier
                let real = Desktop.current()
                let windows = all
                    .filter { $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 60 }
                    .filter { w in real.displays.contains { $0.intersects(w.frame) } }
                    .compactMap { w -> RemoteWindow? in
                        guard let app = w.owningApplication, app.bundleIdentifier != own else { return nil }
                        // 没有应用包的程序（命令行工具开的窗口）系统给不出应用名，用进程名代替
                        let name = app.applicationName.isEmpty
                            ? NSRunningApplication(processIdentifier: app.processID)?.localizedName ?? "未知应用" : app.applicationName
                        return RemoteWindow(id: w.windowID, app: name, title: w.title ?? "", frame: w.frame)
                    }
                    .sorted { ($0.app, $0.title) < ($1.app, $1.title) }
                completion(windows)
            }
        }
    }

    /// 窗口当前外框（全局坐标，点）和所属进程；窗口已关闭时返回 nil
    static func info(_ id: UInt32) -> (frame: CGRect, pid: pid_t)? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[CFString: Any]],
              let entry = list.first,
              let bounds = entry[kCGWindowBounds] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              let pid = entry[kCGWindowOwnerPID] as? pid_t else { return nil }
        return (frame, pid)
    }

    /// 这个点上最前面的普通窗口（窗口号、外框、进程、应用名、标题）
    static func topmost(at point: CGPoint) -> (window: RemoteWindow, pid: pid_t)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        else { return nil }
        for entry in list {
            guard (entry[kCGWindowLayer] as? Int) == 0,
                  let bounds = entry[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            guard let id = entry[kCGWindowNumber] as? UInt32, let pid = entry[kCGWindowOwnerPID] as? pid_t else { return nil }
            let app = entry[kCGWindowOwnerName] as? String ?? ""
            return (RemoteWindow(id: id, app: app, title: entry[kCGWindowName] as? String ?? "", frame: frame), pid)
        }
        return nil
    }

    /// 把窗口挪到指定位置（左上角，全局坐标）
    static func move(_ id: UInt32, pid: pid_t, to origin: CGPoint) {
        guard let window = axWindow(id, pid: pid) else { return }
        var p = origin
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    /// 由窗口号找到辅助功能里的窗口对象：优先用私有接口 _AXUIElementGetWindow 精确匹配，拿不到时按外框匹配
    private static func axWindow(_ id: UInt32, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        if let getWindow = getWindowFunction {
            for w in windows {
                var wid: CGWindowID = 0
                if getWindow(w, &wid) == .success, wid == id { return w }
            }
        }
        guard let frame = info(id)?.frame else { return nil }
        return windows.first { axFrame($0).map { hypot($0.minX - frame.minX, $0.minY - frame.minY) < 2 && abs($0.width - frame.width) < 2 } ?? false }
    }

    private static func axFrame(_ w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFunction: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindow.self)
    }()
}
