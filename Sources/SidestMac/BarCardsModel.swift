import AppKit
import Combine
import SideDeskCore
import SideDeskServices

/// 侧栏卡片流的宿主（对应 C# `NativeModePanel` 的 `_currentWindowConfig` + `_configManager` 组合）：
/// 按停靠边取当前 bar、把 bar 的面板树暴露给 SwiftUI、承接「添加卡片 / 删除卡片 / 行内操作」并落库。
///
/// 与 C# 的差异（本轮范围有意收窄，不是遗漏修复）：
/// - C# 的编辑模式（拖拽调序、拖拽调高、`IsEditMode`）未接：卡片只能按目录追加到末尾，删除走右键；
/// - C# 删除卡片前有确认对话框，此处直接删除（确认文案键尚未在两侧词典里对齐，避免造新键）；
/// - C# 的增量插入（`InsertPanelWidgetIncremental`）在 SwiftUI 里由数据源刷新天然完成。
@MainActor
final class BarCardsModel: ObservableObject {

    /// 兄弟面板同步钩子（对应 C# `BroadcastBarToOtherWindows`）：左右两侧可能显示同一个 bar，
    /// 任一面板改动后所有面板按同一份内存树重取卡片列表。由宿主（AppDelegate）挂接。
    static var onBarChanged: (() -> Void)?

    @Published private(set) var panels: [PanelItem] = []

    /// 一个「虚拟屏幕」标签（对应 C# `_dockState.WindowIds` 里的一项 + 其 `WindowConfig.Name`）。
    /// `index` 是它在本 dock `WindowIds` 里的下标，即 Ctrl+数字 的序号（0 基）。
    struct WindowTab: Identifiable {
        let id: String
        let name: String
        let index: Int
    }

    /// 本 dock 的窗口标签列表（对应 C# `RefreshWindowTabs` 逐个构建的切换按钮数据源）。
    @Published private(set) var tabs: [WindowTab] = []
    /// 本 dock 当前活动标签下标（对应 C# `_dockState.ActiveIndex`）。
    @Published private(set) var activeIndex: Int = 0

    /// 数据修订号：每次 `reload()` 自增。PanelItem/TodoItem 都是引用类型，就地改字段后 `panels`
    /// 数组里的实例引用不变，SwiftUI 会认为 `CardView(panel:model:)` 的输入没变而**跳过重绘**
    /// （实测：待办 IsDone 翻true 但像素不变）。卡片视图用 `.id(revision)` 挂这个号，号一变即整卡重建，
    /// 强制所有就地变更（勾选待办、打卡计数、隐藏外框、快捷组列数/布局…）落到屏幕。
    @Published private(set) var revision: Int = 0

    private let edge: PanelEdge
    private var manager: WindowConfigManager?

    /// 番茄钟计时器（每秒检查是否有阶段到点）。对应 C# 边车进程的 tick；边车未移植，这里原生驱动。
    private var pomoTimer: Timer?

    init(edge: PanelEdge, manager: WindowConfigManager?) {
        self.edge = edge
        self.manager = manager
        reload()
        startPomodoroTicker()
        subscribeAppearanceChanges()
    }

    /// 主题/外观变更（换肤、改卡片字号、改背景透明度…）只改全局令牌与 `AppSettings`，而
    /// `CardView`/`CardBody` 仅持有 `panel`/`model` 引用（实例不变），SwiftUI 差分时会判定输入未变
    /// 而跳过其 body，令牌与 `FS()` 不会被重读（实测：改字号后像素不变、重启才生效）。递增 `revision`
    /// 让卡片 `.id` 变化、整卡重建，对应 C# 改字号/换肤后 `RenderPanels` 的全量重绘。
    private func subscribeAppearanceChanges() {
        ThemeManager.subscribeChanged { [weak self] in
            Task { @MainActor in self?.revision += 1 }
        }
    }

    // MARK: - 取当前 bar

    /// 本面板所属的 dock 状态（左/右各自独立的 `WindowIds` + `ActiveIndex`）。
    private var dock: DockWindowState? {
        guard let manager else { return nil }
        return edge == .left ? manager.LeftDock : manager.RightDock
    }

    /// 本面板当前显示的 bar。对应 C# 的 `_currentWindowConfig`：mac 侧按停靠边取该 dock 的
    /// `WindowIds[ActiveIndex]`。dock 为空或索引越界时回落首个窗口，与 `RepairDockMembership` 的回落口径一致。
    private var currentBar: WindowConfig? {
        guard let manager, let dock else { return nil }
        if dock.WindowIds.indices.contains(dock.ActiveIndex),
           let win = manager.GetById(dock.WindowIds[dock.ActiveIndex]) {
            return win
        }
        return manager.Windows.first
    }

    /// 从内存树重取卡片列表（`panels` 是值类型数组快照，引用类型的 PanelItem 与其共享实例）。
    func reload() {
        panels = currentBar?.Panels ?? []
        refreshTabs()
        revision += 1
    }

    /// 账号作用域切换后重绑配置管理器（对应 C# `MainWindow.ReloadForScopeSwitch` 的
    /// SetWindowConfigManager + 重切活动窗口）：旧内存树属于加载时的作用域，必须整棵替换。
    func rebindManager(_ newManager: WindowConfigManager?) {
        manager = newManager
        reload()
    }

    /// 重建标签列表与活动下标（对应 C# `RefreshWindowTabs` 的数据部分）。
    /// 只列 `ShowInTabs` 的窗口（C# 显隐说明：勾选「显示」的微屏才出现在顶部标签栏）；
    /// `index` 仍取 dock 内的位置下标，与 Ctrl+数字、设置页序号同口径。
    private func refreshTabs() {
        guard let manager, let dock else { tabs = []; activeIndex = 0; return }
        tabs = dock.WindowIds.enumerated().compactMap { index, id in
            guard let win = manager.GetById(id), win.ShowInTabs else { return nil }
            return WindowTab(id: id, name: win.Name, index: index)
        }
        activeIndex = dock.ActiveIndex
    }

    // MARK: - 虚拟屏幕（窗口标签）切换 / 增删

    /// 切换到指定序号的窗口标签（对应 C# `WindowTab_Click`）：写本 dock `ActiveIndex` → 落盘 → 重取卡片。
    /// 只动本 dock（左右各有独立活动项，与 C# 每个 MainWindow 独立 `_dockState` 一致）。
    func switchToTab(_ index: Int) {
        guard let manager, let dock else { return }
        guard dock.WindowIds.indices.contains(index), index != dock.ActiveIndex else { return }
        dock.ActiveIndex = index
        manager.Save()
        reload()
    }

    /// 新建虚拟屏幕（对应 C# `CreateNewWindow`）：加入两侧 dock 并切为活动，两块面板都要重取。
    func createWindow() {
        guard let manager else { return }
        manager.CreateNewWindow()
        reload()
        Self.onBarChanged?()
    }

    /// 删除指定虚拟屏幕（对应 C# `RemoveWindow(index)`）：仅剩一个时禁止删（与 C# 同约束，避免死状态）。
    func removeWindow(_ id: String) {
        guard let manager, let dock else { return }
        guard dock.WindowIds.count > 1, manager.GetById(id) != nil else { return }
        manager.Remove(id)
        manager.RepairDockMembership()   // 收敛越界 ActiveIndex
        reload()
        Self.onBarChanged?()
    }

    /// 重命名指定虚拟屏幕（对应 C# `EditWindowAtIndex(index)` 的名称部分）。
    func renameWindow(_ id: String, _ name: String) {
        guard let manager, manager.GetById(id) != nil else { return }
        manager.RenameWindow(id, name)
        reload()
        Self.onBarChanged?()
    }


    // MARK: - 增删

    /// 添加卡片（对应 C# `AddTopLevelPanel`：追加到顶层 → `Save()` → 重绘 → 广播）。
    func add(_ card: AddableCard) {
        guard let bar = currentBar else {
            RuntimeLog.warn("card", "add skipped: no bar on \(edge == .left ? "left" : "right") dock")
            return
        }
        bar.Panels.append(AddableCardCatalog.makePanelItem(for: card.type))
        manager?.Save()
        reload()
        Self.onBarChanged?()
    }

    /// 向分组添加子卡片（对应 C# `AddModuleToGroup` + `InsertChildPanel` 的追加分支）：
    /// 建卡默认值与顶层「添加卡片」同源（`AddableCardCatalog.makePanelItem`），追加到分组末尾 → 落库 → 重绘。
    /// C# 里按右键位置插入的分支依赖内容区坐标，Swift 侧走 ▾ 菜单无此坐标，故统一追加末尾。
    func addChildCard(_ group: PanelItem, _ card: AddableCard) {
        commit {
            if group.ChildPanels == nil { group.ChildPanels = [] }
            group.ChildPanels?.append(AddableCardCatalog.makePanelItem(for: card.type))
        }
    }

    /// 删除卡片（对应 C# `RemovePanel`）。分享只读的卡片与 C# 一样拒绝删除。
    func remove(_ panel: PanelItem) {
        guard let bar = currentBar else { return }
        guard !panel.IsShareDeleteBlocked else {
            RuntimeLog.info("card", "delete blocked by share policy: \(panel.Id)")
            return
        }
        let before = bar.Panels.count
        bar.Panels.removeAll { $0.Id == panel.Id }
        guard bar.Panels.count != before else { return }
        manager?.Save()
        reload()
        Self.onBarChanged?()
    }

    // MARK: - 行内操作

    /// 行数据变更（勾选待办、点打卡等）：改的是引用类型实例，落库后刷新并广播兄弟面板。
    private func commit(_ change: () -> Void) {
        change()
        manager?.Save()
        reload()
        Self.onBarChanged?()
    }

    /// 隐藏/显示卡片外框（对应 C# `ModuleControl.RebuildMenu` 里 `common.hideModuleFrame` 勾选项）。
    func setHideFrame(_ panel: PanelItem, _ hide: Bool) {
        commit { panel.HideFrame = hide }
    }

    /// 全部隐藏卡片外框（对应 C# `ToggleHideModuleFrame_Click`：写 `AppSettings.HideModuleFrame` + Save + 重绘）。
    /// 全局开关存 AppSettings（非单卡片），故直接落库并重取，不走 `commit`。
    func setHideModuleFrame(_ hide: Bool) {
        AppSettings.Instance.HideModuleFrame = hide
        AppSettings.Instance.Save()
        reload()
        Self.onBarChanged?()
    }

    /// 置顶显示（对应 C# 的 `nativePanel.pinOnTop`：置顶卡片渲染在滚动区上方的置顶区，标题带 ⌖ 前缀）。
    func setPinned(_ panel: PanelItem, _ pin: Bool) {
        commit { panel.IsPinned = pin }
    }

    /// 快捷组：修改列数（对应 C# `nativePanel.changeColumnCount` 子菜单 1-4）。
    /// list 模式渲染时强制单列（C# `Columns = isList ? 1 : group.Columns`），故存值不随模式改。
    func setQuickColumns(_ panel: PanelItem, _ columns: Int) {
        commit { panel.QuickColumns = columns }
    }

    /// 快捷组：切换显示方式 grid/list/popup（对应 C# `host.SetDisplayMode`）。
    func setQuickDisplayMode(_ panel: PanelItem, _ mode: String) {
        commit { panel.QuickDisplayMode = mode }
    }

    /// 打卡：列数 1-4（对应 C# `BuildCheckInWidget` 的「列数」子菜单）。
    func setCheckInColumns(_ panel: PanelItem, _ columns: Int) {
        commit { panel.CheckInColumns = columns }
    }

    /// 打卡：按钮样式（对应 C# 同处的「样式」子菜单，空值语义 = IconTextVertical）。
    func setCheckInStyle(_ panel: PanelItem, _ style: String) {
        commit { panel.CheckInStyle = style }
    }

    /// 新增打卡项（对应 C# `AddCheckInItem` / `ShowCheckInEditor` 的新建分支）：追加末尾、赋末位序号、重排。
    /// 配色由调用方按调色板循环取用（预设与自定义默认色同口径）。
    func addCheckIn(_ panel: PanelItem, text: String, icon: String, color: String) {
        commit {
            if panel.CheckInItems == nil { panel.CheckInItems = [] }
            let ci = CheckInItem()
            ci.Text = text
            ci.Icon = icon
            ci.Color = color
            ci.SortIndex = panel.CheckInItems?.count ?? 0
            panel.CheckInItems?.append(ci)
            Self.reindexCheckIn(panel)
        }
    }

    /// 原地修改打卡项（对应 C# `ShowCheckInEditor` 的编辑分支）。
    func updateCheckIn(_ item: CheckInItem, text: String, icon: String, color: String) {
        commit {
            item.Text = text
            item.Icon = icon
            item.Color = color
        }
    }

    /// 删除打卡项并重排序号（对应 C# 列表行的 ✕ + `ReindexCheckIn`）。
    func removeCheckIn(_ panel: PanelItem, _ item: CheckInItem) {
        commit {
            panel.CheckInItems?.removeAll { $0 === item }
            Self.reindexCheckIn(panel)
        }
    }

    /// 按当前列表顺序重排 SortIndex（0..n-1），对应 C# `ReindexCheckIn`。
    private static func reindexCheckIn(_ panel: PanelItem) {
        guard let items = panel.CheckInItems else { return }
        for (i, it) in items.enumerated() { it.SortIndex = i }
    }

    // MARK: - 信号灯

    /// 应用信号灯布局（对应 C# `ShowSignalLightEditDialog` 的 OK：方向/样式/大小/间距/对齐，
    /// 其中样式与大小同步刷到每盏灯）。灯的增删与单灯详情编辑走各自的方法（列表内实时提交）。
    func applySignalLightLayout(_ panel: PanelItem, vertical: Bool, style: String,
                                size: Double, spacing: Double, alignment: String) {
        commit {
            panel.SignalLightVertical = vertical
            panel.SignalLightSpacing = spacing
            panel.SignalLightAlignment = alignment
            for light in panel.SignalLights ?? [] {
                light.LightStyle = style
                light.Size = size
            }
        }
    }

    /// 添加一盏灯（对应 C# 添加灯按钮：默认红 `#FF4444` / 36 / 无图标 / 亮）。
    func addSignalLight(_ panel: PanelItem) {
        commit {
            if panel.SignalLights == nil { panel.SignalLights = [] }
            let light = SignalLightItem()
            light.Color = "#FF4444"
            light.Size = 36
            light.Icon = ""
            light.IsOn = true
            panel.SignalLights?.append(light)
        }
    }

    /// 删除一盏灯（对应 C# 列表 ✕ / 单灯右键删除）。
    func removeSignalLight(_ panel: PanelItem, _ light: SignalLightItem) {
        commit { panel.SignalLights?.removeAll { $0 === light } }
    }

    /// 修改单盏灯的颜色/大小/图标（对应 C# `ShowSignalLightDetailDialog` 的 OK；size<=0 时不改）。
    func updateSignalLight(_ light: SignalLightItem, color: String, size: Double, icon: String) {
        commit {
            light.Color = color
            if size > 0 { light.Size = size }
            light.Icon = icon
        }
    }

    /// 快捷组：新增快捷项（对应 C# `QuickGroupService.AddItem` + `Save` + 增量刷新）。
    /// 追加末尾并赋末位序号，列表始终按 SortIndex 有序。
    func addQuickItem(_ panel: PanelItem, _ item: QuickItem) {
        commit {
            if panel.QuickItems == nil { panel.QuickItems = [] }
            item.SortIndex = panel.QuickItems!.count
            panel.QuickItems!.append(item)
        }
    }

    /// 正在拉取 favicon 的项 Id（去重，避免同一项被重复触发抓取）。
    private var iconHealInFlight = Set<String>()

    /// 网址类快捷项图标自愈（对应 C# `HealUrlIconAsync`）：项无可用图标时，先命中本地缓存直接采用，
    /// 否则后台拉一次 favicon、缓存到本地、写回 `item.Icon` 并重绘。由 `quickBody.onAppear` 触发。
    /// 抓取在后台进行（不阻塞主线程），失败走 FaviconService 的负缓存，不重复风暴。
    func scheduleQuickIconHeal(_ panel: PanelItem) {
        guard let items = panel.QuickItems else { return }
        for item in items {
            guard item.`Type` == "url", item.Target.lowercased().hasPrefix("http") else { continue }
            // 已有可用图标（emoji，或存在的路径文件）→ 跳过
            if let ic = item.Icon, !ic.isEmpty, !FaviconService.isPathIcon(ic) { continue }
            if let ic = item.Icon, !ic.isEmpty, FileManager.default.fileExists(atPath: ic) { continue }
            // 命中本地缓存：直接采用，无需网络
            if let cached = FaviconService.validCachedOrPurge(item.Target) {
                commit { item.Icon = cached }
                continue
            }
            guard !iconHealInFlight.contains(item.Id) else { continue }
            iconHealInFlight.insert(item.Id)
            let target = item.Target, itemId = item.Id
            Task { [weak self] in
                let path = await FaviconService.fetchFavicon(target)
                await MainActor.run {
                    guard let self else { return }
                    self.iconHealInFlight.remove(itemId)
                    guard let path, let it = self.findQuickItem(itemId) else { return }
                    self.commit { it.Icon = path }
                }
            }
        }
    }

    /// 按 Id 在当前面板树里找快捷项（重绘后 panels 可能已换快照，故按 Id 重定位）。
    private func findQuickItem(_ id: String) -> QuickItem? {
        for panel in panels {
            if let hit = panel.QuickItems?.first(where: { $0.Id == id }) { return hit }
        }
        return nil
    }

    func toggleTodo(_ todo: TodoItem) {
        commit { todo.IsDone.toggle() }
    }

    /// 今日待办：新增一项（对应 C# `ShowTodoDialog` → `TodoItems.Add` + `Save` + `RenderPanels`）。
    func addTodo(_ panel: PanelItem, _ item: TodoItem) {
        commit {
            if panel.TodoItems == nil { panel.TodoItems = [] }
            panel.TodoItems!.append(item)
        }
    }

    // MARK: - 便签（黄色桌面悬浮窗，对应 C# NativeModePanel.StickyCard + StickyDesktopService）

    /// 点击便签行：钉选且显示中 → 收起（记 DeskClosed 抑制开机恢复）；非钉选但显示中（peek）→ 仅置前；
    /// 未显示 → 弹出黄色便签并置为焦点。均不改钉选态（对应 C# `ToggleStickyWindow`）。
    func toggleStickyWindow(_ note: StickyNote) {
        let open = StickyDesktopService.isOpen(note.Id)
        if open && note.Pinned {
            StickyDesktopService.close(note.Id)
            note.DeskClosed = true
        } else if open {
            StickyDesktopService.activate(note.Id)
        } else {
            StickyDesktopService.open(note,
                                      persist: { [weak self] in self?.manager?.Save() },
                                      unpinned: { [weak self] in self?.closeStickyDesk(note) },
                                      activate: true)
            note.DeskClosed = false
        }
        manager?.Save()
    }

    /// 用户在黄色便签内点 ✕ 关窗：不改钉选态，只记 DeskClosed 并落盘（对应 C# `CloseStickyDesk`）。
    private func closeStickyDesk(_ note: StickyNote) {
        note.DeskClosed = true
        manager?.Save()
    }

    /// 新建便签：直接弹出黄色便签供编辑（默认不钉选，#486）。首次出现内容才插入列表头；输入后防抖落盘前
    /// 就关窗，由 unpinned 兜底补入库避免丢字；始终为空则从未入库直接丢弃（对应 C# `AddStickyNote`）。
    func addStickyNote(_ panel: PanelItem) {
        if panel.StickyNotes == nil { panel.StickyNotes = [] }
        let note = StickyNote()
        var committed = false
        // 直接改 panel.StickyNotes（值类型数组，不能捕获局部副本）；入库只做一次，插入列表头。
        let insertOnce = { [weak panel] in
            if !committed {
                committed = true
                if panel?.StickyNotes == nil { panel?.StickyNotes = [] }
                panel?.StickyNotes?.insert(note, at: 0)
            }
        }
        StickyDesktopService.open(note, persist: { [weak self] in
            if !note.Content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertOnce()
                self?.manager?.Save(); self?.reload(); Self.onBarChanged?()
            } else {
                self?.manager?.Save()
            }
        }, unpinned: { [weak self] in
            guard !note.Content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            insertOnce()
            note.DeskClosed = true
            self?.manager?.Save(); self?.reload(); Self.onBarChanged?()
        }, activate: true)
    }

    /// 删除便签：先关掉它的桌面悬浮窗，再从列表移除并落库重绘（对应 C# `RemoveStickyNote`）。
    func removeStickyNote(_ panel: PanelItem, _ note: StickyNote) {
        StickyDesktopService.close(note.Id)
        commit { panel.StickyNotes?.removeAll { $0.Id == note.Id } }
    }

    /// 重绘/开机恢复钉选（对应 C# `BuildStickyNotesCard` 末尾）：仅恢复「仍钉选且未被用户关闭」的便签。
    /// `open` 幂等，故 stickyBody.onAppear 每次重放安全。
    func restorePinnedStickyNotes(_ panel: PanelItem) {
        guard let notes = panel.StickyNotes else { return }
        for n in notes where n.Pinned && !n.DeskClosed {
            StickyDesktopService.open(n,
                                      persist: { [weak self] in self?.manager?.Save() },
                                      unpinned: { [weak self] in self?.closeStickyDesk(n) })
        }
    }

    /// 打卡计数（对应 C# 的 `EnsureTodayCount` + 自增，跨天自动从 0 起算）。
    func checkIn(_ item: CheckInItem) {
        commit {
            item.EnsureTodayCount()
            item.Count += 1
        }
    }

    /// 快捷项执行（对应 C# 的快捷方式点击：url 走浏览器、program 走程序启动）。
    func perform(_ item: QuickItem) {
        if item.`Type` == "program" {
            let url = URL(fileURLWithPath: item.Target)
            guard NSWorkspace.shared.open(url) else {
                RuntimeLog.warn("card", "quick item launch failed: \(item.Target)")
                return
            }
        } else {
            guard let url = URL(string: item.Target), url.scheme?.hasPrefix("http") == true else {
                RuntimeLog.warn("card", "quick item url invalid: \(item.Target)")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 番茄闹钟引擎

    /// 启动每秒计时器。秒级倒计时显示由视图侧 `TimelineView` 自刷，本计时器只负责「阶段到点推进」，
    /// 且仅在真有阶段结束时才落库+重绘（避免整列卡片每秒重建）。
    private func startPomodoroTicker() {
        pomoTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPomodoros() }
        }
        RunLoop.main.add(t, forMode: .common)
        pomoTimer = t
    }

    private func tickPomodoros() {
        var advanced = false
        for panel in panels {
            guard let p = panel.Pomodoro else { continue }
            p.EnsureTodayCount()
            guard p.IsRunning, p.GetRemaining() <= 0 else { continue }
            advancePhase(p)
            advanced = true
        }
        guard advanced else { return }
        manager?.Save()
        reload()
        Self.onBarChanged?()
    }

    /// 阶段推进（对应 C# 模块侧语义）：Work 结束计数 +1，按 `LongBreakInterval` 决定长/短休息；
    /// 休息结束回 Work。`AutoStartNext` 决定下一阶段是否自动开始，否则停在就绪态。
    /// 阶段结束的提醒（闪光/弹窗）与每日活跃 +1 依赖未移植子系统，本轮暂略。
    private func advancePhase(_ p: PomodoroSettings) {
        let ended = p.Mode
        if ended == "Work" {
            p.EnsureTodayCount()
            p.CompletedCount += 1
        }
        let next: String
        if ended == "Work" {
            next = (p.LongBreakInterval > 0 && p.CompletedCount % p.LongBreakInterval == 0) ? "LongBreak" : "ShortBreak"
        } else {
            next = "Work"
        }
        p.Mode = next
        p.RemainingSeconds = Double(p.GetModeTotalSeconds())
        if p.AutoStartNext {
            p.IsRunning = true
            p.StartTime = Date()
        } else {
            p.IsRunning = false
            p.StartTime = nil
        }
        RuntimeLog.info("card", "pomodoro phase ended=\(ended) next=\(next) count=\(p.CompletedCount)")
    }

    /// 开始/暂停（对应 C# `svc.ToggleAsync`）。暂停时把墙钟剩余固化进 `RemainingSeconds`。
    func togglePomodoro(_ panel: PanelItem) {
        commit {
            guard let p = panel.Pomodoro else { return }
            if p.IsRunning {
                p.RemainingSeconds = p.GetRemaining()
                p.IsRunning = false
                p.StartTime = nil
            } else {
                p.EnsureTodayCount()
                if p.RemainingSeconds <= 0 { p.RemainingSeconds = Double(p.GetModeTotalSeconds()) }
                p.IsRunning = true
                p.StartTime = Date()
            }
        }
    }

    /// 切换模式（对应 C# `svc.SetModeAsync`：无条件重置当前阶段剩余时间并停表）。
    func setPomodoroMode(_ panel: PanelItem, _ mode: String) {
        commit {
            guard let p = panel.Pomodoro else { return }
            p.Mode = mode
            p.IsRunning = false
            p.StartTime = nil
            p.RemainingSeconds = Double(p.GetModeTotalSeconds())
        }
    }

    /// 重置当前阶段（对应 C# `svc.ResetAsync`）。
    func resetPomodoro(_ panel: PanelItem) {
        commit {
            guard let p = panel.Pomodoro else { return }
            p.IsRunning = false
            p.StartTime = nil
            p.RemainingSeconds = Double(p.GetModeTotalSeconds())
        }
    }

    /// 应用番茄钟设置（对应 C# `ShowPomodoroSettingsDialog` 的 OK 分支）：写入各阶段时长/间隔/自动开始；
    /// 时长变更且未在运行时重置当前阶段剩余时间（与 C# 同口径）。
    func applyPomodoroSettings(_ panel: PanelItem, work: Int, shortBreak: Int, longBreak: Int,
                               interval: Int, autoStartNext: Bool) {
        commit {
            guard let p = panel.Pomodoro else { return }
            let durationChanged = p.WorkMinutes != work || p.ShortBreakMinutes != shortBreak || p.LongBreakMinutes != longBreak
            p.WorkMinutes = work
            p.ShortBreakMinutes = shortBreak
            p.LongBreakMinutes = longBreak
            p.LongBreakInterval = interval
            p.AutoStartNext = autoStartNext
            if durationChanged && !p.IsRunning {
                p.RemainingSeconds = Double(p.GetModeTotalSeconds())
            }
        }
    }
}
