import Foundation
import SideDeskCore

/// CDP 端点发现与建连。对应 C# `CdpBrowserService.DiscoverWsUrisAsync` / `ConnectBrowserAsync`
/// 以及 `CdpConnectGuard`（全应用唯一的建连去重点）。
public enum CdpDiscovery {

    /// 单次建连超时。C# 放宽到 30 秒是为了等 Edge 的"允许远程调试"确认弹窗；
    /// macOS 浏览器没有该弹窗，但保持同一数值以免"半死不活的端口"让轮询长时间挂住之外的行为差异。
    public static var connectTimeoutSeconds: TimeInterval = 30
    /// 就绪探测的单次连接超时（C# `ConnectWhenReadyAsync` 用 2 秒）
    public static var readyProbeTimeoutSeconds: TimeInterval = 2

    /// `http://…/json/version` 发现用的会话（10 秒超时，与 C# `_discoverHttp` 一致）
    private static let http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    /// 发现浏览器 CDP WebSocket 端点，返回按优先级排列的候选地址。
    ///
    /// Chrome/Edge 的 headless 可能只监听 IPv6 回环（`::1`），且无 GUID 的 `/devtools/browser`
    /// 在新版上返回 404，因此需同时探测 IPv4/IPv6，并从 `DevToolsActivePort` 文件或
    /// HTTP `/json/version` 取完整路径（与 C# 同一套理由）。
    public static func discoverWsUris(port: Int) async -> [URL] {
        var result: [URL] = []
        func add(_ s: String) {
            guard let u = URL(string: s), !result.contains(u) else { return }
            result.append(u)
        }

        // 1. DevToolsActivePort 文件（含 SideDesk 自启动的 HeadlessProfile）：
        //    首行端口、次行 WS 路径；逐个候选校验端口匹配，避免读到其他浏览器实例的文件
        for file in devToolsActivePortFiles() {
            guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            guard lines.count >= 2, let filePort = Int(lines[0].trimmingCharacters(in: .whitespaces)),
                  filePort == port else { continue }
            let path = lines[1].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            add("ws://127.0.0.1:\(port)\(path)")
            add("ws://[::1]:\(port)\(path)")
        }

        // 2. HTTP /json/version 发现（双栈探测：可能只监听 IPv4 或 IPv6）
        for host in ["127.0.0.1", "[::1]"] {
            guard let url = URL(string: "http://\(host):\(port)/json/version"),
                  let (data, resp) = try? await http.data(from: url),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // 该地址可达：无 GUID 的标准路径排前，兼容旧版浏览器
            add("ws://\(host):\(port)/devtools/browser")
            if let wsUrl = obj["webSocketDebuggerUrl"] as? String, let parsed = URL(string: wsUrl) {
                // 响应里的主机可能是 localhost/另一栈地址，统一替换为实际可达的地址（保留带 GUID 的路径）
                add("ws://\(host):\(parsed.port ?? port)\(parsed.path)")
            }
        }

        // 3. 兜底：直接尝试标准路径（双栈）
        add("ws://127.0.0.1:\(port)/devtools/browser")
        add("ws://[::1]:\(port)/devtools/browser")

        return result
    }

    /// 可能的浏览器 DevToolsActivePort 文件（Edge/Chrome/Brave 用户数据目录 + SideDesk 自启动的 HeadlessProfile）
    public static func devToolsActivePortFiles() -> [String] {
        let support = BrowserChannel.appSupportRoot()
        let candidates = [
            support + "/Microsoft Edge/DevToolsActivePort",
            support + "/Google/Chrome/DevToolsActivePort",
            support + "/BraveSoftware/Brave-Browser/DevToolsActivePort",
        ]
        let fm = FileManager.default
        var result: [String] = []
        // 自启动隐藏浏览器的专属 userData 目录优先（端口匹配概率最高）
        let headlessRoot = BrowserChannel.headlessProfileRoot()
        if let dirs = try? fm.contentsOfDirectory(atPath: headlessRoot) {
            result.append(contentsOf: dirs
                .map { headlessRoot + "/" + $0 + "/DevToolsActivePort" }
                .filter { fm.fileExists(atPath: $0) })
        }
        result.append(contentsOf: candidates.filter { fm.fileExists(atPath: $0) })
        return result
    }

    /// 依次尝试候选端点建立连接；全部失败返回 nil（对应 C# `ConnectBrowserAsync`）
    public static func connect(port: Int) async -> CdpClient? {
        for uri in await discoverWsUris(port: port) {
            let client = CdpClient(url: uri, timeout: connectTimeoutSeconds)
            do {
                try await client.connect()
                RuntimeLog.debug("[DataPolling] ★ CDP connection established (attaching to running browser): \(uri)")
                return client
            } catch {
                RuntimeLog.debug("[DataPolling] connection to \(uri) failed: \(error.localizedDescription)")
                client.close()
            }
        }
        return nil
    }

    /// 等待 CDP 端口就绪并直接返回正式连接：探测成功的那条连接直接复用，
    /// 全程只建立 1 条连接（对应 C# `ConnectWhenReadyAsync`）
    public static func connectWhenReady(port: Int, timeout: TimeInterval) async -> CdpClient? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for uri in await discoverWsUris(port: port) {
                let client = CdpClient(url: uri, timeout: readyProbeTimeoutSeconds)
                do {
                    try await client.connect()
                    RuntimeLog.debug("[DataPolling] ★ CDP connection established (hidden browser ready): \(uri)")
                    return client
                } catch {
                    client.close()
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }
}

/// CDP 连接全局守卫：同一调试端口若已有连接尝试进行中，后续请求复用该尝试的结果，
/// 不新建连接。对应 C# `CdpConnectGuard`——跨 CDP 引擎/其它消费者共享的唯一建连去重点。
public final class CdpConnectGuard {
    public static let shared = CdpConnectGuard()

    private let lock = SyncLock()
    private var inflight: [Int: (id: UInt64, task: Task<CdpClient?, Never>)] = [:]
    private var nextId: UInt64 = 0

    private init() {}

    public func connect(port: Int) async -> CdpClient? {
        // 取号与登记在途任务必须原子：否则同端口并发请求会各建一条连接（浏览器重复弹"允许远程调试"）
        let claim: (id: UInt64, task: Task<CdpClient?, Never>, isNew: Bool) = lock.withLock {
            if let existing = inflight[port] { return (existing.id, existing.task, false) }
            nextId += 1
            let task = Task { () -> CdpClient? in
                await CdpDiscovery.connect(port: port)
            }
            inflight[port] = (nextId, task)
            return (nextId, task, true)
        }
        if !claim.isNew {
            RuntimeLog.debug("[CdpGuard] port \(port) already has a connection attempt in progress, reusing")
            return await claim.task.value
        }

        let result = await claim.task.value
        lock.withLock {
            // 仅当仍登记的是本次尝试时才移除（下次请求才会重新发起）
            if inflight[port]?.id == claim.id { inflight.removeValue(forKey: port) }
        }
        return result
    }

    /// 测试用：清空在途登记
    public func reset() {
        lock.withLock { inflight.removeAll() }
    }
}
