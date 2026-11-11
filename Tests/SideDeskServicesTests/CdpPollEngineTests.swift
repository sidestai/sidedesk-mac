import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 假 CDP 客户端：按方法名回应 `Target.*` / `Page.navigate` / `Runtime.evaluate`，记录每条命令。
/// 有了它，CDP 取数路径无需真实浏览器即可验收（本机没有 Chromium，见项目记忆）。
private final class StubCdpClient: CdpClientProtocol {
    /// `Target.getTargets` 返回的 targetInfos
    var pages: [JSONValue] = []
    /// `Runtime.evaluate` 的 result.value（nil = 结果里不带 value 字段）
    var evalValue: String?
    var evalException: String?
    var createdTargetId = "NEW1"
    /// 指定方法抛错（模拟断连/超时）
    var errorByMethod: [String: Error] = [:]

    private(set) var calls: [(method: String, params: [String: JSONValue]?, sessionId: String?)] = []
    private(set) var didClose = false

    var isConnected: Bool { true }

    func sendCommand(_ method: String, _ params: [String: JSONValue]?,
                     _ sessionId: String?, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((method, params, sessionId))
        if let error = errorByMethod[method] { throw error }
        switch method {
        case "Target.getTargets":    return .object(["targetInfos": .array(pages)])
        case "Target.attachToTarget": return .object(["sessionId": .string("S1")])
        case "Target.createTarget":  return .object(["targetId": .string(createdTargetId)])
        case "Runtime.evaluate":
            var result: [String: JSONValue] = [:]
            if let evalValue { result["result"] = .object(["value": .string(evalValue)]) }
            if let evalException { result["exceptionDetails"] = .object(["text": .string(evalException)]) }
            return .object(result)
        default:                     return .object([:])
        }
    }

    func close() { didClose = true }

    // MARK: 记录查询

    func count(of method: String) -> Int { calls.filter { $0.method == method }.count }

    func first(_ method: String) -> (method: String, params: [String: JSONValue]?, sessionId: String?)? {
        calls.first { $0.method == method }
    }
}

private func page(_ id: String, url: String) -> JSONValue {
    .object(["targetId": .string(id), "type": .string("page"), "url": .string(url), "title": .string(id)])
}

/// A3 验收：CDP 取数引擎的连接复用、Tab 匹配、自动打开预算、取值与后过滤、失败清值。
final class CdpPollEngineTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-cdp-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        Settings.DirOverride = dir
        Seam.resetSettings()
    }

    override func tearDown() {
        Seam.resetSettings()
        Settings.DirOverride = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - 装配

    /// 引擎装配：`exePath` 恒为空串，自动拉起浏览器的路径在测试里一律短路（不启动任何进程）
    private func makeEngine(client: StubCdpClient?, autoLaunch: Bool = false)
        -> (svc: DataPollingService, engine: CdpPollEngine, settings: Settings) {
        let settings = Settings()
        settings.DataConnectionMode = "cdp"
        settings.EnableAutoLaunchHiddenBrowser = autoLaunch
        settings.HiddenBrowserMode = "headless"
        settings.CdpDebugPort = 9333

        let svc = DataPollingService()
        svc.settingsProvider = { settings }
        let resolver = BrowserConfigResolver()
        resolver.defaultBrowserExe = { "" }
        let engine = CdpPollEngine(service: svc, channel: BrowserChannel(), browserConfig: resolver)
        engine.connectFactory = { _ in client }
        engine.readyConnectFactory = { _, _ in client }
        engine.tabLoadDelay = 0
        engine.navigateLoadDelay = 0
        return (svc, engine, settings)
    }

    private func makeItem(url: String, type: String = "css", selector: String = "#v") -> DataDashboardItem {
        let item = DataDashboardItem()
        item.Label = "测试项"
        item.TargetUrl = url
        item.SelectorType = type
        item.Selector = selector
        return item
    }

    /// 让引擎直接复用一条已建立的连接（跳过建连分支）
    private func attach(_ svc: DataPollingService, _ client: StubCdpClient, selfLaunched: Bool = false) {
        let conn = svc.obtainConnection("default")
        conn.client = client
        conn.port = 9333
        conn.state = .connected
        if selfLaunched { conn.launchedProcess = Process() }   // 仅用于置 isSelfLaunched，不启动
    }

    // MARK: - 取数主路径

    func testEvaluatesMatchingTabAndKeepsRawValue() async {
        let client = StubCdpClient()
        client.pages = [page("T1", url: "https://login.example"), page("T2", url: "https://a.example/x")]
        client.evalValue = "  42  "
        let (svc, engine, _) = makeEngine(client: client)
        attach(svc, client)

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)

        // C# 只在"全空白"时换成 --，否则原样返回：前后空白保留，移植保持一致
        XCTAssertEqual(value, "  42  ")
        XCTAssertEqual(client.first("Target.attachToTarget")?.params?["targetId"]?.stringValue, "T2",
                       "应 attach 到 URL 归属匹配的页面，而不是第一个")
        let evaluate = client.first("Runtime.evaluate")
        XCTAssertEqual(evaluate?.sessionId, "S1", "取值必须带 attach 回来的 sessionId")
        XCTAssertEqual(evaluate?.params?["expression"]?.stringValue,
                       CdpPollEngine.buildExtractJs("css", "#v"))
        XCTAssertEqual(client.count(of: "Target.createTarget"), 0, "找到 Tab 就不该自动开窗")
    }

    func testSingleTabFallbackAttachesTheOnlyPage() async {
        let client = StubCdpClient()
        client.pages = [page("T9", url: "https://totally.other")]
        client.evalValue = "ok"
        let (svc, engine, _) = makeEngine(client: client)
        attach(svc, client)

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)

        XCTAssertEqual(value, "ok")
        XCTAssertEqual(client.first("Target.attachToTarget")?.params?["targetId"]?.stringValue, "T9",
                       "只有一个 page 时按单 Tab 兜底复用（与 C# 一致）")
    }

    func testExtractRegexAndFormatApplyAfterFetch() async {
        let client = StubCdpClient()
        client.pages = [page("T1", url: "https://a.example/x")]
        client.evalValue = "余额: 12.50 元"
        let (svc, engine, _) = makeEngine(client: client)
        attach(svc, client)

        let item = makeItem(url: "https://a.example/x")
        item.ExtractRegex = #"余额: ([\d.]+)"#
        item.ExtractFormat = "{1}"

        let value = await engine.fetch(item, forceLaunch: false)
        XCTAssertEqual(value, "12.50")
    }

    func testBlankValueBecomesDash() async {
        let client = StubCdpClient()
        client.pages = [page("T1", url: "https://a.example/x")]
        client.evalValue = "   "
        let (svc, engine, _) = makeEngine(client: client)
        attach(svc, client)

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)
        XCTAssertEqual(value, "--", "空白值按 C# 语义显示 --，且不再走后过滤")
    }

    // MARK: - 连接分支

    func testNoBrowserShowsDashAndReportsErrorState() async {
        let (svc, engine, _) = makeEngine(client: nil)
        var states: [ConnectionState] = []
        svc.ConnectionStateChanged = { _, state in states.append(state) }

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)

        XCTAssertEqual(value, "--")
        XCTAssertEqual(states, [.connecting, .error], "连不上且未开自动拉起：连接置 error，不启动任何进程")
        XCTAssertNil(svc.getConnection("default")?.client)
    }

    func testCommandFailureClearsConnectionForReconnect() async {
        let client = StubCdpClient()
        client.pages = [page("T1", url: "https://a.example/x")]
        client.errorByMethod["Runtime.evaluate"] = CdpError.timeout
        let (svc, engine, _) = makeEngine(client: client)
        attach(svc, client)

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)

        XCTAssertEqual(value, "--")
        XCTAssertNil(svc.getConnection("default"), "取数异常要作废连接，下次重连")
        XCTAssertTrue(client.didClose)
    }

    func testSelfLaunchedBrowserNavigatesExistingConnection() async {
        let client = StubCdpClient()
        client.pages = []            // 自启动浏览器里还没有目标页
        client.evalValue = "from new tab"
        let (svc, engine, _) = makeEngine(client: client, autoLaunch: true)
        attach(svc, client, selfLaunched: true)

        let value = await engine.fetch(makeItem(url: "https://a.example/x"), forceLaunch: false)

        XCTAssertEqual(value, "from new tab")
        XCTAssertEqual(client.first("Target.createTarget")?.params?["url"]?.stringValue, "https://a.example/x",
                       "自启动浏览器不新开进程，只在现有浏览器里开 Tab")
        XCTAssertEqual(svc.getConnection("default")?.launchedProcess != nil, true)
    }

    // MARK: - 自动开窗预算（防反复弹窗）

    func testUserBrowserAutoOpenStopsAfterThreeAttempts() async {
        let client = StubCdpClient()
        client.pages = []
        let (svc, engine, _) = makeEngine(client: client, autoLaunch: true)
        attach(svc, client)   // 连接的是用户浏览器（非自启动）
        let item = makeItem(url: "https://a.example/x")

        for _ in 0..<5 { _ = await engine.fetch(item, forceLaunch: false) }
        XCTAssertEqual(engine.autoOpenAttempts(for: item), CdpPollEngine.maxAutoOpenAttempts,
                       "预算用尽后不再累加，安静显示 --")

        // 手动「立即刷新」重置预算、不受限
        _ = await engine.fetch(item, forceLaunch: true)
        XCTAssertEqual(engine.autoOpenAttempts(for: item), 1)
    }

    func testAutoOpenDisabledNeverClaimsBudget() async {
        let client = StubCdpClient()
        client.pages = []
        let (svc, engine, _) = makeEngine(client: client, autoLaunch: false)
        attach(svc, client)
        let item = makeItem(url: "https://a.example/x")

        let value = await engine.fetch(item, forceLaunch: false)
        XCTAssertEqual(value, "--")
        XCTAssertEqual(engine.autoOpenAttempts(for: item), 0, "关闭自动打开时不该消耗开窗预算")
    }

    // MARK: - 纯逻辑

    func testPageBelongsToUrlCoversRedirectCallbacks() {
        XCTAssertTrue(CdpPollEngine.pageBelongsToUrl("https://a.example/x", "https://a.example/x"))
        XCTAssertTrue(CdpPollEngine.pageBelongsToUrl("https://a.example/x/detail", "https://a.example/x"),
                      "前缀匹配（大小写不敏感、忽略尾部斜杠）")
        XCTAssertTrue(CdpPollEngine.pageBelongsToUrl(
            "https://login.example/oauth2?redirect_uri=https%3A%2F%2Fa.example%2Fx", "https://a.example/x"),
            "登录重定向页的回调参数指向目标 URL 也算归属")
        XCTAssertFalse(CdpPollEngine.pageBelongsToUrl(
            "https://login.example/oauth2?redirect_uri=https%3A%2F%2Fother.example", "https://a.example/x"))
        XCTAssertFalse(CdpPollEngine.pageBelongsToUrl("", "https://a.example/x"))
    }

    func testBuildExtractJsCoversFourTypesAndLegacyFallback() {
        XCTAssertTrue(CdpPollEngine.buildExtractJs("xpath", "//div[@id='v']").contains("document.evaluate"))
        XCTAssertTrue(CdpPollEngine.buildExtractJs("css", "#v").contains("document.querySelector"))
        XCTAssertTrue(CdpPollEngine.buildExtractJs("regex", "\\d+").contains("innerText.match"))
        XCTAssertTrue(CdpPollEngine.buildExtractJs("js", "return 1").contains("new Function"))
        // 旧版模板无类型：开头斜杠识别为 XPath，否则 CSS
        XCTAssertEqual(CdpPollEngine.buildExtractJs("", "//a"), CdpPollEngine.buildExtractJs("xpath", "//a"))
        XCTAssertEqual(CdpPollEngine.buildExtractJs("", ".a"), CdpPollEngine.buildExtractJs("css", ".a"))
        // 选择器里的反斜杠与引号需转义进 JS 字符串
        let js = CdpPollEngine.buildExtractJs("css", "a\"b\\c")
        XCTAssertTrue(js.contains("a\\\"b\\\\c"), js)
    }

    func testSelectorTypeIsCaseInsensitiveAndEscapesNewlines() {
        XCTAssertTrue(CdpPollEngine.buildExtractJs("CSS", "#v").contains("querySelector"))
        XCTAssertTrue(CdpPollEngine.buildExtractJs("Js", "x").contains("new Function"))
        XCTAssertTrue(CdpPollEngine.buildExtractJs("js", "a\nb").contains("\\n"))
    }
}
