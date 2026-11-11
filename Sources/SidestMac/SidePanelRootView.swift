import AppKit
import Combine
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 语言变更桥（对应 C# `{l:T}` 标记扩展内部对 `Lang.Changed` 的订阅）。
/// `Lang` 是全局枚举、不是可观察对象，SwiftUI 视图不会因它自动重绘；这里把事件转成
/// `objectWillChange`，视图持有它即可在切换语言后重新取词。
@MainActor
final class LangChangeObserver: ObservableObject {

    init() {
        Lang.subscribeChanged { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
}

/// 侧栏根视图（对应 C# `Views/MainWindow.xaml` 的宿主内容区）。
/// 已落地：标题栏（主标题 + 右上角更多菜单）与卡片流；卡片类型的全量渲染仍属 T5 后续切片。
struct SidePanelRootView: View {

    /// 「隐藏窗口」菜单项动作。mac 特有语义：macOS 没有 AppBar 预留区域，侧栏是可收起的浮层，
    /// 所以这里对应 C# `userWantsPanel` 的关闭态；C# 同位置的「关闭面板」是切到另一侧停靠
    /// （依赖每显示器 `LayoutMode`，Swift 侧尚未落地），语义不同。
    var onHide: () -> Void = {}

    /// 「最大化」按钮动作：把前台应用窗口铺满工作区、给侧栏留出宽度（宿主接到 `WindowManager`）。
    var onMaximize: () -> Void = {}

    /// 本面板停靠边（宿主传入），用于取该侧的侧栏宽度。
    var edge: PanelEdge = .left

    /// 渲染宽度源（宿主 `SidePanel` 持有）：收起=停靠宽，悬停展开=浮动宽。
    @ObservedObject var widthModel: PanelWidthModel

    /// 本面板的卡片流宿主（按停靠边取 bar，增删卡片由它落库）。
    @ObservedObject var cards: BarCardsModel

    @StateObject private var langChange = LangChangeObserver()
    @StateObject private var themeChange = ThemeChangeObserver()

    /// 标题栏悬停态：平时只显示微屏名（微屏 / sidest），鼠标移入标题栏才展开 1,2… 序号切换按钮。
    @State private var titleBarHovering = false

    /// 与 `SidePanel.liveWidth` 同源（经 `widthModel` 传进来）。根视图必须显式固定宽度：否则
    /// NSHostingView 会按内容理想宽度把 NSWindow 撑宽（曾出现设置 65、窗口实际 132，左侧多出一倍压在桌面/窗口上）。
    private var panelWidth: CGFloat { widthModel.width }

    var body: some View {
        let palette = ThemeManager.palette
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(palette.separator.color).frame(height: 1)
            content
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        // 底色 = 主题 ColorBG，alpha 取「设置 → 外观 → 背景透明度」（0-100）
        // （对应 C# `MainWindow.ApplyBackgroundForConfig` 的本地模式分支）。
        // 用实色而非 macOS 材质：BackgroundOpacity 的语义就是不透明度，材质会另叠一层模糊。
        // 高对比度下强制不透明（对应 C# `(HighContrast ? 100 : BackgroundOpacity)/100`）——半透明会削弱可读性。
        .background(palette.bg.color(
            alpha: (SystemPreferences.highContrast ? 100 : Seam.settings.BackgroundOpacity) / 100),
            in: panelShape)
        .overlay(panelShape.stroke(palette.border.color, lineWidth: 1))
        .clipShape(panelShape)
        // 面板级右键菜单（对应 C# `NativeModePanel` 的 `UserControl.ContextMenu`）：在侧栏空白处右键弹出。
        // 卡片自身另有 `.contextMenu`（见 CardShell），命中卡片时覆盖此面板级菜单，与 C# 一致。
        // C# 该菜单还含「编辑模式 / 工具 / 显示设置」三项，均依赖尚未移植的子系统（拖拽编辑、工具栏、
        // 多显示器设置），按「不出死控件」原则暂不搬，仅接已落地的「添加卡片」与「外观 → 全部隐藏卡片外框」。
        .contextMenu { panelContextMenu }
    }

    /// 面板级右键菜单内容。
    @ViewBuilder private var panelContextMenu: some View {
        AddCardMenu(model: cards)
        Divider()
        Menu(Lang.t("common.appearance")) {
            Toggle(Lang.t("common.hideAllModuleFrames"), isOn: Binding(
                get: { AppSettings.Instance.HideModuleFrame },
                set: { cards.setHideModuleFrame($0) }
            ))
        }
    }

    private var panelShape: some Shape {
        Rectangle()
    }

    // MARK: - 标题栏

    /// 标题栏（对应 C# 第 0 行、高 30 的 `titleBarGrid`）：主标题在左、更多按钮在右上角。
    /// 平时只显示微屏名（单/多虚拟屏幕都显示产品名，C# `singleWindowTitle`）；鼠标悬停标题栏且
    /// 存在多个虚拟屏幕时才展开 1,2… 序号切换按钮（对应 C# `windowTabsPanel` 的悬停展开，方向相反：
    /// C# 平时是序号徽标、悬停展开名称标签，此处按用户偏好平时名称、悬停序号）。
    /// C# 标题栏的「+」新建按钮不搬：窄面板（可设到 5px）里它会把右侧两个按钮挤出可视区，
    /// 而新建入口在 ⋯ 菜单的「新建微屏」里已有，属重复控件。
    /// 标题/标签条是唯一可伸缩项（`layoutPriority(-1)` + `minWidth: 0`），保证两个按钮任何宽度下都完整可见。
    private var titleBar: some View {
        let palette = ThemeManager.palette
        return HStack(spacing: 2) {
            if titleBarHovering, cards.tabs.count > 1 {
                tabBar
                    .frame(minWidth: 0)
                    .layoutPriority(-1)
            } else {
                Text(Lang.t("common.sideDeskScreen"))
                    .font(.system(size: ThemeManager.fontSize(12)))
                    .foregroundStyle(palette.textMain.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            maximizeButton
            moreButton
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(palette.inputBG.color)
        .onHover { titleBarHovering = $0 }
        .help(Lang.t("common.sideDeskScreen"))
    }

    /// 窗口标签条（对应 C# `windowTabsPanel`：横向排列的序号切换按钮，多到超宽可横向滚动）。
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(cards.tabs) { tab in
                    tabButton(tab)
                }
            }
        }
    }

    /// 单个窗口标签按钮（对应 C# `RefreshWindowTabs` 里的序号 `Button`）：数字 = 序号（Ctrl+数字 同序），
    /// 激活项反色底（底=`BrushTextMain`、字=`BrushBG`，与 C# 同一反色规范），tooltip = 窗口名。
    /// 右键菜单落地 C# 标签菜单里可移植的两项：改名 / 删除（登录、布局左右两侧、退出分别依赖未移植子系统）。
    private func tabButton(_ tab: BarCardsModel.WindowTab) -> some View {
        let palette = ThemeManager.palette
        let active = tab.index == cards.activeIndex
        let radius = ThemeManager.radius(4)
        return Button {
            cards.switchToTab(tab.index)
        } label: {
            Text("\(tab.index + 1)")
                .font(.system(size: ThemeManager.fontSize(11), weight: active ? .semibold : .regular))
                .foregroundStyle(active ? palette.bg.color : palette.textMain.color)
                .frame(minWidth: 16, minHeight: 18)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: radius)
                    .fill(active ? palette.textMain.color : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.name)
        .contextMenu {
            Button(Lang.t("common.rename")) { promptRename(id: tab.id, current: tab.name) }
            Button(Lang.t("nativePanel.deleteThisWindow"), role: .destructive) {
                cards.removeWindow(tab.id)
            }
            .disabled(cards.tabs.count <= 1)
        }
    }

    /// 改名输入框（对应 C# `EditWindowAtIndex` 弹出的编辑窗口的名称部分）：mac 用带输入框的 NSAlert。
    private func promptRename(id: String, current: String) {
        let alert = NSAlert()
        alert.messageText = Lang.t("window.editWindow")
        alert.addButton(withTitle: Lang.t("common.confirm"))
        alert.addButton(withTitle: Lang.t("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            cards.renameWindow(id, field.stringValue)
        }
    }

    /// 「最大化」按钮（更多按钮左侧）：把前台应用窗口铺满工作区、给侧栏留出宽度。
    /// 图标用双向展开箭头（SF Symbol），tooltip 走 `common.maximize`。
    private var maximizeButton: some View {
        Button {
            onMaximize()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: ThemeManager.fontSize(11), weight: .semibold))
                .foregroundStyle(ThemeManager.palette.textMain.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help(Lang.t("common.maximize"))
    }

    /// 更多按钮（对应 C# `moreButton`：「⋯」点开 `moreMenu`，tooltip `common.more`）。
    /// C# 菜单里「新建微屏 / 导入分享 / 添加模块 / 工具 / 屏幕管理 / 通知中心 / 关于 / 账户」中，
    /// 已接：「新建微屏」（多虚拟屏幕，单窗口时唯一的创建入口）、「添加模块」（`AddCardMenu`）；
    /// 其余分别依赖分享导入、通知中心与登录 UI（均未移植），此处只挂已接线的项。
    private var moreButton: some View {
        Menu {
            windowSwitchSection
            Button(Lang.t("settings.createScreen")) { cards.createWindow() }
            Divider()
            AddCardMenu(model: cards)
            Divider()
            // 对应 C# `common.screenManagement` → `OpenSettingsWindow("windows")`
            Button(Lang.t("common.screenManagement")) {
                Task { @MainActor in SettingsLauncher.show(page: .windows) }
            }
            Button(Lang.t("common.settings")) {
                Task { @MainActor in SettingsLauncher.show() }
            }
            Divider()
            Button(Lang.t("common.hiddenWindow")) { onHide() }
            Button(Lang.t("common.exit")) { NSApplication.shared.terminate(nil) }
        } label: {
            // 用 SF Symbol 而非文本「⋯」：文本字形宽度受字体度量影响，在 18px 窄按钮里会裁掉一个点。
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ThemeManager.palette.textMain.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(Lang.t("common.more"))
    }

    /// 菜单顶部的微屏窗口切换列表（对应 C# `MoreMenu_Opened` 在分隔线前动态插入的
    /// 「{序号}. {窗口名}」可勾选项：当前项打勾、点击 `SwitchToWindowByIndex`）。
    @ViewBuilder private var windowSwitchSection: some View {
        ForEach(cards.tabs) { tab in
            Button {
                cards.switchToTab(tab.index)
            } label: {
                if tab.index == cards.activeIndex {
                    Label("\(tab.index + 1). \(tab.name)", systemImage: "checkmark")
                } else {
                    Text("\(tab.index + 1). \(tab.name)")
                }
            }
        }
        Divider()
    }

    // MARK: - 内容区

    /// 内容区：有卡片走卡片流（对应 C# `RenderPanels`），空 bar 保留占位文案。
    @ViewBuilder private var content: some View {
        if cards.panels.isEmpty {
            emptyState
        } else {
            CardsListView(model: cards)
        }
    }

    /// 空态占位。文案取 C# 的「空窗口，暂无卡片」键（C# 该处另有「点击添加卡片」链接直开添加对话框，
    /// mac 侧入口统一在右上角 ⋯ 菜单里）。
    private var emptyState: some View {
        let palette = ThemeManager.palette
        return VStack(spacing: 12) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(palette.textMuted.color)
            Text(Lang.t("settings.emptyWindowNoComponents"))
                .font(.system(size: ThemeManager.fontSize(11)))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.textMuted.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

#Preview {
    SidePanelRootView(edge: .left, widthModel: PanelWidthModel(320),
                      cards: BarCardsModel(edge: .left, manager: nil))
        .frame(width: 320, height: 600)
}
