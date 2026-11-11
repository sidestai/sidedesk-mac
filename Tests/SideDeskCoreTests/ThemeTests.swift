import XCTest
@testable import SideDeskCore

/// 主题令牌系统（对应 C# `Services.ThemeManager` 的颜色工具 / 派生 / 加载）。
/// 断言值按 C# 的算法手算，确保两端同一份 JSON 主题出同一套颜色。
final class ThemeTests: XCTestCase {

    // MARK: - ThemeColor

    func testParseHexForms() {
        XCTAssertEqual(ThemeColor.parse("#FF161616"), ThemeColor(r: 0x16, g: 0x16, b: 0x16, a: 255))
        XCTAssertEqual(ThemeColor.parse("3B82F6"), ThemeColor(r: 0x3B, g: 0x82, b: 0xF6))
        XCTAssertEqual(ThemeColor.parse("#FFF"), ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(ThemeColor.parse("#15FFFFFF"), ThemeColor(r: 255, g: 255, b: 255, a: 0x15))
        XCTAssertEqual(ThemeColor.parse("  #10B981  "), ThemeColor(r: 0x10, g: 0xB9, b: 0x81))
    }

    func testParseRejectsMalformed() {
        for bad in [nil, "", "#", "#12345", "#GGGGGG", "0x161616", "#1616160000"] {
            XCTAssertNil(ThemeColor.parse(bad), "should reject \(bad ?? "nil")")
        }
    }

    func testLuminance() {
        XCTAssertEqual(ThemeColor.white.luminance(), 1, accuracy: 0.0001)
        XCTAssertEqual(ThemeColor.black.luminance(), 0, accuracy: 0.0001)
        // Dracula 背景 #282A36 属深色（判定阈值 0.5）
        XCTAssertLessThan(ThemeColor.parse("#282A36")!.luminance(), 0.5)
        // LightPure 背景 #F2F3F5 属浅色
        XCTAssertGreaterThan(ThemeColor.parse("#F2F3F5")!.luminance(), 0.5)
    }

    func testBlendTruncatesLikeWPFByteCast() {
        // Blend(#282A36, #FFFFFF, 0.08)：40+(255-40)*0.08=57.2 / 42+17.04=59.04 / 54+16.08=70.08
        // → C# 的 (byte) 强转一律截断为 57 / 59 / 70
        let blended = ThemeColor.parse("#282A36")!.blend(.white, 0.08)
        XCTAssertEqual(blended, ThemeColor(r: 57, g: 59, b: 70))
        // t 越界夹取
        XCTAssertEqual(ThemeColor.black.blend(.white, 5), .white)
        XCTAssertEqual(ThemeColor.black.blend(.white, -1), .black)
    }

    func testWithAlphaAndHex() {
        XCTAssertEqual(ThemeColor.parse("#3B82F6")!.withAlpha(0.20), ThemeColor(r: 0x3B, g: 0x82, b: 0xF6, a: 51))
        XCTAssertEqual(ThemeColor.parse("#44475A")!.withAlpha(0.50).a, 127)
        XCTAssertEqual(ThemeColor.parse("#15FFFFFF")!.hex, "#FFFFFF")   // ToHex 丢掉 alpha
        XCTAssertEqual(ThemeColor.parse("#FF0A0B0C")!.hex, "#0A0B0C")
    }

    // MARK: - 纯函数派生

    func testDeriveRadii() {
        XCTAssertEqual(ThemeManager.deriveRadii(6), ThemeRadii(small: 4, medium: 6, large: 8, xLarge: 10))
        XCTAssertEqual(ThemeManager.deriveRadii(12), ThemeRadii(small: 10, medium: 12, large: 14, xLarge: 16))
        XCTAssertEqual(ThemeManager.deriveRadii(-3), ThemeRadii(small: 0, medium: 0, large: 2, xLarge: 4))
    }

    func testFontFactorIsVersionGated() {
        var theme = ThemeManager.JsonTheme()
        theme.Version = 1
        theme.Font.Size = 20
        XCTAssertEqual(ThemeManager.fontFactor(for: theme), 1.0, "v1 主题不碰字体")
        theme.Version = 2
        XCTAssertEqual(ThemeManager.fontFactor(for: theme), 20 / 13.0, accuracy: 0.0001)
        theme.Font.Size = 0
        XCTAssertEqual(ThemeManager.fontFactor(for: theme), 1.0)
    }

    func testFontLadderScalingRoundsToOneDecimal() {
        let scaled = ThemeFontSizes().scaled(by: 14 / 13)
        XCTAssertEqual(scaled.tiny, 10.8, accuracy: 0.0001)     // round(10 × 1.0769, 1)
        XCTAssertEqual(scaled.normal, 14.0, accuracy: 0.0001)
        XCTAssertEqual(scaled.hero, 34.5, accuracy: 0.0001)
        XCTAssertEqual(ThemeFontSizes().scaled(by: 1.0), ThemeFontSizes())
    }

    func testDeriveMatchesCSharpFormulas() {
        var theme = ThemeManager.JsonTheme()
        theme.Name = "Dracula Vampire"
        theme.Color.Background = "#282A36"
        theme.Color.TextPrimary = "#F8F8F2"
        theme.Color.Accent = "#BD93F9"
        theme.Color.GroupBackground = "#343746"
        theme.Color.Separator = "#44475A"

        let p = ThemeManager.derive(from: theme, base: .dark)
        let bg = ThemeColor.parse("#282A36")!
        let text = ThemeColor.parse("#F8F8F2")!

        XCTAssertEqual(p.bg, bg)
        XCTAssertEqual(p.textMain, text)
        XCTAssertEqual(p.accent, ThemeColor.parse("#BD93F9"))
        XCTAssertEqual(p.border, ThemeColor.parse("#44475A"), "separator 存在时直接当 border")
        XCTAssertEqual(p.textSec, text.blend(bg, 0.35))
        XCTAssertEqual(p.textMuted, text.blend(bg, 0.60))
        XCTAssertEqual(p.inputBG, bg.blend(.white, 0.08))
        XCTAssertEqual(p.dialogBG, bg.blend(.white, 0.04))
        XCTAssertEqual(p.secondaryBtnBG, ThemeColor.parse("#343746"), "groupBackground 优先于 inputBG")
        XCTAssertEqual(p.separator, ThemeColor.parse("#44475A")!.withAlpha(0.50))
        XCTAssertEqual(p.listItemSelectedBG, ThemeColor.parse("#BD93F9")!.withAlpha(0.20))
        XCTAssertEqual(p.contextMenuBG, p.dialogBG.withAlpha(0.95))
        // 深色主题：叠加色用白、正文按钮字用白
        XCTAssertEqual(p.itemButtonText, .white)
        XCTAssertEqual(p.menuHighlightBG, ThemeColor.white.withAlpha(0.15))
        XCTAssertEqual(p.accentText, .white, "accent 亮度 0.385 ≤ 0.6 → 白字")
        // 便签令牌不随主题变化（对应 C# 只覆盖列出的键）
        XCTAssertEqual(p.stickyBG, ThemePalette.dark.stickyBG)
        // v1 主题不动字号/圆角
        XCTAssertEqual(p.fonts, ThemeFontSizes())
        XCTAssertEqual(p.radii, ThemeRadii())
    }

    func testDeriveLightBackgroundFlipsOverlayColors() {
        var theme = ThemeManager.JsonTheme()
        theme.Color.Background = "#F2F3F5"
        theme.Color.TextPrimary = "#222222"

        let p = ThemeManager.derive(from: theme, base: .light)
        XCTAssertEqual(p.itemButtonText, .black)
        XCTAssertEqual(p.tagSelectedText, p.accent, "浅色主题选中标签用强调色")
        XCTAssertEqual(p.inputBG, ThemeColor.parse("#F2F3F5")!.blend(.white, 0.70))
        XCTAssertEqual(p.menuHighlightBG, ThemeColor.black.withAlpha(0.06))
        // 无 separator 时 border = Blend(bg, text, 0.15)
        XCTAssertEqual(p.border, ThemeColor.parse("#F2F3F5")!.blend(ThemeColor.parse("#222222")!, 0.15))
        // 无 groupBackground 时次要按钮底 = inputBG
        XCTAssertEqual(p.secondaryBtnBG, p.inputBG)
    }

    func testDeriveFallsBackToDarkDefaults() {
        // 三个关键色都缺失/非法时回落 C# 的兜底字面量
        var theme = ThemeManager.JsonTheme()
        theme.Color.Background = "not-a-color"
        let p = ThemeManager.derive(from: theme, base: .light)
        XCTAssertEqual(p.bg, ThemeColor.parse("#FF161616"))
        XCTAssertEqual(p.textMain, ThemeColor.parse("#FFFFFFFF"))
        XCTAssertEqual(p.accent, ThemeColor.parse("#FF3B82F6"))
    }

    func testDeriveV2AppliesFontAndRadius() {
        var theme = ThemeManager.JsonTheme()
        theme.Version = 2
        theme.Font.Size = 14
        theme.Layout.CornerRadius = 6
        let p = ThemeManager.derive(from: theme, base: .dark)
        XCTAssertEqual(p.fonts.tiny, 10.8, accuracy: 0.0001)
        XCTAssertEqual(p.radii, ThemeRadii(small: 4, medium: 6, large: 8, xLarge: 10))
    }

    // MARK: - 随包主题

    func testBundledThemesLoad() {
        let themes = ThemeManager.loadThemes()
        XCTAssertEqual(themes.count, 11, "resources/themes 下应有 11 套随包主题")
        XCTAssertTrue(themes.contains { $0.Name == "Dracula Vampire" })
        XCTAssertTrue(themes.contains { $0.Name == "Codex" })
        // 按名称排序（不分大小写）
        let names = themes.map { $0.Name }
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        // FileName 来自文件名（用于持久化标识与中文名映射）
        XCTAssertEqual(themes.first { $0.Name == "Codex" }?.FileName, "Codex_Dark")
    }

    func testGetThemeByNameMatchesNameOrFileName() {
        XCTAssertNotNil(ThemeManager.getThemeByName("Monokai Pro"))
        XCTAssertNotNil(ThemeManager.getThemeByName("monokai_pro"))
        XCTAssertNil(ThemeManager.getThemeByName("NoSuchTheme"))
        XCTAssertNil(ThemeManager.getThemeByName(""))
        XCTAssertNil(ThemeManager.getThemeByName(nil))
    }

    func testParseSkipsMalformedThemeFile() throws {
        let dir = NSTemporaryDirectory() + "sidest-themes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 合法但无 name → 丢弃（对应 C# `string.IsNullOrWhiteSpace(theme.Name)` 判定）
        try "{\"color\":{\"background\":\"#101010\"}}".write(toFile: dir + "/noname.json", atomically: true, encoding: .utf8)
        // 非 JSON → 丢弃
        try "not json".write(toFile: dir + "/broken.json", atomically: true, encoding: .utf8)
        try "{\"name\":\"Only One\",\"version\":1}".write(toFile: dir + "/ok.json", atomically: true, encoding: .utf8)

        ThemeManager.dirOverride = dir
        defer { ThemeManager.dirOverride = nil }
        let themes = ThemeManager.loadThemes()
        XCTAssertEqual(themes.map { $0.Name }, ["Only One"])
        XCTAssertEqual(themes[0].FileName, "ok")
        // 缺省字段走默认值（宽松解码）
        XCTAssertEqual(themes[0].Version, 1)
        XCTAssertEqual(themes[0].Font.Size, 14)
        XCTAssertEqual(themes[0].Layout.CornerRadius, 8)
        XCTAssertEqual(themes[0].Color.Background, "")
    }

    // MARK: - 应用 / 模式

    /// 全局状态用例：按顺序断言并在结束时还原，避免与其它用例互相污染。
    func testApplyThemeModeAndCustomTheme() {
        defer { ThemeManager.initialize(themeMode: "Dark", customThemeName: nil) }

        ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        XCTAssertEqual(ThemeManager.palette, .dark)
        XCTAssertFalse(ThemeManager.isCurrentThemeLight())
        XCTAssertNil(ThemeManager.current)

        ThemeManager.applyThemeMode("Light")
        XCTAssertEqual(ThemeManager.palette, .light)
        XCTAssertTrue(ThemeManager.isCurrentThemeLight())
        // 同模式重复应用是空操作（对应 C# ApplyTheme 的提前 return）
        var fired = 0
        ThemeManager.subscribeChanged { fired += 1 }
        ThemeManager.applyThemeMode("Light")
        XCTAssertEqual(fired, 0)

        // System 模式经接缝判定
        ThemeManager.systemIsLight = { true }
        ThemeManager.applyThemeMode("System")
        XCTAssertEqual(ThemeManager.palette, .light)
        ThemeManager.systemIsLight = { false }
        ThemeManager.applyThemeMode("Dark")
        ThemeManager.applyThemeMode("System")
        XCTAssertEqual(ThemeManager.palette, .dark)
        ThemeManager.systemIsLight = { false }

        // JSON 主题在底座之上派生（前面的 System/Dark 切换已各自触发过一次）
        fired = 0
        XCTAssertTrue(ThemeManager.restoreFromName("Dracula Vampire"))
        XCTAssertEqual(ThemeManager.current?.FileName, "Dracula_Vampire")
        XCTAssertEqual(ThemeManager.palette.bg, ThemeColor.parse("#282A36"))
        XCTAssertEqual(fired, 1, "applyTheme 触发一次变更通知")

        // 切底座时自定义主题仍覆盖在上层（对应 C# 根级键覆盖优先于合并字典）
        ThemeManager.applyThemeMode("Light")
        XCTAssertEqual(ThemeManager.palette.bg, ThemeColor.parse("#282A36"))
        XCTAssertEqual(ThemeManager.palette.stickyBG, ThemePalette.light.stickyBG)

        // 清除后回到纯底座
        ThemeManager.clearTheme()
        XCTAssertNil(ThemeManager.current)
        XCTAssertEqual(ThemeManager.palette, .light)

        // 找不到的主题名不改动状态
        XCTAssertFalse(ThemeManager.restoreFromName("NoSuchTheme"))
        XCTAssertNil(ThemeManager.current)

        // v2 主题（Codex）缩放字号阶梯，v1 主题不缩放
        ThemeManager.applyThemeMode("Dark")
        ThemeManager.restoreFromName("Codex_Dark")
        XCTAssertEqual(ThemeManager.fontSize(10), 10.8, accuracy: 0.0001)
        XCTAssertEqual(ThemeManager.radius(6), 6)
        ThemeManager.restoreFromName("AuroraDream_Purple")
        XCTAssertEqual(ThemeManager.palette.bg, ThemeColor.parse("#1A102A"))
        XCTAssertEqual(ThemeManager.fontSize(10), 10, accuracy: 0.0001)
        XCTAssertEqual(ThemeManager.radius(6), 6, "v1 主题的 layout.cornerRadius 是死字段")
        ThemeManager.clearTheme()

        // 阶梯外的字面量原样返回（对应 C# 查不到资源回落字面量）
        XCTAssertEqual(ThemeManager.fontSize(17), 17)
        XCTAssertEqual(ThemeManager.radius(7), 7)
        XCTAssertEqual(ThemeManager.radius(3), 4, "≤5 → Small")
        XCTAssertEqual(ThemeManager.radius(8), 8)
        XCTAssertEqual(ThemeManager.radius(10), 10)

        // 明暗判定：浅色自定义主题即便底座是深色也判浅色
        ThemeManager.restoreFromName("LightPure_Elegant")
        XCTAssertTrue(ThemeManager.isCurrentThemeLight())
    }

    func testInitializeIgnoresUnknownSavedTheme() {
        defer { ThemeManager.initialize(themeMode: "Dark", customThemeName: nil) }
        ThemeManager.initialize(themeMode: "Light", customThemeName: "被删掉的主题")
        XCTAssertNil(ThemeManager.current)
        XCTAssertEqual(ThemeManager.palette, .light)
    }

    // MARK: - issue #48：尺寸档位 / 文本缩放 / 高对比度 / 颜色桥

    func testComputeTierScale() {
        XCTAssertEqual(ThemeManager.computeTierScale(89), 0.92)
        XCTAssertEqual(ThemeManager.computeTierScale(90), 1.0)
        XCTAssertEqual(ThemeManager.computeTierScale(159), 1.0)
        XCTAssertEqual(ThemeManager.computeTierScale(160), 1.08)
    }

    func testTierScaleScalesFonts() {
        defer {
            SystemPreferences.systemTextScale = { 1.0 }; SystemPreferences.refresh()
            ThemeManager.updateTierScale(105)
            ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        }
        ThemeManager.updateTierScale(105)
        ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        XCTAssertEqual(ThemeManager.fontSize(13), 13, "标准档不缩放")

        ThemeManager.updateTierScale(200)  // 宽松 1.08
        XCTAssertEqual(ThemeManager.fontSize(13), 14.0, accuracy: 0.0001) // round(13×1.08,1)
        ThemeManager.updateTierScale(50)   // 紧凑 0.92
        XCTAssertEqual(ThemeManager.fontSize(13), 12.0, accuracy: 0.0001) // round(13×0.92,1)=round(11.96,1)
        // 档位未变则不重算（no-op）
        var fired = 0
        ThemeManager.subscribeChanged { fired += 1 }
        ThemeManager.updateTierScale(60)   // 仍 0.92
        XCTAssertEqual(fired, 0)
    }

    func testTextScaleCombinesWithTierSingleRounding() {
        defer {
            SystemPreferences.systemTextScale = { 1.0 }; SystemPreferences.refresh()
            ThemeManager.updateTierScale(105)
            ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        }
        ThemeManager.updateTierScale(105)
        SystemPreferences.systemTextScale = { 1.5 }
        SystemPreferences.refresh()
        ThemeManager.reapplyNormal(themeMode: "Dark", customThemeName: nil)
        // 单次取整：round(13 × 1.0(主题) × 1.5(文本) × 1.0(档位), 1) = 19.5
        XCTAssertEqual(ThemeManager.fontSize(13), 19.5, accuracy: 0.0001)
        XCTAssertEqual(ThemeManager.fontSize(10), 15.0, accuracy: 0.0001)
    }

    func testSettingsColorBridgeAndSync() {
        defer { ThemeManager.initialize(themeMode: "Dark", customThemeName: nil) }
        ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        ThemeManager.clearTheme()  // 触发 syncSettingsColorBridge → 基础深色三色（initialize 本身不同步）
        XCTAssertNil(ThemeManager.settingsColorBridge, "无自定义主题 → nil")
        // 无自定义主题时同步基础深色三色（对应 C# SyncThemeToAppSettings 的 else 分支）
        XCTAssertEqual(AppSettings.Instance.BGColor, "#161616")
        XCTAssertEqual(AppSettings.Instance.FontColor, "#FFFFFF")
        XCTAssertEqual(AppSettings.Instance.GroupBGColor, "#252525")

        var theme = ThemeManager.JsonTheme()
        theme.Name = "T"
        theme.Color.Background = "#282A36"
        theme.Color.TextPrimary = "#F8F8F2"
        theme.Color.GroupBackground = "#343746"
        ThemeManager.applyTheme(theme)
        let b = ThemeManager.settingsColorBridge
        XCTAssertEqual(b?.bg, "#282A36")
        XCTAssertEqual(b?.font, "#F8F8F2")
        XCTAssertEqual(b?.groupBG, "#343746")
        // 同步进 AppSettings 旧绑定（不 Save）
        XCTAssertEqual(AppSettings.Instance.BGColor, "#282A36")
        XCTAssertEqual(AppSettings.Instance.GroupBGColor, "#343746")

        // groupBackground 缺失 → Blend(bg, White, 亮度>0.5?0.70:0.08)；#282A36 属深色取 0.08
        theme.Color.GroupBackground = ""
        ThemeManager.applyTheme(theme)
        let expected = ThemeColor.parse("#282A36")!.blend(.white, 0.08).hex
        XCTAssertEqual(ThemeManager.settingsColorBridge?.groupBG, expected)
    }

    func testApplyHighContrastAndRestore() {
        defer {
            ThemeManager.systemColors = { .fallback }
            ThemeManager.reapplyNormal(themeMode: "Dark", customThemeName: nil)
        }
        ThemeManager.initialize(themeMode: "Dark", customThemeName: nil)
        let hc = SystemColorSet(
            window: .black, text: .white,
            highlight: ThemeColor.parse("#FF00FFFF")!, highlightText: .black,
            border: .white, control: ThemeColor.parse("#FF222222")!, menu: .black)
        ThemeManager.systemColors = { hc }
        ThemeManager.applyHighContrast()
        let p = ThemeManager.palette
        XCTAssertEqual(p.bg, .black)
        XCTAssertEqual(p.dialogBG, .black)
        XCTAssertEqual(p.textMain, .white)
        XCTAssertEqual(p.textSec, .white, "HC 下三级文字都并成正文色")
        XCTAssertEqual(p.textMuted, .white)
        XCTAssertEqual(p.accent, ThemeColor.parse("#FF00FFFF"))
        XCTAssertEqual(p.accentText, .black)
        XCTAssertEqual(p.border, .white)
        XCTAssertEqual(p.separator, .white, "HC 分隔线用实色边框，不再半透明")
        XCTAssertEqual(p.inputBG, ThemeColor.parse("#FF222222"))
        XCTAssertEqual(p.listItemSelectedBG, ThemeColor.parse("#FF00FFFF"))
        XCTAssertEqual(p.menuHighlightBG, ThemeColor.parse("#FF00FFFF"))
        XCTAssertNil(ThemeManager.current, "HC 接管清 JSON 主题状态")
        // 便签令牌不被 HC 覆盖（对应 C# 只覆盖列出的键）
        XCTAssertEqual(p.stickyBG, ThemePalette.dark.stickyBG)

        ThemeManager.reapplyNormal(themeMode: "Dark", customThemeName: nil)
        XCTAssertEqual(ThemeManager.palette.bg, ThemePalette.dark.bg)
        XCTAssertEqual(ThemeManager.palette.textMain, ThemePalette.dark.textMain)
    }
}
