import CoreGraphics

/// 虚拟副屏：被控端上一块看不见的虚拟屏，和主控端的一块屏幕一样大、一一对应。
/// 窗口拖到虚拟屏上，主控端就在那块屏幕的同一位置把它显示出来
public struct VirtualScreen: Equatable {
    /// 主控端那块屏幕（主控端坐标）
    public var server: CGRect
    /// 被控端虚拟屏（被控端坐标）
    public var client: CGRect

    public init(server: CGRect, client: CGRect) {
        self.server = server
        self.client = client
    }

    /// 主控端屏幕上的点 → 虚拟屏上的点；不在这块屏幕上时先收到屏幕边上
    public func toClient(_ p: CGPoint) -> CGPoint {
        let q = CGPoint(x: min(max(p.x, server.minX), server.maxX - 1), y: min(max(p.y, server.minY), server.maxY - 1))
        return CGPoint(x: client.minX + q.x - server.minX, y: client.minY + q.y - server.minY)
    }

    /// 虚拟屏上的外框（相对虚拟屏左上角）→ 主控端坐标
    public func toServer(relative r: CGRect) -> CGRect {
        r.offsetBy(dx: server.minX, dy: server.minY)
    }
}

extension Arrangement {
    /// 虚拟屏该放在哪：取与被控端屏幕贴边最长的那块主控端屏幕，按排列换算到被控端坐标。
    /// 这样被控端光标从贴着的那段边推出去，正好进入虚拟屏上对应主控端的位置
    public func virtualScreen(for server: Desktop) -> VirtualScreen? {
        let edges = sharedEdges(with: server)
        func shared(_ s: CGRect) -> CGFloat {
            edges.filter { e in s.insetBy(dx: -1, dy: -1).contains(e.from) && s.insetBy(dx: -1, dy: -1).contains(e.to) }
                .reduce(0) { $0 + hypot($1.to.x - $1.from.x, $1.to.y - $1.from.y) }
        }
        guard let best = server.displays.max(by: { shared($0) < shared($1) }), shared(best) > 0 else { return nil }
        return VirtualScreen(server: best, client: CGRect(origin: toClient(best.origin), size: best.size))
    }
}
