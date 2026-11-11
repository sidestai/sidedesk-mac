import Foundation
import SideDeskCore

/// CDP 取数引擎：连接已运行的浏览器（或自动启动隐藏浏览器），按选择器在页面里取值。
/// 对应 C# `DataPollingService.Browser.cs`（连接/启动/工具）+ `DataPollingService.Extension.cs`
/// 里的 `PollItemAsync` CDP 分支 + `DataPollingService.AppMode.cs` 的自动开窗取页部分。
public final class CdpPollEngine: ValueEngine {

    /// 每会话自动打开目标页的最大尝试次数（C# `MaxAutoOpenAttempts`）
    public static let maxAutoOpenAttempts = 3
    /// 自动启动隐藏浏览器后等待 CDP 就绪的时限（C# 15 秒）
    public var readyTimeoutSeconds: TimeInterval = 15
    /// app 窗口出现后的等待轮次与间隔（C# 10 次 × 1 秒）
    public var appModeWaitRounds = 10
    public var appModeWaitInterval: TimeInterval = 1
    /// 新建 tab / 导航后的等待页面加载时长（C# 固定 2 秒 / 3 秒；测试置零）
    public var tabLoadDelay: TimeInterval = 2
    public var navigateLoadDelay: TimeInterval = 3

    // MARK: - 接缝（测试注入替身）

    /// 连接已运行浏览器（默认走全局守卫，避免同端口重复建连）
    public var connectFactory: (Int) async -> CdpClientProtocol? = { port in
        await CdpConnectGuard.shared.connect(port: port)
    }
    /// 等待端口就绪并直接建立正式连接（自启动路径）
    public var readyConnectFactory: (Int, TimeInterval) async -> CdpClientProtocol? = { port, timeout in
        await CdpDiscovery.connectWhenReady(port: port, timeout: timeout)
    }

    private weak var service: DataPollingService?
    private let channel: BrowserChannel
    private let browserConfig: BrowserConfigResolver

    /// 本引擎打开过的 app 页面（client + targetId + 原始 URL）：URL 被重定向改写后仍能找回该窗口
    private var openedAppTargets: [(client: CdpClientProtocol, targetId: String, url: String)] = []
    /// 自动启动/自动开窗的尝试预算（key → 已尝试次数）
    private var autoLaunchDone: [String: Int] = [:]
    private var launchingItems: Set<String> = []
    private let stateLock = NSLock()

    public init(service: DataPollingService, channel: BrowserChannel, browserConfig: BrowserConfigResolver) {
        self.service = service
        self.channel = channel
        self.browserConfig = browserConfig
    }

    // MARK: - 取数

    public func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String? {
        let settings = service?.settingsProvider() ?? Seam.settings
        let key = service?.getConnectionKey(item) ?? "default"
        RuntimeLog.debug("[DataPolling] === polling \"\(item.Label)\" === key=\(key), url=\(item.TargetUrl)")

        do {
            // 1. 获取或建立 CDP 连接
            guard let conn = await getOrCreateConnection(item, settings, key: key, forceLaunch: forceLaunch),
                  let client = conn.client as? CdpClientProtocol else {
                RuntimeLog.debug("[DataPolling] ✗ cannot establish connection: \(key)")
                return "--"
            }

            // 2. 查找匹配 URL 的 Tab（优先复用本引擎记录过的 app 窗口，覆盖页面重定向改写 URL 的场景）
            var targetId = await findRecordedAppTarget(client, item.TargetUrl)
            if targetId == nil { targetId = await findTabByUrl(client, item.TargetUrl) }

            // 3. 找不到 Tab → 按设置自动打开（每会话最多自动尝试 maxAutoOpenAttempts 次）
            if targetId == nil {
                targetId = await autoOpen(client, item, settings, key: key, conn: conn, forceLaunch: forceLaunch)
            }
            guard let targetId else {
                RuntimeLog.debug("[DataPolling] ✗ no matching tab found: \(item.TargetUrl)")
                return "--"
            }

            // 4. Attach + Evaluate（后台窗口可能被浏览器重新显示，取数前先再隐藏一次）
            channel.reassertHidden(url: item.TargetUrl)
            let value = try await evaluateOnTarget(client, targetId, item.SelectorType, item.Selector)
            let result = value != "--"
                ? DataDashboardItem.ApplyValueExtract(value, item.ExtractRegex, item.ExtractFormat)
                : value
            RuntimeLog.debug("[DataPolling] ✓ \"\(item.Label)\" = \"\(result)\"")
            return result
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ poll error \"\(item.Label)\": \(error.localizedDescription)")
            // 连接可能已断开，清除以便下次重连
            service?.invalidateConnection(key)
            return "--"
        }
    }

    // MARK: - 连接

    private func getOrCreateConnection(_ item: DataDashboardItem, _ settings: Settings,
                                      key: String, forceLaunch: Bool) async -> BrowserConnection? {
        // 快速检查：已有连接且存活
        if let existing = service?.getConnection(key), existing.client != nil { return existing }

        service?.setConnectionState(key, .connecting)
        let cfg = browserConfig.resolve(item, settings)

        // 尝试连接已运行的浏览器（同端口在途尝试由守卫复用）
        if let client = await connectFactory(cfg.port) {
            let conn = service?.obtainConnection(key) ?? BrowserConnection()
            conn.client = client
            conn.port = cfg.port
            conn.launchedProcess = nil
            service?.setConnectionState(key, .connected)
            RuntimeLog.debug("[DataPolling] ✓ browser connected: \(key), port=\(cfg.port)")
            return conn
        }

        // 连接失败 → 自动启动隐藏浏览器（每会话只自动尝试一次，失败后不再反复拉起）
        guard settings.EnableAutoLaunchHiddenBrowser, !cfg.exePath.isEmpty else {
            service?.setConnectionState(key, .error)
            return nil
        }
        let hiddenLaunchKey = "hiddenlaunch|\(key)"
        let allowLaunch = claimHiddenLaunch(hiddenLaunchKey, forceLaunch: forceLaunch)
        if !allowLaunch {
            service?.setConnectionState(key, .error)
            RuntimeLog.debug("[DataPolling] ↷ hidden browser \(key) already auto-launched once, no relaunch after failure")
            return nil
        }

        // 自启动成功时连接已由 launchHiddenBrowser 登记进连接池
        if await launchHiddenBrowser(key: key, cfg: cfg, url: item.TargetUrl, mode: settings.HiddenBrowserMode) == nil {
            service?.setConnectionState(key, .error)
            return nil
        }
        service?.setConnectionState(key, .connected)
        return service?.getConnection(key)
    }

    /// 启动隐藏浏览器并等 CDP 就绪（全程只建 1 条连接）。对应 C# `LaunchHiddenBrowserAsync`。
    private func launchHiddenBrowser(key: String, cfg: BrowserConfigResolver.Config, url: String, mode: String) async -> CdpClientProtocol? {
        guard let proc = channel.launchHiddenBrowser(exePath: cfg.exePath, userDataDir: cfg.userDataDir,
                                                     port: cfg.port, url: url, mode: mode, key: key) else { return nil }
        let client = await readyConnectFactory(cfg.port, readyTimeoutSeconds)
        guard let client else {
            RuntimeLog.debug("[DataPolling] ✗ CDP ready timeout, port=\(cfg.port)")
            if proc.isRunning { proc.terminate() }
            return nil
        }
        let conn = service?.obtainConnection(key) ?? BrowserConnection()
        conn.client = client
        conn.port = cfg.port
        conn.launchedProcess = proc
        RuntimeLog.debug("[DataPolling] ✓ hidden browser launched: \(key), port=\(cfg.port), mode=\(mode)")
        return client
    }

    // MARK: - 目标页查找

    /// 查找本引擎记录过的 app 页面（按 URL 匹配并校验 target 仍存活，失效记录顺手清理）
    private func findRecordedAppTarget(_ client: CdpClientProtocol, _ url: String) async -> String? {
        let snapshot = recordedTargets(client, url)
        if snapshot.isEmpty { return nil }
        guard let targets = try? await CdpDomain.getTargets(client) else { return nil }
        for rec in snapshot {
            if targets.contains(where: { $0.targetId == rec.targetId }) { return rec.targetId }
            // target 已不存在（窗口被关闭）→ 移除失效记录
            dropRecordedTarget(rec.client, rec.targetId, rec.url)
        }
        return nil
    }

    /// 取本引擎记录过、且归属该 URL 的页面（同步加锁，异步上下文不持锁）
    private func recordedTargets(_ client: CdpClientProtocol, _ url: String) -> [(client: CdpClientProtocol, targetId: String, url: String)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openedAppTargets.filter { $0.client === client && BrowserChannel.urlMatches($0.url, url) }
    }

    private func dropRecordedTarget(_ client: CdpClientProtocol, _ targetId: String, _ url: String) {
        stateLock.lock()
        openedAppTargets.removeAll { $0.client === client && $0.targetId == targetId && $0.url == url }
        stateLock.unlock()
    }

    /// 查找匹配 URL 的 page Tab（含重定向归属判定；单 Tab 兜底）
    private func findTabByUrl(_ client: CdpClientProtocol, _ url: String) async -> String? {
        guard let targets = try? await CdpDomain.getTargets(client) else { return nil }
        let pages = targets.filter { $0.type == "page" }
        for tab in pages where Self.pageBelongsToUrl(tab.url, url) { return tab.targetId }
        if pages.count == 1 { return pages[0].targetId }
        return nil
    }

    /// 判定页面是否属于目标 URL：URL 前缀匹配，或登录重定向页的回调参数
    /// （oauth_callback/redirect_uri/return_to/redirect/next）携带目标 URL
    static func pageBelongsToUrl(_ pageUrl: String?, _ targetUrl: String) -> Bool {
        guard let pageUrl, !pageUrl.isEmpty else { return false }
        if BrowserChannel.urlMatches(pageUrl, targetUrl) { return true }
        guard let comps = URLComponents(string: pageUrl), let query = comps.query, !query.isEmpty else { return false }
        let names = ["oauth_callback", "redirect_uri", "return_to", "redirect", "next"]
        for kv in query.components(separatedBy: "&") {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let name = String(kv[kv.startIndex..<eq])
            guard names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            let value = String(kv[kv.index(after: eq)...])
            if BrowserChannel.urlMatches(value.removingPercentEncoding ?? value, targetUrl) { return true }
        }
        return false
    }

    // MARK: - 自动打开目标页

    /// 目标页未打开时的自动打开：自启动浏览器导航已有 tab；用户浏览器按预算开 app 窗口
    private func autoOpen(_ client: CdpClientProtocol, _ item: DataDashboardItem, _ settings: Settings,
                          key: String, conn: BrowserConnection, forceLaunch: Bool) async -> String? {
        guard settings.EnableAutoLaunchHiddenBrowser else { return nil }
        let launchKey = "\(key)|\(item.TargetUrl)"

        if conn.isSelfLaunched {
            // 自启动的浏览器：导航已有 tab 到目标 URL（不新开浏览器）
            return await navigateToUrl(client, item.TargetUrl)
        }

        // 用户浏览器：按尝试次数预算限制，预算用尽后安静显示 --，不再反复弹窗；
        // 手动「立即刷新」重置预算、不受限
        guard claimAppOpen(launchKey, forceLaunch: forceLaunch) else { return nil }
        defer { releaseAppOpen(launchKey) }
        let cfg = browserConfig.resolve(item, settings)
        guard !cfg.exePath.isEmpty else { return nil }
        return await launchAppMode(client, cfg, item.TargetUrl)
    }

    /// 在已连接的浏览器中新建 tab 并导航到 URL
    private func createTab(_ client: CdpClientProtocol, _ url: String) async -> String? {
        do {
            let targetId = try await CdpDomain.createTarget(client, url: url)
            RuntimeLog.debug("[DataPolling] new tab: \(url) -> \(targetId)")
            try? await Task.sleep(nanoseconds: UInt64(tabLoadDelay * 1_000_000_000))   // 等待页面加载
            return targetId
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ failed to create tab: \(error.localizedDescription)")
            return nil
        }
    }

    /// 导航已有 tab 到 URL（用于自启动浏览器）
    private func navigateToUrl(_ client: CdpClientProtocol, _ url: String) async -> String? {
        do {
            let page = try await CdpDomain.getTargets(client).first { $0.type == "page" }
            guard let page else { return await createTab(client, url) }
            let sessionId = try await CdpDomain.attachToTarget(client, targetId: page.targetId)
            _ = try await CdpDomain.navigate(client, sessionId: sessionId, url: url)
            try? await Task.sleep(nanoseconds: UInt64(navigateLoadDelay * 1_000_000_000))   // 等待页面加载
            return page.targetId
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ navigation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 以 app 模式在用户浏览器中启动 URL（干净独立窗口），等待其 target 出现在 CDP 列表。
    /// 对应 C# `LaunchAppModeAsync`：先复用已存在的归属页面（避免每次超时多弹一个窗口），
    /// 再启动进程并等新增 target。
    private func launchAppMode(_ client: CdpClientProtocol, _ cfg: BrowserConfigResolver.Config, _ url: String) async -> String? {
        do {
            // 启动前快照已有 page target：新窗口 URL 被重定向改写时也能按"新增 target"识别
            let beforePages = (try await CdpDomain.getTargets(client)).filter { $0.type == "page" }
            let beforeIds = Set(beforePages.map { $0.targetId })

            let matches = beforePages.filter { Self.pageBelongsToUrl($0.url, url) }
            if let existing = matches.first {
                // 历史失败遗留的重复窗口：保留一个，其余关掉
                for extra in matches.dropFirst() {
                    try? await CdpDomain.closeTarget(client, targetId: extra.targetId)
                    RuntimeLog.debug("[DataPolling] 🧹 closing duplicate app-mode window: \(extra.targetId) (\(extra.url))")
                }
                recordAppTarget(client, existing.targetId, url)
                RuntimeLog.debug("[DataPolling] ✓ reusing existing app-mode page: \(url) -> \(existing.targetId)")
                return existing.targetId
            }

            guard channel.launchAppWindow(exePath: cfg.exePath, userDataDir: cfg.userDataDir, urls: [url],
                                          groupKey: "url:" + url, useNewWindow: false, hideWindow: true) != nil else {
                return nil
            }

            let host = URL(string: url)?.host
            var lastUrls: [String] = []
            for _ in 0..<appModeWaitRounds {
                try? await Task.sleep(nanoseconds: UInt64(appModeWaitInterval * 1_000_000_000))
                let pages = ((try? await CdpDomain.getTargets(client)) ?? [])
                    .filter { $0.type == "page" && !$0.url.isEmpty }
                lastUrls = pages.map { $0.url }
                // 1) URL 归属匹配（含被重定向到登录页、回调参数指向目标 URL 的情形）
                if let found = pages.first(where: { Self.pageBelongsToUrl($0.url, url) }) {
                    recordAppTarget(client, found.targetId, url)
                    RuntimeLog.debug("[DataPolling] ✓ app-mode page ready: \(url) -> \(found.targetId)")
                    return found.targetId
                }
                // 2) 归属匹配不上 → 按新增 target 识别，限同域名避免误抓用户另开的页面
                if let host {
                    if let found = pages.first(where: { !beforeIds.contains($0.targetId) && URL(string: $0.url)?.host == host }) {
                        recordAppTarget(client, found.targetId, url)
                        RuntimeLog.debug("[DataPolling] ✓ app-mode page ready (new target): \(url) -> \(found.targetId)")
                        return found.targetId
                    }
                }
            }
            // 诊断：打印当前连接可见的全部页面
            let visible = lastUrls.isEmpty ? "（无页面）" : lastUrls.joined(separator: " | ")
            RuntimeLog.debug("[DataPolling] ✗ app-mode page wait timeout: \(url); visible pages: \(visible)")
            return nil
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ app-mode page wait error: \(error.localizedDescription)")
            return nil
        }
    }

    /// 隐藏浏览器自动启动预算：每会话只自动尝试一次，`forceLaunch`（手动立即刷新）不受限并复位计数
    private func claimHiddenLaunch(_ key: String, forceLaunch: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let tried = autoLaunchDone[key] ?? 0
        if forceLaunch { autoLaunchDone[key] = 1; return true }
        if tried > 0 { return false }
        autoLaunchDone[key] = tried + 1
        return true
    }

    /// 自动打开目标页：预算内且当前无并发启动流程才放行（同一数据项并发轮询只允许一个启动流程在执行）
    private func claimAppOpen(_ launchKey: String, forceLaunch: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let attempts = autoLaunchDone[launchKey] ?? 0
        if !forceLaunch && attempts >= Self.maxAutoOpenAttempts {
            RuntimeLog.debug("[DataPolling] ↷ \(launchKey) auto-opened \(Self.maxAutoOpenAttempts) times with no data, no more auto-opens")
            return false
        }
        autoLaunchDone[launchKey] = forceLaunch ? 1 : attempts + 1
        if !launchingItems.insert(launchKey).inserted {
            RuntimeLog.debug("[DataPolling] ↷ \(launchKey) already has a launch in progress, skipping")
            return false
        }
        return true
    }

    private func releaseAppOpen(_ launchKey: String) {
        stateLock.lock()
        launchingItems.remove(launchKey)
        stateLock.unlock()
    }

    private func recordAppTarget(_ client: CdpClientProtocol, _ targetId: String, _ url: String) {
        stateLock.lock()
        openedAppTargets.append((client, targetId, url))
        stateLock.unlock()
    }

    // MARK: - 取值

    /// Attach 到 target 并执行 JS 获取元素文本
    private func evaluateOnTarget(_ client: CdpClientProtocol, _ targetId: String,
                                  _ selectorType: String, _ selector: String) async throws -> String {
        let sessionId = try await CdpDomain.attachToTarget(client, targetId: targetId)
        let result = try await CdpDomain.evaluate(client, sessionId: sessionId,
                                                  expression: Self.buildExtractJs(selectorType, selector))
        if let exception = result.exception, !exception.isEmpty {
            RuntimeLog.debug("[DataPolling] ✗ JS exception: \(exception)")
        }
        let value = result.value
        return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "--" : value!
    }

    /// 构建取值 JS 表达式（xpath/css/regex/js 四种；空类型回退旧版自动识别）。与 C# 逐字一致。
    public static func buildExtractJs(_ selectorType: String, _ selector: String) -> String {
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        switch selectorType.lowercased() {
        case "xpath":
            return "(function(){ var r = document.evaluate(\"\(escaped)\", document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null); return r.singleNodeValue ? r.singleNodeValue.textContent.trim() : '--'; })()"
        case "css":
            return "(function(){ var el = document.querySelector(\"\(escaped)\"); return el ? el.textContent.trim() : '--'; })()"
        case "regex":
            return "(function(){ try { var m = document.body.innerText.match(new RegExp(\"\(escaped)\")); return m ? (m[1] !== undefined ? m[1] : m[0]).trim() : '--'; } catch(e) { return '--'; } })()"
        case "js":
            return "(function(){ try { var v = new Function(\"\(escaped)\")(); return (v === undefined || v === null) ? '--' : String(v); } catch(e) { return '--'; } })()"
        default:
            // 旧版模板无类型：开头斜杠自动识别为 XPath，否则 CSS
            return selector.trimmingCharacters(in: .whitespaces).hasPrefix("/")
                ? buildExtractJs("xpath", selector)
                : buildExtractJs("css", selector)
        }
    }

    // MARK: - ValueEngine 其余接口

    /// 该数据源已消耗的自动开窗预算（0 = 未尝试过）。供单测断言预算门控。
    internal func autoOpenAttempts(for item: DataDashboardItem) -> Int {
        let key = service?.getConnectionKey(item) ?? "default"
        stateLock.lock()
        defer { stateLock.unlock() }
        return autoLaunchDone["\(key)|\(item.TargetUrl)"] ?? 0
    }

    /// 手动「立即刷新」：重置该数据源的自动开窗预算（C# `_autoLaunchDone`）
    public func resetLaunchBudget(for item: DataDashboardItem) {
        let key = service?.getConnectionKey(item) ?? "default"
        stateLock.lock()
        autoLaunchDone["\(key)|\(item.TargetUrl)"] = 1
        autoLaunchDone["hiddenlaunch|\(key)"] = 0
        stateLock.unlock()
    }

    /// 数据项/看板删除后关闭已无对应项的隐藏窗口
    public func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>) {
        channel.closeOrphanedWindows(liveGroupKeys: liveGroupKeys, liveUrls: liveUrls)
    }

    public func shutdown() {
        stateLock.lock()
        openedAppTargets.removeAll()
        stateLock.unlock()
        channel.shutdown()
    }
}
