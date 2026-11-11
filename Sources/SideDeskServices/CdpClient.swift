import Foundation
import SideDeskCore

/// CDP 调用错误。
public enum CdpError: Error, Equatable {
    case notConnected
    case timeout
    case failed(String)
}

/// CDP 客户端契约：轮询引擎只经它发命令（单测注入替身，无需真实浏览器）。
/// 对应 C# 里 `DefaultProtocolClient.SendCommandAsync` 的那一侧。
/// 继承 `CdpSession`：连接的登记对象（`BrowserConnection.client`）只需关得掉。
public protocol CdpClientProtocol: CdpSession {
    var isConnected: Bool { get }
    /// 发送命令并等待响应的 `result`。`sessionId` 非空时附 `sessionId`（flatten 会话）。
    func sendCommand(_ method: String, _ params: [String: JSONValue]?, _ sessionId: String?, timeout: TimeInterval) async throws -> JSONValue
}

public extension CdpClientProtocol {
    /// 免参数/免 sessionId 的常用调用形式
    func command(_ method: String, _ params: [String: JSONValue]? = nil,
                 sessionId: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await sendCommand(method, params, sessionId, timeout: timeout)
    }
}

/// 手写的 Chrome DevTools Protocol 客户端：WebSocket + JSON-RPC（id/method/params/sessionId）。
/// 对应 C# 引用的 `ChromeProtocol` NuGet 包里的 `DefaultProtocolClient`——mac 侧无该包，
/// 按 C# 用到的那一小组命令自研（`Target.*` / `Page.navigate` / `Runtime.evaluate`）。
public final class CdpClient: CdpSession, CdpClientProtocol {

    /// 服务端事件回调（method, params, sessionId）。轮询路径不消费事件，保留给后续批次。
    public var onEvent: ((String, JSONValue, String?) -> Void)?

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private let lock = SyncLock()
    private var connected = false
    private var closedByUs = false

    public init(url: URL, timeout: TimeInterval = 30) {
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: cfg)
    }

    public var isConnected: Bool { lock.withLock { connected } }

    /// 建立 WebSocket 连接。失败抛错（调用方按"该端点不可用"处理并释放本客户端）。
    public func connect() async throws {
        let t = session.webSocketTask(with: url)
        lock.withLock { task = t }
        t.resume()
        // URLSessionWebSocketTask 的 resume 立即返回；用一次空收发确认链路可用
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                t.send(.string("{}")) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            t.cancel()
            throw CdpError.notConnected
        }
        lock.withLock { connected = true }
        receiveLoop()
    }

    /// 关闭连接（对应 `CdpSession.close()`）
    public func close() {
        let pending: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            closedByUs = true
            connected = false
            let all = Array(waiting.values)
            waiting.removeAll()
            return all
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        for cont in pending { cont.resume(throwing: CdpError.notConnected) }
    }

    /// 发送命令并等待响应；返回响应的 `result` 对象。
    public func sendCommand(_ method: String, _ params: [String: JSONValue]? = nil,
                            _ sessionId: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            // 取号 + 登记等待在同一把锁内完成，避免响应先于登记到达
            let prepared: (Int, String, URLSessionWebSocketTask)? = lock.withLock {
                guard connected, let task else { return nil }
                let id = nextId
                nextId += 1
                var payload: [String: JSONValue] = ["id": .int(id), "method": .string(method)]
                if let params, !params.isEmpty { payload["params"] = .object(params) }
                if let sessionId { payload["sessionId"] = .string(sessionId) }
                waiting[id] = cont
                return (id, Self.jsonString(payload), task)
            }
            guard let (sentId, text, task) = prepared else {
                cont.resume(throwing: CdpError.notConnected)
                return
            }
            task.send(.string(text)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail(sentId, with: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(sentId, with: CdpError.timeout)
                }
            }
        }
    }

    // MARK: - 收包

    private func receiveLoop() {
        let ws = lock.withLock { self.task }
        guard let ws else { return }
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failAll(error)
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                if case .data(let data) = message { self.handle(String(decoding: data, as: UTF8.self)) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let id = (obj["id"] as? NSNumber)?.intValue {
            let cont = lock.withLock { waiting.removeValue(forKey: id) }
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "CDP command failed"
                cont?.resume(throwing: CdpError.failed(msg))
            } else {
                cont?.resume(returning: JSONValue(any: obj["result"] ?? [String: Any]()))
            }
            return
        }
        if let method = obj["method"] as? String {
            onEvent?(method, JSONValue(any: obj["params"] ?? [String: Any]()), obj["sessionId"] as? String)
        }
    }

    private func fail(_ id: Int, with error: Error) {
        let cont = lock.withLock { waiting.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let all: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            connected = false
            let pending = Array(waiting.values)
            waiting.removeAll()
            return closedByUs ? [] : pending
        }
        for cont in all { cont.resume(throwing: error) }
    }

    private static func jsonString(_ obj: [String: JSONValue]) -> String {
        guard let data = try? SideDeskJSON.encoder().encode(obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - CDP 域命令（轮询用到的那一组）

internal extension JSONValue {
    /// 对象取键（非对象/缺键返回 nil）
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    /// 数组取下标
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
}

/// `Target` 域的一个页面目标。对应 C# `Target.TargetInfo`。
public struct CdpTarget {
    public let targetId: String
    public let type: String
    public let url: String
    /// 页面标题（CDP 的 `title`，可能为空——连接测试用它列标签页）
    public let title: String

    public init(targetId: String, type: String, url: String, title: String = "") {
        self.targetId = targetId
        self.type = type
        self.url = url
        self.title = title
    }
}

/// CDP 常用命令的类型化包装。
public enum CdpDomain {

    /// `Target.getTargets`：全部目标（调用方自行筛 `type == "page"`）
    public static func getTargets(_ client: CdpClientProtocol) async throws -> [CdpTarget] {
        let result = try await client.command("Target.getTargets")
        guard case .array(let list) = result["targetInfos"] ?? .null else { return [] }
        return list.compactMap { t in
            guard case .object(let o) = t,
                  let id = o["targetId"]?.stringValue,
                  let type = o["type"]?.stringValue else { return nil }
            return CdpTarget(targetId: id, type: type, url: o["url"]?.stringValue ?? "",
                             title: o["title"]?.stringValue ?? "")
        }
    }

    /// `Target.createTarget`：新建标签页并导航，返回 targetId
    public static func createTarget(_ client: CdpClientProtocol, url: String) async throws -> String {
        let result = try await client.command("Target.createTarget", ["url": .string(url)])
        guard let id = result["targetId"]?.stringValue else { throw CdpError.failed("no targetId") }
        return id
    }

    /// `Target.attachToTarget`（flatten）：返回 sessionId
    public static func attachToTarget(_ client: CdpClientProtocol, targetId: String) async throws -> String {
        let result = try await client.command("Target.attachToTarget",
                                              ["targetId": .string(targetId), "flatten": .bool(true)])
        guard let sid = result["sessionId"]?.stringValue else { throw CdpError.failed("no sessionId") }
        return sid
    }

    /// `Target.closeTarget`
    public static func closeTarget(_ client: CdpClientProtocol, targetId: String) async throws {
        _ = try await client.command("Target.closeTarget", ["targetId": .string(targetId)])
    }

    /// `Page.navigate`：返回错误文本（nil = 成功）
    public static func navigate(_ client: CdpClientProtocol, sessionId: String, url: String) async throws -> String? {
        let result = try await client.command("Page.navigate", ["url": .string(url)], sessionId: sessionId)
        return result["errorText"]?.stringValue
    }

    /// `Runtime.evaluate`（returnByValue + awaitPromise）：返回结果文本与异常信息
    public static func evaluate(_ client: CdpClientProtocol, sessionId: String, expression: String) async throws
        -> (value: String?, exception: String?) {
        let result = try await client.command("Runtime.evaluate",
                                              ["expression": .string(expression),
                                               "returnByValue": .bool(true),
                                               "awaitPromise": .bool(true)],
                                              sessionId: sessionId)
        let exceptionText = result["exceptionDetails"]?["text"]?.stringValue
            ?? result["exceptionDetails"]?["exception"]?.stringValue
        let value = result["result"]?["value"]
        switch value {
        case .string(let s): return (s, exceptionText)
        case .int(let i): return (String(i), exceptionText)
        case .double(let d): return (String(d), exceptionText)
        case .bool(let b): return (String(b), exceptionText)
        case .object(let o): return (o["description"]?.stringValue, exceptionText)
        default: return (nil, exceptionText)
        }
    }
}
