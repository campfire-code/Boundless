import CoreGraphics

/// 被控端屏幕在主控端坐标系中的摆放位置（相当于系统设置里的「显示器排列」）
public struct Arrangement: Equatable {
    /// 被控端自己的显示器，使用被控端的全局坐标
    public var clientDisplays: [CGRect]
    /// 被控端桌面外框的左上角，放在主控端坐标系中的位置
    public var origin: CGPoint

    public init(clientDisplays: [CGRect], origin: CGPoint) {
        self.clientDisplays = clientDisplays
        self.origin = origin
    }

    /// 两块屏幕贴合的一段边，光标只能从这里穿过
    public struct Segment: Equatable {
        public var from: CGPoint
        public var to: CGPoint
    }

    public var clientBounds: CGRect { Desktop(displays: clientDisplays).bounds }
    public var placedBounds: CGRect { CGRect(origin: origin, size: clientBounds.size) }
    public var placedDisplays: [CGRect] { clientDisplays.map { $0.offsetBy(dx: shift.dx, dy: shift.dy) } }

    private var shift: CGVector {
        CGVector(dx: origin.x - clientBounds.minX, dy: origin.y - clientBounds.minY)
    }

    public func toServer(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + shift.dx, y: p.y + shift.dy) }
    public func toClient(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - shift.dx, y: p.y - shift.dy) }

    /// 主控端坐标上的点若落在被控端某块屏幕上，返回它在被控端的坐标
    public func clientPoint(atServer p: CGPoint) -> CGPoint? {
        placedDisplays.contains { $0.contains(p) } ? toClient(p) : nil
    }

    /// 被控端上离主控端某点最近的位置（快捷键切换时的落点）
    public func nearestClientPoint(toServer p: CGPoint) -> CGPoint {
        Desktop(displays: clientDisplays).clamp(toClient(p))
    }

    /// 被控端整体位于主控端的哪一侧，决定切换快捷键的方向
    public func side(relativeTo server: Desktop) -> Edge {
        let s = server.bounds, c = placedBounds
        if c.minX >= s.maxX - 1 { return .right }
        if c.maxX <= s.minX + 1 { return .left }
        if c.maxY <= s.minY + 1 { return .top }
        if c.minY >= s.maxY - 1 { return .bottom }
        let dx = c.midX - s.midX, dy = c.midY - s.midY
        return abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top)
    }

    public func sharedEdges(with server: Desktop) -> [Segment] {
        var segments: [Segment] = []
        for c in placedDisplays {
            for s in server.displays {
                for x in [s.maxX, s.minX] where abs(c.minX - x) < 0.5 || abs(c.maxX - x) < 0.5 {
                    let lo = max(c.minY, s.minY), hi = min(c.maxY, s.maxY)
                    if hi > lo { segments.append(Segment(from: CGPoint(x: x, y: lo), to: CGPoint(x: x, y: hi))) }
                }
                for y in [s.maxY, s.minY] where abs(c.minY - y) < 0.5 || abs(c.maxY - y) < 0.5 {
                    let lo = max(c.minX, s.minX), hi = min(c.maxX, s.maxX)
                    if hi > lo { segments.append(Segment(from: CGPoint(x: lo, y: y), to: CGPoint(x: hi, y: y))) }
                }
            }
        }
        return segments
    }

    /// 默认放在主控端右侧，与主屏垂直居中
    public static func defaultPlacement(clientDisplays: [CGRect], server: Desktop) -> Arrangement {
        let size = Desktop(displays: clientDisplays).bounds.size
        let main = server.main ?? .zero
        let placed = Arrangement(clientDisplays: clientDisplays,
                                 origin: CGPoint(x: server.bounds.maxX, y: main.midY - size.height / 2))
        return placed.snapped(to: server)
    }

    /// 吸附到最近的主控端屏幕边上：贴边、至少重叠 minOverlap、不与主控端屏幕重叠
    public func snapped(to server: Desktop, minOverlap: CGFloat = 40) -> Arrangement {
        let b = placedBounds
        var best: Arrangement?
        var bestDistance = CGFloat.infinity
        for s in server.displays {
            let oy = min(minOverlap, s.height, b.height)
            let ox = min(minOverlap, s.width, b.width)
            let y = min(max(b.minY, s.minY - b.height + oy), s.maxY - oy)
            let x = min(max(b.minX, s.minX - b.width + ox), s.maxX - ox)
            let candidates = [
                CGPoint(x: s.maxX, y: y), CGPoint(x: s.minX - b.width, y: y),
                CGPoint(x: x, y: s.maxY), CGPoint(x: x, y: s.minY - b.height),
            ]
            for o in candidates {
                let candidate = Arrangement(clientDisplays: clientDisplays, origin: o)
                guard !candidate.overlaps(server) else { continue }
                let distance = hypot(o.x - b.minX, o.y - b.minY)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
        }
        return best ?? self
    }

    private func overlaps(_ server: Desktop) -> Bool {
        placedDisplays.contains { c in
            server.displays.contains { s in
                let i = c.intersection(s)
                return !i.isNull && i.width > 0.5 && i.height > 0.5
            }
        }
    }
}
