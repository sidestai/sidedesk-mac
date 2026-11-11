import Foundation
import SideDeskCore

/// 一条后端 WebSocket 连接的抽象（测试注入点；生产为 `URLSessionWebSocketTask` 包装）。
/// 对应 C# `ClientWebSocket` 的 ConnectAsync/SendAsync/ReceiveAsync/CloseAsync 四件事：
/// resume+ping 等价 ConnectAsync（握手确认），receive 返回 nil 等价收到 Close 帧。
public protocol BackendSocketConnection: AnyObject {
    func resume()
    /// 握手确认：成功即连接已建立（对应 C# ConnectAsync 完成）
    func ping() async throws
    func send(text: String) async throws
    /// 收一条文本消息；nil = 对端关闭；throw = 连接断开
    func receive() async throws -> String?
    func cancel()
}

/// 生产连接：URLSessionWebSocketTask。会话由服务持有（超时配置对齐 C# 连接超时 10 秒）。
final class URLSessionBackendSocket: BackendSocketConnection {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
    }

    func resume() { task.resume() }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
    func send(text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8)
        @unknown default: return nil
        }
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

/// 后端 WebSocket 客户端服务：与后端建立长连接。对应 C# `Services.BackendWebSocketService`。
///
/// 地址从 `Constants.URLs.serverBaseUrl` 派生：生产 wss://api.sidedesk.bigjing.com/ws
/// （网关 /ws 反代到后端 19190）；本地开发（loopback）回退直连 ws://127.0.0.1:19190。
/// 已登录时 `Start(token)` 以用户身份连接；未登录时 `Start(nil)` 以访客（设备）身份连接。
/// 连接 URL 始终携带 deviceId（设备指纹），供后端按设备推送与给未登录用户广播。
/// 支持自动重连（指数退避、最多 10 次）、心跳保活（30 秒 ping）。
///
/// 与 C# 的平台差异：
/// - 省去连接前的 TCP 端口探测（C# 用它避免 Windows 上后端未启动时反复抛 WebSocketException；
///   URLSession 握手失败本身就干净利落，探测属多余往返）；
/// - 握手确认用 `sendPing`（URLSession 的 resume 不等待握手完成），10 秒超时与 C# ConnectAsync 一致；
/// - DPAPI/Dispatcher 等 Windows 设施不存在，事件回调经 `Seam.uiPost` 由消费方自行投递。
public final class BackendWebSocketService {

    /// 心跳间隔（秒），对应 C# HeartbeatIntervalMs = 30_000
    static let heartbeatInterval: TimeInterval = 30
    /// 最大重连次数，对应 C# MaxReconnectAttempts
    static let maxReconnectAttempts = 10
    /// 基础重连延迟（秒），对应 C# BaseReconnectDelayMs = 3_000
    static let baseReconnectDelay: TimeInterval = 3
    /// 握手超时（秒），对应 C# connectCts.CancelAfter(10s)
    static let connectTimeout: TimeInterval = 10

    /// 连接成功时触发（对应 C# Connected 事件）
    public var Connected: (() -> Void)?
    /// 连接断开时触发（对应 C# Disconnected 事件）
    public var Disconnected: (() -> Void)?
    /// 收到文本消息时触发（对应 C# MessageReceived 事件；回调异常由消费方自行兜底）
    public var MessageReceived: ((String) -> Void)?

    /// 测试注入：连接工厂（url → 连接替身）。生产 nil 走 URLSessionWebSocketTask。
    var connectFactory: ((URL) -> BackendSocketConnection)?
    /// 测试注入：重连等待（默认 Task.sleep；测试置空转以确定性驱动退避逻辑）
    var delayProvider: ((TimeInterval) async -> Void)?

    private let stateLock = SyncLock()
    private var running = false
    private var connected = false
    private var token: String?
    private var reconnectAttempts = 0
    /// 连接代次：身份变更重启时旧循环的清理不得触碰新连接的状态
    private var generation = 0
    private var loopTask: Task<Void, Never>?
    private var socket: BackendSocketConnection?
    private var heartbeat: ServiceTimer?

    private var session: URLSession?

    private func defaultSession() -> URLSession {
        if let s = session { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.connectTimeout
        let s = URLSession(configuration: config)
        session = s
        return s
    }

    /// 发送串行门（对应 C# _sendLock 信号量）：actor 方法天然串行
    private let sendGate = SendGate()
    private actor SendGate {
        func send(_ conn: BackendSocketConnection, _ text: String) async throws {
            try await conn.send(text: text)
        }
    }

    /// 是否已连接到后端（对应 C# IsConnected）
    public var IsConnected: Bool { stateLock.withLock { connected } }
    /// 服务是否处于运行状态（含重连等待期间，对应 C# IsRunning）
    public var IsRunning: Bool { stateLock.withLock { running } }

    public init() {}

    deinit { session?.finishTasksAndInvalidate() }

    // MARK: - 地址派生

    /// WebSocket 基址（不含 query）。对应 C# WsBaseUrl：https→wss、http→ws，
    /// 去掉 /console 等子路径只留 host[:port]，拼网关反代路径 /ws；loopback 直连 19190。
    static func wsBaseUrl(from serverBaseUrl: String) -> String {
        guard let uri = URL(string: serverBaseUrl), let host = uri.host else { return serverBaseUrl }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if isLoopback { return "ws://127.0.0.1:19190" }
        let scheme = uri.scheme == "https" ? "wss" : "ws"
        let port = uri.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/ws"
    }

    static var wsBaseUrl: String { wsBaseUrl(from: Constants.URLs.serverBaseUrl) }

    /// 指数退避延迟（秒）：min(3 × 2^min(n-1,5), 60)，对应 C# 重连延迟公式
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        let exp = min(max(attempt - 1, 0), 5)
        return min(baseReconnectDelay * pow(2.0, Double(exp)), 60)
    }

    // MARK: - 起停

    /// 启动 WebSocket 连接（幂等：身份未变时跳过；身份变化时重连）。
    /// token 为空表示以访客（未登录设备）身份连接，仅凭 deviceId 标识。对应 C# Start。
    public func Start(_ token: String?) {
        let t = (token ?? "").isEmpty ? nil : token
        enum Action { case skip, restart, fresh }
        let action: Action = stateLock.withLock {
            if running { return self.token == t ? .skip : .restart }
            return .fresh
        }
        if action == .skip {
            RuntimeLog.debug("[BackendWS] already running, skipping duplicate start")
            return
        }
        if action == .restart {
            RuntimeLog.warn("[BackendWS] connection identity changed, reconnecting")
            stopInternal()
        }
        let gen: Int = stateLock.withLock {
            self.token = t
            running = true
            reconnectAttempts = 0
            generation += 1
            return generation
        }
        RuntimeLog.info(t == nil ? Lang.t("system.backendWsStartedGuest") : Lang.t("system.backendWsStartedLoggedIn"))
        loopTask = Task { [weak self] in await self?.connectLoop(generation: gen) }
    }

    /// 停止 WebSocket 连接（主动停止后不再自动重连）。对应 C# Stop。
    public func Stop() {
        guard IsRunning else { return }
        RuntimeLog.info("[BackendWS] stopping...")
        stopInternal()
        RuntimeLog.info("[BackendWS] stopped")
    }

    private func stopInternal() {
        stateLock.withLock {
            running = false
            connected = false
            generation += 1   // 作废仍在跑的旧循环清理
        }
        loopTask?.cancel()
        loopTask = nil
        stopHeartbeat()
        let conn = stateLock.withLock { () -> BackendSocketConnection? in
            let s = socket; socket = nil; return s
        }
        conn?.cancel()
    }

    // MARK: - 连接主循环

    /// 连接 → 收消息 → 断线后自动重连。对应 C# ConnectLoopAsync。
    private func connectLoop(generation gen: Int) async {
        while !Task.isCancelled && IsRunning {
            var conn: BackendSocketConnection?
            do {
                let url = buildConnectUrl()
                let c = connectFactory?(url) ?? URLSessionBackendSocket(url: url, session: defaultSession())
                conn = c
                stateLock.withLock { socket = c }
                let isGuest = stateLock.withLock { token == nil }
                RuntimeLog.info("[BackendWS] connecting to \(url.host ?? "") (\(isGuest ? "guest" : "logged in")) ...")
                try await establish(c)

                stateLock.withLock {
                    connected = true
                    reconnectAttempts = 0
                }
                RuntimeLog.info("[BackendWS] connected")
                Connected?()
                startHeartbeat()

                try await receiveLoop(c)
            } catch {
                if Task.isCancelled { break }
                RuntimeLog.error("[BackendWS] connection error: \(error.localizedDescription)")
            }

            // 连接断开：仅当本循环仍是当前代次时才动共享状态（身份变更重启后旧循环不得误清新连接）
            let wasConnected: Bool = stateLock.withLock {
                guard generation == gen else { return false }
                let c = connected
                connected = false
                return c
            }
            if wasConnected { Disconnected?() }
            if stateLock.withLock({ generation == gen }) { stopHeartbeat() }
            conn?.cancel()

            if !Task.isCancelled && IsRunning && stateLock.withLock({ generation == gen }) {
                let attempt: Int = stateLock.withLock {
                    reconnectAttempts += 1
                    return reconnectAttempts
                }
                if attempt > Self.maxReconnectAttempts {
                    RuntimeLog.error("[BackendWS] max reconnect attempts (\(Self.maxReconnectAttempts)) reached, giving up")
                    stateLock.withLock { running = false }
                    break
                }
                let delay = Self.reconnectDelay(attempt: attempt)
                RuntimeLog.warn("[BackendWS] retry #\(attempt) in \(Int(delay))s...")
                if let delayProvider {
                    await delayProvider(delay)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if Task.isCancelled { break }
            }
        }
    }

    /// 握手确认：resume 后以 ping 往返判定连接建立（C# ConnectAsync 的等价物），超时 10 秒。
    private func establish(_ conn: BackendSocketConnection) async throws {
        conn.resume()
        struct ConnectTimeout: Error {}
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await conn.ping(); return true }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
                return false
            }
            let ok = try await group.next() ?? false
            group.cancelAll()
            while let _ = try? await group.next() {}
            if !ok { throw ConnectTimeout() }
        }
    }

    private func buildConnectUrl() -> URL {
        let base = Self.wsBaseUrl
        let deviceId = DeviceIdService.deviceId
        let t = stateLock.withLock { token }
        let query: String
        if let t, !t.isEmpty {
            query = "?token=\(BackendApiClient.queryValue(t))&deviceId=\(BackendApiClient.queryValue(deviceId))"
        } else {
            query = "?deviceId=\(BackendApiClient.queryValue(deviceId))"
        }
        return URL(string: base + query) ?? URL(string: base)!
    }

    /// 接收消息循环。对应 C# ReceiveLoopAsync（Close 帧/异常都回主循环走重连）。
    private func receiveLoop(_ conn: BackendSocketConnection) async throws {
        while !Task.isCancelled {
            guard let text = try await conn.receive() else {
                RuntimeLog.warn("[BackendWS] server closed connection")
                return
            }
            RuntimeLog.debug("[BackendWS] message received: \(text)")
            MessageReceived?(text)
        }
    }

    // MARK: - 发送

    /// 发送文本消息到后端（未连接时静默丢弃，对应 C# SendAsync）。
    public func send(_ text: String) async {
        let conn = stateLock.withLock { socket }
        guard let conn, IsConnected else { return }
        do {
            try await sendGate.send(conn, text)
        } catch {
            RuntimeLog.warn("[BackendWS] send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Seam.timerFactory(Self.heartbeatInterval) { [weak self] in
            guard let self, self.IsConnected else { return }
            Task { await self.send(#"{"event":"ping"}"#) }
        }
        heartbeat = timer
        timer.start()
    }

    private func stopHeartbeat() {
        heartbeat?.stop()
        heartbeat = nil
    }
}