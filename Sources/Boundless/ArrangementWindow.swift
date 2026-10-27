import AppKit
import BoundlessCore

/// 屏幕排列画布：画出主控端显示器和被控端屏幕，拖动被控端屏幕调整摆放位置
final class ArrangementView: NSView {
    var serverDesktop = Desktop(displays: []) { didSet { refresh() } }
    var arrangement: Arrangement? { didSet { refresh() } }
    var serverName = ""
    var clientName = ""
    var onCommit: ((CGPoint) -> Void)?

    private var dragStart: NSPoint?
    private var dragStartOrigin: CGPoint?
    private var dragOrigin: CGPoint?

    private let serverFill = NSGradient(starting: NSColor(srgbRed: 0.27, green: 0.30, blue: 0.38, alpha: 1),
                                        ending: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.23, alpha: 1))!
    private let clientFill = NSGradient(starting: NSColor(srgbRed: 0.66, green: 0.33, blue: 0.97, alpha: 1),
                                        ending: NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1))!
    private let edgeColor = NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1)

    override var isFlipped: Bool { true }

    // MARK: - 坐标换算

    /// 画布容纳主控端桌面，四周各留一个被控端大小的空间供拖放；拖动中保持不变，避免画面跳动
    private var transform: (scale: CGFloat, offset: CGPoint) {
        let size = arrangement?.clientBounds.size ?? .zero
        let world = serverDesktop.bounds.insetBy(dx: -size.width * 1.05, dy: -size.height * 1.05)
        let area = bounds.insetBy(dx: 20, dy: 20)
        guard world.width > 0, world.height > 0 else { return (1, .zero) }
        let scale = min(area.width / world.width, area.height / world.height)
        return (scale, CGPoint(x: area.midX - world.midX * scale, y: area.midY - world.midY * scale))
    }

    private func toView(_ r: CGRect) -> CGRect {
        let t = transform
        return CGRect(x: r.minX * t.scale + t.offset.x, y: r.minY * t.scale + t.offset.y,
                      width: r.width * t.scale, height: r.height * t.scale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let t = transform
        return CGPoint(x: p.x * t.scale + t.offset.x, y: p.y * t.scale + t.offset.y)
    }

    /// 当前显示的排列（拖动中为临时位置）
    private var shown: Arrangement? {
        guard let arrangement else { return nil }
        guard let dragOrigin else { return arrangement }
        return Arrangement(clientDisplays: arrangement.clientDisplays, origin: dragOrigin)
    }

    private func refresh() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        panel.fill()
        drawDotGrid()
        NSColor.separatorColor.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        for d in serverDesktop.displays {
            drawScreen(toView(d), fill: serverFill, isMain: d == serverDesktop.main,
                       title: d == serverDesktop.main ? serverName : nil, size: d.size)
        }

        guard let shown else {
            drawCentered("被控端还没连接过，连上一次后就能在这里排列屏幕", color: .secondaryLabelColor)
            return
        }

        let snapped = dragOrigin == nil ? shown : shown.snapped(to: serverDesktop)
        for segment in snapped.sharedEdges(with: serverDesktop) { drawSharedEdge(segment) }

        if dragOrigin != nil {
            for d in snapped.placedDisplays {
                let ghost = NSBezierPath(roundedRect: toView(d), xRadius: 6, yRadius: 6)
                ghost.setLineDash([6, 4], count: 2, phase: 0)
                ghost.lineWidth = 2
                NSColor.systemPurple.withAlphaComponent(0.8).setStroke()
                ghost.stroke()
            }
        }

        NSGraphicsContext.saveGraphicsState()
        if dragOrigin != nil {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
        }
        for (i, d) in shown.placedDisplays.enumerated() {
            drawScreen(toView(d), fill: clientFill, isMain: false,
                       title: i == 0 ? clientName : nil, size: shown.clientDisplays[i].size)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDotGrid() {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        for x in stride(from: bounds.minX + 12, to: bounds.maxX, by: 18) {
            for y in stride(from: bounds.minY + 12, to: bounds.maxY, by: 18) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.6, height: 1.6)).fill()
            }
        }
    }

    private func drawScreen(_ rect: CGRect, fill: NSGradient, isMain: Bool, title: String?, size: CGSize) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fill.draw(in: path, angle: -90)
        if isMain {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(4, rect.height * 0.06)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()

        let sizeText = "\(Int(size.width)) × \(Int(size.height))"
        var lines: [(String, NSFont, NSColor)] = []
        if let title, !title.isEmpty { lines.append((title, .boldSystemFont(ofSize: 12), .white)) }
        lines.append((sizeText, .systemFont(ofSize: 10), NSColor.white.withAlphaComponent(0.7)))
        let attributed = lines.map { NSAttributedString(string: $0.0, attributes: [.font: $0.1, .foregroundColor: $0.2]) }
        let total = attributed.reduce(0) { $0 + $1.size().height } + CGFloat(attributed.count - 1) * 2
        guard total < rect.height - 8 else { return }
        var y = rect.midY - total / 2
        for a in attributed {
            let s = a.size()
            guard s.width < rect.width - 8 else { continue }
            a.draw(at: NSPoint(x: rect.midX - s.width / 2, y: y))
            y += s.height + 2
        }
    }

    private func drawSharedEdge(_ segment: Arrangement.Segment) {
        let path = NSBezierPath()
        path.move(to: toView(segment.from))
        path.line(to: toView(segment.to))
        path.lineWidth = 4
        path.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = edgeColor
        glow.shadowBlurRadius = 8
        glow.set()
        edgeColor.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCentered(_ text: String, color: NSColor) {
        let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color])
        let s = a.size()
        a.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.maxY - 36))
    }

    // MARK: - 拖动

    private func clientRectsInView() -> [CGRect] {
        shown?.placedDisplays.map(toView) ?? []
    }

    override func resetCursorRects() {
        for r in clientRectsInView() { addCursorRect(r, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let arrangement, clientRectsInView().contains(where: { $0.contains(p) }) else { return }
        dragStart = p
        dragStartOrigin = arrangement.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let dragStartOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale = transform.scale
        dragOrigin = CGPoint(x: dragStartOrigin.x + (p.x - dragStart.x) / scale,
                             y: dragStartOrigin.y + (p.y - dragStart.y) / scale)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        NSCursor.pop()
        if let shown, dragOrigin != nil {
            let snapped = shown.snapped(to: serverDesktop)
            dragOrigin = nil
            arrangement = snapped
            onCommit?(snapped.origin)
        }
        dragStart = nil
        dragStartOrigin = nil
        refresh()
    }
}

/// 「屏幕排列」窗口
final class ArrangementWindowController: NSWindowController {
    private let server: ServerController
    private let canvas = ArrangementView()
    private let hint = NSTextField(wrappingLabelWithString: "")

    init(server: ServerController) {
        self.server = server
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "屏幕排列"
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 13)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetArrangement))
        let done = NSButton(title: "完成", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, done])
        buttons.orientation = .horizontal

        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        canvas.onCommit = { [weak self] origin in self?.server.setArrangementOrigin(origin) }

        let stack = NSStackView(views: [hint, canvas, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [hint, canvas, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        reload()
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 创建") }

    func reload() {
        let name = server.clientName
        canvas.serverName = SystemInfo.computerName
        canvas.clientName = name
        canvas.serverDesktop = server.desktop
        canvas.arrangement = server.arrangement
        hint.stringValue = "把紫色的「\(name)」拖到它相对这台 Mac 屏幕的实际位置，松手后会自动贴边。光标只能从两块屏幕贴合的青色边穿过去。"
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func resetArrangement() {
        server.resetArrangement()
    }

    @objc private func finish() {
        close()
    }
}
