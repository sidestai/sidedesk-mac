import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 后端 WS 事件分发验收：拉取类事件（团队行更新/结构变更/分享元数据/源窗口 diff）、
/// 清理类事件（分享取消/团队身份失效/团队卡片·窗口删除）的落盘次序与墓碑语义、
/// 成员身份兜底对账（nil 不删、空列表清光、在籍保留）、未移植事件静默跳过。
final class BackendEventDispatcherTests: XCTestCase {

    private var dir: String!
    private var originalTimerFactory: ((TimeInterval, @escaping () -> Void) -> ServiceTimer)!
    private var refreshCount = 0
    private var pollingSyncCount = 0
    private var purgedVarSets: [String] = []

    /// 假后端：按路径后缀路由响应体，记录全部请求。
    private final class FakeBackend {
        var routes: [String: String] = [:]
        var requests: [(path: String, query: String?)] = []
        var defaultResponse = #"{"code":200,"data":{}}"#

        func transport(_ req: URLRequest) async throws -> (Data, HTTPURLResponse?) {
            let path = req.url?.path ?? ""
            requests.append((path, req.url?.query))
            let json = routes.first { path.hasSuffix($0.key) }?.value ?? defaultResponse
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil))
        }
    }

    private final class NoopTimer: ServiceTimer {
        func start() {}
        func stop() {}
    }

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-ws-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
        Settings.DirOverride = dir
        Seam.resetSettings()
        Seam.settings = Settings()
        Seam.uiPost = { $0() }
        Seam.hasUiThread = { false }
        refreshCount = 0
        Seam.refreshAllWindows = { [unowned self] in self.refreshCount += 1 }
        Seam.reloadWindowsUi = nil
        originalTimerFactory = Seam.timerFactory
        Seam.timerFactory = { _, _ in NoopTimer() }
        pollingSyncCount = 0
        purgedVarSets = []
        AppContainer.shared.reset()
    }

    override func tearDown() {
        AppContainer.shared.reset()
        Seam.resetSettings()
        Seam.uiPost = { _ in }
        Seam.hasUiThread = { false }
        Seam.refreshAllWindows = nil
        Seam.reloadWindowsUi = nil
        Seam.timerFactory = originalTimerFactory
        Settings.DirOverride = nil
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func login() {
        Seam.settings.AccountToken = "tok"
        Seam.settings.EnableCloudSync = true
    }

    /// 分发器：mgr 经组合根登记（CloudSyncService.configs() 回写要用同一实例）；
    /// 轮询重建/变量集清除记数即可，不构造真实轮询服务（会拉起浏览器引擎）。
    private func makeDispatcher(_ mgr: WindowConfigManager,
                                backend: FakeBackend? = nil,
                                teams: [Team]?? = nil) -> BackendEventDispatcher {
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)
        let sync = backend.map { CloudSyncService(api: BackendApiClient(logTag: "[Test]", timeout: 5, transport: $0.transport)) }
        return BackendEventDispatcher(
            manager: { mgr },
            cloudSync: { sync },
            pollingSync: { [unowned self] _ in self.pollingSyncCount += 1 },
            listTeams: { teams ?? nil },
            purgeVariableSets: { [unowned self] in self.purgedVarSets.append($0) })
    }

    private func todo(_ id: String, _ text: String) -> TodoItem {
        let t = TodoItem(); t.Id = id; t.Text = text; return t
    }

    private func todoPanel(_ id: String, serverId: String?, _ items: [TodoItem]) -> PanelItem {
        let p = PanelItem(); p.Id = id; p.ServerId = serverId; p.`Type` = .TodoList; p.TodoItems = items
        return p
    }

    // MARK: - 拉取类事件

    func testTeamRowUpdatedPullsMergeAndRefreshes() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w1"
        let p = todoPanel("p1", serverId: "si-1", [todo("a", "a1")])
        win.Panels = [p]; mgr.Windows = [win]
        mgr.Save()
        let backend = FakeBackend()
        backend.routes["item-row/pull"] = #"""
        {"code":200,"data":{"rows":[
          {"rowId":"a","rowType":"todo","content":{"Id":"a","Text":"a2"}},
          {"rowId":"x","rowType":"todo","content":{"Id":"x","Text":"new"}}
        ]}}
        """#
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"team_row_updated","data":{"itemServerId":"si-1"}}"#)
        XCTAssertEqual(p.TodoItems?.map { $0.Id }, ["a", "x"])
        XCTAssertEqual(p.TodoItems?.first { $0.Id == "a" }?.Text, "a2")
        XCTAssertEqual(refreshCount, 1)
        let pull = backend.requests.first { $0.path.hasSuffix("item-row/pull") }
        XCTAssertTrue(pull?.query?.contains("itemServerId=si-1") == true)
        XCTAssertFalse(pull?.query?.contains("since=") == true, "WS 实时刷新走全量合并，不带 since")
    }

    func testTeamRowUpdatedForceFullReplacesAndAlwaysRefreshes() async {
        login()
        let mgr = WindowConfigManager()
        let p = todoPanel("p1", serverId: "si-1", [todo("a", "a"), todo("b", "b")])
        let win = WindowConfig(); win.Panels = [p]; mgr.Windows = [win]
        mgr.Save()
        let backend = FakeBackend()
        backend.routes["item-row/pull"] = #"""
        {"code":200,"data":{"rows":[{"rowId":"a","rowType":"todo","content":{"Id":"a","Text":"a"}}]}}
        """#
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"team_row_updated","data":{"itemServerId":"si-1","forceFull":true}}"#)
        XCTAssertEqual(p.TodoItems?.map { $0.Id }, ["a"], "全量替换：不可见的本地行移除")
        XCTAssertEqual(refreshCount, 1)
        // 再来一次无变更：forceFull 仍刷新（C# 口径）
        await d.handle(#"{"event":"team_row_updated","data":{"itemServerId":"si-1","forceFull":true}}"#)
        XCTAssertEqual(refreshCount, 2)
    }

    func testTeamRowUpdatedUnknownItemIsNoop() async {
        login()
        let mgr = WindowConfigManager()
        mgr.Windows = [WindowConfig()]
        let backend = FakeBackend()
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"team_row_updated","data":{"itemServerId":"nope"}}"#)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(refreshCount, 0)
    }

    func testStructureChangedReconcilesPullOnly() async {
        login()
        let mgr = WindowConfigManager()
        mgr.Save()
        let backend = FakeBackend()
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"structure_changed"}"#)
        XCTAssertTrue(backend.requests.contains { $0.path.hasSuffix("sync/pull") }, "结构变更触发拉取对账")
        XCTAssertFalse(backend.requests.contains { $0.path.hasSuffix("/sync") }, "pushLocal=false 不上传本地结构")
    }

    func testShareItemMetaUpdatedPullsMetaAndRows() async {
        login()
        let mgr = WindowConfigManager()
        let p = todoPanel("p1", serverId: "si-1", [todo("a", "a")])
        p.Title = "old"
        let win = WindowConfig(); win.Panels = [p]; mgr.Windows = [win]
        mgr.Save()
        let backend = FakeBackend()
        backend.routes["sync/shared-item"] = #"{"code":200,"data":{"title":"new","itemData":{}}}"#
        backend.routes["item-row/pull"] = #"{"code":200,"data":{"rows":[]}}"#
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"share_item_meta_updated","data":{"itemServerId":"si-1"}}"#)
        XCTAssertEqual(p.Title, "new")
        XCTAssertTrue(backend.requests.contains { $0.path.hasSuffix("sync/shared-item") })
        XCTAssertEqual(refreshCount, 1, "元数据变了即刷新")
    }

    func testShareSourceBarItemsChangedDiffsEntryWindow() async {
        login()
        let mgr = WindowConfigManager()
        let entry = WindowConfig(); entry.Id = "w-entry"; entry.SourceBarId = "sb-shared"
        let p = todoPanel("p1", serverId: "si-1", [todo("a", "a")])
        p.Title = "old"
        entry.Panels = [p]; mgr.Windows = [entry]
        mgr.Save()
        let backend = FakeBackend()
        backend.routes["sync/shared-bar-items"] = #"""
        {"code":200,"data":{"items":[{"serverId":"si-1","title":"new","itemData":{}}]}}
        """#
        let d = makeDispatcher(mgr, backend: backend)
        await d.handle(#"{"event":"share_source_bar_updated","data":{"sourceBarId":"sb-shared","action":"items_changed"}}"#)
        XCTAssertEqual(p.Title, "new")
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(mgr.Windows.count, 1, "diff 更新不删入口窗口")
    }

    // MARK: - 分享取消 / 源窗口消失

    func testShareCancelledBarHardDeletesItemsKeepsBarTombstone() async {
        login()
        let mgr = WindowConfigManager()
        let imported = WindowConfig()
        imported.Id = "w-imported"; imported.ServerId = "sb-entry"; imported.SourceBarId = "sb-shared"
        let ref = PanelItem(); ref.Id = "p-ref"; ref.ServerId = "si-src"; ref.`Type` = .StickyNotes
        imported.Panels = [ref]
        mgr.Windows = [imported]
        mgr.LeftDock.WindowIds = ["w-imported"]; mgr.RightDock.WindowIds = ["w-imported"]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"share_cancelled","data":{"shareLevel":"bar","localId":"w-imported"}}"#)
        XCTAssertTrue(mgr.Windows.isEmpty)
        XCTAssertTrue(mgr.LeftDock.WindowIds.isEmpty)
        XCTAssertTrue(mgr.RightDock.WindowIds.isEmpty)
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertTrue(tomb.bars.contains("sb-entry"), "入口空壳留墓碑让服务端软删")
        XCTAssertFalse(tomb.items.contains("si-src"), "引用行硬删不打墓碑（防误删源模块）")
        XCTAssertEqual(pollingSyncCount, 1)
        XCTAssertEqual(refreshCount, 1)
    }

    func testShareCancelledBarFallsBackToSourceBarId() async {
        login()
        let mgr = WindowConfigManager()
        let imported = WindowConfig(); imported.Id = "w-imported"; imported.SourceBarId = "sb-shared"
        mgr.Windows = [imported]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"share_cancelled","data":{"shareLevel":"bar","sourceBarId":"sb-shared"}}"#)
        XCTAssertTrue(mgr.Windows.isEmpty, "旧导入记录无 localId 时按 SourceBarId 匹配")
    }

    func testShareCancelledItemByLocalId() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w-mine"
        let mine = todoPanel("p-mine", serverId: "si-mine", [todo("a", "a")])
        let orphan = todoPanel("p-gone", serverId: "si-gone", [todo("b", "b")])
        win.Panels = [mine, orphan]; mgr.Windows = [win]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"share_cancelled","data":{"shareLevel":"item","localId":"p-gone","itemServerId":"si-gone"}}"#)
        XCTAssertEqual(win.Panels.map { $0.Id }, ["p-mine"])
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertFalse(tomb.items.contains("si-gone"), "引用卡片硬删")
        XCTAssertTrue(tomb.bars.isEmpty)
        XCTAssertEqual(refreshCount, 1)
    }

    func testShareCancelledItemFallsBackToServerIdAndRecursesGroups() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w-mine"
        let group = PanelItem(); group.Id = "g1"; group.`Type` = .Group
        let orphan = todoPanel("p-gone", serverId: "si-gone", [todo("b", "b")])
        let nested = PanelItem(); nested.Id = "p-child"; nested.ServerId = "si-child"; nested.`Type` = .StickyNotes
        orphan.ChildPanels = [nested]
        group.ChildPanels = [orphan]
        win.Panels = [group]; mgr.Windows = [win]
        mgr.Save()
        let d = makeDispatcher(mgr)
        // localId 为空 → 按 ServerId 匹配；子面板一并收集硬删
        await d.handle(#"{"event":"share_cancelled","data":{"itemServerId":"si-gone"}}"#)
        XCTAssertTrue(group.ChildPanels?.isEmpty == true)
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertFalse(tomb.items.contains("si-gone"))
        XCTAssertFalse(tomb.items.contains("si-child"))
    }

    func testShareSourceBarRemovedRemovesEntryWindow() async {
        login()
        let mgr = WindowConfigManager()
        let entry = WindowConfig(); entry.Id = "w-entry"; entry.ServerId = "sb-entry"; entry.SourceBarId = "sb-shared"
        let ref = PanelItem(); ref.Id = "p-ref"; ref.ServerId = "si-src"; ref.`Type` = .StickyNotes
        entry.Panels = [ref]
        mgr.Windows = [entry]
        mgr.LeftDock.WindowIds = ["w-entry"]; mgr.RightDock.WindowIds = ["w-entry"]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"share_source_bar_updated","data":{"sourceBarId":"sb-shared","action":"bar_removed"}}"#)
        XCTAssertTrue(mgr.Windows.isEmpty)
        XCTAssertTrue(mgr.LeftDock.WindowIds.isEmpty)
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertTrue(tomb.bars.contains("sb-entry"))
        XCTAssertFalse(tomb.items.contains("si-src"))
    }

    // MARK: - 窗口改名

    func testBarMetaUpdatedRenamesAndPersists() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w1"; win.ServerId = "sb-1"; win.Name = "old"
        mgr.Windows = [win]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"bar_meta_updated","data":{"barServerId":"sb-1","title":"new"}}"#)
        XCTAssertEqual(win.Name, "new")
        XCTAssertEqual(refreshCount, 1)
        let reloaded = WindowConfigManager.Load()
        XCTAssertEqual(reloaded.Windows.first?.Name, "new", "改名已落库")
    }

    // MARK: - 团队数据即时清理

    func testTeamMembershipRevokedPurgesEverything() async {
        login()
        Seam.settings.SelectedCorpId = "corp-1"
        Seam.settings.SelectedCorpName = "团队一"
        Seam.settings.Save()

        let mgr = WindowConfigManager()
        let teamWin = WindowConfig()
        teamWin.Id = "w-team"; teamWin.ServerId = "sb-team"; teamWin.OwnerType = "team"; teamWin.CorpId = "corp-1"
        let teamCard = todoPanel("p-team-card", serverId: "si-team-card", [todo("t", "t")])
        teamWin.Panels = [teamCard]

        let mineWin = WindowConfig(); mineWin.Id = "w-mine"
        let group = PanelItem(); group.Id = "g1"; group.`Type` = .Group
        let teamPanel = todoPanel("p-tp", serverId: "si-tp", [todo("x", "x")])
        teamPanel.OwnerType = "team"; teamPanel.TeamId = "corp-1"
        let ownNested = todoPanel("p-own-nested", serverId: "si-own-nested", [todo("y", "y")])
        group.ChildPanels = [teamPanel, ownNested]
        let mine = todoPanel("p-mine", serverId: "si-mine", [todo("z", "z")])
        mineWin.Panels = [group, mine]

        mgr.Windows = [teamWin, mineWin]
        mgr.LeftDock.WindowIds = ["w-team", "w-mine"]; mgr.LeftDock.ActiveIndex = 0
        mgr.RightDock.WindowIds = ["w-team", "w-mine"]; mgr.RightDock.ActiveIndex = 0
        let bgTeam = DataDashboardItem(); bgTeam.TeamId = "corp-1"
        let bgMine = DataDashboardItem()
        mgr.BackgroundDashboardItems = [bgTeam, bgMine]
        let vsTeam = VariableSet(); vsTeam.TeamId = "corp-1"
        let vsMine = VariableSet()
        mgr.VariableSets = [vsTeam, vsMine]
        mgr.Save()

        // 用户自建模板：一条归属该团队、一条无归属
        let tplTeam = DataTemplate(); tplTeam.Id = "tpl-team"; tplTeam.TeamId = "corp-1"
        let tplMine = DataTemplate(); tplMine.Id = "tpl-mine"
        let tplData = try! SideDeskJSON.encoder().encode([tplTeam, tplMine])
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! tplData.write(to: URL(fileURLWithPath: DataTemplateManager.userTemplatesFilePath))

        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"team_membership_revoked","data":{"corpId":"corp-1"}}"#)

        XCTAssertEqual(mgr.Windows.map { $0.Id }, ["w-mine"], "团队窗口整个移除")
        XCTAssertEqual(group.ChildPanels?.map { $0.Id }, ["p-own-nested"], "个人窗口里的团队卡片移除，自建保留")
        XCTAssertEqual(mgr.LeftDock.WindowIds, ["w-mine"])
        XCTAssertEqual(mgr.RightDock.WindowIds, ["w-mine"])
        XCTAssertEqual(mgr.BackgroundDashboardItems.count, 1)
        XCTAssertEqual(mgr.VariableSets.count, 1)
        XCTAssertNil(Seam.settings.SelectedCorpId, "选中团队回落个人")
        XCTAssertNil(Seam.settings.SelectedCorpName)
        XCTAssertEqual(purgedVarSets, ["corp-1"], "云端登记变量集清除")
        XCTAssertEqual(pollingSyncCount, 1)
        XCTAssertEqual(refreshCount, 1)

        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertTrue(tomb.bars.isEmpty, "团队窗口硬删不打墓碑")
        XCTAssertTrue(tomb.items.isEmpty, "团队卡片硬删不打墓碑")

        let templates = DataTemplateManager.loadUserTemplates()
        XCTAssertEqual(templates.map { $0.Id }, ["tpl-mine"], "团队模板清除，自建保留")
    }

    func testTeamItemRemovedRecursesAndHardDeletes() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w1"
        let group = PanelItem(); group.Id = "g1"; group.`Type` = .Group
        let target = todoPanel("p-x", serverId: "si-x", [todo("a", "a")])
        let child = PanelItem(); child.Id = "p-x-child"; child.ServerId = "si-x-child"; child.`Type` = .StickyNotes
        target.ChildPanels = [child]
        let other = todoPanel("p-other", serverId: "si-other", [todo("b", "b")])
        group.ChildPanels = [target, other]
        win.Panels = [group]; mgr.Windows = [win]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"team_item_removed","data":{"itemServerId":"si-x"}}"#)
        XCTAssertEqual(group.ChildPanels?.map { $0.Id }, ["p-other"])
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertFalse(tomb.items.contains("si-x"))
        XCTAssertFalse(tomb.items.contains("si-x-child"))
        XCTAssertEqual(refreshCount, 1)
    }

    func testTeamBarRemovedHardDeletesBarAndItems() async {
        login()
        let mgr = WindowConfigManager()
        let teamWin = WindowConfig()
        teamWin.Id = "w-team"; teamWin.ServerId = "sb-team"; teamWin.OwnerType = "team"; teamWin.CorpId = "corp-1"
        let card = todoPanel("p-card", serverId: "si-card", [todo("a", "a")])
        teamWin.Panels = [card]
        let mineWin = WindowConfig(); mineWin.Id = "w-mine"
        mgr.Windows = [teamWin, mineWin]
        mgr.LeftDock.WindowIds = ["w-team", "w-mine"]
        mgr.RightDock.WindowIds = ["w-team", "w-mine"]
        mgr.Save()
        let d = makeDispatcher(mgr)
        await d.handle(#"{"event":"team_bar_removed","data":{"barServerId":"sb-team"}}"#)
        XCTAssertEqual(mgr.Windows.map { $0.Id }, ["w-mine"])
        XCTAssertEqual(mgr.LeftDock.WindowIds, ["w-mine"])
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertFalse(tomb.bars.contains("sb-team"), "团队窗口硬删（服务端已由作者删除）")
        XCTAssertFalse(tomb.items.contains("si-card"))
    }

    // MARK: - 成员身份兜底对账

    private func mgrWithTeamWindow() -> WindowConfigManager {
        let mgr = WindowConfigManager()
        let teamWin = WindowConfig()
        teamWin.Id = "w-team"; teamWin.ServerId = "sb-team"; teamWin.OwnerType = "team"; teamWin.CorpId = "corp-1"
        mgr.Windows = [teamWin]
        mgr.Save()
        return mgr
    }

    func testReconcilePurgesWhenTeamListEmpty() async {
        login()
        let mgr = mgrWithTeamWindow()
        let d = makeDispatcher(mgr, teams: .some([]))
        await d.reconcileTeamMembership()
        XCTAssertTrue(mgr.Windows.isEmpty, "服务端已无该团队身份 → 本地清光")
        XCTAssertTrue(LocalDbService.loadPendingDeleteTombstones().bars.isEmpty)
    }

    func testReconcileSkipsWhenListFailed() async {
        login()
        let mgr = mgrWithTeamWindow()
        let d = makeDispatcher(mgr, teams: .some(nil))   // 接口失败 → nil
        await d.reconcileTeamMembership()
        XCTAssertEqual(mgr.Windows.count, 1, "列表取不回宁可保留也绝不误删")
    }

    func testReconcileKeepsJoinedTeam() async {
        login()
        let mgr = mgrWithTeamWindow()
        var team = Team(); team.Id = "corp-1"
        let d = makeDispatcher(mgr, teams: .some([team]))
        await d.reconcileTeamMembership()
        XCTAssertEqual(mgr.Windows.count, 1)
    }

    func testReconcileSkipsWhenLoggedOut() async {
        let mgr = mgrWithTeamWindow()
        let d = makeDispatcher(mgr, teams: .some([]))
        await d.reconcileTeamMembership()
        XCTAssertEqual(mgr.Windows.count, 1, "未登录不对账")
    }

    func testReconcileCollectsTeamIdsFromAllSurfaces() async {
        login()
        Seam.settings.SelectedCorpId = "corp-sel"
        let mgr = WindowConfigManager()
        let mineWin = WindowConfig(); mineWin.Id = "w-mine"
        let teamPanel = todoPanel("p-tp", serverId: "si-tp", [])
        teamPanel.OwnerType = "team"; teamPanel.TeamId = "corp-panel"
        mineWin.Panels = [teamPanel]
        mgr.Windows = [mineWin]
        let bg = DataDashboardItem(); bg.TeamId = "corp-bg"
        mgr.BackgroundDashboardItems = [bg]
        let vs = VariableSet(); vs.TeamId = "corp-vs"
        mgr.VariableSets = [vs]
        mgr.Save()
        // 服务端只有一个团队都没回 → 四个表面的 corpId 全清
        let d = makeDispatcher(mgr, teams: .some([]))
        await d.reconcileTeamMembership()
        XCTAssertTrue(mineWin.Panels.isEmpty)
        XCTAssertTrue(mgr.BackgroundDashboardItems.isEmpty)
        XCTAssertTrue(mgr.VariableSets.isEmpty)
        XCTAssertNil(Seam.settings.SelectedCorpId)
    }

    // MARK: - 未移植事件 / 非法消息

    func testUnportedEventsAreSilentNoop() async {
        login()
        let mgr = mgrWithTeamWindow()
        let backend = FakeBackend()
        let d = makeDispatcher(mgr, backend: backend)
        for evt in ["friend_request", "friend_online", "notification", "team_invite",
                    "team_join_request", "team_membership_notice", "share_revoked_notice"] {
            await d.handle(#"{"event":"\#(evt)","data":{"x":1}}"#)
        }
        XCTAssertEqual(mgr.Windows.count, 1)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(refreshCount, 0)
    }

    func testInvalidJsonDoesNotCrash() async {
        let mgr = WindowConfigManager()
        let d = makeDispatcher(mgr)
        await d.handle("not json at all")
        await d.handle("")
        XCTAssertTrue(mgr.Windows.isEmpty)
    }
}