import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 云同步验收：结构载荷协议（版本/墓碑/去重/行列表排除）、ServerId 映射回写、
/// 结构拉取（认领/补齐/团队不自动建/墓碑免疫）、itemData 应用口径、
/// 行级推送差分与删除寻址、业务失败不更新快照、行拉取合并/全量替换、
/// 内容比较的数字/日期容忍、失效共享清理（硬删不打墓碑）。
final class CloudSyncServiceTests: XCTestCase {

    private var dir: String!
    private var originalTimerFactory: ((TimeInterval, @escaping () -> Void) -> ServiceTimer)!
    private var originalKeyStore: SyncKeyStoring!

    /// 假后端：按路径后缀路由响应体，记录全部请求（路径/query/解码后 body）。
    private final class FakeBackend {
        var routes: [String: String] = [:]
        var requests: [(path: String, query: String?, body: JSONValue?)] = []
        var defaultResponse = #"{"code":200,"data":{}}"#

        func transport(_ req: URLRequest) async throws -> (Data, HTTPURLResponse?) {
            let path = req.url?.path ?? ""
            let body = req.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            requests.append((path, req.url?.query, body))
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
        dir = NSTemporaryDirectory() + "sidest-cloud-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
        Settings.DirOverride = dir
        Seam.resetSettings()
        Seam.settings = Settings()
        Seam.uiPost = { $0() }
        Seam.refreshAllWindows = nil
        Seam.reloadWindowsUi = nil
        // Save → notifyRowsChanged 会造防抖定时器：测试注入假表，避免 2 秒后异步推送泄漏
        originalTimerFactory = Seam.timerFactory
        Seam.timerFactory = { _, _ in NoopTimer() }
        originalKeyStore = SyncEncryption.keyStore
        SyncEncryption.keyStore = MemorySyncKeyStore()
        AppContainer.shared.reset()
    }

    override func tearDown() {
        AppContainer.shared.reset()
        Seam.resetSettings()
        Seam.uiPost = { _ in }
        Seam.refreshAllWindows = nil
        Seam.reloadWindowsUi = nil
        Seam.timerFactory = originalTimerFactory
        SyncEncryption.keyStore = originalKeyStore
        Settings.DirOverride = nil
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func service(_ backend: FakeBackend) -> CloudSyncService {
        CloudSyncService(api: BackendApiClient(logTag: "[Test]", timeout: 5, transport: backend.transport))
    }

    /// 登录态 + 云同步开关（推送/拉取的公共门控）
    private func login() {
        Seam.settings.AccountToken = "tok"
        Seam.settings.EnableCloudSync = true
    }

    private func register(_ mgr: WindowConfigManager) {
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)
    }

    private func todo(_ id: String, _ text: String) -> TodoItem {
        let t = TodoItem(); t.Id = id; t.Text = text
        return t
    }

    private func todoPanel(_ id: String, serverId: String?, _ items: [TodoItem]) -> PanelItem {
        let p = PanelItem(); p.Id = id; p.ServerId = serverId; p.`Type` = .TodoList
        p.TodoItems = items
        return p
    }

    // MARK: - 结构载荷

    func testBuildSyncPayloadProtocolTombstonesAndCollections() {
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar1"; win.Name = "主屏"; win.ServerId = "sb1"
        let sticky = PanelItem(); sticky.Id = "p1"; sticky.`Type` = .StickyNotes; sticky.Title = "便签"
        sticky.StickyNotes = [StickyNote()]
        let group = PanelItem(); group.Id = "g1"; group.`Type` = .Group; group.ServerId = "sg1"
        let child = PanelItem(); child.Id = "c1"; child.`Type` = .SignalLight
        group.ChildPanels = [child]
        let dash = PanelItem(); dash.Id = "d1"; dash.`Type` = .DataDashboard
        let di = DataDashboardItem(); di.Id = "di1"; di.VarKey = "pv"; di.Value = "42"; di.Label = "访问量"
        di.TeamId = "team-enc"
        dash.DashboardItems = [di]
        win.Panels = [sticky, group, dash]
        mgr.Windows = [win]
        let bg = DataDashboardItem(); bg.Id = "bg1"; bg.VarKey = "uv"; bg.Value = "7"
        mgr.BackgroundDashboardItems = [bg]
        let vs = VariableSet(); vs.VarKey = "total"; vs.Op = "SUM"; vs.SourceKeys = ["pv", "uv"]
        mgr.VariableSets = [vs]

        let payload = CloudSyncService.buildSyncPayload(mgr: mgr, deletedBars: ["db1"], deletedItems: ["di9"])
        let o = payload.objectValue!
        XCTAssertEqual(o["app"]?.stringValue, "SideDesk")
        XCTAssertEqual(o["syncProtocol"]?.doubleValue, 2, "必须显式声明协议版本（空墓碑列表也不能退回首缺席对账）")
        XCTAssertNil(o["corpId"], "个人模式 corpId 省略")
        XCTAssertEqual(o["deletedBars"]?.arrayValue?.compactMap { $0.stringValue }, ["db1"])
        XCTAssertEqual(o["deletedItems"]?.arrayValue?.compactMap { $0.stringValue }, ["di9"])
        XCTAssertFalse((o["syncedAt"]?.stringValue ?? "").isEmpty)

        let bars = o["bars"]!.arrayValue!
        XCTAssertEqual(bars.count, 1)
        let bar = bars[0].objectValue!
        XCTAssertEqual(bar["localId"]?.stringValue, "bar1")
        XCTAssertEqual(bar["serverId"]?.stringValue, "sb1")
        XCTAssertNil(bar["ownerType"], "personal 归属省略（与 C# NullValueHandling.Ignore 一致）")
        let items = bar["items"]!.arrayValue!
        XCTAssertEqual(items.count, 3)
        let groupItem = items.first { $0.objectValue?["localId"]?.stringValue == "g1" }!.objectValue!
        XCTAssertEqual(groupItem["items"]?.arrayValue?.count, 1, "group 子项展开一层")
        let stickyItem = items.first { $0.objectValue?["localId"]?.stringValue == "p1" }!.objectValue!
        XCTAssertNil(stickyItem["data"]?.objectValue?["StickyNotes"], "行列表不进 itemData")

        // 变量：面板项（带团队加密串）+ 后台项；数据项配置全量；变量集
        let vars = o["variables"]!.arrayValue!
        XCTAssertEqual(vars.count, 2)
        XCTAssertEqual(vars.first?.objectValue?["corpId"]?.stringValue, "team-enc")
        XCTAssertEqual(o["dataItems"]?.arrayValue?.count, 2)
        let sets = o["variableSets"]!.arrayValue!
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].objectValue?["op"]?.stringValue, "SUM")
        XCTAssertEqual(sets[0].objectValue?["sourceKeys"]?.arrayValue?.count, 2)
    }

    func testBuildSyncPayloadDedupsSharedServerIdAcrossWindows() {
        let mgr = WindowConfigManager()
        let w1 = WindowConfig(); w1.Id = "w1"; w1.ServerId = "sb1"
        let p1 = PanelItem(); p1.Id = "orig"; p1.`Type` = .StickyNotes; p1.ServerId = "shared"
        w1.Panels = [p1]
        let w2 = WindowConfig(); w2.Id = "w2"; w2.ServerId = "sb2"
        let p2 = PanelItem(); p2.Id = "imported"; p2.`Type` = .StickyNotes; p2.ServerId = "shared"
        w2.Panels = [p2]
        mgr.Windows = [w1, w2]

        let payload = CloudSyncService.buildSyncPayload(mgr: mgr, deletedBars: [], deletedItems: [])
        let bars = payload.objectValue!["bars"]!.arrayValue!
        XCTAssertEqual(bars[0].objectValue?["items"]?.arrayValue?.count, 1, "首个窗口保留")
        XCTAssertEqual(bars[1].objectValue?["items"]?.arrayValue?.count, 0, "同 ServerId 模块在后续窗口跳过")
    }

    func testBuildItemDataExcludesMetadataAndRowLists() {
        let p = PanelItem(); p.Id = "p"; p.ServerId = "s"; p.`Type` = .StickyNotes
        p.Title = "T"; p.BGColor = "#fff"; p.GroupBGColor = "#eee"
        p.StickyNotes = [StickyNote()]
        p.DashboardColumns = 2
        p.OwnerType = "team"; p.TeamId = "t1"; p.TeamName = "团队"
        let data = CloudSyncService.buildItemData(p).objectValue!
        for k in ["Id", "ServerId", "Type", "Title", "BGColor", "GroupBGColor", "ChildPanels",
                  "StickyNotes", "DeskNotes", "TodoItems", "Pomodoro", "DashboardItems", "CheckInItems"] {
            XCTAssertNil(data[k], "itemData 不应含 \(k)")
        }
        XCTAssertEqual(data["DashboardColumns"]?.doubleValue, 2)
        XCTAssertEqual(data["OwnerType"]?.stringValue, "team", "归属随 itemData 上传")
        XCTAssertEqual(data["TeamId"]?.stringValue, "t1")
        XCTAssertTrue(data.values.allSatisfy { $0 != .null }, "null 属性剔除")
    }

    func testApplyServerIdMappingsWritesMapAndModels() {
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar1"
        let p = PanelItem(); p.Id = "p1"; p.`Type` = .StickyNotes
        let group = PanelItem(); group.Id = "g1"; group.`Type` = .Group
        let child = PanelItem(); child.Id = "c1"; child.`Type` = .SignalLight
        group.ChildPanels = [child]
        win.Panels = [p, group]
        mgr.Windows = [win]

        let data = CloudSyncService.parseJSON(#"{"bars":[{"localId":"bar1","serverId":"sb1"}],"items":[{"localId":"p1","serverId":"si1"}],"groups":[{"localId":"c1","serverId":"sg1"}]}"#)
        CloudSyncService.applyServerIdMappings(data: data, settings: Seam.settings, mgr: mgr)
        XCTAssertEqual(win.ServerId, "sb1")
        XCTAssertEqual(p.ServerId, "si1")
        XCTAssertEqual(child.ServerId, "sg1", "group 一层子项也能按 localId 找到")
        XCTAssertEqual(Seam.settings.CloudIdMap["local:bar1"], "sb1", "映射 key 带作用域前缀")
        XCTAssertEqual(Seam.settings.CloudIdMap["local:p1"], "si1")
        // 无 data 静默跳过
        CloudSyncService.applyServerIdMappings(data: nil, settings: Seam.settings, mgr: mgr)
    }

    // MARK: - 结构拉取

    func testPullAndMergeStructureClaimsRestoresAndSkipsTeam() async {
        let mgr = WindowConfigManager()
        let local = WindowConfig(); local.Id = "local-bar"; local.Name = "Home"
        mgr.Windows = [local]
        mgr.LeftDock.WindowIds = [local.Id]; mgr.RightDock.WindowIds = [local.Id]
        let backend = FakeBackend()
        backend.routes["sync/pull"] = #"""
        {"code":200,"data":{"bars":[
          {"serverId":"sb-home","title":"Home","items":[{"serverId":"si-1","itemType":"StickyNotes","title":"便签"}]},
          {"serverId":"sb-team","title":"团队窗","ownerType":"team","items":[{"serverId":"si-team","itemType":"TodoList"}]},
          {"serverId":"sb-new","title":"云端窗","items":[]}
        ]}}
        """#
        let svc = service(backend)
        var newPanels: [PanelItem] = []
        var pulled = Set<String>()
        let changed = await svc.pullAndMergeStructure(mgr: mgr, settings: Seam.settings,
                                                      newPanelsOut: &newPanels, pulledItemServerIdsOut: &pulled)
        XCTAssertTrue(changed)
        XCTAssertEqual(local.ServerId, "sb-home", "同名未同步窗口被认领而非重复新建")
        XCTAssertEqual(local.Panels.count, 1)
        XCTAssertEqual(local.Panels.first?.ServerId, "si-1")
        XCTAssertEqual(mgr.Windows.count, 2, "团队窗口不自动创建；个人新窗口补齐")
        XCTAssertEqual(mgr.Windows.last?.ServerId, "sb-new")
        XCTAssertEqual(newPanels.count, 1)
        XCTAssertTrue(pulled.contains("si-team"), "团队模块 ServerId 仍收集（供共享清理判断归属）")
        let newWinId = mgr.Windows.last!.Id
        XCTAssertTrue(mgr.LeftDock.WindowIds.contains(newWinId) && mgr.RightDock.WindowIds.contains(newWinId),
                      "新建窗口自动入双侧 dock；认领窗口只回写 ServerId 不动 dock（与 C# 一致）")
    }

    func testPullAndMergeStructureTombstoneImmunity() async {
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "bar-del"; win.ServerId = "sb-del"
        let p = PanelItem(); p.Id = "item-del"; p.ServerId = "si-del"; p.`Type` = .StickyNotes
        win.Panels = [p]
        mgr.Windows = [win]
        mgr.Save() // 落库
        mgr.Windows = []
        mgr.Save() // 缺席 → 打墓碑
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertEqual(tomb.bars, ["sb-del"])
        XCTAssertEqual(tomb.items, ["si-del"])

        let backend = FakeBackend()
        backend.routes["sync/pull"] = #"""
        {"code":200,"data":{"bars":[
          {"serverId":"sb-del","title":"已删窗口","items":[{"serverId":"si-del","itemType":"StickyNotes"}]},
          {"serverId":"sb-new","title":"新窗口","items":[]}
        ]}}
        """#
        let svc = service(backend)
        var newPanels: [PanelItem] = []
        var pulled = Set<String>()
        let changed = await svc.pullAndMergeStructure(mgr: mgr, settings: Seam.settings,
                                                      newPanelsOut: &newPanels, pulledItemServerIdsOut: &pulled)
        XCTAssertTrue(changed)
        XCTAssertEqual(mgr.Windows.count, 1, "已打墓碑的窗口不接受服务端回灌复活")
        XCTAssertEqual(mgr.Windows.first?.ServerId, "sb-new")
        XCTAssertTrue(newPanels.isEmpty)
    }

    func testApplyItemDataToPanelAppliesSettingsOnly() {
        let p = PanelItem(); p.`Type` = .StickyNotes; p.Title = "旧"
        let note = StickyNote(); note.Content = "本地行"
        p.StickyNotes = [note]
        let originalId = p.Id
        let data = CloudSyncService.parseJSON(#"{"Title":"新","DashboardColumns":3,"OwnerType":"team","TeamId":"t1","Id":"hack","StickyNotes":[{"Id":"x","Content":"回灌"}],"PanelHeight":null}"#)!
        XCTAssertTrue(CloudSyncService.applyItemDataToPanel(p, data))
        XCTAssertEqual(p.Title, "新")
        XCTAssertEqual(p.DashboardColumns, 3)
        XCTAssertEqual(p.OwnerType, "team", "归属字段随 itemData 应用（C# 反射不排除）")
        XCTAssertEqual(p.TeamId, "t1")
        XCTAssertEqual(p.Id, originalId, "身份元数据以本地为准")
        XCTAssertEqual(p.StickyNotes?.count, 1)
        XCTAssertEqual(p.StickyNotes?.first?.Content, "本地行", "行列表不被服务端旧快照回灌")
        XCTAssertFalse(CloudSyncService.applyItemDataToPanel(p, data), "相同数据再应用无变化")
    }

    // MARK: - 行级推送

    func testRowPushDiffAndDeleteAddressing() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "w"; win.ServerId = "sb"
        let a = todo("a", "old"); let b = todo("b", "b"); let c = todo("c", "c")
        let p = todoPanel("p1", serverId: "si", [a, b, c])
        win.Panels = [p]; mgr.Windows = [win]
        register(mgr)
        let backend = FakeBackend()
        let svc = service(backend)
        // 快照 = 当前全量序列化（保证未改行 b 的序列化形态一致）
        let snap = CloudSyncService.getListDataJson(p)!
        svc.setSnapshot(snap, for: "p1")
        // c 已同步过：缓存服务端主键 → 删除走主键寻址
        LocalDbService.saveRowServerIds([(rowUid: "c", rowServerId: "rc", dataServerId: nil)])

        // 变更：a 改文本、c 删除、d 新增；b 不动
        a.Text = "new"
        p.TodoItems = [a, b, todo("d", "d")]
        await svc.pushAllRows(mgr: mgr, settings: Seam.settings)

        let push = backend.requests.first { $0.path.hasSuffix("item-row/push") }
        XCTAssertNotNil(push)
        let body = push!.body!.objectValue!
        XCTAssertEqual(body["itemServerId"]?.stringValue, "si")
        let rows = body["rows"]!.arrayValue!
        XCTAssertEqual(Set(rows.compactMap { $0.objectValue?["rowId"]?.stringValue }), ["a", "d"], "未改行 b 不推送")
        XCTAssertEqual(rows.first?.objectValue?["rowType"]?.stringValue, "todo")
        XCTAssertEqual(body["deletedRowServerIds"]?.arrayValue?.compactMap { $0.stringValue }, ["rc"], "已缓存行按服务端主键删")
        XCTAssertEqual(body["deletedRowIds"]?.arrayValue?.count, 0)
    }

    func testRowPushBizFailureKeepsSnapshotForRetry() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.ServerId = "sb"
        let p = todoPanel("p1", serverId: "si", [todo("a", "old")])
        win.Panels = [p]; mgr.Windows = [win]
        register(mgr)
        let backend = FakeBackend()
        backend.routes["item-row/push"] = #"{"code":500,"msg":"无权操作此模块"}"#
        let svc = service(backend)
        let snap = CloudSyncService.getListDataJson(p)!
        svc.setSnapshot(snap, for: "p1")
        p.TodoItems = [todo("a", "new")]
        await svc.pushAllRows(mgr: mgr, settings: Seam.settings)
        XCTAssertEqual(svc.snapshot(for: "p1"), snap, "业务失败不更新快照，下次基于原快照重算差异重试")
    }

    func testRowPushSuccessUpdatesSnapshot() async {
        login()
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.ServerId = "sb"
        let p = todoPanel("p1", serverId: "si", [todo("a", "a")])
        win.Panels = [p]; mgr.Windows = [win]
        register(mgr)
        let svc = service(FakeBackend())
        svc.setSnapshot("[]", for: "p1")
        await svc.pushAllRows(mgr: mgr, settings: Seam.settings)
        XCTAssertEqual(svc.snapshot(for: "p1"), CloudSyncService.getListDataJson(p))
        // 再推一次：快照相同 → 静默跳过（无新请求）
        let backend2 = FakeBackend()
        let svc2 = service(backend2)
        svc2.setSnapshot(CloudSyncService.getListDataJson(p)!, for: "p1")
        await svc2.pushAllRows(mgr: mgr, settings: Seam.settings)
        XCTAssertTrue(backend2.requests.isEmpty, "快照无变化不产生请求")
    }

    // MARK: - 行级拉取

    func testRowPullMergesWithSinceAndRowTypeGuard() async {
        login()
        Seam.settings.LastCloudSyncTime = Date(timeIntervalSince1970: 1_000_000)
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.ServerId = "sb"
        let p = todoPanel("p1", serverId: "si", [todo("a", "a1"), todo("b", "b")])
        win.Panels = [p]; mgr.Windows = [win]
        register(mgr)
        let backend = FakeBackend()
        backend.routes["item-row/pull"] = #"""
        {"code":200,"data":{"rows":[
          {"rowId":"a","rowType":"todo","content":{"Id":"a","Text":"a2"}},
          {"rowId":"b","rowType":"todo","deletedAt":"2026-01-01T00:00:00Z"},
          {"rowId":"x","rowType":"todo","content":{"Id":"x","Text":"new"}},
          {"rowId":"y","rowType":"sticky_note","content":{"Id":"y","Content":"跨类型残留"}}
        ]}}
        """#
        let svc = service(backend)
        await svc.pullAllRows(mgr: mgr, settings: Seam.settings)
        XCTAssertEqual(p.TodoItems?.count, 2, "改 a、删 b、增 x；跨类型行 y 被守卫跳过")
        XCTAssertEqual(Set(p.TodoItems?.map { $0.Id } ?? []), ["a", "x"])
        XCTAssertEqual(p.TodoItems?.first { $0.Id == "a" }?.Text, "a2")
        let pull = backend.requests.first { $0.path.hasSuffix("item-row/pull") }
        XCTAssertTrue(pull?.query?.contains("since=") == true, "个人模块增量拉取带 since")
    }

    func testRowPullReplaceAllRemovesInvisibleRows() async {
        login()
        let mgr = WindowConfigManager()
        register(mgr)
        let p = todoPanel("p1", serverId: "si", [todo("a", "a"), todo("b", "b")])
        let backend = FakeBackend()
        backend.routes["item-row/pull"] = #"""
        {"code":200,"data":{"rows":[{"rowId":"a","rowType":"todo","content":{"Id":"a","Text":"a"}}]}}
        """#
        let svc = service(backend)
        let changed = await svc.pullItemFull(p)
        XCTAssertTrue(changed)
        XCTAssertEqual(p.TodoItems?.map { $0.Id }, ["a"], "全量替换：服务端不可见的本地行移除")
        XCTAssertFalse(backend.requests.first?.query?.contains("since=") == true, "全量拉取不带 since")

        // 全量为空也要走替换（分享取消后不可见的行需从本地清除）
        backend.routes["item-row/pull"] = #"{"code":200,"data":{"rows":[]}}"#
        let changed2 = await svc.pullItemFull(p)
        XCTAssertTrue(changed2)
        XCTAssertEqual(p.TodoItems?.count, 0)
    }

    // MARK: - 内容比较 / 有序行集合

    func testRowsContentEqualsNumericAndDateTolerance() {
        let eq = CloudSyncService.rowsContentEquals
        XCTAssertTrue(eq(.int(36), .double(36.0)), "JS 数字往返 36.0→36 按数值等价")
        XCTAssertTrue(eq(.double(36.0), .int(36)))
        XCTAssertFalse(eq(.double(36.5), .int(36)))
        XCTAssertTrue(eq(.object(["a": .int(1), "b": .string("x")]), .object(["b": .string("x"), "a": .int(1)])), "对象键序无关")
        XCTAssertFalse(eq(.array([.int(1), .int(2)]), .array([.int(2), .int(1)])), "数组按位比较")
        // 日期串：C# "o" 带小数秒 vs Swift iso8601 不带——同一整秒判等，防两端互相改写格式乒乓
        XCTAssertTrue(eq(.string("2026-01-01T00:00:00.1234567Z"), .string("2026-01-01T00:00:00Z")))
        XCTAssertFalse(eq(.string("2026-01-01T00:00:01Z"), .string("2026-01-01T00:00:00Z")))
        XCTAssertTrue(eq(.string("hello"), .string("hello")))
        XCTAssertFalse(eq(.string("hello"), .string("world")))
        XCTAssertTrue(eq(.null, .null))
        XCTAssertFalse(eq(.null, .string("")))
    }

    func testOrderedRowsInsertionOrderAndLastWins() {
        let arr = CloudSyncService.parseJSON(#"[{"Id":"a","v":1},{"Id":"b","v":2},{"Id":"a","v":3},{"id":"c","v":4},{"Id":""}]"#)!.arrayValue!
        var rows = CloudSyncService.OrderedRows(array: arr)
        XCTAssertEqual(rows.keys, ["a", "b", "c"], "位置保持首次插入序；小写 id 兜底；空键跳过")
        XCTAssertEqual(rows["a"]?.objectValue?["v"]?.doubleValue, 3, "同 id 后值覆盖前值")
        rows["b"] = nil
        XCTAssertEqual(rows.keys, ["a", "c"])
        rows["d"] = .object(["Id": .string("d")])
        XCTAssertEqual(rows.keys, ["a", "c", "d"])
        XCTAssertEqual(rows.count, 3)
    }

    // MARK: - 失效共享清理

    func testCleanupRevokedSharesHardDeletesWithoutTombstones() async {
        login()
        let mgr = WindowConfigManager()
        // 导入的引用窗口（SourceBarId 指向分享者源窗口）
        let imported = WindowConfig(); imported.Id = "w-imported"; imported.SourceBarId = "sb-shared"
        let sharedPanel = PanelItem(); sharedPanel.Id = "p-src"; sharedPanel.ServerId = "si-src"; sharedPanel.`Type` = .StickyNotes
        imported.Panels = [sharedPanel]
        // 个人窗口：自己的云端模块保留，失效共享残留移除
        let mine = WindowConfig(); mine.Id = "w-mine"
        let myPanel = PanelItem(); myPanel.Id = "p-mine"; myPanel.ServerId = "si-mine"; myPanel.`Type` = .StickyNotes
        let orphan = PanelItem(); orphan.Id = "p-gone"; orphan.ServerId = "si-gone"; orphan.`Type` = .TodoList
        mine.Panels = [myPanel, orphan]
        mgr.Windows = [imported, mine]
        mgr.Save() // 先落库，清理后验证硬删无墓碑

        let backend = FakeBackend()
        backend.routes["share/imports/mine"] = #"{"code":200,"data":[]}"#
        let svc = service(backend)
        let changed = await svc.cleanupRevokedShares(mgr: mgr, settings: Seam.settings, structureItemIds: ["si-mine"])
        XCTAssertTrue(changed)
        XCTAssertEqual(mgr.Windows.count, 1, "失效引用窗口整个移除")
        XCTAssertEqual(mgr.Windows.first?.Id, "w-mine")
        XCTAssertEqual(mgr.Windows.first?.Panels.map { $0.Id }, ["p-mine"])
        let tomb = LocalDbService.loadPendingDeleteTombstones()
        XCTAssertFalse(tomb.items.contains("si-gone"), "引用行硬删不打墓碑（防误删源模块）")
        XCTAssertFalse(tomb.items.contains("si-src"))
    }

    func testCleanupSkippedWhenStructurePullFailed() async {
        login()
        let mgr = WindowConfigManager()
        let imported = WindowConfig(); imported.Id = "w-imported"; imported.SourceBarId = "sb-shared"
        mgr.Windows = [imported]
        let backend = FakeBackend()
        let svc = service(backend)
        // structureItemIds 为空 = 结构拉取失败：无法判断归属，一律不清理
        let changed = await svc.cleanupRevokedShares(mgr: mgr, settings: Seam.settings, structureItemIds: [])
        XCTAssertFalse(changed)
        XCTAssertEqual(mgr.Windows.count, 1)
        XCTAssertTrue(backend.requests.isEmpty, "结构拉取失败时不发导入记录请求")
    }

    // MARK: - 设置项同步

    /// 白名单全量上传 + 敏感字段加密 + C# 线格式（Bool "True"/"False"、数字无 ".0" 尾）
    func testSettingsSyncUploadsWhitelistWithEncryption() async {
        login()
        let s = Seam.settings
        s.ThemeMode = "Light"
        s.BackgroundOpacity = 62.5
        s.ShowNotificationStrip = false
        s.BaiduPanAccessToken = "pan-at"
        s.BaiduPanRefreshToken = "pan-rt"
        s.BaiduPanTokenExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        s.SyncDerivedKey = SyncEncryption.protectKeyForLocal(key)
        s.SyncEncryptEnabled = true

        let backend = FakeBackend()
        await service(backend).syncSettingsUpload(s)
        let req = backend.requests.first { $0.path.hasSuffix("setting/sync") }
        XCTAssertNotNil(req)
        let items = req!.body!.objectValue!["settings"]!.arrayValue!
        XCTAssertEqual(items.count, 9, "白名单 9 项全量")
        var byKey: [String: [String: JSONValue]] = [:]
        for it in items {
            let o = it.objectValue!
            byKey[o["key"]!.stringValue!] = o
        }
        XCTAssertEqual(byKey["general.theme_mode"]?["value"]?.stringValue, "Light")
        XCTAssertEqual(byKey["general.background_opacity"]?["value"]?.stringValue, "62.5")
        XCTAssertEqual(byKey["general.show_notification"]?["value"]?.stringValue, "False", "C# bool.ToString() 线格式")
        XCTAssertEqual(byKey["general.enable_auto_update"]?["value"]?.stringValue, "True")
        XCTAssertEqual(byKey["general.data_connection"]?["value"]?.stringValue, "extension")
        let at = byKey["baidu_pan.access_token"]!
        XCTAssertEqual(at["isEncrypted"]?.doubleValue, 1)
        XCTAssertTrue(SyncEncryption.isEncrypted(at["value"]?.stringValue))
        XCTAssertEqual(SyncEncryption.decrypt(at["value"]!.stringValue!, key: key), "pan-at")
        XCTAssertEqual(byKey["baidu_pan.refresh_token"]?["isEncrypted"]?.doubleValue, 1)
        XCTAssertEqual(byKey["baidu_pan.token_expiry"]?["isEncrypted"]?.doubleValue, 0, "过期时间非敏感")
        XCTAssertEqual(byKey["baidu_pan.token_expiry"]?["category"]?.stringValue, "cloud_drive")
        XCTAssertNotNil(s.LastSettingsSyncTime, "成功后记录同步时间")
    }

    func testSettingsSyncWithoutKeyUploadsPlaintext() async {
        login()
        Seam.settings.BaiduPanAccessToken = "pan-at"
        let backend = FakeBackend()
        await service(backend).syncSettingsUpload(Seam.settings)
        let items = backend.requests.first!.body!.objectValue!["settings"]!.arrayValue!
        var byKey: [String: [String: JSONValue]] = [:]
        for it in items {
            let o = it.objectValue!
            byKey[o["key"]!.stringValue!] = o
        }
        XCTAssertEqual(byKey["baidu_pan.access_token"]?["value"]?.stringValue, "pan-at", "未启用加密同步上传明文")
        XCTAssertEqual(byKey["baidu_pan.access_token"]?["isEncrypted"]?.doubleValue, 0)
        XCTAssertEqual(byKey["general.background_opacity"]?["value"]?.stringValue, "50", "整数透明度不带 .0 尾（C# ToString 口径）")
    }

    func testRestoreSettingsAppliesAndDecrypts() async {
        login()
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        let s = Seam.settings
        s.SyncDerivedKey = SyncEncryption.protectKeyForLocal(key)
        s.SyncEncryptEnabled = true
        let enc = SyncEncryption.encrypt("pan-secret", key: key)!
        let wrongKey = SyncEncryption.deriveKey(password: "other", userId: "u1")!
        let bad = SyncEncryption.encrypt("cannot-decrypt", key: wrongKey)!
        let backend = FakeBackend()
        backend.routes["setting/list"] = """
        {"code":200,"data":[
          {"key":"general.theme_mode","value":"Light","isEncrypted":0},
          {"key":"general.background_opacity","value":"62.5","isEncrypted":0},
          {"key":"general.show_notification","value":"False","isEncrypted":0},
          {"key":"baidu_pan.access_token","value":"\(enc)","isEncrypted":1},
          {"key":"baidu_pan.refresh_token","value":"\(bad)","isEncrypted":1},
          {"key":"unknown.key","value":"x","isEncrypted":0}
        ]}
        """
        let count = await service(backend).restoreSettings()
        XCTAssertEqual(count, 5, "解密失败跳过该项；未知 key 按 C# 口径仍计数")
        XCTAssertEqual(s.ThemeMode, "Light")
        XCTAssertEqual(s.BackgroundOpacity, 62.5)
        XCTAssertFalse(s.ShowNotificationStrip)
        XCTAssertEqual(s.BaiduPanAccessToken, "pan-secret")
        XCTAssertNil(s.BaiduPanRefreshToken, "解不开的不写回")
    }

    func testRestoreSettingsGuards() async {
        let backend = FakeBackend()
        let svc = service(backend)
        let n = await svc.restoreSettings()
        XCTAssertEqual(n, -1, "未登录返回 -1")
        XCTAssertTrue(backend.requests.isEmpty)
        login()
        backend.routes["setting/list"] = #"{"code":500,"msg":"boom"}"#
        let n2 = await svc.restoreSettings()
        XCTAssertEqual(n2, -1, "业务失败返回 -1")
    }

    func testUploadStructureAppendsSettingsSync() async {
        login()
        let mgr = WindowConfigManager()
        register(mgr)
        let backend = FakeBackend()
        let ok = await service(backend).uploadStructure(settings: Seam.settings, mgr: mgr)
        XCTAssertTrue(ok)
        XCTAssertTrue(backend.requests.contains { $0.path.hasSuffix("setting/sync") },
                      "结构上传成功后追加设置项同步（C# UploadStructureAsync 尾步）")
    }

    // MARK: - 资源排序

    func testPushResourcePosFiltersEmptyAndKeepsFilteredIndex() async {
        login()
        let backend = FakeBackend()
        await service(backend).pushResourcePos(resourceType: "row", serverIds: ["a", "", "b"], corpId: "team-enc")
        let req = backend.requests.first { $0.path.hasSuffix("resource-pos/save") }
        XCTAssertNotNil(req)
        let o = req!.body!.objectValue!
        XCTAssertEqual(o["resourceType"]?.stringValue, "row")
        XCTAssertEqual(o["corpId"]?.stringValue, "team-enc", "团队加密串透传")
        let items = o["items"]!.arrayValue!
        XCTAssertEqual(items.count, 2, "空 id 过滤")
        XCTAssertEqual(items[0].objectValue?["resourceServerId"]?.stringValue, "a")
        XCTAssertEqual(items[0].objectValue?["posInx"]?.doubleValue, 0)
        XCTAssertEqual(items[1].objectValue?["resourceServerId"]?.stringValue, "b")
        XCTAssertEqual(items[1].objectValue?["posInx"]?.doubleValue, 1, "posInx 是过滤后的序号（C# Where→Select 口径）")

        Seam.settings.AccountToken = nil
        let backend2 = FakeBackend()
        await service(backend2).pushResourcePos(resourceType: "bar", serverIds: ["x"])
        XCTAssertTrue(backend2.requests.isEmpty, "未登录不发请求")
    }
}