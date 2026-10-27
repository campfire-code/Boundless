import BoundlessCore
import CoreGraphics
import Foundation

enum Role: String {
    /// 共享本机键鼠
    case server
    /// 被另一台控制
    case client
}

/// 持久化设置。基于 UserDefaults，所以可以用命令行参数临时覆盖，例如 `-role client -dryRun YES`
final class Settings {
    private let defaults = UserDefaults.standard

    var role: Role? {
        get { defaults.string(forKey: "role").flatMap(Role.init) }
        set { defaults.set(newValue?.rawValue, forKey: "role") }
    }

    /// 屏幕排列：被控端桌面外框左上角在主控端坐标系中的位置；nil 表示用默认摆放
    var arrangementOrigin: CGPoint? {
        get {
            guard let v = defaults.array(forKey: "arrangementOrigin") as? [Double], v.count == 2 else { return nil }
            return CGPoint(x: v[0], y: v[1])
        }
        set { defaults.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: "arrangementOrigin") }
    }

    /// 最近一次收到的被控端屏幕布局，被控端未连接时也能打开排列窗口
    var clientDisplays: [CGRect] {
        get {
            (defaults.array(forKey: "clientDisplays") as? [[Double]] ?? [])
                .filter { $0.count == 4 }
                .map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
        set { defaults.set(newValue.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }, forKey: "clientDisplays") }
    }

    /// 最近一次连接的被控端名称
    var clientName: String? {
        get { defaults.string(forKey: "clientName") }
        set { defaults.set(newValue, forKey: "clientName") }
    }

    /// 主控端的配对码，首次读取时生成
    var serverCode: String {
        if let code = defaults.string(forKey: "serverCode").flatMap(Pairing.normalize) { return code }
        return regenerateServerCode()
    }

    @discardableResult
    func regenerateServerCode() -> String {
        let code = Pairing.generateCode()
        defaults.set(code, forKey: "serverCode")
        return code
    }

    /// 被控端输入的配对码
    var clientCode: String? {
        get { defaults.string(forKey: "clientCode").flatMap(Pairing.normalize) }
        set { defaults.set(newValue, forKey: "clientCode") }
    }

    /// 被控端指定连接的主控端；nil 表示只发现一台时自动连接
    var preferredServer: String? {
        get { defaults.string(forKey: "preferredServer") }
        set { defaults.set(newValue, forKey: "preferredServer") }
    }

    var clipboardSync: Bool {
        get { defaults.object(forKey: "clipboardSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardSync") }
    }

    /// 联调用：被控端只打印注入动作
    var dryRun: Bool { defaults.bool(forKey: "dryRun") }

    /// 调试用：虚拟屏画面每 2 秒在日志里打印流畅度统计（帧率、码率、卡顿间隔、延迟、丢帧）
    var streamStats: Bool { defaults.bool(forKey: "streamStats") }

    /// 调试用：主控端连上后自动把应用名或标题包含这个关键词的被控端窗口挪过来，便于不点菜单反复压测
    var autoMove: String? { defaults.string(forKey: "autoMove") }
}
