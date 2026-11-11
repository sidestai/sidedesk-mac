import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T5-1 添加卡片目录验收：目录数据表、分类分组过滤、各类型默认初始化、以及新卡片落库往返。
final class AddableCardCatalogTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        Lang.initialize("zh-CN")
        dir = NSTemporaryDirectory() + "sidest-catalog-\(UUID().uuidString)"
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

    // MARK: - 目录数据表

    /// 目录条目数与收敛项：C# 基线 23 条，mac 去掉 ModuleUi / Friend（创建时需要未移植的对话框），
    /// 其中 UsageStats / DigitalEmployee 沿用 C# 的 Hidden 收敛。
    func testCatalogCountsMatchPortedScope() {
        XCTAssertEqual(AddableCardCatalog.all.count, 21)
        XCTAssertEqual(AddableCardCatalog.all.filter { $0.hidden }.map { $0.type },
                       [.UsageStats, .DigitalEmployee])
        XCTAssertFalse(AddableCardCatalog.all.contains { $0.type == .ModuleUi || $0.type == .Friend })
        // 单一事实源：同一 PanelType 不得出现两次
        XCTAssertEqual(Set(AddableCardCatalog.all.map { $0.id }).count, AddableCardCatalog.all.count)
    }

    /// 每个条目都要有可译的标题键与已知的分类键（缺键会在退出时落进 lang-missing.log，属红线）。
    func testCatalogKeysResolve() {
        for card in AddableCardCatalog.all + [AddableCardCatalog.groupCard] {
            XCTAssertNotEqual(Lang.t(card.titleKey), card.titleKey, "标题键未命中: \(card.titleKey)")
            XCTAssertTrue(AddableCardCatalog.categoryOrder.contains(card.categoryKey),
                          "分类键不在分组序里: \(card.categoryKey)")
        }
        for catKey in AddableCardCatalog.categoryOrder {
            XCTAssertNotEqual(Lang.t(catKey), catKey, "分类名未命中: \(catKey)")
        }
    }

    // MARK: - 分组

    /// 分组顺序沿用 C# 的 `CatalogCategoryOrder`；Hidden 条目被过滤；catBasic 首位是结构项「分组」。
    func testCategoriesOrderAndFiltering() {
        let cats = AddableCardCatalog.categories()
        XCTAssertEqual(cats.map { $0.titleKey },
                       ["addCard.catBasic", "addCard.catEfficiency", "addCard.catTodo",
                        "addCard.catTime", "addCard.catData", "addCard.catSocial"])
        let basic = cats[0]
        XCTAssertEqual(basic.cards.first?.type, .Group)
        XCTAssertEqual(basic.cards.filter { $0.hidden }.count, 0)
        // 团队分类因缺少可添加项而不出现（C# 该处挂的是「从团队卡片库添加」动作项，未移植）
        XCTAssertFalse(cats.contains { $0.titleKey == "addCard.catTeam" })
        // 可见条目 = 全表 21 - 2 个 Hidden + 1 个分组结构项
        XCTAssertEqual(cats.reduce(0) { $0 + $1.cards.count }, 20)
        XCTAssertEqual(AddableCardCatalog.categories(includeHidden: true)
            .reduce(0) { $0 + $1.cards.count }, 22)
    }

    // MARK: - 默认初始化

    /// 带默认数据的类型（C# 注释明示"不能降级成 AddPanel(type)"的那几个）必须真的带上数据。
    func testDefaultsForDataSeededTypes() {
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .Timer).TimerItems?.count, 1)
        XCTAssertNotNil(AddableCardCatalog.makePanelItem(for: .Pomodoro).Pomodoro)
        let lights = AddableCardCatalog.makePanelItem(for: .SignalLight).SignalLights
        XCTAssertEqual(lights?.map { $0.Color }, ["#FF4444", "#FFAA00", "#44CC44"])
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .CheckIn).CheckInItems?.count, 3)
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .CheckIn).CheckInColumns, 2)
        let quick = AddableCardCatalog.makePanelItem(for: .QuickGroup)
        XCTAssertEqual(quick.QuickColumns, 2)
        XCTAssertEqual(quick.QuickItems?.count, 0)
        let group = AddableCardCatalog.makePanelItem(for: .Group)
        XCTAssertEqual(group.Title, Lang.t("nativePanel.newGroup"))
        XCTAssertEqual(group.IsExpanded, true)
        XCTAssertEqual(group.ChildPanels?.count, 0)
    }

    /// 空卡片分支：列表类型初始化成空数组（C# 用它避开全局迁移逻辑），其余类型保持 nil。
    func testEmptyListInitsAndPlainTypes() {
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .StickyNotes).StickyNotes?.count, 0)
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .Notes).DeskNotes?.count, 0)
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .TodoList).TodoItems?.count, 0)
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .DataDashboard).DashboardItems?.count, 0)
        XCTAssertEqual(AddableCardCatalog.makePanelItem(for: .Countdown).CountdownItems?.count, 0)
        let plain = AddableCardCatalog.makePanelItem(for: .SystemMonitor)
        XCTAssertNil(plain.DashboardItems)
        XCTAssertNil(plain.Title)
        XCTAssertEqual(plain.`Type`, .SystemMonitor)
        // Id 唯一：连建两张同类卡片不能撞 id
        XCTAssertNotEqual(plain.Id, AddableCardCatalog.makePanelItem(for: .SystemMonitor).Id)
    }

    // MARK: - 落库往返

    /// 新建卡片追加到 bar 尾部并 Save→Load 后类型与默认数据不丢（行级数据走 local_item_row）。
    func testNewCardSurvivesSaveLoadRoundTrip() {
        let mgr = WindowConfigManager()
        let win = WindowConfig()
        win.Name = "Bar1"
        mgr.Windows.append(win)
        mgr.LeftDock.WindowIds.append(win.Id)
        mgr.RightDock.WindowIds.append(win.Id)
        mgr.Save()

        for type in [PanelType.Timer, .CheckIn, .SignalLight, .TodoList] {
            win.Panels.append(AddableCardCatalog.makePanelItem(for: type))
        }
        mgr.Save()

        let reloaded = WindowConfigManager.Load()
        let restored = reloaded.GetById(win.Id)?.Panels ?? []
        XCTAssertEqual(Set(restored.map { $0.`Type` }), Set([PanelType.Timer, .CheckIn, .SignalLight, .TodoList]))
        let timer = restored.first { $0.`Type` == .Timer }
        XCTAssertEqual(timer?.TimerItems?.count, 1)
        XCTAssertEqual(timer?.Title, Lang.t("nativePanel.timer"))
        let checkIn = restored.first { $0.`Type` == .CheckIn }
        XCTAssertEqual(checkIn?.CheckInItems?.map { $0.Text },
                       [Lang.t("nativePanel.presetDrinkWater"), Lang.t("nativePanel.presetStandUp"),
                        Lang.t("nativePanel.presetEyeRest")])
        let signal = restored.first { $0.`Type` == .SignalLight }
        XCTAssertEqual(signal?.SignalLights?.count, 3)
        XCTAssertEqual(restored.first { $0.`Type` == .TodoList }?.TodoItems?.count, 0)
    }
}
