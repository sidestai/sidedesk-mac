import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 外观的状态与流程（对应 C# `ViewModels/AppearanceSettingsViewModel` + `AppearanceSeam`）。
/// 三个输入框一律「失焦 + 回车」两条提交路径，非法值回退当前设置值（与 C# 同口径）。
@MainActor
final class AppearanceSettingsModel: ObservableObject {

    /// 主题模式下拉索引 → 设置值（对应 C# `ThemeModeIndex`：0 深色 / 1 浅色 / 2 跟随系统）
    static let themeModes = ["Dark", "Light", "System"]

    /// 预设色板（对应 C# `BorderColorPresets`：点击即应用）
    static let borderColorPresets =
        ["#A855F7", "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#EC4899", "#06B6D4", "#8E8E8E"]

    /// 配色主题中文显示名（对应 C# `ThemeZhNames`：仅中文语言时生效，键为主题文件名——比 JSON 内的 name 稳定）
    static let themeZhNames: [String: String] = [
        "AuroraDream_Purple": "极光之梦·紫",
        "CyberBlue_Neon": "赛博蓝·霓虹",
        "DarkFlat_Classic": "扁平暗色·经典",
        "DarkNeo_Modern": "新式暗色·现代",
        "DeepOcean_Blue": "深海·蓝",
        "Dracula_Vampire": "德古拉·吸血鬼",
        "LightPure_Elegant": "纯净亮色·优雅",
        "MatrixGreen_Terminal": "矩阵绿·终端",
        "Monokai_Pro": "Monokai 专业版",
        "SolarAmber_Warm": "日光琥珀·暖",
    ]

    /// 主题清单（对应 C# `ReloadCustomThemes`：扫一次目录，标签每次重绘按当前语言算）
    private let themes = ThemeManager.loadThemes()

    @Published private(set) var themeModeIndex: Int
    @Published private(set) var selectedThemeIndex: Int
    @Published private(set) var hideModuleTitle: Bool

    @Published var opacityText: String
    @Published var cardFontSizeText: String
    @Published var shareColorText: String
    @Published var teamColorText: String

    init() {
        themeModeIndex = Self.themeModes.firstIndex(of: Seam.settings.ThemeMode) ?? 0
        hideModuleTitle = AppSettings.Instance.HideModuleTitle
        opacityText = Self.intText(Seam.settings.BackgroundOpacity)
        cardFontSizeText = Self.intText(AppSettings.Instance.CardFontSize)
        shareColorText = AppSettings.Instance.ShareBorderColor
        teamColorText = AppSettings.Instance.TeamBorderColor
        // 按保存的主题名还原选中项（名或文件名匹配，与 C# `Load()` 同口径）
        let saved = AppSettings.Instance.CurrentTheme
        selectedThemeIndex = themes.firstIndex {
            $0.Name.caseInsensitiveCompare(saved) == .orderedSame
                || $0.FileName.caseInsensitiveCompare(saved) == .orderedSame
        }.map { $0 + 1 } ?? 0
    }

    /// 配色主题下拉项（对应 C# `ThemeOptions`：首项「默认」）。
    /// 标签随当前语言变，故在 body 里重算而不是缓存。
    var themeOptions: [String] {
        var labels = [Lang.t("common.default")]
        labels.append(contentsOf: themes.map { displayName($0) })
        return labels
    }

    /// 中文语言下给中文译名，其余语言（或无译文的新主题）显示主题原名（对应 C# `DisplayName`）。
    private func displayName(_ theme: ThemeManager.JsonTheme) -> String {
        if Lang.current.hasPrefix("zh"), let zh = Self.themeZhNames[theme.FileName] { return zh }
        return theme.Name
    }

    private static func intText(_ value: Double) -> String { String(Int(value.rounded())) }

    // MARK: - 主题模式 / 配色主题

    func selectThemeMode(_ index: Int) {
        let mode = Self.themeModes[index]
        guard mode != Seam.settings.ThemeMode else {
            themeModeIndex = index
            return
        }
        Seam.settings.ThemeMode = mode
        Seam.settings.Save()
        // 对应 C# seam 的 `App.ApplyTheme(value)`（内部会触发 ThemeChanged）
        ThemeManager.applyThemeMode(mode)
        themeModeIndex = index
    }

    /// 选中配色主题（对应 C# `SelectedThemeIndex` → `ApplyCustomTheme`：0 = 默认，清除 JSON 覆盖）
    func selectTheme(_ index: Int) {
        applyCustomTheme(index <= 0 ? nil : themes[index - 1].Name)
    }

    /// 对应 C# `AppearanceSeam.ApplyCustomTheme`：找不到主题时不改任何状态（C# 返回 false）。
    private func applyCustomTheme(_ name: String?) {
        guard let name, !name.isEmpty else {
            ThemeManager.clearTheme()
            AppSettings.Instance.CurrentTheme = ""
            AppSettings.Instance.Save()
            selectedThemeIndex = 0
            return
        }
        guard let theme = ThemeManager.getThemeByName(name) else { return }
        ThemeManager.applyTheme(theme)
        AppSettings.Instance.CurrentTheme = theme.Name
        AppSettings.Instance.Save()
        selectedThemeIndex = themes.firstIndex { $0.Name == theme.Name }.map { $0 + 1 } ?? 0
    }

    // MARK: - 数值项

    /// 提交背景透明度：0-100，非法回退当前值（对应 C# `ApplyBgOpacity`）
    func applyOpacity() {
        let typed = Double(opacityText.trimmingCharacters(in: .whitespaces))
        guard let value = typed, value >= 0, value <= 100 else {
            opacityText = Self.intText(Seam.settings.BackgroundOpacity)
            return
        }
        if value != Seam.settings.BackgroundOpacity {
            Seam.settings.BackgroundOpacity = value
            Seam.settings.Save()
            ThemeManager.notifyAppearanceChanged()
        }
        opacityText = Self.intText(value)
    }

    /// 提交卡片字号：9-24，非法回退当前值（对应 C# `ApplyCardFontSize`）
    func applyCardFontSize() {
        let typed = Double(cardFontSizeText.trimmingCharacters(in: .whitespaces))
        guard let size = typed, size >= 9, size <= 24 else {
            cardFontSizeText = Self.intText(AppSettings.Instance.CardFontSize)
            return
        }
        if size != AppSettings.Instance.CardFontSize {
            AppSettings.Instance.CardFontSize = size
            AppSettings.Instance.Save()
            ThemeManager.notifyAppearanceChanged()
        }
        cardFontSizeText = Self.intText(size)
    }

    /// 隐藏卡片外框时同时隐藏标题。
    /// C# 侧这一项同样是「只存不用」（`AppSettings.HideModuleTitle` 除本页外没有任何读取者，
    /// `BuildHideFrameLayout` 一律不建标题栏），照搬保留：值会落盘，等卡片标题有隐藏分支时即刻生效。
    func setHideModuleTitle(_ value: Bool) {
        guard value != AppSettings.Instance.HideModuleTitle else {
            hideModuleTitle = value
            return
        }
        AppSettings.Instance.HideModuleTitle = value
        AppSettings.Instance.Save()
        ThemeManager.notifyAppearanceChanged()
        hideModuleTitle = value
    }

    // MARK: - 边框色

    /// 提交边框色：非法回退当前值（对应 C# `ApplyBorderColor`）。
    /// 校验口径比 C# 窄：C# 用 `BrushConverter`（还接受 "Red" 这类命名色），这里只认
    /// `#RGB` / `#RRGGBB` / `#AARRGGBB`——命名色是 WPF 特有的历史包袱，mac 侧不引入。
    func applyBorderColor(share: Bool, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard ThemeColor.parse(trimmed) != nil else {
            if share { shareColorText = AppSettings.Instance.ShareBorderColor }
            else { teamColorText = AppSettings.Instance.TeamBorderColor }
            return
        }
        let settings = AppSettings.Instance
        if share {
            settings.ShareBorderColor = trimmed
            shareColorText = trimmed
        } else {
            settings.TeamBorderColor = trimmed
            teamColorText = trimmed
        }
        settings.Save()
        ThemeManager.notifyAppearanceChanged()
    }
}

/// 外观页（对应 C# `Views/AppearanceSettingsPage.xaml`）。
/// C# 的 8 行里落地 7 行：「显示通知条」（`settings.showNotificationBar`）依赖通知条子系统，未移植。
struct AppearanceSettingsPage: View {

    @StateObject private var model = AppearanceSettingsModel()
    @FocusState private var focused: Field?

    /// 四个输入框的失焦提交（对应 C# 的 `*_LostFocus`）。
    private enum Field: Hashable { case opacity, cardFontSize, shareColor, teamColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(titleKey: "common.appearance")

            SettingsCard(spacing: 16) {
                SettingsRow(titleKey: "common.themeMode", hintKey: "settings.colorThemeHint") {
                    Picker(selection: Binding(
                        get: { model.themeModeIndex },
                        set: { model.selectThemeMode($0) }
                    ), label: EmptyView()) {
                        Text(Lang.t("common.dark")).tag(0)
                        Text(Lang.t("common.light")).tag(1)
                        Text(Lang.t("settings.followSystem")).tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                SettingsRow(titleKey: "settings.colorTheme", hintKey: "settings.customThemesNote") {
                    Picker(selection: Binding(
                        get: { model.selectedThemeIndex },
                        set: { model.selectTheme($0) }
                    ), label: EmptyView()) {
                        ForEach(Array(model.themeOptions.enumerated()), id: \.offset) { index, label in
                            Text(label).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                SettingsRow(titleKey: "common.backgroundOpacity", hintKey: "settings.panelOpacityHint") {
                    HStack(spacing: 6) {
                        numberField(text: $model.opacityText, field: .opacity, commit: model.applyOpacity)
                        unitLabel("%")
                    }
                }

                SettingsToggleRow(
                    titleKey: "settings.alsoHideTheModule",
                    hintKey: "settings.hideTitleWithFrameHint",
                    isOn: Binding(
                        get: { model.hideModuleTitle },
                        set: { model.setHideModuleTitle($0) }
                    )
                )

                borderRow(titleKey: "settings.sharedComponentBorderColor",
                          hintKey: "settings.shareImportColorHint",
                          text: $model.shareColorText,
                          field: .shareColor,
                          share: true)

                borderRow(titleKey: "settings.teamComponentBorderColor",
                          hintKey: "settings.teamOwnerColorHint",
                          text: $model.teamColorText,
                          field: .teamColor,
                          share: false)

                SettingsRow(titleKey: "settings.cardFontSize", hintKey: "settings.cardFontSizeHint") {
                    HStack(spacing: 6) {
                        numberField(text: $model.cardFontSizeText, field: .cardFontSize,
                                    commit: model.applyCardFontSize)
                        unitLabel("px")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(ThemeManager.palette.bg.color)
    }

    // MARK: - 行内控件

    /// 边框色行：预设色板（点击即应用）+ 手填 hex（对应 C# 的 `SwatchTemplate` + `*BorderHexBox`）
    private func borderRow(titleKey: String, hintKey: String, text: Binding<String>,
                           field: Field, share: Bool) -> some View {
        SettingsRow(titleKey: titleKey, hintKey: hintKey) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(AppearanceSettingsModel.borderColorPresets, id: \.self) { hex in
                        swatch(hex: hex, selected: hex == text.wrappedValue.trimmingCharacters(in: .whitespaces)) {
                            model.applyBorderColor(share: share, hex)
                        }
                    }
                }
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.center)
                    .focused($focused, equals: field)
                    .onSubmit { model.applyBorderColor(share: share, text.wrappedValue) }
                    .onChange(of: focused) { now in
                        if now != field { model.applyBorderColor(share: share, text.wrappedValue) }
                    }
            }
        }
    }

    /// 预设色块（对应 C# `Swatch` 样式：18 见方、圆角 Small、选中时用强调色描边 2px）
    private func swatch(hex: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        let radius = ThemeManager.radius(4)
        return Button(action: pick) {
            RoundedRectangle(cornerRadius: radius)
                .fill(ThemeColor.parse(hex)?.color ?? Color.clear)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(ThemeManager.palette.accent.color, lineWidth: selected ? 2 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    private func numberField(text: Binding<String>, field: Field, commit: @escaping () -> Void) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .multilineTextAlignment(.center)
            .focused($focused, equals: field)
            .onSubmit { commit() }
            // 失焦即提交（对应 C# LostFocus）：焦点走到别的框或清空时 now != field
            .onChange(of: focused) { now in
                if now != field { commit() }
            }
    }

    private func unitLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ThemeManager.fontSize(11)))
            .foregroundStyle(ThemeManager.palette.textMuted.color)
    }
}

#Preview {
    AppearanceSettingsPage()
        .frame(width: 500, height: 500)
}
