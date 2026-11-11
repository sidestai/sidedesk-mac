import Foundation

/// 主题管理（对应 C# `Services.ThemeManager` + `App.ApplyTheme` / `App.IsCurrentThemeLight`）。
///
/// 与 C# 的分工相同：底座是深/浅两套固定调色板（对应 `Themes/DarkTheme.xaml` / `LightTheme.xaml`，
/// 由 `Settings.ThemeMode` 选），JSON 自定义主题在底座之上覆盖派生（一套 JSON = 一套主题）。
/// 差别只在载体：WPF 靠 `Application.Resources` 的「根级键覆盖 + 记录已覆盖键」，Swift 侧没有资源字典，
/// 改成每次重算出一个不可变 `ThemePalette`（`recompute`），语义等价、无覆盖栈需要维护。
///
/// issue #48 环境适应层（文本缩放 / 尺寸档位 / 高对比度）与 `SettingsColorBridge` 已移植，见下方对应小节。
///
/// 未移植（各自依赖缺席的子系统，见对应 C# 位置）：
/// - `ThemeCornerRadius` / `ThemeButtonPadding`——C# 由 `Themes/Controls.xaml` 的按钮样式消费，Swift 侧尚无对应样式。
public enum ThemeManager {

    // MARK: - JSON 主题模型（对应 ThemeManager.JsonTheme 一族）

    /// 一套 JSON 自定义主题（`resources/themes/*.json`）。字段名沿用 C# PascalCase，
    /// JSON 键名走 CodingKeys 映射（与 C# 的 `[JsonProperty]` 同口径）。
    public struct JsonTheme: Codable, Equatable {
        public var Name: String = ""
        public var Version: Int = 1
        public var Color: JsonThemeColor = JsonThemeColor()
        public var Font: JsonThemeFont = JsonThemeFont()
        public var Layout: JsonThemeLayout = JsonThemeLayout()

        /// 来源文件名（不含扩展名），用于持久化标识。对应 C# 的 `[JsonIgnore] FileName`，不参与编解码。
        public var FileName: String = ""

        public init() {}

        enum CodingKeys: String, CodingKey { case Name = "name", Version = "version", Color = "color", Font = "font", Layout = "layout" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Name = c.or(.Name, "")
            Version = c.or(.Version, 1)
            // 子对象整体缺失/类型不符时也要回落默认值（`or` 只覆盖类型不符，缺键会抛）
            Color = (try? c.decodeIfPresent(JsonThemeColor.self, forKey: .Color)) ?? JsonThemeColor()
            Font = (try? c.decodeIfPresent(JsonThemeFont.self, forKey: .Font)) ?? JsonThemeFont()
            Layout = (try? c.decodeIfPresent(JsonThemeLayout.self, forKey: .Layout)) ?? JsonThemeLayout()
        }
    }

    public struct JsonThemeColor: Codable, Equatable {
        public var Background: String = ""
        /// C# 侧是死字段（`ApplyTheme` 从不读它，透明度只认设置里的 `BackgroundOpacity`），照搬保留以维持线格式。
        public var BackgroundOpacity: Double = 1.0
        public var TextPrimary: String = ""
        public var TextAlert: String = ""
        public var GroupBackground: String = ""
        public var Accent: String = ""
        public var AccentBookmark: String = ""
        public var AccentAITool: String = ""
        public var AccentBrowser: String = ""
        public var AccentProgram: String = ""
        public var AccentCounter: String = ""
        public var AccentTaskbar: String = ""
        public var Separator: String = ""

        public init() {}

        enum CodingKeys: String, CodingKey {
            case Background = "background", BackgroundOpacity = "backgroundOpacity", TextPrimary = "textPrimary"
            case TextAlert = "textAlert", GroupBackground = "groupBackground", Accent = "accent"
            case AccentBookmark = "accentBookmark", AccentAITool = "accentAITool", AccentBrowser = "accentBrowser"
            case AccentProgram = "accentProgram", AccentCounter = "accentCounter", AccentTaskbar = "accentTaskbar"
            case Separator = "separator"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Background = c.or(.Background, "")
            BackgroundOpacity = c.or(.BackgroundOpacity, 1.0)
            TextPrimary = c.or(.TextPrimary, "")
            TextAlert = c.or(.TextAlert, "")
            GroupBackground = c.or(.GroupBackground, "")
            Accent = c.or(.Accent, "")
            AccentBookmark = c.or(.AccentBookmark, "")
            AccentAITool = c.or(.AccentAITool, "")
            AccentBrowser = c.or(.AccentBrowser, "")
            AccentProgram = c.or(.AccentProgram, "")
            AccentCounter = c.or(.AccentCounter, "")
            AccentTaskbar = c.or(.AccentTaskbar, "")
            Separator = c.or(.Separator, "")
        }
    }

    public struct JsonThemeFont: Codable, Equatable {
        public var Family: String = ""
        public var Size: Double = 14
        public var Bold: Bool = false

        public init() {}

        enum CodingKeys: String, CodingKey { case Family = "family", Size = "size", Bold = "bold" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            Family = c.or(.Family, "")
            Size = c.or(.Size, 14)
            Bold = c.or(.Bold, false)
        }
    }

    public struct JsonThemeLayout: Codable, Equatable {
        public var CornerRadius: Int = 8
        public var ButtonPadding: Int = 8
        public var GroupSpacing: Int = 5
        public var ItemSpacing: Int = 2
        public var SidebarPadding: Int = 5

        public init() {}

        enum CodingKeys: String, CodingKey {
            case CornerRadius = "cornerRadius", ButtonPadding = "buttonPadding", GroupSpacing = "groupSpacing"
            case ItemSpacing = "itemSpacing", SidebarPadding = "sidebarPadding"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            CornerRadius = c.or(.CornerRadius, 8)
            ButtonPadding = c.or(.ButtonPadding, 8)
            GroupSpacing = c.or(.GroupSpacing, 5)
            ItemSpacing = c.or(.ItemSpacing, 2)
            SidebarPadding = c.or(.SidebarPadding, 5)
        }
    }

    // MARK: - 当前状态

    /// 当前生效的令牌集（底座 + JSON 覆盖派生的结果）。UI 侧每次重绘时读它。
    public private(set) static var palette: ThemePalette = .dark

    /// 当前已应用的 JSON 主题（nil = 使用默认深浅底座）。对应 C# `ThemeManager.Current`。
    public private(set) static var current: JsonTheme?

    /// 主题模式（"Dark" / "Light" / "System"），来自 `Settings.ThemeMode`。对应 C# `App._currentThemeMode`。
    private static var themeMode = "Dark"

    /// 系统明暗接缝：C# 读注册表 `AppsUseLightTheme`，mac 侧由宿主注入（`NSApp.effectiveAppearance`）。
    /// 与 C# 同口径按需读取（不做实时监听），故 System 模式下切换系统外观要等下次主题重算才生效。
    public static var systemIsLight: () -> Bool = { false }

    /// 侧栏停靠宽度档位缩放（issue #48 L2，对应 C# `_tierScale`）。启动与布局重建后由宿主经
    /// `updateTierScale(_:)` 更新；默认 1.0（标准档）。
    private static var tierScale = 1.0

    /// 高对比度系统色接缝（对应 C# `System.Windows.SystemColors.*`）：Core 平台无关，宿主注入 NSColor 转换。
    public static var systemColors: () -> SystemColorSet = { .fallback }

    // MARK: - 变更通知（对应 C# `App.ThemeChanged` 事件）

    private static let lock = NSLock()
    private static var changedHandlers: [() -> Void] = []

    /// 订阅主题变更（UI 层据此重绘；对应 C# `App.ThemeChanged += handler`）。
    public static func subscribeChanged(_ handler: @escaping () -> Void) {
        lock.lock(); changedHandlers.append(handler); lock.unlock()
    }

    private static func fireChanged() {
        lock.lock(); let handlers = changedHandlers; lock.unlock()
        for h in handlers { h() }
    }

    /// 外观设置变更广播（背景透明度 / 卡片字号 / 分享与团队边框色）。
    /// C# 侧这三者各有专用钩子（`AppearanceSettingsViewModel` 的 `ApplyPanelBackgroundOpacity` /
    /// `RefreshHostPanels`），Swift 侧收敛到同一条主题变更通道——消费者都是「重绘时重新读设置」的
    /// 同一批视图，分三条通道只会多两次重绘。
    public static func notifyAppearanceChanged() { fireChanged() }

    // MARK: - 加载

    /// 主题目录覆盖（测试缝隙）。nil = 随包主题 + 用户数据目录主题。
    public static var dirOverride: String?

    /// 扫描主题目录，解析全部合法 JSON 主题（按名称排序，不分大小写）。对应 C# `ThemeManager.LoadThemes`。
    ///
    /// 目录口径与 C# 的差别：C# 只扫安装目录下 `resources/themes`；mac 的 `.app` 是签名只读包，
    /// 用户没法往里放主题文件，故额外扫 `{dataDir}/themes`——同名时用户目录的胜出（就近覆盖）。
    public static func loadThemes() -> [JsonTheme] {
        var byName: [String: JsonTheme] = [:]
        for url in bundledThemeURLs {
            if let theme = parse(url) { byName[theme.Name.lowercased()] = theme }
        }
        for url in userThemeURLs {
            if let theme = parse(url) { byName[theme.Name.lowercased()] = theme }
        }
        // C# 用 StringComparer.OrdinalIgnoreCase：固定 POSIX 区域，避免本地化排序把非 ASCII 主题名挪位。
        return byName.values.sorted {
            $0.Name.compare($1.Name, options: .caseInsensitive,
                            range: nil, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
        }
    }

    /// 按主题名查找（名或文件名，不分大小写）。对应 C# `ThemeManager.GetThemeByName`。
    public static func getThemeByName(_ name: String?) -> JsonTheme? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return loadThemes().first {
            $0.Name.caseInsensitiveCompare(name) == .orderedSame
                || $0.FileName.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// 随包主题（对应 C# `ThemeManager.ThemesDir` = 输出目录下 `resources/themes`）。
    private static var bundledThemeURLs: [URL] {
        if let dir = dirOverride { return jsonFiles(in: dir) }
        return ResourceBundles.core.urls(forResourcesWithExtension: "json", subdirectory: "themes") ?? []
    }

    /// 用户数据目录下的主题（mac 特有的可写落点，见 `loadThemes` 的说明）。
    private static var userThemeURLs: [URL] {
        guard dirOverride == nil else { return [] }
        return jsonFiles(in: (AppPaths.dataDir as NSString).appendingPathComponent("themes"))
    }

    private static func jsonFiles(in dir: String) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { ($0 as NSString).pathExtension.lowercased() == "json" }
            .map { URL(fileURLWithPath: (dir as NSString).appendingPathComponent($0)) }
    }

    private static func parse(_ url: URL) -> JsonTheme? {
        do {
            let data = try Data(contentsOf: url)
            var theme = try JSONDecoder().decode(JsonTheme.self, from: data)
            guard !theme.Name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            theme.FileName = url.deletingPathExtension().lastPathComponent
            return theme
        } catch {
            RuntimeLog.debug("[ThemeManager] failed to parse theme \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 应用 / 清除

    /// 应用主题模式（Dark / Light / System）。对应 C# `App.ApplyTheme`。
    /// 目标模式与当前一致时 C# 会提前 return（不触发 ThemeChanged），此处同口径。
    public static func applyThemeMode(_ mode: String) {
        guard mode != themeMode else { return }
        themeMode = mode
        recompute()
        syncSettingsColorBridge()
        RuntimeLog.info("Theme", "apply theme mode: \(mode)")
        fireChanged()
    }

    /// 应用一个 JSON 主题（对应 C# `ThemeManager.ApplyTheme`）。
    public static func applyTheme(_ theme: JsonTheme) {
        current = theme
        recompute()
        syncSettingsColorBridge()
        RuntimeLog.info("Theme", "apply theme \(theme.Name) v\(theme.Version)")
        fireChanged()
    }

    /// 清除 JSON 主题覆盖，还原为纯底座（对应 C# `ThemeManager.ClearTheme`）。
    public static func clearTheme() {
        current = nil
        recompute()
        syncSettingsColorBridge()
        fireChanged()
    }

    /// 按持久化的主题名恢复应用（启动时调用）。返回是否成功。对应 C# `ThemeManager.RestoreFromName`。
    @discardableResult
    public static func restoreFromName(_ name: String?) -> Bool {
        guard let theme = getThemeByName(name) else { return false }
        applyTheme(theme)
        return true
    }

    /// 重算 `palette`：底座随主题模式，JSON 主题在底座上派生覆盖。
    private static func recompute() {
        let base = baseUseLightTheme() ? ThemePalette.light : ThemePalette.dark
        var p: ThemePalette
        if let theme = current {
            p = derive(from: theme, base: base)
        } else {
            p = base
        }
        // 字号合并管线（issue #48，对应 C# `ApplyFontScale`）：base × 主题因子 × 系统文本缩放 × 尺寸档位，
        // 单次取整——derive 已按主题因子缩放过字号，这里从 base 重算整套以对齐 C# 的
        // `round(baseSize × f, 1)`（避免二次取整偏差）。默认三因子皆 1.0 时 `scaled(by:1)` 恒等，palette == 底座。
        let f = (current.map { fontFactor(for: $0) } ?? 1.0) * SystemPreferences.textScale * tierScale
        p.fonts = base.fonts.scaled(by: f)
        palette = p
    }

    /// v2 主题的字号因子（`font.size / 13`）；v1 主题恒 1.0——对应 C# `ApplyTheme` 的版本门控
    /// （v1 只声明颜色，字号/圆角零变化）。
    static func fontFactor(for theme: JsonTheme) -> Double {
        theme.Version >= 2 && theme.Font.Size > 0 ? theme.Font.Size / 13.0 : 1.0
    }

    /// JSON 主题 → 全套令牌（对应 C# `ThemeManager.ApplyTheme` 的派生段，逐式对齐）。
    static func derive(from theme: JsonTheme, base: ThemePalette) -> ThemePalette {
        var p = base
        let c = theme.Color
        let bg = ThemeColor.parse(c.Background) ?? ThemeColor.parse("#FF161616")!
        let text = ThemeColor.parse(c.TextPrimary) ?? ThemeColor.parse("#FFFFFFFF")!
        let accent = ThemeColor.parse(c.Accent) ?? ThemeColor.parse("#FF3B82F6")!
        let groupBG = ThemeColor.parse(c.GroupBackground)
        let sep = ThemeColor.parse(c.Separator)

        let isLight = bg.luminance() > 0.5
        // C# 侧这几处写作 `isLight ? black : white`：浅色主题用黑做半透明叠加，深色主题用白。
        let overlay = isLight ? ThemeColor.black : ThemeColor.white

        // —— 派生次要颜色 ——
        let border = sep ?? bg.blend(text, 0.15)
        let textSec = text.blend(bg, 0.35)
        let textMuted = text.blend(bg, 0.60)
        let inputBG = bg.blend(.white, isLight ? 0.70 : 0.08)
        let dialogBG = bg.blend(.white, isLight ? 0.50 : 0.04)
        let secondaryBtnBG = groupBG ?? inputBG

        p.bg = bg
        p.border = border
        p.accent = accent
        p.textMain = text
        p.textSec = textSec
        p.textMuted = textMuted
        p.inputBG = inputBG

        p.accentText = accent.luminance() > 0.6 ? .black : .white
        p.itemButtonText = isLight ? .black : .white
        p.tagSelectedText = isLight ? accent : .white
        p.secondaryBtnBG = secondaryBtnBG
        p.secondaryBtnBorder = border
        p.secondaryBtnText = textSec

        p.listItemMouseOver = overlay.withAlpha(isLight ? 0.05 : 0.08)
        p.listItemHeaderBG = secondaryBtnBG
        p.listItemSelectedBG = accent.withAlpha(0.20)
        p.listItemSelectedBorder = accent.withAlpha(0.40)

        p.dialogBG = dialogBG
        p.contextMenuBG = dialogBG.withAlpha(0.95)
        p.contextMenuBorder = overlay.withAlpha(0.15)
        p.separator = (sep ?? border).withAlpha(0.50)
        p.menuHighlightBG = overlay.withAlpha(isLight ? 0.06 : 0.15)
        p.menuGestureText = overlay.withAlpha(0.50)
        p.menuDisabledText = overlay.withAlpha(0.25)

        // —— v2 样式层（issue #46）：字号阶梯等比缩放、圆角四档派生 ——
        if theme.Version >= 2 {
            p.fonts = base.fonts.scaled(by: fontFactor(for: theme))
            p.radii = deriveRadii(Double(theme.Layout.CornerRadius))
        }
        return p
    }

    /// v2 圆角派生（纯函数，对应 C# `ThemeManager.DeriveRadii`）：主题值视作 Medium，上下各推一档。
    static func deriveRadii(_ cornerRadius: Double) -> ThemeRadii {
        let r = max(0, cornerRadius)
        return ThemeRadii(small: max(0, r - 2), medium: r, large: r + 2, xLarge: r + 4)
    }

    // MARK: - issue #48：尺寸档位 / 高对比度 / 颜色桥

    /// 尺寸档位缩放（纯函数，单测用，对应 C# `ComputeTierScale`）：停靠静息宽度 DIP 决定密度档——
    /// <90 紧凑(0.92) / 90-159 标准(1.0) / ≥160 宽松(1.08)。取静息宽度而非悬浮瞬态，避免悬停抖动。
    public static func computeTierScale(_ restingWidth: Int) -> Double {
        restingWidth < 90 ? 0.92 : restingWidth < 160 ? 1.0 : 1.08
    }

    /// 按停靠宽度更新档位并重算字号（对应 C# `UpdateTierFromSettings`）：值未变则免动。
    /// 宽度由宿主从 `Seam.settings`（Right 布局取 RightPanelWidth，否则 LeftPanelWidth）算出后传入——
    /// Core 不依赖 Services，故读取留在宿主。
    public static func updateTierScale(_ restingWidth: Int) {
        let scale = computeTierScale(restingWidth)
        guard abs(scale - tierScale) >= 0.001 else { return }
        tierScale = scale
        recompute()
        RuntimeLog.info("Theme", "尺寸档位: 停靠宽度=\(restingWidth) → 缩放=\(scale)")
        fireChanged()
    }

    /// 高对比度接管（对应 C# `ApplyHighContrast`）：用系统色覆盖可见令牌，保证任意主题下可读。
    /// 从当前 palette 起覆盖（非覆盖键如便签/次要按钮保持），并清 `current`——关闭后由宿主经
    /// `reapplyNormal` 恢复用户主题。字号管线不受影响（tierScale/textScale 仍在 recompute 里生效）。
    public static func applyHighContrast() {
        let sc = systemColors()
        var p = palette
        p.bg = sc.window
        p.dialogBG = sc.window
        p.contextMenuBG = sc.menu
        p.contextMenuBorder = sc.border
        p.textMain = sc.text
        p.textSec = sc.text
        p.textMuted = sc.text
        p.accent = sc.highlight
        p.accentText = sc.highlightText
        p.border = sc.border
        p.separator = sc.border
        p.inputBG = sc.control
        p.listItemMouseOver = sc.highlight
        p.listItemSelectedBG = sc.highlight
        p.listItemSelectedBorder = sc.highlight
        p.menuHighlightBG = sc.highlight
        palette = p
        current = nil
        RuntimeLog.info("Theme", "高对比度适配已应用（SystemColors 覆盖）")
        fireChanged()
    }

    /// 关闭高对比度后恢复正常主题（对应 C# `OnSystemPreferencesChanged` 的 else 分支）：
    /// 按主题模式 + 持久化主题名重算（无自定义主题则回底座），并广播重绘。
    public static func reapplyNormal(themeMode mode: String, customThemeName: String?) {
        themeMode = mode
        current = getThemeByName(customThemeName)
        recompute()
        syncSettingsColorBridge()
        fireChanged()
    }

    /// 当前 JSON 主题的颜色桥值（不透明 #RRGGBB，对应 C# `SettingsColorBridge`）；无自定义主题时为 nil。
    /// groupBackground 缺失时按 `Blend(bg, White, 亮度>0.5 ? 0.70 : 0.08)` 兜底——与 derive 的 inputBG 同式。
    public static var settingsColorBridge: (bg: String, font: String, groupBG: String)? {
        guard let t = current else { return nil }
        let bg = ThemeColor.parse(t.Color.Background) ?? ThemeColor.parse("#FF161616")!
        let text = ThemeColor.parse(t.Color.TextPrimary) ?? ThemeColor.parse("#FFFFFFFF")!
        let groupBG = ThemeColor.parse(t.Color.GroupBackground)
            ?? bg.blend(.white, bg.luminance() > 0.5 ? 0.70 : 0.08)
        return (bg.hex, text.hex, groupBG.hex)
    }

    /// 把当前主题色同步到 `AppSettings` 旧绑定（对应 C# `App.SyncThemeToAppSettings`）：
    /// 有自定义主题走颜色桥，否则按基础深浅落固定三色。与 C# 同口径——只改内存实例、不 Save。
    static func syncSettingsColorBridge() {
        let s = AppSettings.Instance
        if let b = settingsColorBridge {
            s.BGColor = b.bg; s.FontColor = b.font; s.GroupBGColor = b.groupBG
        } else if baseUseLightTheme() {
            s.BGColor = "#F9FAFB"; s.FontColor = "#111827"; s.GroupBGColor = "#F3F4F6"
        } else {
            s.BGColor = "#161616"; s.FontColor = "#FFFFFF"; s.GroupBGColor = "#252525"
        }
    }

    // MARK: - 明暗判定

    /// 当前是否浅色（对应 C# `App.IsCurrentThemeLight`）：JSON 自定义主题的背景明暗优先。
    public static func isCurrentThemeLight() -> Bool {
        if let theme = current, let bg = ThemeColor.parse(theme.Color.Background) {
            return bg.luminance() > 0.5
        }
        return baseUseLightTheme()
    }

    /// 基础模式（Dark/Light/System）的明暗判定，不含 JSON 主题覆盖（对应 C# `App.BaseUseLightTheme`）。
    static func baseUseLightTheme() -> Bool {
        if themeMode.caseInsensitiveCompare("System") == .orderedSame { return systemIsLight() }
        return themeMode.caseInsensitiveCompare("Light") == .orderedSame
    }

    // MARK: - 令牌取用（对应 C# `internal static class ThemeTokens`）

    /// 按字面量档位取字号：10/11/12/…/32 → 阶梯对应档（v2 主题下已缩放），其余原样返回。
    /// 对应 C# `ThemeTokens.FontSize`（查不到资源时回落字面量，行为与改造前一致）。
    public static func fontSize(_ literal: Double) -> Double {
        let f = palette.fonts
        switch literal {
        case 10: return f.tiny
        case 11: return f.small
        case 12: return f.smallPlus
        case 13: return f.normal
        case 14: return f.normalPlus
        case 15: return f.large
        case 16: return f.largePlus
        case 18: return f.subtitle
        case 20: return f.title
        case 24: return f.header
        case 32: return f.hero
        default: return literal
        }
    }

    /// 按字面量档位取圆角：≤5 → Small、6 → Medium、8 → Large、10 → XLarge，其余原样返回。
    /// 对应 C# `ThemeTokens.Radius`。
    public static func radius(_ literal: Double) -> Double {
        let r = palette.radii
        switch literal {
        case 6:  return r.medium
        case 8:  return r.large
        case 10: return r.xLarge
        default: return literal <= 5 ? r.small : literal
        }
    }

    /// 启动时按已保存偏好布置主题（对应 C# `App.StartupServices` 的
    /// `ApplyTheme(AppSettings.ThemeMode)` + `ThemeManager.RestoreFromName(AppSettings.Instance.CurrentTheme)`）。
    /// 不触发变更通知——此时还没有任何 UI 订阅者。
    public static func initialize(themeMode mode: String, customThemeName: String?) {
        themeMode = mode
        current = getThemeByName(customThemeName)
        if current == nil, let name = customThemeName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            RuntimeLog.debug("[ThemeManager] saved theme not found: \(name)")
        }
        recompute()
    }
}

/// 高对比度系统色集（对应 C# `System.Windows.SystemColors.*`）。Core 平台无关，宿主把 NSColor 转成分量注入。
/// 字段名按用途而非 WPF 键名，映射见 `ThemeManager.applyHighContrast`。
public struct SystemColorSet: Equatable {
    /// WindowColor → bg / dialogBG
    public var window: ThemeColor
    /// WindowTextColor → textMain / textSec / textMuted
    public var text: ThemeColor
    /// HighlightColor → accent / 列表选中 / 菜单高亮
    public var highlight: ThemeColor
    /// HighlightTextColor → accentText
    public var highlightText: ThemeColor
    /// ActiveBorderColor → border / separator / contextMenuBorder
    public var border: ThemeColor
    /// ControlColor → inputBG
    public var control: ThemeColor
    /// MenuColor → contextMenuBG
    public var menu: ThemeColor

    public init(window: ThemeColor, text: ThemeColor, highlight: ThemeColor, highlightText: ThemeColor,
                border: ThemeColor, control: ThemeColor, menu: ThemeColor) {
        self.window = window; self.text = text; self.highlight = highlight
        self.highlightText = highlightText; self.border = border; self.control = control; self.menu = menu
    }

    /// 宿主未注入时的兜底（黑底白字高对比），保证 Core 单测/无 UI 环境不崩。
    public static let fallback = SystemColorSet(
        window: .black, text: .white, highlight: ThemeColor.parse("#FF00FFFF")!,
        highlightText: .black, border: .white, control: .black, menu: .black
    )
}
