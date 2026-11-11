import Foundation

/// 系统环境偏好（issue #48，L1 无障碍三件套）：高对比度 / 减少动效 / 文本缩放。
/// 对应 C# `Framework.SystemPreferences`——WPF 侧读 `SystemParameters` + 辅助功能注册表，
/// mac 侧无注册表，三项都换成宿主注入的接缝（`NSWorkspace` 无障碍选项 / `NSFont` 首选字号）。
/// 环境强制缝隙与 C# 同口径：`SIDESK_FORCE_HC=1` / `SIDESK_FORCE_REDUCE_MOTION=1` / `SIDESK_TEXT_SCALE=150`。
public enum SystemPreferences {

    /// 高对比度开启（对应 C# `HighContrast`）
    public private(set) static var highContrast = false

    /// 减少动效（对应 C# `ReduceMotion`）
    public private(set) static var reduceMotion = false

    /// 系统文本缩放倍数（1.0~2.25，对应 C# `TextScale`）
    public private(set) static var textScale = 1.0

    // MARK: - 宿主接缝（对应 C# 读 SystemParameters / 注册表）

    /// 系统高对比度（mac：`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`）
    public static var systemHighContrast: () -> Bool = { false }

    /// 系统减少动效（mac：`NSWorkspace.accessibilityDisplayShouldReduceMotion`）
    public static var systemReduceMotion: () -> Bool = { false }

    /// 系统文本缩放倍数（mac：`NSFont.preferredFont(.body).pointSize / 13`），已归一为倍数而非百分比
    public static var systemTextScale: () -> Double = { 1.0 }

    // MARK: - 初始化 / 刷新

    /// 启动初始化：读初始值（对应 C# `SystemPreferences.Init`）。订阅由宿主负责
    /// （mac 无 SystemParameters.StaticPropertyChanged，改监听 `accessibilityDisplayOptionsDidChangeNotification`
    /// 后回调 `refresh`）。
    public static func initialize() { refresh() }

    /// 重读三项偏好（对应 C# `ReadAll`）：环境强制优先于真实系统状态。
    public static func refresh() {
        let env = ProcessInfo.processInfo.environment
        if let f = env["SIDESK_FORCE_HC"] { highContrast = (f == "1") }
        else { highContrast = systemHighContrast() }
        if let f = env["SIDESK_FORCE_REDUCE_MOTION"] { reduceMotion = (f == "1") }
        else { reduceMotion = systemReduceMotion() }
        textScale = readTextScaleFactor(env["SIDESK_TEXT_SCALE"])
        RuntimeLog.info("A11y", "环境偏好: HighContrast=\(highContrast) ReduceMotion=\(reduceMotion) "
                       + "TextScale=\(String(format: "%.2f", textScale))")
    }

    /// 文本缩放倍数（纯函数，单测用，对应 C# `ReadTextScaleFactor`）：
    /// 环境覆盖按百分比解析（150 → 1.5），缺失/非法回落系统接缝；两路都钳到 1.0~2.25。
    static func readTextScaleFactor(_ envOverride: String?) -> Double {
        if let e = envOverride?.trimmingCharacters(in: .whitespaces), !e.isEmpty {
            guard let v = Int(e), v > 0 else { return 1.0 }
            return min(max(Double(v) / 100.0, 1.0), 2.25)
        }
        return min(max(systemTextScale(), 1.0), 2.25)
    }
}
