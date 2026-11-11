import Foundation
import SideDeskCore

/// 数据项 → 浏览器配置的解析（可执行文件、userData 目录、CDP 端口）。
/// 对应 C# `DataPollingService.ResolveBrowserConfig` + `AllocatePort`。
/// CDP 引擎与扩展引擎共用一份（端口分配记录必须一致，否则同一浏览器会被分到两个端口）。
public final class BrowserConfigResolver {

    /// 程序登记表：由组合根注入（未注入 = 无登记表，一律回落默认浏览器）
    public var registryProvider: () -> ProgramRegistryManager? = { nil }
    /// 默认浏览器解析接缝（mac 侧读不到 Windows 注册表，见 `BrowserChannel.defaultBrowserResolver`）
    public var defaultBrowserExe: () -> String = { BrowserChannel.defaultBrowserResolver() }

    /// 自增端口池起点/上限（与 C# 一致：从 9300 起，超过 9399 回绕）
    public static let autoPortStart = 9300
    public static let autoPortMax = 9399

    private var allocatedPorts: [String: Int] = [:]
    private var nextAutoPort = autoPortStart
    private let lock = NSLock()

    public init() {}

    public struct Config {
        public let exePath: String
        public let userDataDir: String
        public let port: Int
    }

    /// 解析数据项对应的浏览器配置
    public func resolve(_ item: DataDashboardItem, _ settings: Settings) -> Config {
        // 默认浏览器（未指定 BrowserId）
        let browserId = item.BrowserId ?? ""
        if browserId.isEmpty {
            return Config(exePath: defaultBrowserExe(), userDataDir: "", port: settings.CdpDebugPort)
        }

        // 指定了浏览器：从 ProgramRegistry 查找；查不到回落默认浏览器
        guard let browser = registryProvider()?.GetBrowserById(browserId) else {
            return Config(exePath: defaultBrowserExe(), userDataDir: "", port: settings.CdpDebugPort)
        }

        // 解析 Profile（userData 目录）
        let userDataDir = registryProvider()?.GetProfileById(browserId, item.ProfileId)?.Directory ?? ""

        return Config(exePath: browser.ExePath, userDataDir: userDataDir,
                      port: allocatePort(browserId, item.ProfileId))
    }

    /// 为指定浏览器+Profile 分配固定端口
    func allocatePort(_ browserId: String, _ profileId: String?) -> Int {
        let key = "\(browserId)_\(profileId ?? "")"
        lock.lock()
        defer { lock.unlock() }
        if let existing = allocatedPorts[key] { return existing }
        let port = nextAutoPort
        nextAutoPort = nextAutoPort >= Self.autoPortMax ? Self.autoPortStart : nextAutoPort + 1
        allocatedPorts[key] = port
        return port
    }
}
