import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3 后续：QuickGroupService（快捷面板门面）验收 —— 枚举/增删/项操作/排序/临时项清理。
final class QuickGroupServiceTests: XCTestCase {

    private var dir: String!
    private var mgr: WindowConfigManager!
    private var svc: QuickGroupService!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-qg-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil

        mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar-1"; win.ShowInTabs = true
        mgr.Windows = [win]
        svc = QuickGroupService()
        svc.Init(mgr)
    }

    override func tearDown() {
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func mkItem(_ name: String, sort: Int = 0, created: Date = Date(),
                        source: String? = nil, longTerm: Bool = false) -> QuickItem {
        let q = QuickItem(); q.Name = name; q.SortIndex = sort; q.CreatedAt = created
        q.Source = source; q.IsLongTermWindow = longTerm; return q
    }

    func testAddGroupAndGetAll() {
        let g = QuickGroup(); g.Name = "Sites"; g.Columns = 2
        svc.AddGroup(g)
        XCTAssertEqual(svc.GetAll().count, 1)
        XCTAssertEqual(svc.GetAll().first?.Name, "Sites")
    }

    func testAddGroupTargetsFirstWindowWhenUnspecified() {
        let g = QuickGroup(); svc.AddGroup(g)
        XCTAssertTrue(mgr.Windows[0].Panels.contains { $0.Id == g.Id })
    }

    func testAddItemAssignsTrailingSortIndex() {
        let g = QuickGroup(); svc.AddGroup(g)
        svc.AddItem(g.Id, mkItem("a"))
        svc.AddItem(g.Id, mkItem("b"))
        let items = g.Items
        XCTAssertEqual(items.map { $0.SortIndex }, [0, 1])
    }

    func testRemoveItem() {
        let g = QuickGroup(); svc.AddGroup(g)
        let a = mkItem("a"); svc.AddItem(g.Id, a)
        svc.RemoveItem(g.Id, a.Id)
        XCTAssertTrue(g.Items.isEmpty)
    }

    func testReindexItems() {
        let g = QuickGroup(); svc.AddGroup(g)
        // 手工塞入乱序 SortIndex
        g.Items = [mkItem("x", sort: 7), mkItem("y", sort: 2), mkItem("z", sort: 9)]
        svc.ReindexItems(g.Id)
        XCTAssertEqual(g.Items.map { $0.SortIndex }, [0, 1, 2])
    }

    func testRemoveGroupRecursive() {
        let g = QuickGroup()
        let host = PanelItem(); host.`Type` = .Group; host.ChildPanels = [g.Panel]
        mgr.Windows[0].Panels = [host]
        XCTAssertTrue(svc.GetAll().contains { $0.Id == g.Id }, "嵌套子面板里的快捷组应被枚举到")
        svc.RemoveGroup(g.Id)
        XCTAssertFalse(svc.GetAll().contains { $0.Id == g.Id })
    }

    func testGetOrCreateDefaultGroup() {
        let id1 = svc.GetOrCreateDefaultGroup()
        XCTAssertEqual(svc.GetAll().count, 1)
        let id2 = svc.GetOrCreateDefaultGroup()
        XCTAssertEqual(id1, id2, "已有面板时应复用第一个")
    }

    func testSortByIndexStatic() {
        var items: [QuickItem]? = [mkItem("b", sort: 2), mkItem("a", sort: 1)]
        QuickGroupService.SortByIndex(&items)
        XCTAssertEqual(items?.map { $0.Name }, ["a", "b"])
    }

    func testRemoveTransientWindowItems() {
        let g = QuickGroup(); svc.AddGroup(g)
        g.Items = [
            mkItem("transient", source: "window", longTerm: false),
            mkItem("kept-longterm", source: "window", longTerm: true),
            mkItem("kept-url", source: nil),
        ]
        let removed = svc.RemoveTransientWindowItems()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(g.Items.map { $0.Name }, ["kept-longterm", "kept-url"])
    }
}
