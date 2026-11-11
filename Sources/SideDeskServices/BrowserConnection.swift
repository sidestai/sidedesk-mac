import Foundation

/// 数据看板连接状态。对应 C# `ConnectionState`。
public enum ConnectionState: String {
    case disconnected, connecting, connected, error
}

/// CDP 会话句柄的最小契约（A3 的 CDP 客户端实现之）：轮询服务只需要能把它关掉。
public protocol CdpSession: AnyObject {
    func close()
}

/// 浏览器 CDP 连接（按 browserId+profileId 分组）。对应 C# `BrowserConnection`。
public final class BrowserConnection {
    /// "{browserId}_{profileId}" 或 "default"
    public var Key = ""
    /// 已建立的 CDP 会话（nil = 尚未连接）
    public var client: CdpSession?
    /// 本服务自启动的隐藏浏览器进程（nil = 连接的是用户浏览器）
    public var launchedProcess: Process?
    public var port = 0
    public var state: ConnectionState = .disconnected

    /// 由本服务自行启动的浏览器（断开时可杀进程、可导航已有 tab）
    public var isSelfLaunched: Bool { launchedProcess != nil }

    public init() {}
}
