// 3D 科幻风图标渲染：swift scripts/icons/render.swift <输出目录>
// 用 SceneKit 渲染真实 3D 场景（PBR 金属/玻璃材质 + 自发光 + HDR 辉光），再裁进 macOS 圆角方形
import AppKit
import Metal
import SceneKit

let outDir = CommandLine.arguments.dropFirst().first ?? "."
let S = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - 2D 贴图工具

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

/// 横向渐变条，给管道沿长度方向上色
func strip(_ colors: [CGColor]) -> CGImage {
    image(512, 4) { $0.drawLinearGradient(gradient(colors), start: .zero, end: CGPoint(x: 512, y: 0), options: []) }
}

func radialGlow(_ color: UInt32, _ alpha: CGFloat = 1) -> CGImage {
    image(512, 512) {
        $0.drawRadialGradient(gradient([rgb(color, alpha), rgb(color, alpha * 0.35), rgb(color, 0)], [0, 0.45, 1]),
                              startCenter: CGPoint(x: 256, y: 256), startRadius: 0,
                              endCenter: CGPoint(x: 256, y: 256), endRadius: 256, options: [])
    }
}

/// 全息屏幕画面：暗底 + 网格 + 数据线
func screenTexture(_ tint: UInt32, _ accent: UInt32) -> CGImage {
    image(640, 440) { c in
        c.drawLinearGradient(gradient([rgb(0x050816), rgb(tint, 0.55)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 640, y: 440), options: [])
        c.setStrokeColor(rgb(tint, 0.35))
        c.setLineWidth(2)
        for x in stride(from: 0, through: 640, by: 40) { c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: 440)) }
        for y in stride(from: 0, through: 440, by: 40) { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 640, y: y)) }
        c.strokePath()
        c.setFillColor(rgb(accent, 0.95))
        for (i, w) in [300, 420, 220, 360].enumerated() {
            c.addPath(CGPath(roundedRect: CGRect(x: 60, y: 300 - i * 50, width: w, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
        }
        c.fillPath()
        c.setStrokeColor(rgb(accent, 0.9))
        c.setLineWidth(6)
        c.stroke(CGRect(x: 8, y: 8, width: 624, height: 424))
    }
}

/// 可平铺的霓虹网格
func gridTile(_ color: UInt32) -> CGImage {
    image(128, 128) { c in
        c.setFillColor(rgb(0x000000))
        c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        c.setFillColor(rgb(color))
        c.fill(CGRect(x: 0, y: 0, width: 128, height: 5))
        c.fill(CGRect(x: 0, y: 0, width: 5, height: 128))
    }
}

/// 合成波落日：上黄下粉渐变，下半部横向切条
func synthSun() -> CGImage {
    image(512, 512) { c in
        c.addEllipse(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        c.clip()
        c.drawLinearGradient(gradient([rgb(0xFF2E97), rgb(0xFF8A3D), rgb(0xFFE66D)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 512), options: [])
        c.setBlendMode(.clear)
        var y: CGFloat = 40
        var h: CGFloat = 26
        while y < 250 { c.fill(CGRect(x: 0, y: y, width: 512, height: h)); y += 52; h -= 4 }
    }
}

/// 反射用环境贴图（等距柱状投影）：深蓝底 + 几道亮光带，让金属有科幻感的高光
func environment() -> CGImage {
    image(1024, 512) { c in
        c.drawLinearGradient(gradient([rgb(0x02030A), rgb(0x141A4A), rgb(0x02030A)]), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 512), options: [])
        let bands: [(CGFloat, CGFloat, UInt32, CGFloat)] = [(430, 26, 0xFFFFFF, 1), (300, 14, 0x22D3EE, 0.9), (200, 18, 0xE879F9, 0.8), (90, 10, 0x6366F1, 0.8)]
        for (y, h, color, a) in bands {
            c.setFillColor(rgb(color, a))
            c.fill(CGRect(x: 0, y: y, width: 1024, height: h))
        }
        c.setFillColor(rgb(0xFFFFFF, 1))
        c.fill(CGRect(x: 120, y: 340, width: 180, height: 60))
        c.fill(CGRect(x: 640, y: 360, width: 120, height: 40))
    }
}

/// 深空背景：径向渐变 + 星点 + 透视网格
func spaceBackground(core: UInt32, edge: UInt32, grid: UInt32?) -> CGImage {
    image(S, S) { c in
        c.setFillColor(rgb(edge))
        c.fill(CGRect(x: 0, y: 0, width: S, height: S))
        c.drawRadialGradient(gradient([rgb(core), rgb(edge)]), startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
                             endCenter: CGPoint(x: 512, y: 600), endRadius: 620, options: [])
        var rng = SeededRandom(seed: 7)
        for _ in 0..<90 {
            let r = CGFloat(rng.next() % 3 + 1)
            c.setFillColor(rgb(0xFFFFFF, CGFloat(rng.next() % 60 + 20) / 100))
            c.fillEllipse(in: CGRect(x: CGFloat(rng.next() % 1024), y: CGFloat(rng.next() % 1024), width: r, height: r))
        }
        if let grid {
            c.setStrokeColor(rgb(grid, 0.22))
            c.setLineWidth(2)
            for i in -12...12 { c.move(to: CGPoint(x: 512, y: 470)); c.addLine(to: CGPoint(x: 512 + CGFloat(i) * 140, y: -200)) }
            var y: CGFloat = 440
            var step: CGFloat = 12
            while y > 0 { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 1024, y: y)); step *= 1.35; y -= step }
            c.strokePath()
        }
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % 100_000)
    }
}

// MARK: - 3D 工具

func pbr(_ diffuse: Any, metal: CGFloat, rough: CGFloat, emission: Any? = nil, emissionIntensity: CGFloat = 1) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = diffuse
    m.metalness.contents = metal
    m.roughness.contents = rough
    if let emission {
        m.emission.contents = emission
        m.emission.intensity = emissionIntensity
    }
    m.isDoubleSided = true
    return m
}

func neon(_ contents: Any, _ intensity: CGFloat) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = NSColor.black
    m.emission.contents = contents
    m.emission.intensity = intensity
    m.isDoubleSided = true
    return m
}

let chrome = pbr(NSColor(white: 0.95, alpha: 1), metal: 1, rough: 0.12)
let darkMetal = pbr(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.16, alpha: 1), metal: 0.9, rough: 0.25)

/// 沿曲线生成圆管网格（平行移动标架，避免扭曲），u 坐标沿长度 0→1
func tube(_ pts: [SIMD3<Float>], radius: Float, sides: Int = 32) -> SCNGeometry {
    var verts: [SCNVector3] = [], norms: [SCNVector3] = [], uvs: [CGPoint] = [], idx: [Int32] = []
    let n = pts.count
    func tangent(_ i: Int) -> SIMD3<Float> {
        simd_normalize(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
    }
    var normal = simd_normalize(simd_cross(tangent(0), SIMD3<Float>(0.3, 0.5, 0.8)))
    for i in 0..<n {
        let t = tangent(i)
        normal = simd_normalize(normal - simd_dot(normal, t) * t)
        let binormal = simd_cross(t, normal)
        for s in 0...sides {
            let a = Float(s) / Float(sides) * 2 * .pi
            let dir = cos(a) * normal + sin(a) * binormal
            let p = pts[i] + dir * radius
            verts.append(SCNVector3(p.x, p.y, p.z))
            norms.append(SCNVector3(dir.x, dir.y, dir.z))
            uvs.append(CGPoint(x: Double(i) / Double(n - 1), y: Double(s) / Double(sides)))
        }
    }
    for i in 0..<(n - 1) {
        for s in 0..<sides {
            let a = Int32(i * (sides + 1) + s), b = a + Int32(sides + 1)
            idx += [a, b, a + 1, a + 1, b, b + 1]
        }
    }
    return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms),
                                 SCNGeometrySource(textureCoordinates: uvs)],
                       elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
}

func bezier(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, steps: Int = 120) -> [SIMD3<Float>] {
    (0...steps).map { i in
        let t = Float(i) / Float(steps), u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    }
}

/// 挤出的立体光标，原点在箭头尖
func cursorNode(scale: CGFloat, depth: CGFloat, material: SCNMaterial) -> SCNNode {
    let raw: [(CGFloat, CGFloat)] = [(0, 0), (0, -22), (5, -17), (9, -26), (12.5, -24.5), (8.6, -15.6), (15.5, -15.6)]
    let path = NSBezierPath()
    for (i, p) in raw.enumerated() {
        let pt = NSPoint(x: p.0 * scale, y: p.1 * scale)
        i == 0 ? path.move(to: pt) : path.line(to: pt)
    }
    path.close()
    path.flatness = 0.002
    let shape = SCNShape(path: path, extrusionDepth: depth)
    shape.chamferRadius = depth * 0.35
    shape.materials = [material]
    return SCNNode(geometry: shape)
}

func light(_ type: SCNLight.LightType, _ color: NSColor, _ intensity: CGFloat, at pos: SCNVector3? = nil, lookAt: SCNVector3 = SCNVector3(0, 0, 0)) -> SCNNode {
    let l = SCNLight()
    l.type = type
    l.color = color
    l.intensity = intensity
    let n = SCNNode()
    n.light = l
    if let pos {
        n.position = pos
        n.look(at: lookAt)
    }
    return n
}

func makeScene(background: CGImage) -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = background
    scene.lightingEnvironment.contents = environment()
    scene.lightingEnvironment.intensity = 1.6
    let root = scene.rootNode
    root.addChildNode(light(.ambient, NSColor(srgbRed: 0.3, green: 0.3, blue: 0.5, alpha: 1), 120))
    root.addChildNode(light(.directional, .white, 900, at: SCNVector3(-4, 6, 8)))
    root.addChildNode(light(.omni, NSColor(srgbRed: 0.2, green: 0.9, blue: 1, alpha: 1), 900, at: SCNVector3(5, 2, 3)))
    root.addChildNode(light(.omni, NSColor(srgbRed: 1, green: 0.3, blue: 0.9, alpha: 1), 700, at: SCNVector3(-5, -2, 3)))
    return scene
}

func camera(z: Float = 12, y: Float = 0, lookAt: SCNVector3 = SCNVector3(0, 0, 0), fov: CGFloat = 32) -> SCNNode {
    let cam = SCNCamera()
    cam.fieldOfView = fov
    cam.zFar = 200
    cam.wantsHDR = true
    cam.bloomIntensity = 1.4
    cam.bloomThreshold = 0.75
    cam.bloomBlurRadius = 14
    cam.wantsExposureAdaptation = false
    cam.vignettingIntensity = 0.6
    cam.vignettingPower = 0.8
    let node = SCNNode()
    node.camera = cam
    node.position = SCNVector3(0, y, z)
    node.look(at: lookAt)
    return node
}

func render(_ scene: SCNScene, _ cam: SCNNode) -> CGImage {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    scene.rootNode.addChildNode(cam)
    renderer.pointOfView = cam
    let img = renderer.snapshot(atTime: 0, with: CGSize(width: S, height: S), antialiasingMode: .multisampling4X)
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// 裁进 macOS 圆角方形（824×824，四周留 100），加外投影和玻璃描边
func iconize(_ art: CGImage, rim: UInt32) -> CGImage {
    image(S, S) { c in
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.5))
        c.addPath(path)
        c.setFillColor(rgb(0x05060F))
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.addPath(path)
        c.clip()
        c.draw(art, in: CGRect(x: 0, y: 0, width: S, height: S))
        // 顶部玻璃反光
        c.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 640), options: [])
        c.restoreGState()

        c.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
        c.setLineWidth(4)
        c.replacePathWithStrokedPath()
        c.clip()
        c.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(rim, 0.35), rgb(0xFFFFFF, 0.08)]),
                             start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    }
}

func save(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
    print("已生成 \(url.path)")
}

// MARK: - A 双屏跃迁

func variantA() -> CGImage {
    let scene = makeScene(background: spaceBackground(core: 0x1B1464, edge: 0x03020C, grid: 0x6366F1))
    let root = scene.rootNode

    func monitor(x: Float, angle: CGFloat, tint: UInt32, accent: UInt32) {
        let box = SCNBox(width: 2.0, height: 1.36, length: 0.14, chamferRadius: 0.07)
        let screen = neon(screenTexture(tint, accent), 1.6)
        box.materials = [screen, darkMetal, darkMetal, darkMetal, darkMetal, darkMetal]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(x, -0.35, 0)
        node.eulerAngles.y = angle
        root.addChildNode(node)
        // 屏幕下方的全息投射光
        let glow = SCNPlane(width: 2.4, height: 0.9)
        glow.materials = [neon(radialGlow(accent, 0.8), 1.2)]
        glow.firstMaterial?.blendMode = .add
        let g = SCNNode(geometry: glow)
        g.position = SCNVector3(x, -1.35, 0)
        g.eulerAngles.x = -.pi / 2.4
        root.addChildNode(g)
    }
    monitor(x: -1.2, angle: 0.32, tint: 0x0EA5E9, accent: 0x67E8F9)
    monitor(x: 1.2, angle: -0.32, tint: 0xA21CAF, accent: 0xF0ABFC)

    let arcPts = bezier(SIMD3(-1.1, -0.2, 0.45), SIMD3(-0.7, 2.3, 1.2), SIMD3(0.7, 2.3, 1.2), SIMD3(1.0, -0.15, 0.55))
    let arc = SCNNode(geometry: tube(arcPts, radius: 0.075))
    arc.geometry?.materials = [neon(strip([rgb(0x22D3EE, 0.2), rgb(0x67E8F9), rgb(0xFFFFFF), rgb(0xF0ABFC)]), 2.6)]
    root.addChildNode(arc)

    for (i, p) in arcPts.enumerated() where i % 20 == 10 {
        let s = SCNNode(geometry: SCNSphere(radius: 0.05))
        s.geometry?.materials = [neon(NSColor.white, 3)]
        s.position = SCNVector3(p.x + 0.12, p.y + 0.18, p.z)
        root.addChildNode(s)
    }

    let cursor = cursorNode(scale: 0.05, depth: 0.22, material: chrome)
    cursor.position = SCNVector3(1.02, -0.12, 0.7)
    cursor.eulerAngles = SCNVector3(0.15, -0.45, 0.12)
    root.addChildNode(cursor)

    return iconize(render(scene, camera(z: 12, y: 0.4, lookAt: SCNVector3(0, 0.1, 0))), rim: 0x818CF8)
}

// MARK: - B 无限之环

func variantB() -> CGImage {
    let scene = makeScene(background: spaceBackground(core: 0x2A0B4D, edge: 0x050210, grid: nil))
    let root = scene.rootNode

    let a: Float = 2.25
    let pts: [SIMD3<Float>] = (0...400).map { i in
        let t = Float(i) / 400 * 2 * .pi
        let d = 1 + sin(t) * sin(t)
        return SIMD3(a * cos(t) / d, a * sin(t) * cos(t) / d, 0.5 * sin(t))
    }
    let ring = SCNNode(geometry: tube(pts, radius: 0.3, sides: 64))
    ring.geometry?.materials = [pbr(NSColor(white: 0.55, alpha: 1), metal: 1, rough: 0.22,
                                    emission: strip([rgb(0x06B6D4), rgb(0x4F46E5), rgb(0xC026D3), rgb(0xE11D48), rgb(0xC026D3), rgb(0x4F46E5), rgb(0x06B6D4)]),
                                    emissionIntensity: 0.55)]
    // 管道表面一条高亮霓虹细线，增强科幻感
    let lined = pts.map { $0 + SIMD3<Float>(0, 0, 0.31) }
    let core = SCNNode(geometry: tube(lined, radius: 0.035, sides: 12))
    core.geometry?.materials = [neon(strip([rgb(0x67E8F9), rgb(0xFFFFFF), rgb(0xF0ABFC), rgb(0xFFFFFF), rgb(0x67E8F9)]), 2.4)]

    let group = SCNNode()
    group.addChildNode(ring)
    group.addChildNode(core)
    group.eulerAngles = SCNVector3(-0.45, 0.25, -0.12)
    group.position = SCNVector3(0, -0.15, 0)
    root.addChildNode(group)

    let cursor = cursorNode(scale: 0.05, depth: 0.24, material: chrome)
    cursor.position = SCNVector3(1.05, 1.25, 1.2)
    cursor.eulerAngles = SCNVector3(0.2, -0.5, 0.15)
    root.addChildNode(cursor)

    let floorGlow = SCNNode(geometry: SCNPlane(width: 7, height: 3))
    floorGlow.geometry?.materials = [neon(radialGlow(0x7C3AED, 0.9), 1)]
    floorGlow.geometry?.firstMaterial?.blendMode = .add
    floorGlow.position = SCNVector3(0, -2.0, -0.5)
    floorGlow.eulerAngles.x = -.pi / 2.3
    root.addChildNode(floorGlow)

    return iconize(render(scene, camera(z: 12, y: 0.8, lookAt: SCNVector3(0, 0, 0))), rim: 0xE879F9)
}

// MARK: - C 传送门

func variantC() -> CGImage {
    let scene = makeScene(background: spaceBackground(core: 0x062C43, edge: 0x01060C, grid: 0x0EA5E9))
    let root = scene.rootNode

    let portal = SCNNode()
    portal.eulerAngles = SCNVector3(0, 0.62, 0)
    portal.position = SCNVector3(0.35, -0.05, -0.6)
    root.addChildNode(portal)

    let outer = SCNNode(geometry: SCNTorus(ringRadius: 1.75, pipeRadius: 0.16))
    outer.geometry?.materials = [pbr(NSColor(white: 0.85, alpha: 1), metal: 1, rough: 0.2, emission: NSColor(srgbRed: 0.2, green: 0.85, blue: 1, alpha: 1), emissionIntensity: 1.4)]
    outer.eulerAngles.x = .pi / 2
    portal.addChildNode(outer)

    let inner = SCNNode(geometry: SCNTorus(ringRadius: 1.48, pipeRadius: 0.05))
    inner.geometry?.materials = [neon(NSColor(srgbRed: 1, green: 0.35, blue: 0.9, alpha: 1), 3)]
    inner.eulerAngles.x = .pi / 2
    portal.addChildNode(inner)

    let disc = SCNNode(geometry: SCNPlane(width: 3.1, height: 3.1))
    let discMat = neon(radialGlow(0x38BDF8, 0.9), 1.3)
    discMat.blendMode = .add
    disc.geometry?.materials = [discMat]
    portal.addChildNode(disc)

    for i in 0..<14 {
        let angle = Float(i) / 14 * 2 * .pi
        let s = SCNNode(geometry: SCNSphere(radius: CGFloat(0.035 + Float(i % 3) * 0.015)))
        s.geometry?.materials = [neon(NSColor.white, 3)]
        s.position = SCNVector3(cos(angle) * 2.05, sin(angle) * 2.05, Float(i % 4) * 0.1)
        portal.addChildNode(s)
    }

    let cursor = cursorNode(scale: 0.075, depth: 0.32, material: chrome)
    cursor.position = SCNVector3(-0.35, 1.05, 0.9)
    cursor.eulerAngles = SCNVector3(0.1, 0.75, 0.2)
    root.addChildNode(cursor)

    return iconize(render(scene, camera(z: 12, y: 0.2)), rim: 0x38BDF8)
}

// MARK: - D 无尽地平线

func variantD() -> CGImage {
    let sky = image(S, S) { c in
        c.drawLinearGradient(gradient([rgb(0x020212), rgb(0x1E0B3D), rgb(0x7A1B6B), rgb(0xFF5E8A)], [0, 0.45, 0.8, 1]),
                             start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 470), options: [])
        c.draw(synthSun(), in: CGRect(x: 302, y: 420, width: 420, height: 420))
        c.setFillColor(rgb(0x020212))
        c.fill(CGRect(x: 0, y: 0, width: 1024, height: 470))
    }
    let scene = makeScene(background: sky)
    scene.fogColor = NSColor(srgbRed: 0.35, green: 0.08, blue: 0.3, alpha: 1)
    scene.fogStartDistance = 10
    scene.fogEndDistance = 45
    let root = scene.rootNode

    let floor = SCNNode(geometry: SCNPlane(width: 120, height: 120))
    let gridMat = neon(gridTile(0xE879F9), 2.2)
    gridMat.emission.wrapS = .repeat
    gridMat.emission.wrapT = .repeat
    gridMat.emission.mipFilter = .linear
    gridMat.emission.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)
    floor.geometry?.materials = [gridMat]
    floor.eulerAngles.x = -.pi / 2
    floor.position = SCNVector3(0, -1.6, -40)
    root.addChildNode(floor)

    let cursor = cursorNode(scale: 0.085, depth: 0.4, material: chrome)
    cursor.position = SCNVector3(-0.55, 1.35, 1.5)
    cursor.eulerAngles = SCNVector3(0.25, 0.55, 0.12)
    root.addChildNode(cursor)

    let shadow = SCNNode(geometry: SCNPlane(width: 2.6, height: 2.6))
    let shadowMat = neon(radialGlow(0x22D3EE, 0.9), 1.4)
    shadowMat.blendMode = .add
    shadow.geometry?.materials = [shadowMat]
    shadow.eulerAngles.x = -.pi / 2
    shadow.position = SCNVector3(0.1, -1.58, 1.2)
    root.addChildNode(shadow)

    return iconize(render(scene, camera(z: 12, y: 0.3, lookAt: SCNVector3(0, 0.25, 0))), rim: 0xFF5E8A)
}

save(variantA(), "A-双屏跃迁.png")
save(variantB(), "B-无限之环.png")
save(variantC(), "C-传送门.png")
save(variantD(), "D-无尽地平线.png")
