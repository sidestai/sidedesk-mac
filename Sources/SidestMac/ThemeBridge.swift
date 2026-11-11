import AppKit
import SwiftUI
import SideDeskCore

/// 主题令牌的 SwiftUI 桥：`SideDeskCore` 保持平台无关（分量存 0-255），颜色在这里落成 `Color`。
/// 视图侧的用法是 `let p = ThemeManager.palette` 之后 `p.textMain.color`。
extension ThemeColor {

    /// 分量 → Color（sRGB，与 WPF `Color` 同一口径），含令牌自带的 alpha。
    var color: Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a / 255)
    }

    /// 同上，但丢掉令牌自带的 alpha 改用给定不透明度（0-1）。
    /// 对应 C# `MainWindow.ApplyBackgroundForConfig` 的 `Color.FromArgb(opacity * 255, bg.R, bg.G, bg.B)`。
    func color(alpha: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: min(max(alpha, 0), 1))
    }
}

/// 主题变更桥（对应 C# `App.ThemeChanged += handler`）。
/// `ThemeManager` 是全局枚举、不是可观察对象，SwiftUI 不会因它自动重绘；这里把变更转成
/// `objectWillChange`，视图持有它即可在换肤、改背景透明度、改卡片字号后重新取令牌。
@MainActor
final class ThemeChangeObserver: ObservableObject {

    init() {
        ThemeManager.subscribeChanged { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
}

/// 原生外观桥：自绘部分吃令牌，但 NSMenu、Picker、TextField、Toggle 这些原生控件只认 `NSAppearance`。
/// 主题与系统外观不一致时（系统浅色 + 主题深色）不锁外观就会出现「深底窗配浅色控件」，
/// 故整个 app 的外观跟当前主题走（对应 C# 换肤后全部 `DynamicResource` 与系统主题一起变）。
@MainActor
enum ThemeAppearance {

    /// 启动期装一次：立即套用当前主题，并订阅后续变更。
    static func install() {
        apply()
        ThemeManager.subscribeChanged { DispatchQueue.main.async { apply() } }
    }

    private static func apply() {
        NSApp.appearance = NSAppearance(named: ThemeManager.isCurrentThemeLight() ? .aqua : .darkAqua)
    }
}
