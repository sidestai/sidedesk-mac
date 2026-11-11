import SwiftUI
import SideDeskCore

/// 设置窗导航项（对应 C# `SettingsWindow.xaml:45-60` 的 16 项 ListBox）。
///
/// C# 16 项里只落地已接线的 8 项，其余不给空导航位（避免点进去一片空白）：
/// 团队/好友/云空间/我的数据/大模型/开发者依赖尚未移植的后端链路；
/// 程序管理依赖已安装程序枚举；插件依赖插件宿主。
/// 账户页已落地（登录/云同步/加密同步/备份恢复，见 `AccountSettingsPage`）；
/// 微屏窗口页已落地（本地窗口行：显隐/改名/删除；导入/分享/结构编辑器依赖未移植链路，见 `WindowsSettingsPage`）；
/// 关于页已落地（自动更新卡走 Sparkle，见 `AboutSettingsPage` 与 `UpdateService`）；
/// 快捷键页只落地「Ctrl+数字切换窗口」开关，语音输入快捷键依赖语音子系统（T6），见 `ShortcutsSettingsPage`。
/// C# 的顺序保持：常规 → 微屏窗口 → 账户 → 外观 → … → 工具 → 数据看板 → 快捷键 → 关于。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case windows
    case account
    case appearance
    case tools
    case dataDashboard
    case hotkeys
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general:       return "settings.general"
        case .windows:       return "common.screenWindow"
        case .account:       return "common.account"
        case .appearance:    return "common.appearance"
        case .tools:         return "common.tools"
        case .dataDashboard: return "common.dataDashboard"
        case .hotkeys:       return "common.hotkeys"
        case .about:         return "settings.about"
        }
    }
}

/// 设置窗根视图（对应 C# `SettingsWindow`：左 200 导航栏 + 右内容区，保存即生效、无确定/取消）。
/// 语言切换后整窗重绘：`Lang` 不是可观察对象，靠 `LangChangeObserver` 桥接（与侧栏根视图同法）。
struct SettingsRootView: View {

    @State private var page: SettingsPage
    /// 悬停的导航项（对应 C# `GlobalListBoxItemStyle` 的 `IsMouseOver` 触发器）
    @State private var hovered: SettingsPage?
    @StateObject private var langChange = LangChangeObserver()
    /// C# 的设置窗整窗吃 DynamicResource，主题一切全窗重绘；这里靠同一个观察者桥接。
    @StateObject private var themeChange = ThemeChangeObserver()

    init(initialPage: SettingsPage = .general) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        let palette = ThemeManager.palette
        HStack(spacing: 0) {
            navColumn
            // C# 是左栏 Border 的 `BorderThickness="0,0,1,0"` + `BrushBorder`
            Rectangle()
                .fill(palette.border.color)
                .frame(width: 1)
            ScrollView(.vertical, showsIndicators: true) {
                pageBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 窗口尺寸由宿主锁定（700×500）
        .background(palette.bg.color)                        // C# Window Background=BrushBG
    }

    // MARK: - 左栏

    /// 左栏（对应 C# 左侧 `Border`：BrushInputBG 底 + 右边框；顶部「设置」标题，下面是导航列表）。
    /// C# 标题右侧的团队切换下拉（`corpSelectorCombo`）依赖登录态，未移植。
    private var navColumn: some View {
        let palette = ThemeManager.palette
        return VStack(alignment: .leading, spacing: 0) {
            Text(Lang.t("common.settings"))
                .font(.system(size: ThemeManager.fontSize(20), weight: .bold))   // C# FontSizeTitle
                .foregroundStyle(palette.textMain.color)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 12))
            VStack(alignment: .leading, spacing: 4) {   // C# ListBoxItem Margin="0,2"
                ForEach(SettingsPage.allCases) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, 8)                    // C# ListBox Padding="8,0"
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .topLeading)
        .background(palette.inputBG.color)
    }

    /// 导航项（对应 C# `GlobalListBoxItemStyle`：Padding 16,10 + `CornerRadiusLarge`，
    /// 文字恒为 `BrushTextMain`，选中底色 `BrushListViewItemSelectedBG`、悬停 `BrushListViewItemMouseOver`）。
    private func navRow(_ item: SettingsPage) -> some View {
        let palette = ThemeManager.palette
        let selected = page == item
        let fill: Color = selected ? palette.listItemSelectedBG.color
            : (hovered == item ? palette.listItemMouseOver.color : Color.clear)
        return Button {
            page = item
        } label: {
            Text(Lang.t(item.titleKey))
                .font(.system(size: ThemeManager.fontSize(13)))
                .foregroundStyle(palette.textMain.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: ThemeManager.radius(8)).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? item : (hovered == item ? nil : hovered) }
    }

    // MARK: - 右栏

    /// 内容区（对应 C# 右侧 `ScrollViewer`：16 个页面全部预建、按 `Nav_Changed` 切 Visibility；
    /// SwiftUI 侧按需构造即可，状态由各页自己的 `@StateObject` 模型持有）。
    @ViewBuilder private var pageBody: some View {
        switch page {
        case .general:       GeneralSettingsPage()
        case .windows:       WindowsSettingsPage()
        case .account:       AccountSettingsPage()
        case .appearance:    AppearanceSettingsPage()
        case .tools:         ToolsSettingsPage()
        case .dataDashboard: DataDashboardSettingsView()
        case .hotkeys:       ShortcutsSettingsPage()
        case .about:         AboutSettingsPage()
        }
    }
}

#Preview {
    SettingsRootView()
        .frame(width: 700, height: 500)
}
