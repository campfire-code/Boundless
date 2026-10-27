import CoreGraphics

/// 屏幕的一条边
public enum Edge: UInt8, CaseIterable {
    case left, right, top, bottom

    public var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

/// 一台 Mac 的全部显示器，使用 CG 全局坐标（左上角为原点，y 向下）
public struct Desktop: Equatable {
    public var displays: [CGRect]

    public init(displays: [CGRect]) {
        self.displays = displays
    }

    public func display(containing p: CGPoint) -> CGRect? {
        displays.first { $0.contains(p) }
    }

    /// 把点收回到最近的显示器内
    public func clamp(_ p: CGPoint) -> CGPoint {
        if displays.isEmpty || display(containing: p) != nil { return p }
        var best = p
        var bestDistance = Double.infinity
        for d in displays {
            let q = CGPoint(x: min(max(p.x, d.minX), d.maxX - 1), y: min(max(p.y, d.minY), d.maxY - 1))
            let distance = hypot(q.x - p.x, q.y - p.y)
            if distance < bestDistance {
                best = q
                bestDistance = distance
            }
        }
        return best
    }

    /// 点是否贴在整个桌面的外沿 edge 上（边外没有其他显示器）
    public func isAtEdge(_ p: CGPoint, _ edge: Edge) -> Bool {
        let q = clamp(p)
        guard let d = display(containing: q) else { return false }
        let beyond: CGPoint
        switch edge {
        case .left:
            guard q.x < d.minX + 1 else { return false }
            beyond = CGPoint(x: d.minX - 1, y: q.y)
        case .right:
            guard q.x >= d.maxX - 2 else { return false }
            beyond = CGPoint(x: d.maxX + 1, y: q.y)
        case .top:
            guard q.y < d.minY + 1 else { return false }
            beyond = CGPoint(x: q.x, y: d.minY - 1)
        case .bottom:
            guard q.y >= d.maxY - 2 else { return false }
            beyond = CGPoint(x: q.x, y: d.maxY + 1)
        }
        return display(containing: beyond) == nil
    }

    /// 所有显示器的外框
    public var bounds: CGRect {
        displays.isEmpty ? .zero : displays.reduce(CGRect.null) { $0.union($1) }
    }

    /// 带菜单栏的主屏（原点在 (0,0)）
    public var main: CGRect? {
        displays.first { $0.origin == .zero } ?? displays.first
    }

    /// 光标贴在桌面外沿并继续往外推时，返回推出去的那个点（紧贴边外）；没有推出桌面返回 nil
    public func pointBeyond(_ p: CGPoint, dx: Double, dy: Double) -> CGPoint? {
        let q0 = clamp(p)
        guard let d = display(containing: q0) else { return nil }
        var q = CGPoint(x: q0.x + dx, y: q0.y + dy)
        var pushed = false
        if dx > 0, isAtEdge(q0, .right) { q.x = max(q.x, d.maxX); pushed = true }
        if dx < 0, isAtEdge(q0, .left) { q.x = min(q.x, d.minX - 0.5); pushed = true }
        if dy > 0, isAtEdge(q0, .bottom) { q.y = max(q.y, d.maxY); pushed = true }
        if dy < 0, isAtEdge(q0, .top) { q.y = min(q.y, d.minY - 0.5); pushed = true }
        guard pushed, display(containing: q) == nil else { return nil }
        return q
    }
}
