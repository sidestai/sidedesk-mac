import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 常规（对应 C# `GeneralSettingsPage` + `GeneralSettingsViewModel`）。
///
/// 已落地：每显示器的停靠位置、左右侧栏宽度与「开启浮动 / 浮动宽度」（悬停展开，均写 `Monitors[i]`，
/// 与 C# 同一存储位置）、界面语言。
/// 未落地（依赖 macOS 侧尚不存在的子系统，不给死控件）：
/// - 虚拟桌面独立配置（`EnablePerVirtualDesktop`）：Spaces 无稳定标识，C# 靠 COM 取 DesktopId；
/// - AI 对话模式、MCP 工具配置下载、软件渲染回退、AI 推荐浮层：对应子系统未移植。
@MainActor
final class GeneralSettingsModel: ObservableObject {

    /// 一台显示器一行（对应 C# `MonitorCardViewModel`）。
    /// `layoutIndex` 与 C# 下拉同序：0 无停靠 / 1 左侧 / 2 右侧 / 3 两侧。
    struct MonitorRow: Identifiable {
        let id: Int
        let label: String
        var layoutIndex: Int
        var leftWidthText: String
        var rightWidthText: String
        var leftHoverOn: Bool
        var rightHoverOn: Bool
        var leftHoverWidthText: String
        var rightHoverWidthText: String

        var leftVisible: Bool { layoutIndex == 1 || layoutIndex == 3 }
        var rightVisible: Bool { layoutIndex == 2 || layoutIndex == 3 }
    }

    @Published private(set) var monitors: [MonitorRow] = []
    @Published private(set) var languageIndex: Int = 0

    /// 下拉索引 → 停靠模式（C# `GeneralSettingsViewModel.cs:466` 的同一映射，顺序不可改：
    /// `LayoutMode` 以整数持久化，none 追加在末尾）。
    static let layoutByIndex: [LayoutMode] = [.none, .left, .right, .both]

    /// 语言选项（对应 C# `GeneralSettingsViewModel.cs:46-54`）：前两项走词典，
    /// 其余用本族语名（endonym 与 C# 同样是硬编码，不进词典）。
    static var languageOptions: [(label: String, tag: String)] {
        [(Lang.t("settings.followSystem"), Lang.auto),
         (Lang.t("settings.simplifiedChinese"), Lang.zhCN),
         ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko"),
         ("Deutsch", "de"), ("Español", "es"), ("Français", "fr"), ("Italiano", "it"),
         ("Polski", "pl"), ("Русский", "ru"), ("Português (Brasil)", "pt-BR"), ("Türkçe", "tr")]
    }

    /// 从设置与当前屏幕拓扑重建行（页首与显示器变化后调用）。
    func reload() {
        let settings = Seam.settings
        var rows: [MonitorRow] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            let monitor = settings.GetMonitor(index)
            let size = screen.frame.size
            rows.append(MonitorRow(
                id: index,
                label: Lang.tf("settings.monitorLabel",
                               index + 1,
                               screen == NSScreen.main ? Lang.t("window.mainSuffix") : "",
                               " · \(Int(size.width))×\(Int(size.height))"),
                layoutIndex: Self.layoutByIndex.firstIndex(of: monitor.Layout) ?? 0,
                leftWidthText: String(monitor.LeftPanelWidth),
                rightWidthText: String(monitor.RightPanelWidth),
                leftHoverOn: monitor.LeftHoverEnabled,
                rightHoverOn: monitor.RightHoverEnabled,
                leftHoverWidthText: String(monitor.LeftHoverWidth),
                rightHoverWidthText: String(monitor.RightHoverWidth)))
        }
        monitors = rows
        languageIndex = Self.languageOptions.firstIndex { $0.tag == settings.Language } ?? 0
    }

    // MARK: - 停靠

    /// 切换停靠位置（对应 C# `OnLayout`：写每屏配置 → 落盘 → 宿主重排）。
    func setLayout(_ index: Int, layoutIndex: Int) {
        guard monitors.indices.contains(index) else { return }
        monitors[index].layoutIndex = layoutIndex
        let monitor = Seam.settings.GetMonitor(monitors[index].id)
        monitor.Layout = Self.layoutByIndex[layoutIndex]
        saveAndRelayout()
    }

    /// 提交侧栏宽度（对应 C# `OnPanelWidth`：5-500，非法回退当前值）。
    func applyWidth(_ index: Int, left: Bool, text: String) {
        guard monitors.indices.contains(index) else { return }
        let monitor = Seam.settings.GetMonitor(monitors[index].id)
        let current = left ? monitor.LeftPanelWidth : monitor.RightPanelWidth
        guard let width = Int(text.trimmingCharacters(in: .whitespaces)),
              (5...500).contains(width) else {
            setWidthText(index, left: left, String(current))
            return
        }
        if left { monitor.LeftPanelWidth = width } else { monitor.RightPanelWidth = width }
        setWidthText(index, left: left, String(width))
        saveAndRelayout()
    }

    func setWidthText(_ index: Int, left: Bool, _ text: String) {
        guard monitors.indices.contains(index) else { return }
        if left { monitors[index].leftWidthText = text } else { monitors[index].rightWidthText = text }
    }

    /// 切换「开启浮动」（对应 C# `ApplyHoverEnabled`：写该侧开关 → 落盘 → 宿主热重载悬停计时器）。
    func setHoverEnabled(_ index: Int, left: Bool, enabled: Bool) {
        guard monitors.indices.contains(index) else { return }
        if left { monitors[index].leftHoverOn = enabled } else { monitors[index].rightHoverOn = enabled }
        let monitor = Seam.settings.GetMonitor(monitors[index].id)
        if left { monitor.LeftHoverEnabled = enabled } else { monitor.RightHoverEnabled = enabled }
        saveAndRelayout()
    }

    /// 提交浮动展开宽度（对应 C# `OnHoverWidth`：100-500，非法回退当前值）。
    func applyHoverWidth(_ index: Int, left: Bool, text: String) {
        guard monitors.indices.contains(index) else { return }
        let monitor = Seam.settings.GetMonitor(monitors[index].id)
        let current = left ? monitor.LeftHoverWidth : monitor.RightHoverWidth
        guard let width = Int(text.trimmingCharacters(in: .whitespaces)),
              (100...500).contains(width) else {
            setHoverWidthText(index, left: left, String(current))
            return
        }
        if left { monitor.LeftHoverWidth = width } else { monitor.RightHoverWidth = width }
        setHoverWidthText(index, left: left, String(width))
        saveAndRelayout()
    }

    func setHoverWidthText(_ index: Int, left: Bool, _ text: String) {
        guard monitors.indices.contains(index) else { return }
        if left { monitors[index].leftHoverWidthText = text } else { monitors[index].rightHoverWidthText = text }
    }

    /// 切换界面语言（对应 C# `LanguageIndex` setter：落盘 + 即时应用，词典变更由订阅方重绘）。
    func setLanguage(index: Int) {
        let options = Self.languageOptions
        guard options.indices.contains(index) else { return }
        languageIndex = index
        let tag = options[index].tag
        guard Seam.settings.Language != tag else { return }
        Seam.settings.Language = tag
        Seam.settings.Save()
        Lang.apply(tag)
    }

    private func saveAndRelayout() {
        Seam.settings.Save()
        SettingsLauncher.panelGeometryChanged()
    }
}

/// 常规页（对应 C# `GeneralSettingsPage.xaml`：页头 + 每显示器卡片 + 语言行）。
struct GeneralSettingsPage: View {

    @StateObject private var model = GeneralSettingsModel()
    @FocusState private var focused: WidthField?
    /// 上一个获得焦点的宽度框：焦点移走时提交它（对应 C# 的 LostFocus → ApplyWidthCommand）。
    @State private var lastFocused: WidthField?

    /// 宽度输入框的焦点标识（每屏左右各一个，失焦提交与 C# 的 `EventSetter` 同语义）。
    private enum WidthField: Hashable {
        case width(monitor: Int, left: Bool)
        case hoverWidth(monitor: Int, left: Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(titleKey: "settings.general")

            ForEach(model.monitors) { row in
                monitorCard(row)
            }

            languageCard

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(ThemeManager.palette.bg.color)
        .onAppear { model.reload() }
        .onChange(of: focused) { newValue in
            // 失焦提交：提交的是刚失去焦点的那个框，不是新获得焦点的
            switch lastFocused {
            case .width(let monitor, let left)?:
                model.applyWidth(monitor, left: left, text: widthText(monitor, left: left))
            case .hoverWidth(let monitor, let left)?:
                model.applyHoverWidth(monitor, left: left, text: hoverWidthText(monitor, left: left))
            case nil:
                break
            }
            lastFocused = newValue
        }
    }

    private func widthText(_ index: Int, left: Bool) -> String {
        guard model.monitors.indices.contains(index) else { return "" }
        return left ? model.monitors[index].leftWidthText : model.monitors[index].rightWidthText
    }

    private func hoverWidthText(_ index: Int, left: Bool) -> String {
        guard model.monitors.indices.contains(index) else { return "" }
        return left ? model.monitors[index].leftHoverWidthText : model.monitors[index].rightHoverWidthText
    }

    // MARK: - 每显示器卡片

    private func monitorCard(_ row: GeneralSettingsModel.MonitorRow) -> some View {
        SettingsCard {
            Text(row.label)
                .font(.system(size: ThemeManager.fontSize(13), weight: .bold))
                .foregroundStyle(ThemeManager.palette.textMain.color)

            SettingsRow(titleKey: "settings.dockPosition", hintKey: "settings.dockSideHint") {
                Picker(selection: Binding(
                    get: { row.layoutIndex },
                    set: { model.setLayout(index(of: row), layoutIndex: $0) }
                ), label: EmptyView()) {
                    Text(Lang.t("settings.noDocking")).tag(0)
                    Text(Lang.t("common.left")).tag(1)
                    Text(Lang.t("common.right")).tag(2)
                    Text(Lang.t("common.twoSides")).tag(3)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            // 左右子块按停靠模式显隐（对应 C# `LeftVisible` / `RightVisible`）。
            if row.leftVisible {
                sideBlock(titleKey: "settings.leftPanel", index: index(of: row), left: true,
                          text: row.leftWidthText, hoverOn: row.leftHoverOn,
                          hoverText: row.leftHoverWidthText)
            }
            if row.rightVisible {
                sideBlock(titleKey: "settings.rightPanel", index: index(of: row), left: false,
                          text: row.rightWidthText, hoverOn: row.rightHoverOn,
                          hoverText: row.rightHoverWidthText)
            }
        }
    }

    /// 一侧的宽度 + 浮动配置（对应 C# 一个侧栏块内三行：侧栏宽度 / 开启浮动 / 浮动宽度，
    /// 第三行仅在该侧开启浮动时出现）。
    private func sideBlock(titleKey: String, index: Int, left: Bool, text: String,
                           hoverOn: Bool, hoverText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Lang.t(titleKey))
                .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                .foregroundStyle(ThemeManager.palette.textMain.color)

            SettingsRow(titleKey: "settings.sidebarWidth", hintKey: "settings.sidebarDockWidthHint") {
                widthField(text: text, field: .width(monitor: index, left: left),
                           onInput: { model.setWidthText(index, left: left, $0) },
                           commit: { model.applyWidth(index, left: left, text: text) })
            }

            SettingsToggleRow(titleKey: "settings.enableFloating",
                              hintKey: "settings.enableFloatingHint",
                              isOn: Binding(get: { hoverOn },
                                            set: { model.setHoverEnabled(index, left: left, enabled: $0) }))

            if hoverOn {
                SettingsRow(titleKey: "settings.floatingWidth", hintKey: "settings.hoverExpandWidthHint") {
                    widthField(text: hoverText, field: .hoverWidth(monitor: index, left: left),
                               onInput: { model.setHoverWidthText(index, left: left, $0) },
                               commit: { model.applyHoverWidth(index, left: left, text: hoverText) })
                }
            }
        }
        .padding(.leading, 12)
    }

    /// 宽度输入框 + `px` 单位（对应 C# `TextBox Width=70 TextAlignment=Center` 与尾随的
    /// `TextBlock Text="px"`；失焦提交由 `onChange(of: focused)` 兜住，这里只管回车）。
    private func widthField(text: String, field: WidthField,
                            onInput: @escaping (String) -> Void,
                            commit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField("", text: Binding(get: { text }, set: { onInput($0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.center)
                .focused($focused, equals: field)
                .onSubmit(commit)
            Text("px")
                .font(.system(size: ThemeManager.fontSize(12)))
                .foregroundStyle(ThemeManager.palette.textMuted.color)
        }
    }

    // MARK: - 语言

    private var languageCard: some View {
        SettingsCard {
            SettingsRow(titleKey: "settings.interfaceLanguage", hintKey: "settings.languageSwitchHint") {
                Picker(selection: Binding(
                    get: { model.languageIndex },
                    set: { model.setLanguage(index: $0) }
                ), label: EmptyView()) {
                    ForEach(Array(GeneralSettingsModel.languageOptions.enumerated()), id: \.offset) { i, option in
                        Text(option.label).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private func index(of row: GeneralSettingsModel.MonitorRow) -> Int {
        model.monitors.firstIndex { $0.id == row.id } ?? 0
    }
}

#Preview {
    GeneralSettingsPage()
        .frame(width: 500, height: 500)
}
