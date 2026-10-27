import Network
import XCTest
@testable import BoundlessCore

/// 本机回环上的真实 TLS-PSK 连接测试
final class LinkTests: XCTestCase {
    private func startListener(psk: Data, onConnection: @escaping (NWConnection) -> Void) throws -> LinkListener {
        let listener = try LinkListener(psk: psk, serviceName: nil)
        listener.onConnection = onConnection
        let ready = expectation(description: "listener ready")
        listener.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        return listener
    }

    private func connect(port: UInt16, psk: Data) -> Link {
        Link(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: Transport.parameters(psk: psk)))
    }

    func testMessagesFlowBothWaysWithMatchingCode() throws {
        let psk = Pairing.presharedKey(for: Pairing.generateCode())
        let serverGot = expectation(description: "server got key")
        let clientGot = expectation(description: "client got leave")
        var serverLink: Link?

        let listener = try startListener(psk: psk) { connection in
            let link = Link(connection: connection)
            serverLink = link
            link.onEvent = { event in
                if case .message(.key(code: 12, down: true, autorepeat: false)) = event {
                    serverGot.fulfill()
                    link.send(.edgePush(x: 1, y: 2))
                }
            }
            link.start()
        }

        let client = connect(port: listener.port!, psk: psk)
        client.onEvent = { event in
            switch event {
            case .ready: client.send(.key(code: 12, down: true, autorepeat: false))
            case .message(.edgePush(x: 1, y: 2)): clientGot.fulfill()
            default: break
            }
        }
        client.start()

        wait(for: [serverGot, clientGot], timeout: 5)
        client.cancel()
        serverLink?.cancel()
        listener.cancel()
    }

    func testVideoFramesAndBacklogDrain() throws {
        let psk = Pairing.presharedKey(for: Pairing.generateCode())
        let frame = Data((0..<(400 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let got = expectation(description: "all frames arrived")
        got.expectedFulfillmentCount = 30
        var serverLink: Link?

        let listener = try startListener(psk: psk) { connection in
            let link = Link(connection: connection)
            serverLink = link
            link.onEvent = { event in
                if case let .message(.videoFrame(window: 1, keyframe: _, captureTime: _, data: data)) = event {
                    XCTAssertEqual(data, frame)
                    got.fulfill()
                }
            }
            link.start()
        }

        let client = connect(port: listener.port!, psk: psk)
        client.onEvent = { event in
            guard case .ready = event else { return }
            client.send(.hello(version: Transport.protocolVersion, name: "测试", channel: .video))
            for i in 0..<30 { client.send(.videoFrame(window: 1, keyframe: i == 0, captureTime: 0, data: frame)) }
            XCTAssertGreaterThan(client.backlog, 0)
        }
        client.start()

        wait(for: [got], timeout: 10)
        XCTAssertEqual(client.backlog, 0, "全部发完后积压应归零")
        client.cancel()
        serverLink?.cancel()
        listener.cancel()
    }

    func testWrongCodeIsRejected() throws {
        let serverPSK = Pairing.presharedKey(for: Pairing.generateCode())
        let clientPSK = Pairing.presharedKey(for: Pairing.generateCode())
        let closed = expectation(description: "client closed")
        var becameReady = false
        var serverMessages = 0
        var serverLink: Link?

        let listener = try startListener(psk: serverPSK) { connection in
            let link = Link(connection: connection)
            serverLink = link
            link.onEvent = { if case .message = $0 { serverMessages += 1 } }
            link.start()
        }

        let client = connect(port: listener.port!, psk: clientPSK)
        client.onEvent = { event in
            switch event {
            case .ready:
                becameReady = true
                client.send(.releaseAll)
            case .closed: closed.fulfill()
            default: break
            }
        }
        client.start()

        wait(for: [closed], timeout: 8)
        XCTAssertFalse(becameReady, "配对码不一致时不应握手成功")
        XCTAssertEqual(serverMessages, 0)
        serverLink?.cancel()
        listener.cancel()
    }

    func testLargeClipboardPayloadArrivesIntact() throws {
        let psk = Pairing.presharedKey(for: Pairing.generateCode())
        let payload = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let got = expectation(description: "clipboard arrived")
        var serverLink: Link?

        let listener = try startListener(psk: psk) { connection in
            let link = Link(connection: connection)
            serverLink = link
            link.onEvent = { event in
                if case let .message(.clipboard(items)) = event {
                    XCTAssertEqual(items, [ClipboardItem(type: "public.png", data: payload)])
                    got.fulfill()
                }
            }
            link.start()
        }

        let client = connect(port: listener.port!, psk: psk)
        client.onEvent = { event in
            if case .ready = event { client.send(.clipboard([ClipboardItem(type: "public.png", data: payload)])) }
        }
        client.start()

        wait(for: [got], timeout: 10)
        client.cancel()
        serverLink?.cancel()
        listener.cancel()
    }

    func testHandshakeThatNeverCompletesTimesOut() throws {
        // 只接受 TCP、从不回应 TLS 的对端，模拟握手卡住
        let listener = try NWListener(using: .tcp)
        var accepted: [NWConnection] = []
        let listening = expectation(description: "tcp listener ready")
        listener.newConnectionHandler = { c in accepted.append(c); c.start(queue: .main) }
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: .main)
        wait(for: [listening], timeout: 5)

        let closed = expectation(description: "handshake timed out")
        let client = Link(connection: NWConnection(host: "127.0.0.1", port: listener.port!,
                                                   using: Transport.parameters(psk: Pairing.presharedKey(for: Pairing.generateCode()))),
                          handshakeTimeout: 1)
        client.onEvent = { event in
            if case let .closed(error) = event {
                XCTAssertEqual(error as? LinkError, .handshakeTimeout)
                closed.fulfill()
            }
        }
        client.start()
        wait(for: [closed], timeout: 5)
        accepted.forEach { $0.cancel() }
        listener.cancel()
    }

    func testPeerDisappearingIsDetected() throws {
        let psk = Pairing.presharedKey(for: Pairing.generateCode())
        let closed = expectation(description: "client noticed server gone")
        var serverLink: Link?

        let listener = try startListener(psk: psk) { connection in
            let link = Link(connection: connection)
            serverLink = link
            link.onEvent = { if case .ready = $0 { link.cancel() } }
            link.start()
        }

        let client = connect(port: listener.port!, psk: psk)
        client.onEvent = { if case .closed = $0 { closed.fulfill() } }
        client.start()

        wait(for: [closed], timeout: Link.timeout + 3)
        _ = serverLink
        listener.cancel()
    }
}
