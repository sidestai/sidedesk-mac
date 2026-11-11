import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// ForEach 需要：`PanelItem.Id` 是持久化 GUID，直接用作 identity。
extension PanelItem: Identifiable {
    public var id: String { Id }
}

/// 行数据的 identity 同上：各卡片的行都用持久化 GUID。
extension StickyNote: Identifiable { public var id: String { Id } }
extension DeskNote: Identifiable { public var id: String { Id } }
extension TodoItem: Identifiable { public var id: String { Id } }
extension QuickItem: Identifiable { public var id: String { Id } }
extension SignalLightItem: Identifiable { public var id: String { Id } }
extension CheckInItem: Identifiable { public var id: String { Id } }
extension FileAreaItem: Identifiable { public var id: String { Id } }
extension ClipboardSavedItem: Identifiable { public var id: String { Id } }
extension DataDashboardItem: Identifiable { public var id: String { Id } }
extension TimerItem: Identifiable { public var id: String { Id } }
extension CountdownItem: Identifiable { public var id: String { Id } }

// MARK: - 标题

/// 卡片默认标题的词典键（对应 C# 各 `Build*Card` 传给 `WrapWidget` 的 `defaultTitle`；
/// 带 emoji 的 `nativePanel.*` 键沿用 C# 的写法，emoji 来自词典而非代码）。
private func defaultTitleKey(_ type: PanelType) -> String {
    switch type {
    case .QuickGroup:         return "common.shortcut"
    case .StickyNotes:        return "nativePanel.stickyNotes"
    case .Notes:              return "common.notes"
    case .TodoList:           return "common.todayTodos"
    case .Clipboard:          return "nativePanel.clipboardFavorites"
    case .SystemMonitor:      return "nativePanel.systemInfo"
    case .UsageStats:         return "nativePanel.usageStatistics"
    case .AIChat:             return "nativePanel.aiChat"
    case .FileArea:           return "nativePanel.fileArea"
    case .ClipboardHistory:   return "nativePanel.clipboardFavorites"
    case .DataDashboard:      return "nativePanel.dataDashboardAlt"
    case .Timer:              return "nativePanel.timer"
    case .Group:              return "common.group"
    case .SignalLight:        return "nativePanel.signalLight"
    case .DigitalEmployee:    return "nativePanel.digitalEmployees"
    case .Friend:             return "common.friends"
    case .ImageCarousel:      return "nativePanel.imageCarousel"
    case .DailyActivity:      return "common.dailyActivity"
    case .Calendar:           return "nativePanel.calendar"
    case .Plugin:             return "common.plugins"
    case .ScreenTime:         return "common.screenTime"
    case .Countdown:          return "nativePanel.countdown"
    case .Pomodoro:           return "nativePanel.pomodoro"
    case .WebBaidu:           return "nativePanel.baiduSearch"
    case .CheckIn:            return "common.checkIn"
    case .Dsh:                return "common.sideDeskScreen"
    case .ModuleUi:           return "nativePanel.moduleUi"
    }
}

/// 卡片显示标题（对应 C# `ModuleControl`：自定义 `Title` 非空优先，否则取类型默认标题）。
func cardTitle(_ panel: PanelItem) -> String {
    if let title = panel.Title, !title.isEmpty { return title }
    if panel.`Type` == .QuickGroup { return panel.QuickGroupName }
    return Lang.t(defaultTitleKey(panel.`Type`))
}

// MARK: - 小工具

/// 秒数 → `mm:ss` / `h:mm:ss`（计时器、倒计时、番茄共用）。
private func clockString(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds).rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// `#RGB` / `#RRGGBB` / `#AARRGGBB` → Color（信号灯/打卡配色与卡片自定义底色来自用户数据，
/// 解析失败回落调用方给的次级色）。对应 C# `ModuleControl.ApplyDashColor` 的 `BrushConverter`。
func hexColor(_ hex: String?) -> Color? {
    ThemeColor.parse(hex)?.color
}

/// 卡片内字号（对应 C# `NativeModePanel.FS`：设计基准 12，随「设置 → 外观 → 卡片内字体大小」缩放；
/// 卡片标题走 `FS(13)` 即自动大 1 号）。
///
/// 偏差记录：C# 现行卡片正文已改走 `UI/Yaml/Nodes` 的 `UiTokens.Font("tiny")` 阶梯（只随主题/v2 字号因子变，
/// 不随 CardFontSize 变）；Swift 侧的卡片渲染对应 pre-YAML 的 `NativeModePanel.Build*Widget` 那一代，
/// 那一代用 `FS()`。沿用 `FS()` 才能让「卡片内字体大小」这一设置真正生效。
func cardFont(_ designSize: Double, weight: Font.Weight = .regular) -> Font {
    .system(size: AppSettings.Instance.FS(designSize), weight: weight)
}

/// 行数据视图：单卡片内 0-n 行的通用渲染（文本类卡片与列表类卡片共用）。
private struct CardRow: Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
}

private struct CardRowsView: View {
    let rows: [CardRow]
    var body: some View {
        let palette = ThemeManager.palette
        if rows.isEmpty {
            CardEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(cardFont(10))
                            .foregroundStyle(palette.textMain.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(4)
                        if let detail = row.detail, !detail.isEmpty {
                            Text(detail)
                                .font(cardFont(9))
                                .foregroundStyle(palette.textSec.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct CardEmptyView: View {
    var body: some View {
        Text(Lang.t("common.noData"))
            .font(cardFont(10))
            .foregroundStyle(ThemeManager.palette.textMuted.color)
    }
}

// MARK: - 外框

/// 卡片菜单（对应 C# `ModuleControl.RebuildMenu` 的 `_moduleMenu`：右上角 ▾ 与整卡右键共用同一份）。
/// 各类型的「添加」自定义项（C# `WrapWidget` 的 `onAddClick`）已按类型接线：快捷组、便签、打卡、今日待办。
/// C# 首项「卡片设置」（`common.moduleSettings` → `ShowPanelSettingsDialog`）依赖每类型的设置面板，尚未移植；
/// 分享只读拦截（C# 的 `EditBlocked` 守卫）随登录/分享链路一起补。
private struct CardMenuItems: View {

    let panel: PanelItem
    let model: BarCardsModel

    var body: some View {
        // 快捷组卡片额外带「修改列数 / 显示方式」两组（对应 C# `QuickGroupPanelBuilder` 的 ⌄ 弹出菜单里
        // `colItem` + `displayItem`）。其余卡片只有下方通用三项。
        if panel.Type == .QuickGroup {
            quickGroupItems
            Divider()
        }
        if panel.Type == .StickyNotes {
            // 新建便签（对应 C# `WrapWidget` 的 `onAddClick: () => AddStickyNote`）：直接弹黄色便签供编辑。
            Button(Lang.t("common.add")) { model.addStickyNote(panel) }
            Divider()
        }
        if panel.Type == .TodoList {
            // 新增待办（对应 C# `BuildTodoCard` → `WrapWidget` 的 `onAddClick: () => ShowTodoDialog`）。
            Button(Lang.t("common.add")) { openAddTodo() }
            Divider()
        }
        if panel.Type == .Pomodoro {
            // 番茄钟设置（对应 C# `BuildPomodoroCard` 的 `settingsMi` → `ShowPomodoroSettingsDialog`）。
            Button(Lang.t("nativePanel.pomodoroSettings")) { openPomodoroSettings() }
            Divider()
        }
        if panel.Type == .CheckIn {
            // 添加打卡（对应 C# `BuildCheckInWidget` → `WrapWidget` 的 `onAddClick: () => ShowCheckInPickerDialog`）。
            Button(Lang.t("nativePanel.addCheckIn")) { openCheckInPicker() }
            checkInItems
            Divider()
        }
        if panel.Type == .Group {
            // 添加卡片到分组（对应 C# `BuildGroupWidget` 右键菜单的 `common.addModule` 子菜单 → `AddModuleToGroup`）。
            // 目录与顶层「添加卡片」同源（`AddableCardCatalog.categories`），点击即追加为本分组的子卡片。
            Menu(Lang.t("common.addModule")) {
                ForEach(AddableCardCatalog.categories()) { category in
                    Menu(Lang.t(category.titleKey)) {
                        ForEach(category.cards) { card in
                            Button(Lang.t(card.titleKey)) { model.addChildCard(panel, card) }
                        }
                    }
                }
            }
            Divider()
        }
        if panel.Type == .SignalLight {
            // 设置信号灯（对应 C# `BuildSignalLightWidget` → `WrapWidget` 的 `onAddClick: () => ShowSignalLightEditDialog`）：
            // 管理弹窗内可增删灯、编辑单灯（颜色/大小/图标）、调方向/样式/间距/对齐。
            Button(Lang.t("nativePanel.setSignalLight")) { openSignalLightSettings() }
            Divider()
        }
        Toggle(isOn: Binding(
            get: { panel.HideFrame },
            set: { model.setHideFrame(panel, $0) }
        )) {
            Text(Lang.t("common.hideModuleFrame"))
        }
        Toggle(isOn: Binding(
            get: { panel.IsPinned },
            set: { model.setPinned(panel, $0) }
        )) {
            Text(Lang.t("nativePanel.pinOnTop"))
        }
        Button(Lang.t("nativePanel.deleteModule"), role: .destructive) {
            model.remove(panel)
        }
    }

    /// 快捷组专属：添加（程序/网址）+ 修改列数（1-4）+ 显示方式（大图标 / 列表 / 弹出菜单）。
    /// 顺序对应 C# `QuickGroupPanelBuilder` 的 ⌄ 弹出菜单：`addSubMenu` 在最前，其后 `colItem` + `displayItem`。
    @ViewBuilder private var quickGroupItems: some View {
        Menu(Lang.t("common.add")) {
            Button(Lang.t("settings.addProgram")) { openAddItem("program") }
            Button(Lang.t("settings.addUrl")) { openAddItem("url") }
        }
        Menu(Lang.t("nativePanel.changeColumnCount")) {
            ForEach(1...4, id: \.self) { col in
                Toggle(Lang.tf("nativePanel.columnCountValue", col), isOn: Binding(
                    get: { panel.QuickColumns == col },
                    set: { if $0 { model.setQuickColumns(panel, col) } }
                ))
            }
        }
        Menu(Lang.t("common.show")) {
            displayModeToggle("grid", "nativePanel.largeIcons")
            displayModeToggle("list", "common.list")
            displayModeToggle("popup", "common.popupMenu")
        }
    }

    /// 弹出「添加快捷项」对话框，保存后追加到本组（对应 C# `host.ShowAddItemDialog`）。
    private func openAddItem(_ presetType: String) {
        AddQuickItemDialog.present(presetType: presetType) { item in
            model.addQuickItem(panel, item)
        }
    }

    /// 弹出「添加待办」对话框，保存后追加到本卡片（对应 C# `ShowTodoDialog`）。
    private func openAddTodo() {
        AddTodoDialog.present { item in
            model.addTodo(panel, item)
        }
    }

    /// 弹出「番茄钟设置」对话框，确定即写回本卡片配置（对应 C# `ShowPomodoroSettingsDialog`）。
    private func openPomodoroSettings() {
        guard let settings = panel.Pomodoro else { return }
        PomodoroSettingsDialog.present(settings: settings) { work, shortBreak, longBreak, interval, autoStartNext in
            model.applyPomodoroSettings(panel, work: work, shortBreak: shortBreak,
                                        longBreak: longBreak, interval: interval, autoStartNext: autoStartNext)
        }
    }

    /// 弹出「添加打卡」管理弹窗（对应 C# `ShowCheckInPickerDialog`）：预设一键添加 + 自定义 + 现有项编辑/删除。
    private func openCheckInPicker() {
        CheckInPickerDialog.present(panel: panel, model: model)
    }

    /// 弹出「设置信号灯」管理弹窗（对应 C# `ShowSignalLightEditDialog`）：增删灯 + 单灯详情 + 布局。
    private func openSignalLightSettings() {
        SignalLightSettingsDialog.present(panel: panel, model: model)
    }

    private func displayModeToggle(_ mode: String, _ key: String) -> some View {
        Toggle(Lang.t(key), isOn: Binding(
            get: { panel.QuickDisplayMode == mode },
            set: { if $0 { model.setQuickDisplayMode(panel, mode) } }
        ))
    }

    /// 打卡专属：列数（1-4）+ 样式（4 种），均勾选当前值。
    /// 对应 C# `BuildCheckInWidget` 里 `mc.AddCustomMenuItem` 挂的「列数」「样式」两个子菜单。
    @ViewBuilder private var checkInItems: some View {
        Menu(Lang.t("common.columnCount")) {
            ForEach(1...4, id: \.self) { col in
                Toggle(Lang.tf("nativePanel.columnCountValue", col), isOn: Binding(
                    get: { panel.CheckInColumns == col },
                    set: { if $0 { model.setCheckInColumns(panel, col) } }
                ))
            }
        }
        Menu(Lang.t("common.style")) {
            styleToggle("TextOnly", "nativePanel.checkInStyleTextOnly")
            styleToggle("IconOnly", "nativePanel.checkInStyleIconOnly")
            styleToggle("IconTextVertical", "nativePanel.checkInStyleIconTextVertical")
            styleToggle("IconTextHorizontal", "nativePanel.checkInStyleIconTextHorizontal")
        }
    }

    private func styleToggle(_ value: String, _ key: String) -> some View {
        Toggle(Lang.t(key), isOn: Binding(
            get: { checkInStyle == value },
            set: { if $0 { model.setCheckInStyle(panel, value) } }
        ))
    }

    /// 与 C# 同口径：空串视为 IconTextVertical。
    private var checkInStyle: String {
        panel.CheckInStyle.isEmpty ? "IconTextVertical" : panel.CheckInStyle
    }
}

/// 卡片标题显示文本（对应 C# `ModuleControl.Api.GetDisplayTitle`：置顶卡片带 ⌖ 前缀。
/// ⌖ 是文本字形而非彩色 emoji，与 C# 同一口径，故不进词典）。
private func cardDisplayTitle(_ panel: PanelItem) -> String {
    let title = cardTitle(panel)
    return panel.IsPinned ? "⌖ \(title)" : title
}

/// 卡片外框（对应 C# `WrapWidget` + `ModuleControl`：统一标题条、外框、▾ 菜单与右键菜单）。
/// 隐藏外框走 C# `BuildHideFrameLayout` 的口径：无标题条、无边框、无内边距，只留内容和右键菜单
/// （标题条没了，▾ 也就没了，恢复只能靠右键——与 C# 同）。
private struct CardShell<Content: View>: View {

    let panel: PanelItem
    let model: BarCardsModel
    @ViewBuilder var content: () -> Content

    /// 对应 C# `(Item.HideFrame || AppSettings.Instance.HideModuleFrame) && !IsEditMode`
    /// （编辑模式未移植，故无 `!IsEditMode` 分支）。
    private var hideFrame: Bool { panel.HideFrame || AppSettings.Instance.HideModuleFrame }

    /// 卡片底色（对应 C# `ApplyDashColor(BGColorOverride ?? Item.BGColor, "BrushInputBG")`：
    /// 卡片自定义底色优先，非法/缺省回落主题的 InputBG）。
    private var cardBackground: Color {
        hexColor(panel.BGColor) ?? ThemeManager.palette.inputBG.color
    }

    /// 分享/团队标识边框（对应 C# `ModuleControl.ResolveSpecialBorder`）：分享导入优先于团队归属，
    /// 标识色非法时回落 BrushBorder；两者都命中不了就是默认边框、1px。
    private var frameBorder: (color: Color, width: CGFloat) {
        let palette = ThemeManager.palette
        let settings = AppSettings.Instance
        if let shareId = panel.ShareId, !shareId.isEmpty {
            return (hexColor(settings.ShareBorderColor) ?? palette.border.color, 1.5)
        }
        if panel.OwnerType == "team" {
            return (hexColor(settings.TeamBorderColor) ?? palette.border.color, 1.5)
        }
        return (palette.border.color, 1)
    }

    var body: some View {
        // 间距 3 = C# `_header` 的 Margin(0,0,0,3)；内边距 3 = `_rootBorder` 的 Padding(3)；
        // 圆角走 `ThemeTokens.Radius(6)`（v2 主题下随 layout.cornerRadius 变）。
        let border = frameBorder
        let cornerRadius = ThemeManager.radius(6)
        return VStack(alignment: .leading, spacing: 3) {
            if !hideFrame { titleBar }
            content()
        }
        .padding(hideFrame ? 0 : 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .topLeading) {
            // 隐藏外框走 C# `BuildHideFrameLayout`：底色照留，只是 BorderThickness = 0
            if !hideFrame {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border.color, lineWidth: border.width)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { CardMenuItems(panel: panel, model: model) }
    }

    /// 标题条：标题占满整行、▾ 叠在右上角（overlay 不参与布局分配）。
    /// 窄面板下若让 ▾ 与标题同处 HStack 分宽度，标题会被压到只剩一个「…」；
    /// 叠放后标题至少保住「一个字 + …」的可读宽度。
    private var titleBar: some View {
        let palette = ThemeManager.palette
        return Text(cardDisplayTitle(panel))
            .font(cardFont(13))
            .foregroundStyle(palette.textMain.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) { menuButton }
    }

    /// ▾（U+25BE，与 C# `_menuBtn.Content` 同字形）：点开卡片菜单。
    /// 前景 BrushTextMuted 对应 C# `_menuBtn`。尺寸做成 14 见方的小正方形：`Menu` 默认 bezel
    /// 会在标签外再包一圈内边距（实测把 16×14 的标签撑成明显偏大的圆角块），故改用无边框菜单样式、
    /// 自绘淡底小方块，视觉与标题字号相称。
    private var menuButton: some View {
        let palette = ThemeManager.palette
        let side: CGFloat = 14
        return Menu {
            CardMenuItems(panel: panel, model: model)
        } label: {
            Text("▾")
                .font(.system(size: ThemeManager.fontSize(10)))
                .foregroundStyle(palette.textMuted.color)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: ThemeManager.radius(4))
                    .fill(palette.listItemMouseOver.color))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: side, height: side)
    }
}

// MARK: - 单卡分发

/// 按类型渲染卡片内容。对应 C# `NativeModePanel.CreatePanelWidget` 的 `switch item.Type`：
/// 已移植的类型出真实内容，其余出「暂无数据」占位（与 C# 未识别类型返回 null 后显示空态同义）。
struct CardView: View {

    let panel: PanelItem
    let model: BarCardsModel

    var body: some View {
        Group {
            if panel.SkipWrapper {
                // C# 的 SkipWrapper：计时/倒计时/番茄在分组内不带外层框
                CardBody(panel: panel, model: model)
            } else {
                CardShell(panel: panel, model: model) {
                    CardBody(panel: panel, model: model)
                }
                .frame(height: panel.PanelHeight.map { CGFloat($0) })   // nil = 自适应高度（C# PanelHeight 语义）
            }
        }
    }
}

private struct CardBody: View {

    let panel: PanelItem
    let model: BarCardsModel

    var body: some View {
        switch panel.`Type` {
        case .Group:            groupBody
        case .TodoList:         todoBody
        case .QuickGroup:       quickBody
        case .StickyNotes:      stickyBody
        case .SignalLight:      signalBody
        case .CheckIn:          checkInBody
        case .Pomodoro:         pomodoroBody
        default:                otherBody
        }
    }

    /// 其余类型：文本类（便签/记事/剪贴板）与行类（计时器/倒计时/文件区/数据看板）走通用渲染，
    /// 依赖未移植子系统（网页、日历、图片轮播、监控、AI、插件…）的类型先出占位。
    @ViewBuilder private var otherBody: some View {
        switch panel.`Type` {
        case .Notes:
            CardRowsView(rows: (panel.DeskNotes ?? []).map { CardRow(title: $0.Content) })
        case .Clipboard:
            CardRowsView(rows: (panel.ClipboardItems ?? []).map { CardRow(title: $0.Content) })
        case .Timer:
            CardRowsView(rows: (panel.TimerItems ?? []).map {
                CardRow(title: $0.Name, detail: clockString($0.GetElapsed()))
            })
        case .Countdown:
            CardRowsView(rows: (panel.CountdownItems ?? []).map {
                CardRow(title: $0.Name, detail: clockString($0.GetRemaining()))
            })
        case .FileArea:
            CardRowsView(rows: (panel.FileItems ?? []).map {
                CardRow(title: ($0.Alias?.isEmpty == false ? $0.Alias! : $0.Name))
            })
        case .DataDashboard:
            CardRowsView(rows: (panel.DashboardItems ?? []).map {
                CardRow(title: $0.Label, detail: $0.Value)
            })
        default:
            CardEmptyView()
        }
    }

    /// 分组：标题下递归渲染子卡片（对应 C# `BuildGroupWidget` 的 groupMode）。
    /// 置顶子卡片不在分组内渲染：C# `BuildGroupWidget` 会 `continue` 跳过，改由渲染层提到置顶区。
    @ViewBuilder private var groupBody: some View {
        let all = panel.ChildPanels ?? []
        let children = all.filter { !$0.IsPinned }
        if all.isEmpty {
            CardEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(children) { child in
                    CardView(panel: child, model: model)
                }
            }
        }
    }

    /// 今日待办：点击行切换完成态（对应 C# 待办行的勾选）；空列表显示可点击的「点击添加」提示。
    @ViewBuilder private var todoBody: some View {
        let items = panel.TodoItems ?? []
        let palette = ThemeManager.palette
        if items.isEmpty {
            // 对应 C# `BuildEmptyAddTip`：点击直接弹出添加待办对话框。
            Button {
                AddTodoDialog.present { item in model.addTodo(panel, item) }
            } label: {
                Text(Lang.t("nativePanel.noTodosClickTo"))
                    .font(cardFont(12))
                    .foregroundStyle(palette.textMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { todo in
                    Button {
                        model.toggleTodo(todo)
                    } label: {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: todo.IsDone ? "checkmark.square.fill" : "square")
                                .font(cardFont(12))
                                .foregroundStyle(todo.IsDone ? palette.accent.color : palette.textMuted.color)
                            // 完成态：删除线 + text.muted（对应 C# TodoBoardNode 的 TextDecorations / SetBrush）
                            Text(todo.Text)
                                .font(cardFont(12))
                                .strikethrough(todo.IsDone)
                                .foregroundStyle(todo.IsDone ? palette.textMuted.color : palette.textMain.color)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 快捷方式：按 `QuickDisplayMode` 渲染（对应 C# `BuildQuickGroupWidget`）——
    /// grid = `QuickColumns` 列大图标；list = 单列紧凑行；popup = 折叠成一个弹出菜单。
    @ViewBuilder private var quickBody: some View {
        let items = panel.QuickItems ?? []
        if items.isEmpty {
            CardEmptyView()
        } else {
            Group {
            switch panel.QuickDisplayMode {
            case "list":
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in quickItemButton(item, listMode: true) }
                }
            case "popup":
                // 弹出菜单：整组折叠为一个下拉按钮，展开列出全部快捷项（对应 C# isPopup 的 itemPopup，
                // 其内容按 listMode 构建）。点击项即执行，与网格项一致。
                Menu {
                    ForEach(items) { item in
                        Button(item.Name) { model.perform(item) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2").font(cardFont(11))
                        Text(panel.QuickGroupName)
                            .font(cardFont(11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ThemeManager.palette.textMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            default: // grid
                let columns = max(1, panel.QuickColumns)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns),
                          spacing: 3) {
                    ForEach(items) { item in quickItemButton(item, listMode: false) }
                }
            }
            }
            .onAppear { model.scheduleQuickIconHeal(panel) }
        }
    }

    /// 单个快捷项按钮。listMode：图标+名称横排左对齐（C# `BuildItemButton(listMode: true)`）；
    /// 否则图标在上、名称在下的大图标格子（C# `largeIcon: !isList`）。
    private func quickItemButton(_ item: QuickItem, listMode: Bool) -> some View {
        // 按钮底色（对应 C# `BuildItemButton` 的 `BackgroundColor`）：nil/空 = 透明。
        // 有色时文字转白（onDark 口径）并加内边距，透明时保持原有零内边距布局不变。
        let bg = hexColor(item.BackgroundColor)
        let textColor = bg != nil ? Color.white : ThemeManager.palette.textMain.color
        return Button {
            model.perform(item)
        } label: {
            Group {
                if listMode {
                    HStack(spacing: 5) {
                        quickIcon(item)
                        Text(item.Name)
                            .font(cardFont(11))
                            .lineLimit(1)
                            .foregroundStyle(textColor)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 2) {
                        quickIcon(item)
                        Text(item.Name)
                            .font(cardFont(10))
                            .lineLimit(1)
                            .foregroundStyle(textColor)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, bg != nil ? 5 : 0)
            .padding(.vertical, bg != nil ? 3 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if let bg {
                RoundedRectangle(cornerRadius: ThemeManager.radius(4)).fill(bg)
            }
        }
    }

    /// 快捷项图标：本机图片文件（缓存的 favicon）用 `NSImage(contentsOfFile:)` 直接解码其内容；
    /// 程序/应用路径用 `NSWorkspace.icon(forFile:)` 提取关联图标（对应 C# `BuildIconPreview`）；
    /// 否则 emoji 字符优先，最后 SF Symbol 占位。
    @ViewBuilder private func quickIcon(_ item: QuickItem) -> some View {
        let iconPath = (item.Icon?.isEmpty == false && FileManager.default.fileExists(atPath: item.Icon!))
            ? item.Icon!
            : (item.`Type` == "program" && FileManager.default.fileExists(atPath: item.Target) ? item.Target : nil)
        if let path = iconPath, Self.isImageFile(path), let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else if let path = iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 16, height: 16)
        } else if item.Icon?.isEmpty == false {
            Text(item.Icon!).font(cardFont(12))
        } else {
            Image(systemName: "link").font(cardFont(11))
        }
    }

    /// 后缀判定为可解码图片文件（缓存的 favicon 落盘格式）。
    private static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp", "ico", "tiff"].contains(ext)
    }

    /// 便签：每行点整行 = 切换黄色桌面便签悬浮窗显隐（对应 C# `WireStickyRow` + `ToggleStickyWindow`）；
    /// 空态点击 = 新建；行右键 = 删除。重绘时恢复仍钉选且未关的便签（`BuildStickyNotesCard` 末尾同点）。
    /// 钉选行的 accent 高亮与焦点选中圈（#480/#490 依赖 StickyDesktopService 事件）本轮未接。
    @ViewBuilder private var stickyBody: some View {
        let notes = panel.StickyNotes ?? []
        Group {
            if notes.isEmpty {
                Button {
                    model.addStickyNote(panel)
                } label: {
                    Text(Lang.t("nativePanel.noStickyNotesClick"))
                        .font(cardFont(10))
                        .foregroundStyle(ThemeManager.palette.textMuted.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notes) { note in stickyRow(note) }
                }
            }
        }
        .onAppear { model.restorePinnedStickyNotes(panel) }
    }

    /// 单行便签：预览文本按钮（点击切换黄色便签窗）+ 右键删除菜单。
    private func stickyRow(_ note: StickyNote) -> some View {
        Button {
            model.toggleStickyWindow(note)
        } label: {
            Text(note.Preview)
                .font(cardFont(11))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(ThemeManager.palette.textMain.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Lang.t("common.delete"), role: .destructive) { model.removeStickyNote(panel, note) }
        }
    }

    /// 信号灯：看板运行时（三态条件状态机 + 闪烁/监控定时器 + 辉光/压暗视觉）见 `SignalLightBoardView`，
    /// 对应 C# `BuildSignalLightWidget` + `SignalLightBoardNode`。此处只做分发。
    @ViewBuilder private var signalBody: some View {
        SignalLightBoardView(panel: panel, model: model)
    }

    /// 打卡：点击计数（当日次数走 `CheckInItem.TodayCount`，跨天自动归零）。
    /// 按钮内排布按 `CheckInStyle` 四选一（对应 C# `CheckInBoardNode` 的 4 种样式），
    /// 计数行在所有样式下都保留（C# 的计数徽标也是全样式常显）。
    @ViewBuilder private var checkInBody: some View {
        let items = panel.CheckInItems ?? []
        if items.isEmpty {
            // 对应 C# `BuildEmptyAddTip`：点击直接弹出打卡管理弹窗。
            Button {
                CheckInPickerDialog.present(panel: panel, model: model)
            } label: {
                Text(Lang.t("nativePanel.addCheckIn"))
                    .font(cardFont(12))
                    .foregroundStyle(ThemeManager.palette.textMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            let columns = max(1, panel.CheckInColumns)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns),
                      spacing: 3) {
                ForEach(items) { item in
                    Button {
                        model.checkIn(item)
                    } label: {
                        checkInLabel(item)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func checkInLabel(_ item: CheckInItem) -> some View {
        let palette = ThemeManager.palette
        let count = Text("\(item.TodayCount())")
            .font(cardFont(10, weight: .medium))
            .foregroundStyle(hexColor(item.Color) ?? palette.textMuted.color)
        let text = Text(item.Text)
            .font(cardFont(10))
            .lineLimit(1)
            .foregroundStyle(palette.textMain.color)
        switch checkInStyle {
        case "TextOnly":
            VStack(spacing: 1) { text; count }
        case "IconOnly":
            VStack(spacing: 1) { checkInIcon(item); count }
        case "IconTextHorizontal":
            VStack(spacing: 1) {
                HStack(spacing: 2) { checkInIcon(item); text }
                count
            }
        default:
            VStack(spacing: 1) { checkInIcon(item); text; count }
        }
    }

    private func checkInIcon(_ item: CheckInItem) -> some View {
        Group {
            if item.Icon.isEmpty {
                Image(systemName: "checkmark").font(cardFont(11))
            } else {
                Text(item.Icon).font(cardFont(12))
            }
        }
    }

    /// 与 C# 同口径：空串视为 IconTextVertical。
    private var checkInStyle: String {
        panel.CheckInStyle.isEmpty ? "IconTextVertical" : panel.CheckInStyle
    }

    /// 番茄闹钟：品牌红圆角底 → 居中竖排 [模式 ▾ 菜单, 白环 mm:ss 表盘, 开始/暂停按钮, 状态行]。
    /// 对应 C# `resources/ui/cards/pomodoro.yaml`（`PomodoroSource` 供文案、`PomodoroTimerNode` 供表盘）。
    /// 计时引擎在宿主 `BarCardsModel`（每秒 tick 推进阶段），表盘走 `TimelineView` 每秒重绘，不经修订号——
    /// 否则整栏卡片会每秒重建。
    @ViewBuilder private var pomodoroBody: some View {
        if let pomo = panel.Pomodoro {
            let onDark = Color.white
            VStack(spacing: 4) {
                Menu {
                    Button(Lang.t("common.pomodoro")) { model.setPomodoroMode(panel, "Work") }
                    Button(Lang.t("common.shortBreak")) { model.setPomodoroMode(panel, "ShortBreak") }
                    Button(Lang.t("common.longBreak")) { model.setPomodoroMode(panel, "LongBreak") }
                    Divider()
                    Button(Lang.t("common.reset")) { model.resetPomodoro(panel) }
                } label: {
                    Text(pomodoroModeLabel(pomo.Mode) + " ▾")
                        .font(cardFont(12, weight: .medium))
                        .foregroundStyle(onDark)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)

                PomodoroDial(remaining: { pomo.GetRemaining() }, onDark: onDark)

                Button {
                    model.togglePomodoro(panel)
                } label: {
                    Text(Lang.t(pomo.IsRunning ? "common.pause" : "common.start"))
                        .font(cardFont(12))
                        .foregroundStyle(onDark)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(onDark.opacity(0.6), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(pomodoroStatus(pomo))
                    .font(cardFont(10))
                    .foregroundStyle(onDark)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            // 品牌红 #E8564F（Themes/Styles.xaml `BrushPomodoro`）；解析失败回落同色常量。
            .background(hexColor("#E8564F") ?? Color(red: 232/255, green: 86/255, blue: 79/255))
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.radius(6)))
        } else {
            CardEmptyView()
        }
    }

    /// 模式存储值 → 展示词（对应 C# `PomodoroSource.ModeLabel`）。
    private func pomodoroModeLabel(_ mode: String) -> String {
        switch mode {
        case "ShortBreak": return Lang.t("common.shortBreak")
        case "LongBreak":  return Lang.t("common.longBreak")
        default:           return Lang.t("common.pomodoro")
        }
    }

    /// 状态行（对应 C# `PomodoroSource.statusText` 非降级分支）：运行中「× n | 模式词」，否则「× n」。
    private func pomodoroStatus(_ p: PomodoroSettings) -> String {
        guard p.IsRunning else { return "× \(p.CompletedCount)" }
        let modeText: String
        switch p.Mode {
        case "ShortBreak": modeText = Lang.t("nativePanel.onShortBreak")
        case "LongBreak":  modeText = Lang.t("nativePanel.onLongBreak")
        default:           modeText = Lang.t("nativePanel.focusing")
        }
        return "× \(p.CompletedCount)  |  \(modeText)"
    }
}

/// 番茄表盘：白色圆环 + 居中 `mm:ss`（对应 C# `PomodoroTimerNode`：100x100 Viewbox，环 StrokeThickness=3，
/// 数字 Consolas Bold ~20）。`TimelineView(.periodic)` 每秒刷新，用 `.rounded(.up)`（C# 走 `Math.Ceiling`，
/// 而 `clockString` 默认四舍五入，故这里先向上取整）。
private struct PomodoroDial: View {
    let remaining: () -> TimeInterval
    let onDark: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ZStack {
                Circle()
                    .stroke(onDark, lineWidth: 3)
                Text(clockString(remaining().rounded(.up)))
                    .font(.system(size: AppSettings.Instance.FS(20), weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(onDark)
            }
            // 窄侧栏（如 65）下表盘要跟着压缩：固定 100 会溢出窗口、内容被裁成居中切片。
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 100, maxHeight: 100)
            .padding(2)
        }
    }
}

// MARK: - 卡片流

/// 侧栏内容区的卡片流（对应 C# `RenderPanels`：按 bar 的面板树逐个建 widget）。
/// 布局对应 C# 的 `DockPanel`：置顶区固定在滚动区上方（`pinnedArea`，压缩下方可用高度），
/// 其余卡片在 `ScrollView` 里滚动；无置顶项时置顶区整块隐藏。
struct CardsListView: View {

    @ObservedObject var model: BarCardsModel

    var body: some View {
        let parts = CardsListView.partition(model.panels)
        // 每张卡片挂 `.id("\(panel.Id)#\(model.revision)")`：PanelItem 是引用类型，就地改字段（勾选待办、
        // 打卡、隐藏外框、快捷组列数/布局…）后实例引用不变，SwiftUI 会跳过 CardView 重绘；把修订号并进
        // 身份号，号一变即整卡重建，变更才能落屏（详见 BarCardsModel.revision）。
        // 间距 6 / 内边距 5：对应 C# 每张卡片 `_rootBorder` 的 Margin(0,0,0,6) 与主题 layout.sidebarPadding
        VStack(spacing: 0) {
            if !parts.pinned.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parts.pinned) { panel in
                        CardView(panel: panel, model: model)
                            .id("\(panel.Id)#\(model.revision)")
                    }
                }
                .padding(5)
                Rectangle().fill(ThemeManager.palette.separator.color).frame(height: 1)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(parts.normal) { panel in
                        CardView(panel: panel, model: model)
                            .id("\(panel.Id)#\(model.revision)")
                    }
                }
                .padding(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// 置顶区/滚动区拆分（对应 C# `RenderPanels` 的 foreach）：按面板顺序，非置顶分组里被置顶的
    /// 子卡片先提到置顶区，再放本层卡片（顶层置顶 → 置顶区，其余 → 滚动区）。
    /// C# 中「分组自身被置顶」时不会提取其置顶子卡片（分组整体进置顶区，`BuildGroupWidget` 仍跳过
    /// 置顶子卡片），这类子卡片在两侧都不显示——按「照搬不修」保留。
    static func partition(_ panels: [PanelItem]) -> (pinned: [PanelItem], normal: [PanelItem]) {
        var pinned: [PanelItem] = []
        var normal: [PanelItem] = []
        for panel in panels {
            if panel.`Type` == .Group, !panel.IsPinned, let children = panel.ChildPanels {
                pinned.append(contentsOf: children.filter { $0.IsPinned })
            }
            if panel.IsPinned {
                pinned.append(panel)
            } else {
                normal.append(panel)
            }
        }
        return (pinned, normal)
    }
}

/// 「添加卡片」子菜单（对应 C# `PopulateAddModuleMenu` 从 `BuildAddableCards` 派生子菜单）。
struct AddCardMenu: View {

    let model: BarCardsModel

    var body: some View {
        Menu(Lang.t("common.addModule")) {
            ForEach(AddableCardCatalog.categories()) { category in
                Menu(Lang.t(category.titleKey)) {
                    ForEach(category.cards) { card in
                        Button(Lang.t(card.titleKey)) { model.add(card) }
                    }
                }
            }
        }
    }
}
