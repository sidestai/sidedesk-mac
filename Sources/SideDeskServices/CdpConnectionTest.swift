import Foundation
import SideDeskCore

/// CDP 连接自检。对应 C# `ModulesSeam.TestCdpConnectionAsync`：
/// 建一次连接 → `Target.getTargets` 取页面标签 → 把结果拼成设置页弹窗看的文本。
/// 文案一律走 Lang；测试用的连接用完即关（不复用轮询持有长连接的路径）。
public enum CdpConnectionTest {

    /// 建连接缝（测试注入假客户端，默认走全局守卫）
    public static var connectFactory: (_ port: Int) async -> CdpClientProtocol? = { port in
        await CdpConnectGuard.shared.connect(port: port)
    }

    public static func run(port: Int) async -> String {
        guard let client = await connectFactory(port) else {
            return Lang.tf("settings.cdpConnectFailedDetail", port, port)
        }
        defer { client.close() }

        do {
            let pages = try await CdpDomain.getTargets(client).filter { $0.type == "page" }
            if pages.isEmpty { return Lang.tf("settings.cdpConnectedNoTabs", port) }

            var lines = [
                Lang.tf("settings.cdpConnectedTabSummary", port, pages.count),
                String(repeating: "─", count: 40),
            ]
            for (i, tab) in pages.enumerated() {
                lines.append("\(i + 1). " + (tab.title.isEmpty ? Lang.t("settings.untitled") : tab.title))
                lines.append("   \(tab.url)")
            }
            return lines.joined(separator: "\n")
        } catch {
            return Lang.tf("settings.cdpConnectFailed", error.localizedDescription, port)
        }
    }
}
