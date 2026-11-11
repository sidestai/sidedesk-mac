import Foundation

/// 主题色（对应 WPF `System.Windows.Media.Color`）：RGBA 四通道均按 0-255 取值，
/// 与 C# 的 `(byte)` 分量同口径——混合/透明度的截断行为因此与 Windows 端逐位一致。
/// 平台无关（纯 Foundation），UI 层再桥成 `SwiftUI.Color`。
public struct ThemeColor: Equatable {

    public var r: Double
    public var g: Double
    public var b: Double
    /// 不透明度，0-255（WPF `Color.A` 口径，不是 0-1）。
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let white = ThemeColor(r: 255, g: 255, b: 255)
    public static let black = ThemeColor(r: 0, g: 0, b: 0)

    /// 解析 `#RGB` / `#RRGGBB` / `#AARRGGBB`（对应 C# `ThemeManager.ParseColor`），失败返回 nil。
    public static func parse(_ hex: String?) -> ThemeColor? {
        guard let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return nil }
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard let v = UInt64(h, radix: 16) else { return nil }
        func byte(_ shift: Int) -> Double { Double((v >> UInt64(shift)) & 0xFF) }
        func nibble(_ shift: Int) -> Double { Double((v >> UInt64(shift)) & 0xF) }
        switch h.count {
        case 3:
            // #RGB：每位重复（对应 C# 的 h[..1]+h[..1]，即 nibble × 17）
            return ThemeColor(r: nibble(8) * 17, g: nibble(4) * 17, b: nibble(0) * 17)
        case 6:
            return ThemeColor(r: byte(16), g: byte(8), b: byte(0))
        case 8:
            return ThemeColor(r: byte(16), g: byte(8), b: byte(0), a: byte(24))
        default:
            return nil
        }
    }

    /// 相对亮度 0~1（对应 C# `ThemeManager.Luminance`）：用于判定背景深浅。
    public func luminance() -> Double {
        func linear(_ v: Double) -> Double {
            let c = v / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// 自身向 `other` 线性混合，`t` 为 other 的占比（对应 C# `ThemeManager.Blend`）。
    /// 分量按 C# 的 `(byte)` 强转截断（不四舍五入），保证同一份 JSON 主题两端出同一种颜色。
    public func blend(_ other: ThemeColor, _ t: Double) -> ThemeColor {
        let k = min(max(t, 0), 1)
        func mix(_ from: Double, _ to: Double) -> Double { Double(Int(from + (to - from) * k)) }
        return ThemeColor(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b), a: mix(a, other.a))
    }

    /// 改不透明度（入参 0-1），保留 RGB（对应 C# `ThemeManager.WithAlpha`）。
    public func withAlpha(_ alpha: Double) -> ThemeColor {
        ThemeColor(r: r, g: g, b: b, a: Double(Int(min(max(alpha, 0), 1) * 255)))
    }

    /// 不透明 `#RRGGBB`（对应 C# `ThemeManager.ToHex`，颜色桥只接受不透明 hex）。
    public var hex: String {
        String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
    }
}

/// 字号阶梯（对应 `Themes/Typography.xaml` 的 11 个 `FontSize*` 键）。
/// v2 JSON 主题按 `font.size / 13` 等比缩放整套阶梯（对应 `ThemeManager.ApplyFontScale`）。
public struct ThemeFontSizes: Equatable {
    public var tiny: Double = 10
    public var small: Double = 11
    public var smallPlus: Double = 12
    public var normal: Double = 13
    public var normalPlus: Double = 14
    public var large: Double = 15
    public var largePlus: Double = 16
    public var subtitle: Double = 18
    public var title: Double = 20
    public var header: Double = 24
    public var hero: Double = 32

    /// 按缩放因子派生整套阶梯，保留 1 位小数（对应 C# `Math.Round(baseSize * f, 1)`）。
    func scaled(by factor: Double) -> ThemeFontSizes {
        func s(_ v: Double) -> Double { (v * factor * 10).rounded() / 10 }
        return ThemeFontSizes(tiny: s(tiny), small: s(small), smallPlus: s(smallPlus),
                              normal: s(normal), normalPlus: s(normalPlus), large: s(large),
                              largePlus: s(largePlus), subtitle: s(subtitle), title: s(title),
                              header: s(header), hero: s(hero))
    }
}

/// 圆角四档（对应 `Themes/Styles.xaml` 的 `CornerRadiusSmall/Medium/Large/XLarge`）。
/// v2 JSON 主题把 `layout.cornerRadius` 视作 Medium，上下各推一档（`ThemeManager.DeriveRadii`）。
public struct ThemeRadii: Equatable {
    public var small: Double = 4
    public var medium: Double = 6
    public var large: Double = 8
    public var xLarge: Double = 10
}

/// 一套主题令牌（对应 `Themes/DarkTheme.xaml` / `LightTheme.xaml` 的全部资源键 +
/// Typography 字号阶梯 + Styles 圆角四档）。
///
/// 键名去掉 C# 的 `Color`/`Brush` 前缀：WPF 侧同一颜色有两个键（`ColorBG` 给需要 Color 的场合、
/// `BrushBG` 给需要 Brush 的场合），值恒等，Swift 侧无此区分故合并为一个。
/// JSON 自定义主题的派生见 `ThemeManager.derive`。
public struct ThemePalette: Equatable {

    // —— 基础色 ——
    public var bg: ThemeColor
    public var border: ThemeColor
    public var accent: ThemeColor
    public var textMain: ThemeColor
    public var textSec: ThemeColor
    public var textMuted: ThemeColor
    public var inputBG: ThemeColor

    // —— 按钮 ——
    public var accentText: ThemeColor
    public var itemButtonText: ThemeColor
    public var tagSelectedText: ThemeColor
    public var secondaryBtnBG: ThemeColor
    public var secondaryBtnBorder: ThemeColor
    public var secondaryBtnText: ThemeColor

    // —— 列表 ——
    public var listItemMouseOver: ThemeColor
    public var listItemHeaderBG: ThemeColor
    public var listItemSelectedBG: ThemeColor
    public var listItemSelectedBorder: ThemeColor

    // —— 对话框 / 右键菜单 / 分隔线 ——
    public var dialogBG: ThemeColor
    public var contextMenuBG: ThemeColor
    public var contextMenuBorder: ThemeColor
    public var separator: ThemeColor
    public var menuHighlightBG: ThemeColor
    public var menuGestureText: ThemeColor
    public var menuDisabledText: ThemeColor

    // —— 桌面便签（黄色便签，不随深浅色主题变化） ——
    public var stickyBG: ThemeColor
    public var stickyBorder: ThemeColor
    public var stickyText: ThemeColor
    public var stickyFieldBG: ThemeColor

    public var fonts: ThemeFontSizes
    public var radii: ThemeRadii

    /// 深色底座（对应 `Themes/DarkTheme.xaml`，Premium Dark）。
    public static let dark = ThemePalette(
        bg: hex("#FF161616"), border: hex("#FF2A2A2A"), accent: hex("#FF3B82F6"),
        textMain: hex("#FFFFFFFF"), textSec: hex("#FF8E8E8E"), textMuted: hex("#FF6B7280"),
        inputBG: hex("#FF1E1E1E"),
        accentText: .white, itemButtonText: .white, tagSelectedText: .white,
        secondaryBtnBG: hex("#FF252525"), secondaryBtnBorder: hex("#FF333333"),
        secondaryBtnText: hex("#FFAAAAAA"),
        listItemMouseOver: hex("#14FFFFFF"), listItemHeaderBG: hex("#FF252525"),
        listItemSelectedBG: hex("#1F3B82F6"), listItemSelectedBorder: hex("#403B82F6"),
        dialogBG: hex("#FF1A1A1A"), contextMenuBG: hex("#F21A1A1A"),
        contextMenuBorder: hex("#25FFFFFF"), separator: hex("#15FFFFFF"),
        menuHighlightBG: hex("#26FFFFFF"), menuGestureText: hex("#80FFFFFF"),
        menuDisabledText: hex("#40FFFFFF"),
        stickyBG: hex("#FFFFF9C4"), stickyBorder: hex("#FFE0C862"),
        stickyText: hex("#FF4A3B00"), stickyFieldBG: hex("#FFFFFFFF"),
        fonts: ThemeFontSizes(), radii: ThemeRadii()
    )

    /// 浅色底座（对应 `Themes/LightTheme.xaml`，Premium Light）。
    public static let light = ThemePalette(
        bg: hex("#FFF9FAFB"), border: hex("#FFE5E7EB"), accent: hex("#FF2563EB"),
        textMain: hex("#FF111827"), textSec: hex("#FF6B7280"), textMuted: hex("#FFA1A1AA"),
        inputBG: hex("#FFFFFFFF"),
        accentText: .white, itemButtonText: .black, tagSelectedText: hex("#FF2563EB"),
        secondaryBtnBG: hex("#FFF3F4F6"), secondaryBtnBorder: hex("#FFE5E7EB"),
        secondaryBtnText: hex("#FF4B5563"),
        listItemMouseOver: hex("#0D000000"), listItemHeaderBG: hex("#FFF3F4F6"),
        listItemSelectedBG: hex("#202563EB"), listItemSelectedBorder: hex("#402563EB"),
        dialogBG: hex("#FFF9FAFB"), contextMenuBG: hex("#F2FFFFFF"),
        contextMenuBorder: hex("#25000000"), separator: hex("#15000000"),
        menuHighlightBG: hex("#10000000"), menuGestureText: hex("#80000000"),
        menuDisabledText: hex("#40000000"),
        stickyBG: hex("#FFFFF9C4"), stickyBorder: hex("#FFE0C862"),
        stickyText: hex("#FF4A3B00"), stickyFieldBG: hex("#FFFFFFFF"),
        fonts: ThemeFontSizes(), radii: ThemeRadii()
    )

    /// XAML 里的颜色字面量都是合法值，故强制解包（非法即编程错误，尽早崩）。
    private static func hex(_ literal: String) -> ThemeColor { ThemeColor.parse(literal)! }
}
