import CoreGraphics
import Network
import XCTest
@testable import BoundlessCore

/// 与 Windows 版（Rust）的互通测试：真实的 Bonjour 发现 + TLS-PSK 握手 + 全部消息往返。
/// 需要先编译 Rust 对端，再用环境变量指给测试：
///   (cd windows && cargo build --example peer)
///   BOUNDLESS_RUST_PEER=$PWD/windows/target/debug/examples/peer swift test --filter InteropTests
final class InteropTests: XCTestCase {
    private var peer: Process?

    override func tearDown() {
        peer?.terminate()
        peer = nil
    }

    private func peerPath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["BOUNDLESS_RUST_PEER"] else {
            throw XCTSkip("未设置 BOUNDLESS_RUST_PEER，跳过与 Windows 版的互通测试")
        }
        return path
    }

    private func launchPeer(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try peerPath())
        p.arguments = args
        try p.run()
        peer = p
    }

    /// 启动 Rust 主控端，返回它的监听端口（对端在标准输出打印 "READY <端口>"）
    private func launchServePeer(code: String, name: String) throws -> UInt16 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try peerPath())
        p.arguments = ["serve", code, name]
        let pipe = Pipe()
        p.standardOutput = pipe
        let ready = expectation(description: "Rust 主控端开始监听")
        var port: UInt16 = 0
        pipe.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            if port == 0, let line = text.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }),
               let n = UInt16(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                port = n
                ready.fulfill()
            }
        }
        try p.run()
        peer = p
        wait(for: [ready], timeout: 10)
        pipe.fileHandleForReading.readabilityHandler = nil
        return port
    }

    private static let samples: [Message] = [
        .hello(version: Transport.protocolVersion, name: "Mac 互通测试", channel: .control, platform: .mac),
        .layout(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -98.5, width: 1920, height: 1080)]),
        .enter(x: 3.5, y: 490.25),
        .leave,
        .edgePush(x: -4, y: 120.5),
        .mouseMove(dx: -3.5, dy: 12.25),
        .mouseButton(button: 2, down: true, clickCount: 2),
        .scroll(ScrollEvent(deltaAxis1: -1, deltaAxis2: 2, pointDeltaAxis1: -10, pointDeltaAxis2: 20,
                            fixedDeltaAxis1: -1.5, fixedDeltaAxis2: 2.5, isContinuous: true, scrollPhase: 2, momentumPhase: 1)),
        .key(code: 55, down: false, autorepeat: true),
        .systemKey(data1: 0x000A_0A00),
        .clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("你好，Windows".utf8)),
                    ClipboardItem(type: "public.png", data: Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }))]),
        .releaseAll,
        .windowListRequest,
        .windowList([RemoteWindow(id: 42, app: "终端", title: "kl — zsh", frame: CGRect(x: 10, y: 38, width: 585, height: 368))]),
        .virtualDisplay(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
        .virtualReady(frame: .zero),
        .virtualWindows(capture: CGRect(x: 0, y: 32, width: 1216, height: 808), windows: [CGRect(x: 10, y: 38, width: 1200, height: 800)]),
        .moveTo(x: -1820.5, y: 300),
        .moveWindowToVirtual(window: 42),
        .recallWindows,
        .videoFormat(window: 0, codec: .hevc, nalLengthSize: 4, parameterSets: [Data([0x40, 1]), Data([0x42])]),
        .videoFrame(window: 0, keyframe: true, captureTime: 1_792_000_000.125, data: Data(repeating: 0x26, count: 200_000)),
        .requestKeyframe(window: 0),
        .clockProbe(serverTime: 1_792_000_000.5),
        .clockReply(serverTime: 1_792_000_000.5, clientTime: 1_792_000_000.25),
    ]

    /// 连上后先收到 Rust 的 hello，再把发过去的每条消息原样收回。
    /// 给了 onEarlyClose 时，提前断开交给调用方处理而不是直接判失败
    private func exchange(over link: Link, done: XCTestExpectation, onEarlyClose: ((Error?) -> Void)? = nil) {
        var received: [Message] = []
        link.onEvent = { event in
            switch event {
            case .ready:
                Self.samples.forEach(link.send)
            case let .message(m):
                received.append(m)
                guard received.count == Self.samples.count + 1 else { return }
                XCTAssertEqual(received[0], .hello(version: Transport.protocolVersion, name: "Rust 对端", channel: .control, platform: .windows))
                for (got, sent) in zip(received.dropFirst(), Self.samples) { XCTAssertEqual(got, sent) }
                done.fulfill()
            case let .closed(error):
                guard received.count <= Self.samples.count else { return }
                if let onEarlyClose { onEarlyClose(error) } else { XCTFail("连接提前关闭：\(String(describing: error))") }
            }
        }
        link.start()
    }

    private func browse(for name: String) -> ServiceBrowser.Service? {
        let browser = ServiceBrowser()
        let found = expectation(description: "通过 Bonjour 找到 Rust 主控端")
        var service: ServiceBrowser.Service?
        browser.onChange = { services in
            if service == nil, let s = services[name] {
                service = s
                found.fulfill()
            }
        }
        browser.start()
        wait(for: [found], timeout: 15)
        browser.cancel()
        return service
    }

    /// 连到 endpoint 并做全部消息往返，返回是否成功
    private func roundTrip(to endpoint: NWEndpoint, code: String) -> Bool {
        let finished = expectation(description: "往返结束")
        var ok = false
        let done = XCTestExpectation(description: "全部消息往返")
        let link = Link(connection: NWConnection(to: endpoint, using: Transport.parameters(psk: Pairing.presharedKey(for: code))))
        exchange(over: link, done: done) { error in
            print("连接 \(endpoint) 提前关闭：\(String(describing: error))")
            finished.fulfill()
        }
        DispatchQueue.global().async {
            if XCTWaiter().wait(for: [done], timeout: 20) == .completed {
                ok = true
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 25)
        link.cancel()
        return ok
    }

    func testMacConnectsToRustServerFoundViaBonjour() throws {
        let code = Pairing.generateCode()
        let name = "无界互通-\(UUID().uuidString.prefix(6))"
        let port = try launchServePeer(code: code, name: name)
        let service = try XCTUnwrap(browse(for: name))
        if roundTrip(to: service.endpoint, code: code) { return }
        // GitHub Actions 的 macOS 机器上，测试进程经 Bonjour 解析出的局域网地址连不通（peer 日志里看不到任何新连接），
        // 只在 CI 上退回回环地址验证协议本身；本机运行时 Bonjour 路径必须一次成功
        guard ProcessInfo.processInfo.environment["CI"] != nil else {
            return XCTFail("经 Bonjour 连接 Rust 主控端失败")
        }
        print("⚠️ CI 上经 Bonjour 连接失败，改走回环地址 127.0.0.1:\(port) 验证协议互通")
        XCTAssertTrue(roundTrip(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), code: code))
    }

    func testRustConnectsToMacServerFoundViaMDNS() throws {
        let code = Pairing.generateCode()
        let name = "无界互通-\(UUID().uuidString.prefix(6))"
        let listener = try LinkListener(psk: Pairing.presharedKey(for: code), serviceName: name)
        let done = expectation(description: "全部消息往返")
        var serverLink: Link?
        listener.onConnection = { [unowned self] connection in
            let link = Link(connection: connection)
            serverLink = link
            self.exchange(over: link, done: done)
        }
        let ready = expectation(description: "监听就绪")
        listener.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)

        try launchPeer(["connect", code, name])
        wait(for: [done], timeout: 30)
        serverLink?.cancel()
        listener.cancel()
    }

    func testWrongCodeIsRejectedByRustServer() throws {
        let name = "无界互通-\(UUID().uuidString.prefix(6))"
        _ = try launchServePeer(code: Pairing.generateCode(), name: name)
        let service = try XCTUnwrap(browse(for: name))

        let closed = expectation(description: "握手失败")
        var becameReady = false
        let link = Link(connection: NWConnection(to: service.endpoint,
                                                 using: Transport.parameters(psk: Pairing.presharedKey(for: Pairing.generateCode()))))
        link.onEvent = { event in
            switch event {
            case .ready: becameReady = true
            case .closed: closed.fulfill()
            case .message: break
            }
        }
        link.start()
        wait(for: [closed], timeout: 15)
        XCTAssertFalse(becameReady, "配对码不一致时不应握手成功")
    }
}
