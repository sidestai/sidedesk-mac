import Foundation
import Network
import SideDeskCore

/// 浏览器扩展/外部程序连上本地 WS 服务后的元数据。对应 C# `WsClientInfo`。
public final class WsClientInfo {
    public let id: String
    public var uniqId = ""      // 扩展端生成的唯一标识
    public var title = ""
    public var url = ""
    public var tabId: Int?
    public let connectedAt = Date()

    init(id: String) { self.id = id }
}

/// 扩展取数通道的发送接缝：`ExtensionPollEngine` 只经它下发消息（单测注入替身即可）。
/// 由 `WebSocketServerService` 实现。
public protocol ExtensionTransport: AnyObject {
    var isRunning: Bool { get }
    var clientCount: Int { get }
    func broadcast(_ message: String)
}

/// 本地 WebSocket 服务端：启动时监听 127.0.0.1:19191，供浏览器扩展/外部程序与 SideDesk 双向通信。
/// 对应 C# `Services/WebSocketServerService.cs`（分帧协议见 `WsProtocol.swift`）。
///
/// macOS 侧用 Network.framework 的 `NWListener` 取代 C# 的 `TcpListener`：
/// 同样只依赖 TCP，不经系统 HTTP 升级 API；监听地址固定回环，不对外。
public final class WebSocketServerService: ExtensionTransport {

    /// 监听地址（仅回环：扩展桥不暴露到局域网）
    public static let host = "127.0.0.1"
    /// 监听端口：`SIDESK_WS_PORT` 环境变量 > `runtime-config.json` 的 `ws.port` > 默认 19191
    public static var port: Int { RuntimeConfig.getInt("ws.port", RuntimeConfig.webSocketPortDefault) }

    /// 收到文本消息（客户端 Id, 消息文本）
    public var MessageReceived: ((String, String) -> Void)?
    /// 客户端接入
    public var ClientConnected: ((String) -> Void)?
    /// 客户端断开
    public var ClientDisconnected: ((String) -> Void)?
    /// 客户端元数据更新（register 消息）
    public var ClientInfoUpdated: (() -> Void)?

    public private(set) var isRunning = false
    public var clientCount: Int { snapshotCount() }

    private let queue = DispatchQueue(label: "sidedesk.ws.server")
    private var listener: NWListener?
    private var clients: [String: ServerConnection] = [:]
    private var clientInfo: [String: WsClientInfo] = [:]

    public init() {}

    /// 启动服务端（幂等：已运行时重复调用无副作用）
    public func start() {
        queue.sync { startLocked() }
    }

    /// 指定端口启动（测试用固定/随机端口）
    public func start(port: Int) {
        queue.sync { startLocked(port: port) }
    }

    private func startLocked(port: Int? = nil) {
        if isRunning { return }
        let bindPort = port ?? Self.port
        guard let p = NWEndpoint.Port(rawValue: UInt16(bindPort)) else {
            RuntimeLog.debug("[WebSocketServer] start failed: invalid port \(bindPort)")
            return
        }
        let params = NWParameters.tcp
        // 只绑回环：扩展桥不暴露到局域网（与 C# TcpListener(IPAddress.Loopback) 同口径）
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
        do {
            let l = try NWListener(using: params, on: p)
            l.newConnectionHandler = { [weak self] conn in self?.handleNewConnection(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let err):
                    RuntimeLog.debug("[WebSocketServer] listener failed: \(err.localizedDescription)")
                    self?.isRunning = false
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
            isRunning = true
            RuntimeLog.debug("[WebSocketServer] started, listening on ws://\(Self.host):\(bindPort)/")
        } catch {
            isRunning = false
            RuntimeLog.debug("[WebSocketServer] start failed: \(error.localizedDescription)")
        }
    }

    /// 停止服务端并断开所有连接
    public func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            for (_, conn) in clients { conn.abort() }
            clients.removeAll()
            clientInfo.removeAll()
            listener?.cancel()
            listener = nil
            RuntimeLog.debug("[WebSocketServer] stopped")
        }
    }

    /// 向指定客户端发送文本消息
    public func send(clientId: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let conn = self.clients[clientId] else {
                RuntimeLog.debug("[WebSocketServer] send skipped [\(clientId)]: socket missing (current=\(self?.clients.count ?? 0))")
                return
            }
            conn.sendText(message)
        }
    }

    /// 向所有已连接客户端广播文本消息
    public func broadcast(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            RuntimeLog.debug("[WebSocketServer] broadcasting, current client count=\(self.clients.count)")
            for (_, conn) in self.clients { conn.sendText(message) }
        }
    }

    /// 更新客户端元数据（由 register 消息触发）
    public func updateClientInfo(clientId: String, uniqId: String, title: String, url: String, tabId: Int?) {
        queue.async { [weak self] in
            guard let self, let info = self.clientInfo[clientId] else { return }
            info.uniqId = uniqId
            info.title = title
            info.url = url
            info.tabId = tabId
            self.ClientInfoUpdated?()
        }
    }

    /// 所有已连接客户端的元数据列表
    public func getConnectedClients() -> [WsClientInfo] {
        queue.sync { Array(clientInfo.values) }
    }

    private func snapshotCount() -> Int {
        queue.sync { clients.count }
    }

    // MARK: - 连接生命周期

    private func handleNewConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn) { [weak self] head in
            guard let self, let head else {
                conn.cancel()
                return
            }
            let accept = WsProtocol.computeAccept(head)
            if accept == nil || !WsProtocol.isUpgradeRequest(head) {
                // 非升级请求：回 400 后关闭（与 C# 同口径）
                conn.send(content: WsProtocol.buildBadRequestResponse(), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            conn.send(content: WsProtocol.buildHandshakeResponse(accept!), completion: .contentProcessed { [weak self] _ in
                self?.registerConnection(conn)
            })
        }
    }

    private func registerConnection(_ nw: NWConnection) {
        let id = UUID().uuidString
        let conn = ServerConnection(id: id, nw: nw, queue: queue)
        conn.onMessage = { [weak self] text in
            guard let self else { return }
            RuntimeLog.debug("[WebSocketServer] message received [\(id)]: \(text)")
            self.MessageReceived?(id, text)
        }
        clients[id] = conn
        clientInfo[id] = WsClientInfo(id: id)
        ClientConnected?(id)
        RuntimeLog.debug("[WebSocketServer] client connected: \(id) (current \(clients.count))")

        conn.onClosed = { [weak self] in
            guard let self else { return }
            self.clients[id] = nil
            self.clientInfo[id] = nil
            self.ClientDisconnected?(id)
            RuntimeLog.debug("[WebSocketServer] client disconnected: \(id) (current \(self.clients.count))")
        }
        conn.run()
    }

    /// 逐字节语义的握手头读取：读到 `\r\n\r\n` 为止；超过 32KB 视为异常请求头丢弃。
    private func readHead(_ conn: NWConnection, _ completion: @escaping (String?) -> Void) {
        var buf = [UInt8]()
        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if error != nil || isComplete {
                    completion(nil)
                    return
                }
                if let data { buf.append(contentsOf: data) }
                if buf.count > 32 * 1024 {
                    completion(nil)
                    return
                }
                if Self.headComplete(buf) {
                    completion(String(decoding: buf[0..<Self.headEnd(buf)!], as: UTF8.self))
                    return
                }
                step()
            }
        }
        step()
    }

    private static func headEnd(_ buf: [UInt8]) -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) {
            if buf[i] == 0x0D, buf[i + 1] == 0x0A, buf[i + 2] == 0x0D, buf[i + 3] == 0x0A {
                return i + 4
            }
        }
        return nil
    }

    private static func headComplete(_ buf: [UInt8]) -> Bool { headEnd(buf) != nil }
}

/// 单条已握手的连接：按帧读取（掩码校验/控制帧/分片重组）+ 串行写入。
/// 对应 C# `WsConnection`。
final class ServerConnection {
    let id: String
    private let nw: NWConnection
    private let queue: DispatchQueue
    private var recv: [UInt8] = []
    private var fragments: [UInt8]?
    private var fragmentOpcode: UInt8 = 0
    private var closed = false

    var onMessage: ((String) -> Void)?
    var onClosed: (() -> Void)?

    init(id: String, nw: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.nw = nw
        self.queue = queue
    }

    func run() { readLoop() }

    /// 发送一帧文本（服务端帧不掩码）
    func sendText(_ text: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            let frame = WsProtocol.encodeFrame(WsProtocol.opText, Array(text.utf8))
            self.nw.send(content: frame, completion: .contentProcessed { error in
                if error != nil { self.close() }
            })
        }
    }

    /// 立即断开（服务停止/清理路径；不做关闭握手）
    func abort() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.nw.cancel()
        }
    }

    // MARK: - 内部

    private func readLoop() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, !isComplete else {
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.recv.append(contentsOf: data)
                if !self.drainFrames() {
                    return   // drainFrames 内部已 close
                }
            }
            if self.closed { return }
            self.readLoop()
        }
    }

    /// 消费缓冲区里所有完整帧；返回 false 表示连接应结束。
    private func drainFrames() -> Bool {
        while true {
            let (frame, consumed, status, error) = WsProtocol.tryParseFrame(recv, recv.count)
            switch status {
            case .needMore:
                return true
            case .error(let msg):
                RuntimeLog.debug("[WebSocketServer] protocol error [\(id)]: \(msg)")
                sendClose(code: 1002, reason: msg)
                close()
                return false
            case .ok:
                recv.removeFirst(consumed)
                if !handleFrame(frame) { return false }
            }
        }
    }

    private func handleFrame(_ frame: WsFrame) -> Bool {
        switch frame.opcode {
        case WsProtocol.opPing:
            sendFrame(WsProtocol.opPong, frame.payload)
            return true
        case WsProtocol.opPong:
            return true
        case WsProtocol.opClose:
            sendClose(code: 1000, reason: "")
            close()
            return false
        case WsProtocol.opText, WsProtocol.opBinary:
            if frame.fin {
                deliver(frame.opcode, frame.payload)
                return true
            }
            fragments = frame.payload
            fragmentOpcode = frame.opcode
            return true
        case WsProtocol.opContinuation:
            guard fragments != nil else {
                sendClose(code: 1002, reason: "意外的续帧")
                close()
                return false
            }
            guard fragments!.count + frame.payload.count <= WsProtocol.maxMessageBytes else {
                sendClose(code: 1009, reason: "消息超出上限")
                close()
                return false
            }
            fragments!.append(contentsOf: frame.payload)
            if frame.fin {
                let opcode = fragmentOpcode
                let data = fragments!
                fragments = nil
                deliver(opcode, data)
            }
            return true
        default:
            sendClose(code: 1002, reason: "未知 opcode")
            close()
            return false
        }
    }

    /// 把完整消息交给上层；与 C# 一致，只上报文本消息。
    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        guard opcode == WsProtocol.opText, !payload.isEmpty else { return }
        onMessage?(String(decoding: payload, as: UTF8.self))
    }

    private func sendFrame(_ opcode: UInt8, _ payload: [UInt8]) {
        guard !closed else { return }
        nw.send(content: WsProtocol.encodeFrame(opcode, payload), completion: .contentProcessed { _ in })
    }

    /// 发关闭帧（尽力而为，失败即忽略）——关闭握手不需要等对端回应。
    private func sendClose(code: UInt16, reason: String) {
        var payload = [UInt8](repeating: 0, count: 2)
        payload[0] = UInt8(code >> 8)
        payload[1] = UInt8(code & 0xFF)
        payload.append(contentsOf: Array(reason.utf8))
        sendFrame(WsProtocol.opClose, payload)
    }

    private func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.nw.cancel()
            self.onClosed?()
        }
    }
}
