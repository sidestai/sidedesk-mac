import Foundation

/// 应用数据路径（跨平台集中点）。对应 Windows C# 的 `Framework.AppPaths`。
///
/// macOS 用惯用的 `~/Library/Application Support/SideDesk`（而非 .NET 在 mac 会落到的
/// `~/.local/share`）。所有落盘数据（settings.json / Logs / DB）的统一父目录。
public enum AppPaths {

    /// 测试缝隙：隔离数据目录到临时目录（`RuntimeMode.isTestMode` 用；nil=真实路径）。
    private static var overrideDir: String?

    private static var defaultDataDir: String {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return root.appendingPathComponent("SideDesk").path
    }

    /// 应用数据根目录（含 "SideDesk"）。
    public static var dataDir: String { overrideDir ?? defaultDataDir }

    /// 覆盖数据根目录（测试隔离）；传 nil 复位为真实路径。
    public static func setOverride(_ dir: String?) { overrideDir = dir }
}
