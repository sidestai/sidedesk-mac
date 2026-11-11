import Foundation
import SideDeskCore

/// 一次在途的扩展取数请求：`fetch` 挂起等应答，超时或应答只生效一次。
final class ExtensionFetchWaiter {
    private let lock = NSLock()
    private var cont: CheckedContinuation<(Bool, String, String)?, Never>?

    func attach(_ cont: CheckedContinuation<(Bool, String, String)?, Never>) {
        lock.lock()
        self.cont = cont
        lock.unlock()
    }

    /// 应答（nil = 超时）。已应答或已超时则忽略，保证 continuation 只 resume 一次。
    func settle(_ result: (Bool, String, String)?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: result)
    }
}

/// 插件（浏览器扩展）取数引擎：经本地 WS(19191) 让扩展在页面里代取代数。
/// 对应 C# `DataPollingService.Extension.cs`（`PollViaExtensionAsync` / `PushTasksToExtensions` /
/// `HandleExtensionFetchResult` / `OnExtensionRegistered` / `TryAutoOpenForExtension`）。
public final class ExtensionPollEngine: ExtensionEngine {

    /// 等待扩展应答的超时（C# 20 秒）。测试可缩短。
    public var fetchTimeoutSeconds: Double = 20
    /// 每看板分组自动开窗的次数预算（C# `MaxAutoOpenAttempts`）
    public static let maxAutoOpenAttempts = 3

    private weak var service: DataPollingService?
    private let transport: ExtensionTransport?
    private let channel: BrowserChannel
    private let browserConfig: BrowserConfigResolver

    /// register 消息里的客户端元数据回写接缝（宿主 WS 服务注入）
    public var clientInfoUpdater: ((String, String, String, String, Int?) -> Void)?

    private var pending: [String: ExtensionFetchWaiter] = [:]
    private var autoLaunchDone: [String: Int] = [:]
    private var launchingItems: Set<String> = []
    private var tasksPushedClients: Set<String> = []
    private let stateLock = NSLock()

    public init(service: DataPollingService, transport: ExtensionTransport?,
                channel: BrowserChannel, browserConfig: BrowserConfigResolver) {
        self.service = service
        self.transport = transport
        self.channel = channel
        self.browserConfig = browserConfig
    }

    // MARK: - 取数

    /// 插件模式取数：向所有已连接扩展广播 fetch 请求，等待 fetchResult 应答。
    ///
    /// 扩展侧：页面已打开 → 刷新该页（回 `error=reloading`，值在加载完成后经主动推送到达）；
    /// 页面未打开 → 回 `error=tab_not_open`，由本引擎拉起目标浏览器独立隐藏新窗口。
    /// **扩展未连接、失败或超时都返回 nil（保留当前值不清零）**——页面打开/刷新完成时扩展会按任务清单主动推送。
    public func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String? {
        let settings = service?.settingsProvider() ?? Seam.settings
        guard transport?.isRunning == true, (transport?.clientCount ?? 0) > 0 else {
            RuntimeLog.debug("[DataPolling] ↷ \"\(item.Label)\" extension fetch skipped: no extension connected")
            return nil
        }
        if item.TargetUrl.isEmpty || item.Selector.isEmpty {
            RuntimeLog.debug("[DataPolling] ↷ \"\(item.Label)\" extension fetch skipped: no url/selector")
            return nil
        }

        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let waiter = ExtensionFetchWaiter()
        stateLock.lock()
        pending[requestId] = waiter
        stateLock.unlock()

        let msg = JSONValue.object([
            "type": .string("fetch"),
            "requestId": .string(requestId),
            "varKey": .string(item.VarKey ?? ""),
            "label": .string(item.Label),
            "url": .string(item.TargetUrl),
            "selector": .string(item.Selector),
            "selectorType": .string(item.SelectorType.isEmpty ? "css" : item.SelectorType),
        ])
        transport?.broadcast(Self.jsonString(msg))
        RuntimeLog.debug("[DataPolling] === extension fetch \"\(item.Label)\" === requestId=\(requestId), url=\(item.TargetUrl)")

        let answer = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String, String)?, Never>) in
            waiter.attach(cont)
            let timeout = self.fetchTimeoutSeconds
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                waiter.settle(nil)
                if let self {
                    self.stateLock.lock()
                    self.pending.removeValue(forKey: requestId)
                    self.stateLock.unlock()
                }
            }
        }

        guard let answer else {
            RuntimeLog.debug("[DataPolling] ✗ extension fetch timeout \"\(item.Label)\" (requestId=\(requestId))")
            consumePending(requestId)
            return nil
        }
        consumePending(requestId)
        let (ok, value, error) = answer
        if !ok {
            if error == "reloading" {
                // 扩展正在刷新已打开的页面：值将在加载完成后经主动推送（无 requestId，按 varKey）到达
                RuntimeLog.debug("[DataPolling] ↷ \"\(item.Label)\" page is being refreshed by extension; value will arrive via push")
            } else {
                RuntimeLog.debug("[DataPolling] ↷ extension fetch failed \"\(item.Label)\": \(error)")
                if error == "tab_not_open" { tryAutoOpen(item, settings, forceLaunch) }
            }
            return nil
        }
        return Self.applyValueExtract(Self.trimValue(value), item)
    }

    // MARK: - 任务清单下发

    /// 把当前需要扩展代取的数据任务清单推给所有已连接扩展（syncTasks）。
    /// 扩展收到后：缓存清单；对已打开的匹配标签页立即补推一次；此后页面加载/刷新完成时按清单取数推送。
    public func pushTasks() {
        guard let transport, transport.isRunning, transport.clientCount > 0 else { return }
        let tasks: [JSONValue] = (service?.getAllItems() ?? [])
            .filter { ($0.ApiMethod ?? "").isEmpty && !$0.TargetUrl.isEmpty && !$0.Selector.isEmpty }
            .map { i in
                .object([
                    "varKey": .string(i.VarKey ?? ""),
                    "label": .string(i.Label),
                    "targetUrl": .string(i.TargetUrl),
                    "selector": .string(i.Selector),
                    "selectorType": .string(i.SelectorType.isEmpty ? "css" : i.SelectorType),
                    "refreshIntervalSeconds": .int(i.RefreshIntervalSeconds),
                ])
            }
        transport.broadcast(Self.jsonString(.object([
            "type": .string("syncTasks"),
            "tasks": .array(tasks),
        ])))
        RuntimeLog.debug("[DataPolling] syncTasks pushed to extensions: \(tasks.count) task(s)")
    }

    /// 扩展 register 到达：新连接推一次任务清单；同一连接的重复 register（切标签页触发）不重推
    public func extensionRegistered(_ clientId: String) {
        stateLock.lock()
        let firstTime = tasksPushedClients.insert(clientId).inserted
        stateLock.unlock()
        if firstTime { pushTasks() }
    }

    /// 扩展连接断开：清除"已推过清单"标记，重连后重新推一次
    public func extensionDisconnected(_ clientId: String) {
        stateLock.lock()
        tasksPushedClients.remove(clientId)
        stateLock.unlock()
    }

    /// 处理扩展经 WS 回传的 fetchResult：requestId 命中在途拉取请求则完成之（由 `fetch` 应用值）；
    /// 无 requestId 视为扩展主动推送（页面加载/刷新完成触发），按 varKey 定位数据项直接落值。
    public func handleFetchResult(requestId: String?, varKey: String?, success: Bool, value: String?, error: String?) {
        if let requestId, !requestId.isEmpty {
            consumePending(requestId)?.settle((success, value ?? "", error ?? ""))
            return   // 已消费/超时的拉取应答：不再按 varKey 重复落值
        }
        guard success, let varKey, !varKey.isEmpty else { return }
        guard let item = service?.findItem(byVarKey: varKey) else {
            RuntimeLog.debug("[DataPolling] extension push ignored: no item for varKey=\(varKey)")
            return
        }
        let v = Self.applyValueExtract(Self.trimValue(value ?? ""), item)
        service?.updateItemValue(item, v)
        RuntimeLog.debug("[DataPolling] ✓ (extension) \"\(item.Label)\" = \"\(v)\"")
    }

    /// WS 入站消息分流（宿主把 `WebSocketServerService.MessageReceived` 接 here）。
    /// 对应 C# `App.BackendWs.cs` 里 fetchResult / register 两个分支。
    public func handleIncomingMessage(clientId: String, text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else {
            RuntimeLog.debug("[DataPolling] WS message parse error: \(text)")
            return
        }
        switch type {
        case "fetchResult":
            handleFetchResult(
                requestId: obj["requestId"] as? String,
                varKey: obj["varKey"] as? String,
                success: (obj["success"] as? Bool) ?? false,
                value: obj["value"] as? String,
                error: obj["error"] as? String)
        case "register":
            let uniqId = (obj["uniqid"] as? String) ?? ""
            let title = (obj["title"] as? String) ?? ""
            let url = (obj["url"] as? String) ?? ""
            let tabId = (obj["tabId"] as? NSNumber)?.intValue
            clientInfoUpdater?(clientId, uniqId, title, url, tabId)
            RuntimeLog.debug("[DataPolling] register: uniqid=\(uniqId), title=\(title), url=\(url), tabId=\(tabId ?? -1)")
            extensionRegistered(clientId)
        default:
            RuntimeLog.debug("[DataPolling] unhandled WS message from \(clientId): \(text)")
        }
    }

    // MARK: - 目标页未打开时拉起浏览器

    /// 插件模式目标页未打开时拉起浏览器：按「看板分组」开一个 `--new-window` 独立新窗口
    /// （带数据项配置的 profile user-data-dir，扩展即在其中运行，页面加载完成后按任务清单推送值）；
    /// 同组多个数据点一次开齐为该窗口的多 tab。尝试次数预算与 CDP 路径一致。
    private func tryAutoOpen(_ item: DataDashboardItem, _ settings: Settings, _ forceLaunch: Bool) {
        guard !item.TargetUrl.isEmpty else { return }
        let groupKey = DataPollingService.dashboardGroupKey(item)
        let launchKey = "extension|\(groupKey)"

        stateLock.lock()
        let attempts = autoLaunchDone[launchKey] ?? 0
        if !forceLaunch && attempts >= Self.maxAutoOpenAttempts {
            stateLock.unlock()
            RuntimeLog.debug("[DataPolling] ↷ dashboard group \(groupKey) auto-opened \(Self.maxAutoOpenAttempts) times with no data (extension mode), no more auto-opens")
            return
        }
        autoLaunchDone[launchKey] = forceLaunch ? 1 : attempts + 1
        let busy = !launchingItems.insert(launchKey).inserted
        stateLock.unlock()
        if busy { return }   // 已有启动流程在执行
        defer {
            stateLock.lock()
            launchingItems.remove(launchKey)
            stateLock.unlock()
        }

        // 之前拉起的隐藏窗口还活着 → 不重复开窗，只把可能被浏览器重新显示的窗口压回隐藏
        channel.reassertHidden(url: item.TargetUrl)
        if channel.hiddenWindowAlive(groupKey: groupKey.isEmpty ? "solo:" + item.Id : groupKey) {
            RuntimeLog.debug("[DataPolling] ↷ hidden window for dashboard group \(groupKey) still alive, skip relaunch (extension mode)")
            return
        }

        let cfg = browserConfig.resolve(item, settings)
        guard !cfg.exePath.isEmpty else {
            RuntimeLog.debug("[DataPolling] ✗ extension auto-open skipped: browser exe not resolved for \"\(item.Label)\"")
            return
        }
        let groupUrls = collectGroupUrls(item, groupKey)
        let proc = channel.launchAppWindow(exePath: cfg.exePath, userDataDir: cfg.userDataDir,
                                           urls: groupUrls, groupKey: groupKey,
                                           useNewWindow: true, hideWindow: true)
        if proc != nil {
            RuntimeLog.debug("[DataPolling] ✓ extension mode: dashboard group launched in hidden new window (\(groupUrls.count) tab(s)): \(groupUrls.joined(separator: ", "))")
        }
    }

    /// 收集同一看板分组下当前全部数据点的目标 URL（去重保序；触发项置首，跳过 API 型项）
    private func collectGroupUrls(_ item: DataDashboardItem, _ groupKey: String) -> [String] {
        var urls: [String] = []
        var seen = Set<String>()
        func add(_ u: String) {
            guard !u.isEmpty, !seen.contains(u.lowercased()) else { return }
            seen.insert(u.lowercased())
            urls.append(u)
        }
        add(item.TargetUrl)   // 触发项优先，保证第一个 tab 是它
        for other in service?.getAllItems() ?? [] {
            guard (other.ApiMethod ?? "").isEmpty else { continue }   // API 型不经浏览器
            guard DataPollingService.dashboardGroupKey(other) == groupKey else { continue }
            add(other.TargetUrl)
        }
        return urls
    }

    // MARK: - ValueEngine 其余接口

    /// 手动「立即刷新」：重置该分组（或该项）的自动开窗预算，本次不受限制
    public func resetLaunchBudget(for item: DataDashboardItem) {
        let groupKey = DataPollingService.dashboardGroupKey(item)
        stateLock.lock()
        autoLaunchDone["extension|\(groupKey)"] = 1
        stateLock.unlock()
    }

    /// 数据项/看板删除后关闭已无对应项的隐藏窗口
    public func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>) {
        channel.closeOrphanedWindows(liveGroupKeys: liveGroupKeys, liveUrls: liveUrls)
    }

    public func shutdown() {
        stateLock.lock()
        let waiters = Array(pending.values)
        pending.removeAll()
        stateLock.unlock()
        for w in waiters { w.settle(nil) }
    }

    // MARK: - 内部

    private func consumePending(_ requestId: String) -> ExtensionFetchWaiter? {
        stateLock.lock()
        let waiter = pending.removeValue(forKey: requestId)
        stateLock.unlock()
        return waiter
    }

    /// 应用扩展取回的值（提取规则与 CDP 路径一致）
    static func trimValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "--" : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func applyValueExtract(_ value: String, _ item: DataDashboardItem) -> String {
        value != "--" ? DataDashboardItem.ApplyValueExtract(value, item.ExtractRegex, item.ExtractFormat) : value
    }

    static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? SideDeskJSON.encoder().encode(value),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
