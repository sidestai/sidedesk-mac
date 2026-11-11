import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3-3 WindowConfigManager 验收：SQLite 关系树往返、示例播种、dock 自愈、作用域守卫。
final class WindowConfigManagerTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-wcm-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
    }

    override func tearDown() {
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - 往返

    func testSaveLoadRoundTripPreservesTreeAndRows() {
        let mgr = WindowConfigManager()
        let win = WindowConfig()
        win.Id = "bar-1"; win.Name = "Home"; win.ShowInTabs = true
        win.Panels = [stickyPanel(["hello", "world"]),
                      todoPanel(["a", "b"])]
        // 嵌套分组：父 Group 携带子信号灯面板
        let group = PanelItem(); group.Id = "grp"; group.`Type` = .Group
        let child = PanelItem(); child.Id = "sig"; child.`Type` = .SignalLight
        child.SignalLights = [signalLight("#FF4444")]
        group.ChildPanels = [child]
        win.Panels.append(group)
        mgr.Windows = [win]
        mgr.LeftDock.WindowIds = ["bar-1"]; mgr.LeftDock.ActiveIndex = 0
        mgr.RightDock.WindowIds = ["bar-1"]
        mgr.Save()

        let reloaded = LocalDbService.loadManager()
        XCTAssertEqual(reloaded.Windows.count, 1)
        let w = reloaded.Windows[0]
        XCTAssertEqual(w.Name, "Home")
        XCTAssertEqual(w.Panels.count, 3, "两个根面板 + 分组（子面板挂在其下，不重复出现在根层）")

        let sticky = w.Panels.first { $0.`Type` == .StickyNotes }
        XCTAssertEqual(sticky?.StickyNotes?.count, 2)
        XCTAssertEqual(Set(sticky?.StickyNotes?.map { $0.Content } ?? []), ["hello", "world"])

        let todo = w.Panels.first { $0.`Type` == .TodoList }
        XCTAssertEqual(Set(todo?.TodoItems?.map { $0.Text } ?? []), ["a", "b"])

        let grp = w.Panels.first { $0.Id == "grp" }
        XCTAssertEqual(grp?.ChildPanels?.count, 1)
        XCTAssertEqual(grp?.ChildPanels?.first?.Id, "sig")
        XCTAssertEqual(grp?.ChildPanels?.first?.SignalLights?.count, 1)

        XCTAssertEqual(reloaded.LeftDock.WindowIds, ["bar-1"])
        XCTAssertEqual(reloaded.LeftDock.ActiveIndex, 0)
    }

    func testItemDataExcludesRowLists() {
        // item_data blob 不应含行列表数据（行数据独立存储）；重载后仍由行表还原
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar-x"
        let p = stickyPanel(["only-in-row"])
        win.Panels = [p]
        mgr.Windows = [win]
        mgr.Save()

        let conn = LocalDbService.open()!; defer { conn.close() }
        let blob = conn.scalarString("SELECT item_data FROM local_item WHERE local_uid=$u", ["$u": p.Id]) ?? ""
        XCTAssertFalse(blob.contains("only-in-row"), "StickyNotes 应被排除出 item_data")

        let reloaded = LocalDbService.loadManager()
        XCTAssertEqual(reloaded.Windows.first?.Panels.first?.StickyNotes?.first?.Content, "only-in-row",
                       "行数据应由 local_item_row 还原")
    }

    func testRemoveWindowTombstonesAndReloadsEmpty() {
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar-del"
        mgr.Windows = [win]
        mgr.LeftDock.WindowIds = ["bar-del"]; mgr.RightDock.WindowIds = ["bar-del"]
        mgr.Save()
        XCTAssertEqual(LocalDbService.loadManager().Windows.count, 1)

        mgr.Remove("bar-del")
        let reloaded = LocalDbService.loadManager()
        XCTAssertEqual(reloaded.Windows.count, 0, "Remove 后全量重写应打墓碑、重载即空")
    }

    // MARK: - 作用域守卫

    func testSaveRejectedOnScopeMismatch() {
        // 先在 local 作用域写入一条 bar
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar-scoped"
        mgr.Windows = [win]
        mgr.LoadedScope = LocalDbService.currentScope()   // == "local"
        mgr.Save()
        XCTAssertEqual(LocalDbService.loadManager().Windows.count, 1)

        // 模拟登录态变更：内存实例仍标记旧作用域，currentScope 变 → 拒绝以内存为准的保存
        LocalDbService.accountUserIdProvider = { "cipher-user" }
        let stale = WindowConfigManager()
        stale.LoadedScope = "local"
        stale.Windows = []                                  // 若真按内存为准会清空库
        stale.Save()
        LocalDbService.accountUserIdProvider = nil
        // 回到 local 作用域读取：数据库应保持不变（仍含 bar-scoped）
        XCTAssertEqual(LocalDbService.loadManager().Windows.count, 1, "作用域不一致时保存必须被拒绝")
    }

    // MARK: - 示例播种 / 兜底 / 自愈

    func testEnsureDefaultSeedsSamplePanelsOnce() {
        let mgr = WindowConfigManager()
        mgr.EnsureDefault()
        XCTAssertEqual(mgr.Windows.count, 1)
        let kinds = mgr.Windows[0].Panels.map { $0.`Type` }
        XCTAssertTrue(kinds.contains(.StickyNotes))
        XCTAssertTrue(kinds.contains(.QuickGroup))
        XCTAssertTrue(kinds.contains(.Group))
        XCTAssertTrue(kinds.contains(.TodoList))
        XCTAssertTrue(kinds.contains(.Pomodoro))
        // dock 两侧都补上
        XCTAssertEqual(mgr.LeftDock.WindowIds, mgr.Windows.map { $0.Id })
        XCTAssertEqual(mgr.RightDock.WindowIds, mgr.Windows.map { $0.Id })

        // 二次调用不再播种
        let mgr2 = WindowConfigManager()
        mgr2.EnsureDefault()
        XCTAssertEqual(mgr2.Windows.count, 0, "已置标后不得重复播种")
    }

    func testEnsureAtLeastOneBar() {
        let mgr = WindowConfigManager()
        mgr.EnsureAtLeastOneBar()
        XCTAssertEqual(mgr.Windows.count, 1)
        XCTAssertTrue(mgr.Windows[0].Panels.isEmpty)
        mgr.EnsureAtLeastOneBar()
        XCTAssertEqual(mgr.Windows.count, 1, "已有 bar 时不再补建")
    }

    func testRepairDockMembership() {
        let mgr = WindowConfigManager()
        let w1 = WindowConfig(); w1.Id = "w1"; w1.ShowInTabs = true
        let w2 = WindowConfig(); w2.Id = "w2"; w2.ShowInTabs = true
        let hidden = WindowConfig(); hidden.Id = "w3"; hidden.ShowInTabs = false
        mgr.Windows = [w1, w2, hidden]
        // dock 里含孤儿 id，且缺 w2；ActiveIndex 越界
        mgr.LeftDock.WindowIds = ["gone", "w1"]; mgr.LeftDock.ActiveIndex = 5
        mgr.RightDock.WindowIds = ["gone"]
        mgr.RepairDockMembership()
        XCTAssertEqual(mgr.LeftDock.WindowIds, ["w1", "w2"], "清孤儿 + 按顺序补回，hidden 不复活")
        XCTAssertEqual(mgr.LeftDock.ActiveIndex, 0, "越界 ActiveIndex 在清孤儿阶段按当时末尾回落（补回在其后）")
        XCTAssertEqual(mgr.RightDock.WindowIds, ["w1", "w2"])
        XCTAssertFalse(mgr.LeftDock.WindowIds.contains("w3"))
    }

    // MARK: - 多虚拟屏幕（窗口标签）

    func testCreateNewWindowAddsToBothDocksAndActivates() {
        let mgr = WindowConfigManager()
        mgr.EnsureAtLeastOneBar()   // 先有一个窗口
        let firstId = mgr.Windows[0].Id
        XCTAssertEqual(mgr.LeftDock.ActiveIndex, 0)

        let created = mgr.CreateNewWindow()
        XCTAssertEqual(mgr.Windows.count, 2)
        XCTAssertTrue(created.Panels.isEmpty, "新虚拟屏幕是空的")
        XCTAssertFalse(created.Name.isEmpty, "名称走 Lang，不应为空")
        XCTAssertEqual(mgr.LeftDock.WindowIds.last, created.Id, "追加到左 dock")
        XCTAssertEqual(mgr.RightDock.WindowIds.last, created.Id, "追加到右 dock")
        XCTAssertEqual(mgr.LeftDock.ActiveIndex, 1, "新建即切为活动")
        XCTAssertEqual(mgr.RightDock.ActiveIndex, 1)

        // 落盘往返
        let reloaded = LocalDbService.loadManager()
        XCTAssertEqual(reloaded.Windows.count, 2)
        XCTAssertEqual(reloaded.LeftDock.ActiveIndex, 1)
        XCTAssertNotNil(reloaded.GetById(firstId))
    }

    func testRenameWindowTrimsAndIgnoresEmpty() {
        let mgr = WindowConfigManager()
        let win = mgr.CreateNewWindow()
        mgr.RenameWindow(win.Id, "  工作台  ")
        XCTAssertEqual(mgr.GetById(win.Id)?.Name, "工作台")
        mgr.RenameWindow(win.Id, "   ")
        XCTAssertEqual(mgr.GetById(win.Id)?.Name, "工作台", "空名忽略，保留原值")
        mgr.RenameWindow("nope", "x")   // 不存在的 id 不崩
    }

    func testRemoveWindowClampsActiveIndex() {
        let mgr = WindowConfigManager()
        mgr.EnsureAtLeastOneBar()
        let a = mgr.Windows[0].Id
        let b = mgr.CreateNewWindow().Id   // ActiveIndex → 1
        XCTAssertEqual(mgr.LeftDock.ActiveIndex, 1)
        mgr.Remove(b)
        mgr.RepairDockMembership()
        XCTAssertEqual(mgr.LeftDock.WindowIds, [a])
        XCTAssertEqual(mgr.LeftDock.ActiveIndex, 0, "删掉活动项后越界下标回落末尾")
        XCTAssertNil(mgr.GetById(b))
    }

    // MARK: - 工厂

    private func note(_ text: String) -> StickyNote { let n = StickyNote(); n.Content = text; return n }
    private func stickyPanel(_ texts: [String]) -> PanelItem {
        let p = PanelItem(); p.`Type` = .StickyNotes; p.StickyNotes = texts.map { note($0) }; return p
    }
    private func todoPanel(_ texts: [String]) -> PanelItem {
        let p = PanelItem(); p.`Type` = .TodoList
        p.TodoItems = texts.map { let t = TodoItem(); t.Text = $0; return t }; return p
    }
    private func signalLight(_ color: String) -> SignalLightItem {
        let s = SignalLightItem(); s.Color = color; return s
    }
}
