import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3-3 批次验收：作用域晋升（AdoptScope）、数据变量手动值层、变量集聚合。
final class VariableSetAndScopeTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-varset-\(UUID().uuidString)"
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

    // MARK: - AdoptScope

    func testAdoptScopeMigratesLayoutAndContent() {
        // local 作用域下建 1 个 bar + 1 个便签面板 + 1 行内容 + dock 状态
        let mgr = LocalDbService.loadManager()
        let win = WindowConfig()
        win.Name = "home"
        let panel = PanelItem()
        panel.`Type` = .StickyNotes
        let note = StickyNote()
        note.Content = "晋升我"
        panel.StickyNotes = [note]
        win.Panels = [panel]
        mgr.Windows = [win]
        mgr.LeftDock.WindowIds = [win.Id]
        LocalDbService.saveManager(mgr)

        // 切到账号作用域后晋升
        LocalDbService.adoptScope(from: "local", to: "u:cipher")

        LocalDbService.accountUserIdProvider = { "cipher" }
        let promoted = LocalDbService.loadManager()
        XCTAssertEqual(promoted.Windows.count, 1, "窗口应随晋升进入账号作用域")
        XCTAssertEqual(promoted.Windows[0].Panels[0].StickyNotes?.first?.Content, "晋升我")
        XCTAssertEqual(promoted.LeftDock.WindowIds, [win.Id], "作用域化 dock 状态应采用源值")

        // 源作用域已清空
        LocalDbService.accountUserIdProvider = nil
        XCTAssertTrue(LocalDbService.loadManager().Windows.isEmpty, "晋升后 local 作用域应无数据")
    }

    func testAdoptScopeKeepsTargetDockStateAndPrunesEmptyBar() {
        // local：一个有内容的 bar + 一个兜底空 bar（无面板、无 server_id）+ 无后缀旧 dock key
        let mgr = LocalDbService.loadManager()
        let filled = WindowConfig()
        let panel = PanelItem()
        panel.`Type` = .TodoList
        panel.TodoItems = []
        filled.Panels = [panel]
        let empty = WindowConfig() // 模拟 EnsureAtLeastOneBar 的兜底空 bar
        mgr.Windows = [filled, empty]
        mgr.LeftDock.WindowIds = [filled.Id, empty.Id]
        mgr.LeftDock.ActiveIndex = 1
        LocalDbService.saveManager(mgr)
        // 目标作用域已有自己的 dock 状态（真实登录态：左=2）
        if let conn = LocalDbService.open() {
            LocalDbService.upsertState(conn, LocalDbService.scopedKey("left_dock", "u:cipher"),
                                       "{\"WindowIds\":[],\"ActiveIndex\":2}")
            conn.close()
        }

        LocalDbService.adoptScope(from: "local", to: "u:cipher")

        LocalDbService.accountUserIdProvider = { "cipher" }
        let out = LocalDbService.loadManager()
        XCTAssertEqual(out.Windows.count, 1, "兜底空 bar 不应晋升")
        XCTAssertEqual(out.LeftDock.ActiveIndex, 2, "目标作用域已有 dock 状态时不得被源值覆盖")
    }

    // MARK: - 数据变量手动值

    func testManualVariableRoundTripAndScopeIsolation() {
        let store = ManualVariableStore()
        XCTAssertNil(store.get("qoder.count"))

        store.set("qoder.count", "12")
        XCTAssertEqual(store.get("qoder.count"), "12")
        XCTAssertEqual(store.get("QODER.COUNT"), "12", "变量名大小写不敏感")

        // 落库可按作用域读回
        XCTAssertEqual(LocalDbService.loadDataVariables("local").map { $0.varKey }, ["qoder.count"])

        // 切号后未归属（local）数据"跟人走"：首次加载即晋升到新作用域
        LocalDbService.accountUserIdProvider = { "other" }
        XCTAssertEqual(store.get("qoder.count"), "12", "离线期间的变量应晋升给登录用户")
        XCTAssertTrue(LocalDbService.loadDataVariables("local").isEmpty, "晋升后 local 作用域不再保留")
        XCTAssertEqual(LocalDbService.loadDataVariables("u:other").count, 1)

        LocalDbService.accountUserIdProvider = nil
        XCTAssertNil(store.get("qoder.count"), "晋升是单向的：登出后不回落到 local")

        LocalDbService.accountUserIdProvider = { "other" }
        store.reload()
        XCTAssertTrue(store.clear("qoder.count"))
        XCTAssertFalse(store.clear("qoder.count"), "重复解除返回 false")
        XCTAssertTrue(LocalDbService.loadDataVariables("u:other").isEmpty)
    }

    func testManualVariableMigratesLegacyBlob() {
        LocalDbService.saveBusinessData("manual_var_values", "{\"old.key\":\"7\"}")
        let store = ManualVariableStore()
        XCTAssertEqual(store.get("old.key"), "7")
        XCTAssertNil(LocalDbService.loadBusinessData("manual_var_values"), "迁移后删除旧 blob")
        XCTAssertEqual(LocalDbService.loadDataVariables("local").first?.varValue, "7")
    }

    func testUpsertDataVariableKeepsCorpIdWhenNil() {
        LocalDbService.upsertDataVariable("local", "v", "1", "corp-1")
        LocalDbService.upsertDataVariable("local", "v", "2", nil)
        let rows = LocalDbService.loadDataVariables("local")
        XCTAssertEqual(rows.first?.varValue, "2")
        XCTAssertEqual(rows.first?.corpId, "corp-1", "corpId 传 nil 时保留行上已有值")
    }

    // MARK: - 变量集聚合（纯函数）

    func testResolveSourceKeysExplicitAndPattern() {
        let set = VariableSet()
        set.VarKey = "sum.all"
        set.SourceKeys = ["a", "b", "A", "sum.all"]   // 去重 + 排除自引用
        set.Pattern = "x*"
        let keys = VariableSetService.resolveSourceKeys(set, ["x1", "x2", "y1", "a"])
        XCTAssertEqual(keys, ["a", "b", "x1", "x2"])
    }

    func testComputeValueOps() {
        func running(_ pairs: [String: [String]]) -> [String: [String]] { pairs }
        let set = VariableSet()
        set.VarKey = "q.all"
        set.SourceKeys = ["q.a", "q.b"]

        set.Op = "SUM"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["1", "2"], "q.b": ["3"]])), "6")
        set.Op = "AVG"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["1"], "q.b": ["2"]])), "1.5")
        set.Op = "MAX"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["10"], "q.b": ["2"]])), "10")
        set.Op = "MIN"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["10"], "q.b": ["2.5"]])), "2.5")
        set.Op = "COUNT"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["10", "--"], "q.b": ["x"]])), "2")

        // 千分位与带文字的值
        set.Op = "SUM"
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["1,234"], "q.b": [" visits: 42 "]])), "1276")
        // 全部缺失 → --
        XCTAssertEqual(VariableSetService.computeValue(set, running([:])), "--")
        XCTAssertEqual(VariableSetService.computeValue(set, running(["q.a": ["--"]])), "--")
    }

    func testPatternMatchingAndSplit() {
        XCTAssertEqual(VariableSetService.splitPatterns("a.*, b，c*"), ["a.*", "b", "c*"])
        XCTAssertTrue(VariableSetService.matchesPattern("qoder.*", "Qoder.count"))
        XCTAssertFalse(VariableSetService.matchesPattern("qoder.*", "qoderxcount"), "除 * ? 外按字面匹配")
        XCTAssertTrue(VariableSetService.matchesPattern("qoder.?", "qoder.a"))
        XCTAssertFalse(VariableSetService.matchesPattern("qoder.?", "qoder.ab"))
        XCTAssertFalse(VariableSetService.matchesPattern("", "anything"))
    }

    func testParseNumber() {
        XCTAssertEqual(VariableSetService.parseNumber("42"), 42)
        XCTAssertEqual(VariableSetService.parseNumber("1,234.5"), 1234.5)
        XCTAssertEqual(VariableSetService.parseNumber("visits: 42"), 42)
        XCTAssertEqual(VariableSetService.parseNumber("-7"), -7)
        XCTAssertNil(VariableSetService.parseNumber("no digits"))
    }

    // MARK: - 变量集服务（虚拟项 + 重算）

    func testServiceRebuildAndRecompute() {
        let setA = VariableSet()
        setA.VarKey = "sum.all"
        setA.Op = "SUM"
        setA.SourceKeys = ["a", "b"]

        let svc = VariableSetService()
        svc.setsProvider = { [setA] }
        var published: [(String, String)] = []
        svc.publishUpdate = { published.append(($0, $1)) }
        svc.runningValuesProvider = { ["a": ["1"], "b": ["2"]] }
        svc.rebuild()

        XCTAssertEqual(svc.findItem(byVarKey: "SUM.all")?.Value, "3")
        XCTAssertEqual(published.count, 1)

        // 值未变化时不重复广播
        published.removeAll()
        svc.recomputeAll()
        XCTAssertTrue(published.isEmpty)

        // 手动值覆盖：跳过自动重算
        svc.manualValueProvider = { _ in "99" }
        svc.runningValuesProvider = { ["a": ["5"], "b": ["5"]] }
        svc.recomputeAll()
        XCTAssertEqual(svc.findItem(byVarKey: "sum.all")?.Value, "3", "保持手动值")
    }

    func testServiceRemovesStaleItemAndPrefersLocalOverRemote() {
        let local = VariableSet()
        local.VarKey = "dup"
        local.Op = "MAX"
        local.SourceKeys = ["x"]

        let remote = VariableSet()
        remote.VarKey = "dup"
        remote.Op = "MIN"
        remote.SourceKeys = ["y"]

        let svc = VariableSetService()
        svc.setsProvider = { [local] }
        svc.runningValuesProvider = { ["x": ["1"], "y": ["9"]] }
        svc.setRemoteSets([remote])
        XCTAssertEqual(svc.getSets().count, 1, "同名时本地定义优先")
        XCTAssertEqual(svc.findItem(byVarKey: "dup")?.Value, "1", "采用本地 MAX(x)")

        // 删除定义后虚拟项随之消失
        svc.setsProvider = { [] }
        svc.setRemoteSets([])
        XCTAssertNil(svc.findItem(byVarKey: "dup"))
        XCTAssertTrue(svc.getItems().isEmpty)
    }

    func testPurgeTeamAndRemoveRemote() {
        let a = VariableSet(); a.VarKey = "team.a"; a.TeamId = "t1"
        let b = VariableSet(); b.VarKey = "team.b"; b.TeamId = "t2"
        let svc = VariableSetService()
        svc.setRemoteSets([a, b])
        XCTAssertEqual(svc.getRemoteSets().count, 2)

        svc.removeRemote("team.a", teamId: "t1")
        XCTAssertEqual(svc.getRemoteSets().map { $0.VarKey }, ["team.b"])

        svc.purgeTeam("t2")
        XCTAssertTrue(svc.getRemoteSets().isEmpty)
    }

    // MARK: - 聚合驱动（对应 C# Init 的订阅 + 兜底定时器）

    func testOnDataUpdatedCoalescesToSingleRecomputePerTurn() {
        let savedUi = Seam.hasUiThread
        let savedPost = Seam.uiPost
        Seam.hasUiThread = { true }
        var posted: [() -> Void] = []
        Seam.uiPost = { posted.append($0) }
        defer { Seam.hasUiThread = savedUi; Seam.uiPost = savedPost }

        let setA = VariableSet()
        setA.VarKey = "sum.all"
        setA.Op = "SUM"
        setA.SourceKeys = ["a", "b"]
        let svc = VariableSetService()
        svc.setsProvider = { [setA] }
        var running = ["a": ["1"], "b": ["2"]]
        svc.runningValuesProvider = { running }
        var published: [(String, String)] = []
        svc.publishUpdate = { published.append(($0, $1)) }
        svc.rebuild()
        published.removeAll()

        // 同一轮多次更新只投递一次重算（否则每个数据点都全量重算）
        svc.onDataUpdated("x", "1"); svc.onDataUpdated("y", "2"); svc.onDataUpdated("z", "3")
        XCTAssertEqual(posted.count, 1, "高频更新必须合并")
        posted.forEach { $0() }
        posted.removeAll()
        XCTAssertEqual(svc.findItem(byVarKey: "sum.all")?.Value, "3")
        XCTAssertTrue(published.isEmpty, "值未变化不重复广播")

        // 下一轮：源值变化后聚合值随之更新并广播
        running = ["a": ["5"], "b": ["2"]]
        svc.onDataUpdated("x", "5")
        posted.forEach { $0() }
        XCTAssertEqual(svc.findItem(byVarKey: "sum.all")?.Value, "7")
        XCTAssertEqual(published.count, 1)
    }

    func testOnDataUpdatedDroppedWithoutUiThread() {
        let savedUi = Seam.hasUiThread
        let savedPost = Seam.uiPost
        Seam.hasUiThread = { false }
        var posted: [() -> Void] = []
        Seam.uiPost = { posted.append($0) }
        defer { Seam.hasUiThread = savedUi; Seam.uiPost = savedPost }

        let svc = VariableSetService()
        svc.onDataUpdated("x", "1")
        XCTAssertTrue(posted.isEmpty, "无 UI 线程时这一轮直接放弃（与 C# 分流一致）")

        // 放弃时合并标志必须复位，否则后续更新永远排不进
        Seam.hasUiThread = { true }
        svc.onDataUpdated("x", "1")
        XCTAssertEqual(posted.count, 1)
    }

    func testFallbackTimerRecomputesAndIsStartedOnce() {
        let savedFactory = Seam.timerFactory
        defer { Seam.timerFactory = savedFactory }
        var made: [RecordingTimer] = []
        Seam.timerFactory = { interval, action in
            let t = RecordingTimer(interval: interval, action: action)
            made.append(t)
            return t
        }

        let setA = VariableSet()
        setA.VarKey = "cnt"
        setA.Op = "COUNT"
        setA.SourceKeys = ["a"]
        let svc = VariableSetService()
        svc.setsProvider = { [setA] }
        var running: [String: [String]] = [:]
        svc.runningValuesProvider = { running }
        svc.rebuild()

        svc.startFallbackTimer()
        svc.startFallbackTimer()
        XCTAssertEqual(made.count, 1, "兜底定时器只应挂一个")
        XCTAssertEqual(made[0].interval, 5, "C# Init 的兜底定时器间隔为 5 秒")
        XCTAssertTrue(made[0].started)

        // 源变量随后上线：无需数据更新事件，兜底一轮即可算出
        running = ["a": ["1", "2"]]
        made[0].fire()
        XCTAssertEqual(svc.findItem(byVarKey: "cnt")?.Value, "2")
    }

    // MARK: - 云端拉取（对应 C# PullRemoteAsync）

    func testPullRemoteMergesPersonalAndTeamScopes() async {
        let svc = VariableSetService()
        var scopes: [String?] = []
        svc.cloudListProvider = { corpId in
            scopes.append(corpId)
            if corpId == nil {
                // 个人作用域：op 空 → SUM；记录自带 corpId → 仍落到 TeamId（C# `teamId ?? s.CorpId` 口径）
                return [Self.info("sum.a", op: "", sources: ["x"], corpId: "c9"),
                        Self.info("dup", op: "MAX", sources: ["y"])]
            }
            return [Self.info("team.b", op: "COUNT", corpId: corpId)]
        }
        svc.teamsProvider = { [Self.team("t1", "研发团队")] }

        await svc.pullRemote()

        XCTAssertEqual(scopes, [nil, "t1"], "个人作用域一次 + 每个已加入团队各一次")
        let remote = svc.getRemoteSets()
        XCTAssertEqual(remote.map { $0.VarKey }, ["sum.a", "dup", "team.b"])
        XCTAssertEqual(remote[0].Op, "SUM", "后端 op 为空按 SUM")
        XCTAssertEqual(remote[0].SourceKeys, ["x"])
        XCTAssertEqual(remote[0].Pattern, "", "缺 pattern 回落空串")
        XCTAssertEqual(remote[0].TeamId, "c9")
        XCTAssertNil(remote[1].TeamId, "个人记录且后端未带 corpId → 无作用域")
        XCTAssertEqual(remote[2].TeamId, "t1")
        XCTAssertEqual(remote[2].TeamName, "研发团队", "团队名仅本地展示用")

        // 同名时本地定义优先
        let local = VariableSet()
        local.VarKey = "dup"
        local.Op = "MIN"
        svc.setsProvider = { [local] }
        XCTAssertEqual(svc.getSets().first { $0.VarKey == "dup" }?.Op, "MIN")
    }

    func testPullRemoteClearsWhenBackendUnreachable() async {
        let svc = VariableSetService()
        let a = VariableSet()
        a.VarKey = "cloud.a"
        svc.setRemoteSets([a])
        XCTAssertEqual(svc.getRemoteSets().count, 1)

        svc.cloudListProvider = { _ in nil }
        svc.teamsProvider = { nil }
        await svc.pullRemote()

        XCTAssertTrue(svc.getRemoteSets().isEmpty, "拉取失败按「云端为空」并入，不留着上次成功的快照冒充本次结果")
    }

    private static func info(_ varKey: String, op: String, sources: [String]? = nil, corpId: String? = nil) -> VariableSetInfo {
        var info = VariableSetInfo()
        info.VarKey = varKey
        info.Op = op
        info.SourceKeys = sources
        info.CorpId = corpId
        return info
    }

    private static func team(_ id: String, _ name: String) -> Team {
        var t = Team()
        t.Id = id
        t.Name = name
        return t
    }
}

/// 假计时器：记录间隔/起止，回调可手动触发（聚合驱动测试用）
private final class RecordingTimer: ServiceTimer {
    let interval: TimeInterval
    let action: () -> Void
    private(set) var started = false
    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }
    func start() { started = true }
    func stop() { started = false }
    func fire() { action() }
}
