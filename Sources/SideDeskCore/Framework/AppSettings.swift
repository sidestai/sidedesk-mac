import Foundation

/// 卡片字体设置。对应 C# `FontSetting`（仅 FontSize 参与序列化）。
public final class FontSetting: Codable, Equatable {
    public var FontSize: Int

    public init(_ fontSize: Int) { self.FontSize = fontSize }

    public var TitleFontSize: Int { FontSize + 2 }
    public var SmallFontSize: Int { FontSize - 2 }

    public var IconSize: Int {
        switch FontSize {
        case 10: return 18
        case 12: return 22
        case 16: return 28
        case 18: return 32
        default: return 24   // 14 及其它
        }
    }

    public var BarHeight: Int { FontSize - 3 }
    public var BarWidth: Int { BarHeight * 6 }
    public var BarWidthWide: Int { BarHeight * 8 }

    public static let x10 = FontSetting(10)
    public static let x12 = FontSetting(12)
    public static let x14 = FontSetting(14)
    public static let x16 = FontSetting(16)
    public static let x18 = FontSetting(18)

    public static func == (lhs: FontSetting, rhs: FontSetting) -> Bool { lhs.FontSize == rhs.FontSize }
}

/// 文本对齐。对应 C# `TextAlign : byte`。
public enum TextAlign: UInt8, Codable {
    case Left = 0
    case Right = 1
}

/// 应用外观/行为设置（settings.json）。对应 C# `Framework.AppSettings`。
///
/// 属性名保留 C# PascalCase（1:1 对照）。WPF 的 `INotifyPropertyChanged` 已剥离——
/// SwiftUI 侧改为观察 `ObservableObject` 包装或订阅变更回调（见 UI 层，T5）。
public final class AppSettings: Codable {

    // ========== 通用设置 ==========
    public var RunAtStartup: Bool = true
    public var ShowInTaskbar: Bool = true

    /// 任务栏标题锁定看门狗刷新间隔（毫秒），限定 500..60000。
    public var TitleLockWatchdogInterval: Int = 5000
    /// 任务栏标题锁定重扫全部窗口间隔（毫秒），限定 2000..600000。
    public var TitleLockRescanInterval: Int = 15000

    // ========== 显示设置 ==========
    public var ShowUsageStats: Bool = false
    public var HideModuleFrame: Bool = false
    /// 隐藏卡片外框时，是否同时隐藏卡片标题栏。
    public var HideModuleTitle: Bool = false

    // ========== 主题/外观 ==========
    /// 卡片内字体大小（px，默认 12，限定 9..24）。
    public var CardFontSize: Double = 12

    /// 卡片字号换算：以 12 为设计基准，偏移量随 CardFontSize 同步缩放。
    public func FS(_ designSize: Double) -> Double { CardFontSize + (designSize - 12) }

    public var BGColor: String = "#000000"
    public var FontSetting: FontSetting = .x14
    public var FontColor: String = "#FFFFFF"
    public var GroupBGColor: String = "#333333"
    public var AccentColor: String = "#7C3AED"
    public var AccentBookmark: String = "#2ECC71"
    public var AccentAITool: String = "#7C3AED"
    public var AccentBrowser: String = "#4A90D9"
    public var AccentProgram: String = "#9B59B6"
    public var AccentCounter: String = "#E74C3C"
    public var AccentTaskbar: String = "#FF8C00"
    /// 分享导入卡片的边框颜色（默认紫色）。
    public var ShareBorderColor: String = "#A855F7"
    /// 团队归属卡片的边框颜色（默认蓝色）。
    public var TeamBorderColor: String = "#3B82F6"
    public var FontFamily: String = "Microsoft YaHei UI"
    public var ThemeCornerRadius: Int = 8
    public var ThemeButtonPadding: Int = 8
    public var CurrentTheme: String = ""

    // ========== 浮动上下文窗口 ==========
    public var FloatingContextEnabled: Bool = false
    public var FloatingContextOffset: Double = 0.15
    public var FloatingContextCompact: Bool = false

    public init() {}

    // MARK: - 单例

    private static var _instance: AppSettings?

    public static var Instance: AppSettings {
        if let i = _instance { return i }
        let i = Load()
        _instance = i
        return i
    }

    public func Reload() { AppSettings._instance = AppSettings.Load() }

    // MARK: - 持久化

    private static var SettingsFilePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("settings.json")
    }

    public func Save() {
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(self)
            try data.write(to: URL(fileURLWithPath: AppSettings.SettingsFilePath), options: .atomic)
        } catch {
            RuntimeLog.debug("[AppSettings] save failed: \(error.localizedDescription)")
        }
    }

    public static func Load() -> AppSettings {
        let path = SettingsFilePath
        guard FileManager.default.fileExists(atPath: path) else { return AppSettings() }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try SideDeskJSON.decoder().decode(AppSettings.self, from: data)
        } catch {
            RuntimeLog.debug("[AppSettings] load failed: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    // MARK: - Codable（宽松解码 + 加载期钳制，对齐 C# setter 的 clamp）

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        RunAtStartup = c.or(.RunAtStartup, true)
        ShowInTaskbar = c.or(.ShowInTaskbar, true)
        TitleLockWatchdogInterval = min(max(c.or(.TitleLockWatchdogInterval, 5000), 500), 60000)
        TitleLockRescanInterval = min(max(c.or(.TitleLockRescanInterval, 15000), 2000), 600000)
        ShowUsageStats = c.or(.ShowUsageStats, false)
        HideModuleFrame = c.or(.HideModuleFrame, false)
        HideModuleTitle = c.or(.HideModuleTitle, false)
        CardFontSize = min(max(c.or(.CardFontSize, 12.0), 9), 24)
        BGColor = c.or(.BGColor, "#000000")
        FontSetting = c.or(.FontSetting, SideDeskCore.FontSetting(14))
        FontColor = c.or(.FontColor, "#FFFFFF")
        GroupBGColor = c.or(.GroupBGColor, "#333333")
        AccentColor = c.or(.AccentColor, "#7C3AED")
        AccentBookmark = c.or(.AccentBookmark, "#2ECC71")
        AccentAITool = c.or(.AccentAITool, "#7C3AED")
        AccentBrowser = c.or(.AccentBrowser, "#4A90D9")
        AccentProgram = c.or(.AccentProgram, "#9B59B6")
        AccentCounter = c.or(.AccentCounter, "#E74C3C")
        AccentTaskbar = c.or(.AccentTaskbar, "#FF8C00")
        ShareBorderColor = c.or(.ShareBorderColor, "#A855F7")
        TeamBorderColor = c.or(.TeamBorderColor, "#3B82F6")
        FontFamily = c.or(.FontFamily, "Microsoft YaHei UI")
        ThemeCornerRadius = c.or(.ThemeCornerRadius, 8)
        ThemeButtonPadding = c.or(.ThemeButtonPadding, 8)
        CurrentTheme = c.or(.CurrentTheme, "")
        FloatingContextEnabled = c.or(.FloatingContextEnabled, false)
        FloatingContextOffset = c.or(.FloatingContextOffset, 0.15)
        FloatingContextCompact = c.or(.FloatingContextCompact, false)
    }
}
