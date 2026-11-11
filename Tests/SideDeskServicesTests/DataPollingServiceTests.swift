import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 假计时器：由测试手动触发 tick（避免真实等待轮询间隔）
private final class FakeTimer: ServiceTimer {
    let action: () -> Void
    let interval: TimeInterval
    var started = false
    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }
    func start() { started = true }
    func stop() { started = false }
}

/// 假取数引擎：记录调用、返回预设值（同时充当扩展引擎，故带上任务下发/应答接口）
private final class FakeEngine: ExtensionEngine {
    var next: String? = "--"
    private(set) var calls: [String] = []
    private(set) var forceFlags: [Bool] = []
    private(set) var budgetResets: [String] = []
    private(set) var orphanArgs: [(groupKeys: Set<String>, urls: Set<String>)] = []
    private(set) var didShutdown = false
    private(set) var pushCount = 0

    func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String? {
        calls.append(item.Label)
        forceFlags.append(forceLaunch)
        return next
    }
    func resetLaunchBudget(for item: DataDashboardItem) { budgetResets.append(item.Id) }
    func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>) {
        orphanArgs.append((liveGroupKeys, liveUrls))
    }
    func shutdown() { didShutdown = true }
    func pushTasks() { pushCount += 1 }
    func handleFetchResult(requestId: String?, varKey: String?, success: Bool, value: String?, error: String?) {}
    func extensionRegistered(_ clientId: String) {}
}

/// A1 验收：数据轮询服务核心（身份去重、配置同步、定时器重建、手动值优先、
/// 值广播同步重复实例、连接状态、作用域晋升应用）。
final class DataPollingServiceTests: XCTestCase {

    private var dir: String!
    private var timers: [FakeTimer] = []
    private var svc: DataPollingService!
    private var store: ManualVariableStore!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-poll-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
        Settings.DirOverride = dir
        Seam.resetSettings()

        timers = []
        Seam.timerFactory = { [weak self] interval, action in
            let t = FakeTimer(interval: interval, action: action)
            self?.timers.append(t)
            return t
        }
        // 默认按 CDP 模式跑（Settings 缺省是 "extension"，测试里按需改）
        var cdp = Settings()
        cdp.DataConnectionMode = "cdp"
        Seam.settings = cdp
        store = ManualVariableStore()
        svc = DataPollingService()
        svc.manualStore = store
    }

    override func tearDown() {
        Seam.timerFactory = { BackgroundTimer(interval: $0, action: $1) }
        Seam.resetSettings()
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        Settings.DirOverride = nil
        Seam.resetSettings()
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func makeItem(label: String, tpl: String = "t1", url: String = "https://a.com",
                          selector: String = ".n", browser: String? = nil, profile: String? = nil,
                          varKey: String? = nil, apiMethod: String? = nil, group: String? = nil) -> DataDashboardItem {
        let i = DataDashboardItem()
        i.Label = label
        i.TemplateId = tpl
        i.TargetUrl = url
        i.Selector = selector
        i.BrowserId = browser
        i.ProfileId = profile
        i.VarKey = varKey
        i.ApiMethod = apiMethod
        i.DashboardGroupId = group
        return i
    }

    private func configs(with items: [DataDashboardItem], background: [DataDashboardItem] = []) -> WindowConfigManager {
        let mgr = WindowConfigManager()
        let win = WindowConfig()
        let panel = PanelItem()
        panel.DashboardItems = items
        win.Panels = [panel]
        mgr.Windows = [win]
        mgr.BackgroundDashboardItems = background
        return mgr
    }

    // MARK: - 身份与去重

    func testIdentityIgnoresVarKeyAndLabel() {
        let a = makeItem(label: "A", varKey: "x.count")
        let b = makeItem(label: "B", varKey: nil)
        XCTAssertEqual(DataPollingService.getItemIdentity(a), DataPollingService.getItemIdentity(b),
                       "变量名与标签不参与身份：同一张卡片")

        let c = makeItem(label: "A", browser: "chrome")
        XCTAssertNotEqual(DataPollingService.getItemIdentity(a), DataPollingService.getItemIdentity(c),
                          "浏览器不同则身份不同")
    }

    func testSyncFromConfigsDedupsAndFlagsDuplicates() {
        let dup1 = makeItem(label: "first", varKey: "v1")
        let dup2 = makeItem(label: "second", varKey: "v2")
        let other = makeItem(label: "other", url: "https://b.com")
        svc.syncFromConfigs(configs(with: [dup1, dup2, other]))

        XCTAssertEqual(svc.getAllItems().count, 2, "同一数据卡片只保留一个轮询实例")
        XCTAssertTrue(svc.isDuplicateSource(makeItem(label: "probe")))
        XCTAssertFalse(svc.isDuplicateSource(makeItem(label: "probe", url: "https://c.com")))
    }

    func testSyncPromotesRepresentativeWhenFirstHasNoVarKey() {
        // 代表实例没变量、后到成员有变量 → 提升为代表，保证按变量名可查到该卡片
        let noVar = makeItem(label: "noVar")
        let withVar = makeItem(label: "withVar", varKey: "found.me")
        svc.syncFromConfigs(configs(with: [noVar, withVar]))

        XCTAssertEqual(svc.findItem(byVarKey: "found.me")?.Label, "withVar")
        XCTAssertEqual(svc.getAllItems().count, 1)
    }

    func testSyncSkipsReferenceItems() {
        let source = makeItem(label: "source", varKey: "src")
        let ref = makeItem(label: "ref")
        ref.RefVarKey = "src"      // 引用项仅展示、不轮询
        svc.syncFromConfigs(configs(with: [source, ref]))
        XCTAssertEqual(svc.getAllItems().count, 1)
        XCTAssertNil(svc.findItem(byVarKey: nil))
    }

    // MARK: - 定时器

    func testRebuildTimersUsesMinIntervalAndOnePerDedupedSource() {
        let a = makeItem(label: "a")
        a.RefreshIntervalSeconds = 1          // 钳到 10 秒
        let b = makeItem(label: "b", url: "https://b.com")
        b.RefreshIntervalSeconds = 300
        let dup = makeItem(label: "dup-of-a")
        svc.syncFromConfigs(configs(with: [a, b, dup]))

        XCTAssertEqual(timers.count, 2, "每个去重后数据源一个定时器")
        XCTAssertTrue(timers.allSatisfy { $0.started })
        XCTAssertEqual(timers.map { $0.interval }.sorted(), [10.0, 300.0])

        // 重配置后旧定时器全部停掉、不泄漏
        let previous = timers
        svc.syncFromConfigs(configs(with: [a]))
        XCTAssertTrue(previous.allSatisfy { !$0.started }, "重配置应停掉旧定时器")
        XCTAssertEqual(timers.count, 3)
        XCTAssertEqual(timers.filter { $0.started }.count, 1)
    }

    func testTimerTickSkipsWhenPreviousPollStillRunning() async throws {
        let item = makeItem(label: "slow")
        item.RefreshIntervalSeconds = 10
        svc.syncFromConfigs(configs(with: [item]))
        let timer = try XCTUnwrap(timers.first)

        // 第一次轮询卡在 await 中：第二次 tick 应被防重叠跳过
        let hold = Semaphore()
        svc.cdpEngine = BlockingEngine(hold: hold)
        timer.action()
        timer.action()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(BlockingEngine.entered, 1)

        hold.release()
        try await Task.sleep(nanoseconds: 120_000_000)
        timer.action()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(BlockingEngine.entered, 2, "上一轮结束后可再次轮询")
        BlockingEngine.reset()
    }

    // MARK: - 模式分流与值广播

    func testPollRoutesByMode() async {
        let api = FakeEngine(); api.next = "9"
        let ext = FakeEngine(); ext.next = "8"
        let cdp = FakeEngine(); cdp.next = "7"
        svc.apiEngine = api
        svc.extensionEngine = ext
        svc.cdpEngine = cdp

        let apiItem = makeItem(label: "api", apiMethod: "GET")
        let pageItem = makeItem(label: "page")
        let cfg = configs(with: [apiItem, pageItem])
        svc.syncFromConfigs(cfg)

        var extMode = Settings()
        extMode.DataConnectionMode = "extension"
        Seam.settings = extMode
        await svc.poll(apiItem, forceLaunch: false)
        await svc.poll(pageItem, forceLaunch: false)
        XCTAssertEqual(api.calls, ["api"])
        XCTAssertEqual(ext.calls, ["page"], "extension 模式下页面项走扩展引擎")

        var cdpMode = Settings()
        cdpMode.DataConnectionMode = "cdp"
        Seam.settings = cdpMode
        await svc.poll(pageItem, forceLaunch: true)
        XCTAssertEqual(cdp.calls, ["page"])
        XCTAssertEqual(cdp.forceFlags, [true])
        XCTAssertEqual(cdp.budgetResets, [pageItem.Id], "手动刷新重置自动启动预算")
    }

    func testUpdateBroadcastsToAllDuplicateInstances() {
        let a = makeItem(label: "a", varKey: "shared")
        let b = makeItem(label: "b")   // 与 a 同一数据卡片
        var groupIds: [String] = []
        svc.addDataUpdatedObserver { id, value in groupIds.append(id); _ = value }
        svc.syncFromConfigs(configs(with: [a, b]))

        svc.updateItemValue(a, "42")
        XCTAssertEqual(b.Value, "42", "重复实例值同步，保证多窗口面板一起刷新")
        XCTAssertEqual(Set(groupIds), Set([a.Id, b.Id]))
    }

    /// 事件为多播（对应 C# `DataUpdated +=`）：后订阅的一方不会顶掉先订阅的。
    func testDataUpdatedObserversAreAdditive() {
        let item = makeItem(label: "solo")
        var first: [String] = []
        var second: [String] = []
        svc.addDataUpdatedObserver { id, _ in first.append(id) }
        svc.addDataUpdatedObserver { id, _ in second.append(id) }
        svc.syncFromConfigs(configs(with: [item]))

        svc.updateItemValue(item, "1")
        XCTAssertEqual(first, [item.Id])
        XCTAssertEqual(second, [item.Id])
    }

    func testEngineReturningNilKeepsCurrentValue() async {
        let engine = FakeEngine(); engine.next = nil
        svc.cdpEngine = engine
        let item = makeItem(label: "keep")
        item.Value = "旧值"
        svc.syncFromConfigs(configs(with: [item]))
        await svc.poll(item, forceLaunch: false)
        XCTAssertEqual(item.Value, "旧值", "扩展未连接/超时属正常等待，不清零")
    }

    // MARK: - 手动值优先

    func testManualValueShortCircuitsPollAndReappliesAfterSync() async {
        let engine = FakeEngine(); engine.next = "polled"
        svc.cdpEngine = engine
        let item = makeItem(label: "m", varKey: "my.var")
        svc.syncFromConfigs(configs(with: [item]))

        XCTAssertTrue(svc.setVariableValue("my.var", "manual"))
        XCTAssertEqual(item.Value, "manual")
        XCTAssertTrue(engine.calls.isEmpty, "设置手动值时已即时生效，无需轮询")

        await svc.poll(item, forceLaunch: false)
        XCTAssertEqual(item.Value, "manual", "手动值优先于轮询结果")
        XCTAssertTrue(engine.calls.isEmpty)

        // 配置重建后手动值重新应用
        let item2 = makeItem(label: "m", varKey: "my.var")
        svc.syncFromConfigs(configs(with: [item2]))
        XCTAssertEqual(item2.Value, "manual")

        XCTAssertTrue(svc.clearVariableValue("my.var"))
        await svc.poll(item2, forceLaunch: false)
        XCTAssertEqual(item2.Value, "polled")
    }

    func testSetVariableValueWithoutRunningItemStillRecords() {
        XCTAssertFalse(svc.setVariableValue("later.var", "5"), "暂无同名运行变量：值仍记录，返回 false")
        XCTAssertEqual(store.get("later.var"), "5")
        let snapshot = svc.getVariableSnapshot()
        XCTAssertEqual(snapshot.first { $0.varKey == "later.var" }?.manual, true)
        XCTAssertEqual(snapshot.first { $0.varKey == "later.var" }?.value, "5")
    }

    func testSnapshotIncludesVariableSetVirtualItems() {
        let item = makeItem(label: "p", varKey: "q.a")
        item.Value = "3"
        let virtualItem = DataDashboardItem()
        virtualItem.VarKey = "q.all"
        virtualItem.Value = "6"
        svc.variableSetItemsProvider = { [virtualItem] }
        svc.syncFromConfigs(configs(with: [item]))

        let snap = svc.getVariableSnapshot()
        XCTAssertEqual(snap.map { $0.varKey }, ["q.a", "q.all"])
        XCTAssertEqual(snap.first { $0.varKey == "q.all" }?.value, "6")
    }

    // MARK: - 作用域晋升

    func testAdoptPendingLocalDataAppliesPromotedManualValues() {
        let item = makeItem(label: "a", varKey: "adopt.var")
        svc.syncFromConfigs(configs(with: [item]))
        XCTAssertEqual(item.Value, "--")

        // 未登录期间外部写入：只落到 local 作用域，尚未应用到卡片
        store.set("adopt.var", "from-offline")
        XCTAssertEqual(item.Value, "--")

        LocalDbService.accountUserIdProvider = { "cipher" }
        svc.adoptPendingLocalData()
        XCTAssertEqual(item.Value, "from-offline", "晋升的手动值应立即应用到同名变量")
        XCTAssertEqual(LocalDbService.loadDataVariables("u:cipher").count, 1)
    }

    // MARK: - 连接状态

    func testConnectionLifecycle() {
        let item = makeItem(label: "a", browser: "chrome", profile: "p1")
        XCTAssertEqual(svc.getConnectionKey(item), "chrome_p1")
        XCTAssertEqual(svc.getConnectionKey(makeItem(label: "b")), "default")
        XCTAssertEqual(svc.getItemState(item), .disconnected)

        var seen: [(String, ConnectionState)] = []
        svc.ConnectionStateChanged = { seen.append(($0, $1)) }

        let conn = svc.obtainConnection("chrome_p1")
        let session = FakeSession()
        conn.client = session
        svc.setConnectionState("chrome_p1", .connected)
        XCTAssertEqual(svc.getItemState(item), .connected)

        svc.invalidateConnection("chrome_p1")
        XCTAssertTrue(session.closed, "失效即关闭会话")
        XCTAssertEqual(svc.getItemState(item), .disconnected)

        let second = svc.obtainConnection("chrome_p1")
        let secondSession = FakeSession()
        second.client = secondSession
        svc.disconnectConnection("chrome_p1")
        XCTAssertNil(svc.getConnection("chrome_p1"))
        XCTAssertTrue(secondSession.closed)
        XCTAssertEqual(seen.map { $1 }, [ConnectionState.connected, .disconnected, .disconnected])
    }

    func testDisposeStopsTimersAndShutsDownEngines() {
        let engine = FakeEngine()
        svc.cdpEngine = engine
        let item = makeItem(label: "a")
        item.RefreshIntervalSeconds = 10
        svc.syncFromConfigs(configs(with: [item]))
        XCTAssertTrue(timers.allSatisfy { $0.started })

        svc.dispose()
        XCTAssertTrue(timers.allSatisfy { !$0.started })
        XCTAssertTrue(engine.didShutdown)
    }
}

// MARK: - 测试替身

private final class FakeSession: CdpSession {
    var closed = false
    func close() { closed = true }
}

private final class Semaphore {
    private let sem = DispatchSemaphore(value: 0)
    func wait() { sem.wait() }
    func release() { sem.signal() }
}

/// 卡住直到测试放行的引擎（用于验证防重叠）
private final class BlockingEngine: ValueEngine {
    static var entered = 0
    static func reset() { entered = 0 }
    private let hold: Semaphore
    init(hold: Semaphore) { self.hold = hold }
    func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String? {
        BlockingEngine.entered += 1
        hold.wait()
        return nil
    }
}
