import Foundation
import Network
import Security

public enum Transport {
    public static let serviceType = "_boundless._tcp"
    public static let protocolVersion: UInt16 = 7

    /// TLS 1.2 预共享密钥 + TCP 关闭 Nagle，配对码不一致时握手直接失败；interface 非空时只走这张网卡
    public static func parameters(psk: Data, interface: NWInterface? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("boundless".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        if let interface { params.requiredInterface = interface }
        return params
    }
}

public enum LinkError: Error, LocalizedError {
    case timeout
    case handshakeTimeout
    case pathLost

    public var errorDescription: String? {
        switch self {
        case .timeout: return "心跳超时"
        case .handshakeTimeout: return "握手超时（配对码可能不正确）"
        case .pathLost: return "网络路径中断"
        }
    }
}

/// 一条已加密的消息通道：分帧、心跳、断线检测。事件在 delivery 队列（默认主线程）回调
public final class Link {
    public enum Event {
        case ready
        case message(Message)
        case closed(Error?)
    }

    public static let heartbeatInterval: TimeInterval = 1
    public static let timeout: TimeInterval = 4

    public var onEvent: ((Event) -> Void)?
    public let connection: NWConnection

    /// 当前是否走 Wi-Fi（否则是有线：USB / 雷雳直连或网线）
    public var usesWiFi: Bool { connection.currentPath?.usesInterfaceType(.wifi) ?? false }

    private let queue = DispatchQueue(label: "boundless.link")
    private let delivery: DispatchQueue
    private let handshakeTimeout: TimeInterval
    private var decoder = FrameDecoder()
    private var timer: DispatchSourceTimer?
    private var lastReceived = DispatchTime.now()
    private var ready = false
    private var finished = false
    private var viable = true
    private let backlogLock = NSLock()
    private var inFlight = 0

    public init(connection: NWConnection, delivery: DispatchQueue = .main, handshakeTimeout: TimeInterval = 8) {
        self.connection = connection
        self.delivery = delivery
        self.handshakeTimeout = handshakeTimeout
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        // 拔线等导致路径不可用时，1 秒内没恢复就断开，不必等 4 秒心跳超时
        connection.viabilityUpdateHandler = { [weak self] isViable in
            guard let self else { return }
            self.viable = isViable
            guard !isViable else { return }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.viable else { return }
                self.finish(LinkError.pathLost)
            }
        }
        connection.start(queue: queue)
        // 连 Bonjour 服务时 TLS 握手失败不会报错，而是在各地址间反复重试、一直停在 preparing，只能靠超时兜底
        queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish(LinkError.handshakeTimeout)
        }
    }

    /// 已交给系统、还没发完的消息数。视频通道据此丢帧，免得网络跟不上时画面延迟越攒越大
    public var backlog: Int {
        backlogLock.lock()
        defer { backlogLock.unlock() }
        return inFlight
    }

    public func send(_ message: Message) {
        backlogLock.lock()
        inFlight += 1
        backlogLock.unlock()
        connection.send(content: Frame.encode(message), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.backlogLock.lock()
            self.inFlight -= 1
            self.backlogLock.unlock()
            if let error { self.finish(error) }
        })
    }

    public func cancel() {
        queue.async { self.finish(nil) }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            lastReceived = .now()
            startHeartbeat()
            receive()
            deliver(.ready)
        case let .failed(error), let .waiting(error):
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.lastReceived = .now()
                do {
                    for m in try self.decoder.append(data) where m != .ping {
                        self.deliver(.message(m))
                    }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Link.heartbeatInterval, repeating: Link.heartbeatInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let silent = DispatchTime.now().uptimeNanoseconds - self.lastReceived.uptimeNanoseconds
            if silent > UInt64(Link.timeout * 1_000_000_000) {
                self.finish(LinkError.timeout)
            } else {
                self.send(.ping)
            }
        }
        t.resume()
        timer = t
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.cancel()
        deliver(.closed(error))
    }

    private func deliver(_ event: Event) {
        delivery.async { self.onEvent?(event) }
    }
}

/// 主控端监听：接受 TLS 连接，并通过 Bonjour 广播服务
public final class LinkListener {
    public var onConnection: ((NWConnection) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "boundless.listener")

    public init(psk: Data, serviceName: String?) throws {
        listener = try NWListener(using: Transport.parameters(psk: psk))
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: Transport.serviceType)
        }
    }

    public var port: UInt16? { listener.port?.rawValue }

    public func start(onReady: (() -> Void)? = nil) {
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async { self?.onConnection?(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { onReady?() }
            case let .failed(error):
                DispatchQueue.main.async { self?.onFailure?(error) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    public func cancel() {
        listener.cancel()
    }
}

/// 被控端：通过 Bonjour 查找局域网内的主控端
public final class ServiceBrowser {
    /// 发现的一台主控端，以及在哪些网卡上能找到它
    public struct Service {
        public var endpoint: NWEndpoint
        public var interfaces: [NWInterface]

        /// 能找到它的有线网卡（USB / 雷雳直连或网线）
        public var wiredInterface: NWInterface? { interfaces.first { $0.type == .wiredEthernet } }
    }

    public var onChange: (([String: Service]) -> Void)?

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "boundless.browser")

    public init() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: params)
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Service] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var service = found[name] ?? Service(endpoint: result.endpoint, interfaces: [])
                service.interfaces += result.interfaces.filter { i in !service.interfaces.contains { $0.name == i.name } }
                found[name] = service
            }
            DispatchQueue.main.async { self?.onChange?(found) }
        }
        browser.start(queue: queue)
    }

    public func cancel() {
        browser.cancel()
    }
}
