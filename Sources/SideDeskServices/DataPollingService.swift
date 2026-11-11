import Foundation
import SideDeskCore

/// 取数引擎接缝。对应 C# `PollItemAsync` 里按模式分流的三条取数路径（API / 插件 / CDP）。
///
/// 返回 `nil` = 保留当前值不更新（C# 里"扩展未连接/超时/正在刷新页面"这类正常等待状态）；
/// 返回字符串（含 `"--"`）= 应用该值并按身份组同步广播。
/// 失败清值、断连失效等分支由引擎自己经 `DataPollingService` 完成，保持与 C# 各分支一致。
public protocol ValueEngine: AnyObject {
    func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String?
    /// 手动「立即刷新」重置该数据源的自动启动预算（C# `_autoLaunchDone`）。默认无预算概念（API 模式）。
    func resetLaunchBudget(for item: DataDashboardItem)
    /// 数据项/看板删除后关闭已无对应项的隐藏窗口（C# `CloseOrphanedHiddenWindows`）。默认 no-op。
    func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>)
    /// 释放引擎资源（关闭自启动进程 / 断开连接）
    func shutdown()
}

public extension ValueEngine {
    func resetLaunchBudget(for item: DataDashboardItem) {}
    func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>) {}
    func shutdown() {}
}

/// 插件（扩展）引擎：除取数外还要维护任务清单下发与扩展应答。
/// 对应 C# `PushTasksToExtensions` / `HandleExtensionFetchResult` / `OnExtensionRegistered`。
public protocol ExtensionEngine: ValueEngine {
    func pushTasks()
    func handleFetchResult(requestId: String?, varKey: String?, success: Bool, value: String?, error: String?)
    func extensionRegistered(_ clientId: String)
}

/// 数据轮询服务：把分散数据源统一成数据看板卡片的定时抓取引擎；卡片只做展示，不管连接。
/// 对应 C# `DataPollingService`（主 partial：容器/去重/调度/手动值/广播/连接状态）。
public final class DataPollingService {

    /// 数据项更新事件订阅者 (itemId, newValue)。对应 C# `event Action<string, string>? DataUpdated`：
    /// 多播语义——变量集聚合与 UI 展示各自订阅，后接的一方不会覆盖前一方。
    /// 以令牌登记，供订阅方在生命周期结束时退订（对应 C# `DataUpdated -=`，如信号灯看板 Unloaded）。
    public private(set) var DataUpdated: [(id: UUID, handler: (String, String) -> Void)] = []
    /// 追加数据更新订阅者（对应 C# `DataUpdated +=`），返回退订令牌。
    @discardableResult
    public func addDataUpdatedObserver(_ handler: @escaping (String, String) -> Void) -> UUID {
        let id = UUID()
        DataUpdated.append((id, handler))
        return id
    }
    /// 按令牌退订（对应 C# `DataUpdated -=`）；令牌不存在时静默忽略。
    public func removeDataUpdatedObserver(_ id: UUID) {
        DataUpdated.removeAll { $0.id == id }
    }

    /// 连接状态变化事件 (connectionKey, newState)
    public var ConnectionStateChanged: ((String, ConnectionState) -> Void)?

    // 所有数据项（按身份去重：同一看板模板/同一变量分布在多个窗口时只轮询一次）
    private var items: [DataDashboardItem] = []
    // 身份 key -> 全部重复实例（含轮询代表实例）：值更新后同步给所有重复实例并按各自 Id 发事件，
    // 保证多个微屏窗口的面板同步刷新
    private var itemGroups: [String: [DataDashboardItem]] = [:]
    private let itemsLock = NSLock()

    // 每个去重后数据源一个定时器
    private var timers: [String: ServiceTimer] = [:]
    // 正在轮询中的数据项（防重叠：上一次抓取未完成时跳过本轮，避免重复建连/重复打开页面）
    private var pollingItems: Set<String> = []
    private let pollingLock = NSLock()

    // CDP 连接池: key = "{browserId}_{profileId}" 或 "default"
    private var connections: [String: BrowserConnection] = [:]
    private let connectionsLock = NSLock()

    public var settingsProvider: () -> Settings = { Seam.settings }
    /// 手动值层（外部程序/后端推送写入）。组合根注入；nil 视为无手动值。
    public var manualStore: ManualVariableStore?
    /// 变量集虚拟项（按名兜底查找 + 快照列出），由 `VariableSetService` 注入。
    public var variableSetItemProvider: (String) -> DataDashboardItem? = { _ in nil }
    public var variableSetItemsProvider: () -> [DataDashboardItem] = { [] }

    // 三条取数路径的引擎（A2/A3/A4 实现并注入；未注入即该路径不可用，保持当前值）
    public var apiEngine: ValueEngine?
    public var extensionEngine: ExtensionEngine?
    public var cdpEngine: ValueEngine?

    internal init() {}

    // MARK: - 身份与去重

    /// 数据项身份标识 = 数据卡片（后端实例）：同模板+同浏览器+同网址/选择器即同一数据卡片，
    /// 同一卡片出现在多个微屏窗口时共享同一个轮询实例。
    /// 变量名（VarKey）是卡片的属性、不参与身份——避免同一卡片因一个设了变量、另一个没设而被拆成两个实例。
    public static func getItemIdentity(_ item: DataDashboardItem) -> String {
        """
        tpl|\(item.TemplateId)|\(item.BrowserId ?? "")|\(item.ProfileId ?? "")|\(item.TargetUrl)\
        |\(item.SelectorType ?? "")|\(item.Selector)|\(item.ApiMethod ?? "")|\(item.ResponseExtract ?? "")\
        |\(item.ApiExtractType ?? "")
        """.lowercased()
    }

    /// 当前轮询名单中是否已存在同一数据源。身份含 BrowserId/ProfileId：
    /// 浏览器或 Profile 不一致则身份不同、天然不算重复（允许不同会话并行取数）。
    public func isDuplicateSource(_ probe: DataDashboardItem) -> Bool {
        let key = Self.getItemIdentity(probe)
        return getAllItems().contains { Self.getItemIdentity($0) == key }
    }

    // MARK: - 配置同步

    /// 从 WindowConfigs 同步数据项（面板项 + 后台项），按身份去重后重建定时器。
    /// 对应 C# `SyncFromConfigs`。
    ///
    /// 面板项只取窗口顶层面板（与 C# 逐字一致：不递归 ChildPanels）——分组面板内的数据卡片
    /// 是否应纳入轮询属上游行为问题，移植保持原语义。
    public func syncFromConfigs(_ configs: WindowConfigManager) {
        var totalBefore = 0
        itemsLock.lock()
        items.removeAll()
        itemGroups.removeAll()

        var candidates: [DataDashboardItem] = []
        // 面板数据项（引用项仅展示、不轮询，不纳入）
        for win in configs.Windows {
            for panel in win.Panels {
                guard let list = panel.DashboardItems, !list.isEmpty else { continue }
                candidates.append(contentsOf: list.filter { ($0.RefVarKey ?? "").isEmpty })
            }
        }
        // 后台数据项
        candidates.append(contentsOf: configs.BackgroundDashboardItems.filter { ($0.RefVarKey ?? "").isEmpty })

        totalBefore = candidates.count

        for d in candidates {
            let key = Self.getItemIdentity(d)
            if var group = itemGroups[key] {
                // 变量是卡片属性：代表实例没变量而新成员有则提升为代表，保证按变量名可查到该卡片
                if !(d.VarKey ?? "").isEmpty && (group[0].VarKey ?? "").isEmpty,
                   let idx = items.firstIndex(where: { $0 === group[0] }) {
                    items[idx] = d
                    group[0] = d
                }
                group.append(d)
                itemGroups[key] = group
            } else {
                itemGroups[key] = [d]
                items.append(d)
            }
        }
        itemsLock.unlock()

        // 新数据源的启动 key 不在引擎的自动启动记录里，首次轮询自然允许尝试一次；
        // 已有数据源失败后保持安静，配置变更不重置该限制（避免增删改后浏览器反复弹出）。

        // 恢复手动值：配置重建后把外部设置的值重新应用到匹配变量
        for item in getAllItems() {
            guard let varKey = item.VarKey, !varKey.isEmpty else { continue }
            if let manual = getManualValue(varKey) { updateItemValue(item, manual) }
        }

        // 数据项/看板删除：关闭已无对应数据项的隐藏窗口
        let liveGroupKeys = Set(getAllItems().map { Self.dashboardGroupKey($0) })
        var liveUrls = Set<String>()
        for i in getAllItems() where !i.TargetUrl.isEmpty { liveUrls.insert(i.TargetUrl.lowercased()) }
        cdpEngine?.closeOrphanedWindows(liveGroupKeys: liveGroupKeys, liveUrls: liveUrls)
        extensionEngine?.closeOrphanedWindows(liveGroupKeys: liveGroupKeys, liveUrls: liveUrls)

        rebuildTimers()
        RuntimeLog.debug("[DataPolling] SyncFromConfigs: \(totalBefore) data items in total, \(items.count) polling instances after dedup")
        // 任务清单可能变化：推给已连接扩展（插件模式下由扩展按清单在页面加载/刷新时取数推送）
        extensionEngine?.pushTasks()
    }

    /// 数据项的看板分组键：有 DashboardGroupId 用之（同批多数据点共享）；否则按项独立
    public static func dashboardGroupKey(_ item: DataDashboardItem) -> String {
        (item.DashboardGroupId ?? "").isEmpty ? "solo:" + item.Id : item.DashboardGroupId!
    }

    /// 获取当前所有数据项（引用副本）
    public func getAllItems() -> [DataDashboardItem] {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        return items
    }

    /// 按变量名查找实际轮询中的数据项（供引用项展示取值；找不到再查变量集虚拟项）
    public func findItem(byVarKey varKey: String?) -> DataDashboardItem? {
        guard let varKey, !varKey.isEmpty else { return nil }
        itemsLock.lock()
        let hit = items.first { ($0.VarKey ?? "").lowercased() == varKey.lowercased() }
        itemsLock.unlock()
        return hit ?? variableSetItemProvider(varKey)
    }

    /// 广播外部数据项（如变量集虚拟项）的值更新，供订阅方（引用展示/格式渲染/信号灯）刷新
    public func publishUpdate(itemId: String, value: String) {
        notifyDataUpdated(itemId, value)
    }

    // MARK: - 值更新

    /// 更新数据项的值并触发事件（同一数据源的重复实例一并同步，保证多个窗口面板都收到更新）
    public func updateItemValue(_ item: DataDashboardItem, _ value: String) {
        item.Value = value
        itemsLock.lock()
        let group = itemGroups[Self.getItemIdentity(item)]
        itemsLock.unlock()

        if let group {
            for dup in group {
                if dup !== item { dup.Value = value }
                notifyDataUpdated(dup.Id, value)
            }
        } else {
            notifyDataUpdated(item.Id, value)
        }
    }

    private func notifyDataUpdated(_ itemId: String, _ value: String) {
        for entry in DataUpdated { entry.handler(itemId, value) }
    }

    // MARK: - 手动值

    /// 获取指定变量的手动值（nil = 无手动覆盖）
    public func getManualValue(_ varKey: String) -> String? {
        manualStore?.get(varKey)
    }

    /// 手动设置变量值（本地 HTTP 接口 / 后端推送调用）。手动值优先：设置后轮询与变量集聚合
    /// 都不再覆盖该变量，直到 `clearVariableValue` 解除。返回是否找到同名运行中变量
    /// （未找到时值仍会记录，变量出现后自动生效）。对应 C# `SetVariableValue`。
    @discardableResult
    public func setVariableValue(_ varKey: String, _ value: String, corpId: String? = nil) -> Bool {
        let key = varKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return false }
        manualStore?.set(key, value, corpId: corpId)
        guard let item = findItem(byVarKey: key) else { return false }
        updateItemValue(item, value)
        return true
    }

    /// 解除手动值：变量恢复轮询/聚合自动取值
    @discardableResult
    public func clearVariableValue(_ varKey: String) -> Bool {
        manualStore?.clear(varKey) ?? false
    }

    /// 全部变量快照（轮询项 + 变量集虚拟项 + 仅有手动值的变量），供本地 HTTP 接口列出
    public func getVariableSnapshot() -> [(varKey: String, value: String, label: String, manual: Bool)] {
        // 变量名大小写不敏感去重；展示用首次出现时的原始大小写
        var dict: [String: (varKey: String, value: String, label: String, manual: Bool)] = [:]
        func put(_ vk: String, _ value: String, _ label: String) {
            dict[vk.lowercased()] = (vk, value, label, getManualValue(vk) != nil)
        }
        for item in getAllItems() {
            guard let vk = item.VarKey, !vk.isEmpty else { continue }
            put(vk, item.Value, item.Label)
        }
        for item in variableSetItemsProvider() {
            guard let vk = item.VarKey, !vk.isEmpty, dict[vk.lowercased()] == nil else { continue }
            put(vk, item.Value, item.Label)
        }
        for row in manualStore?.snapshot() ?? [] where dict[row.varKey.lowercased()] == nil {
            dict[row.varKey.lowercased()] = (row.varKey, row.value, "", true)
        }
        return dict.values.map { ($0.varKey, $0.value, $0.label, $0.manual) }.sorted { $0.varKey < $1.varKey }
    }

    /// 登录成功/切换账号后调用：把未归属（local）数据晋升到当前用户作用域，
    /// 并把晋升的手动值立即应用到同名运行中变量。对应 C# `AdoptPendingLocalData`。
    public func adoptPendingLocalData() {
        let scope = LocalDbService.currentScope()
        if scope != "local" {
            // 布局与内容类数据（窗口/卡片/便签/待办/剪贴板收藏等）同步晋升
            LocalDbService.adoptScope(from: "local", to: scope)
        }
        manualStore?.reload()   // 内含数据变量晋升 + 旧 blob 迁移
        if scope == "local" { return }
        for item in getAllItems() {
            guard let vk = item.VarKey, !vk.isEmpty, let manual = getManualValue(vk) else { continue }
            updateItemValue(item, manual)
        }
    }

    // MARK: - 轮询调度

    /// 重建所有定时器（每个去重后的数据源一个轮询实例）。对应 C# `RebuildTimers`。
    public func rebuildTimers() {
        for t in timers.values { t.stop() }
        timers.removeAll()

        for item in getAllItems() {
            let interval = Double(max(item.RefreshIntervalSeconds, 10))
            let timer = Seam.timerFactory(interval) { [weak self, weak item] in
                guard let self, let item else { return }
                if !self.beginPoll(item.Id) { return }   // 上次未跑完则跳过本轮，防重叠
                Task {
                    await self.poll(item, forceLaunch: false)
                    self.endPoll(item.Id)
                }
            }
            timer.start()
            timers[item.Id] = timer
        }
    }

    private func beginPoll(_ id: String) -> Bool {
        pollingLock.lock()
        defer { pollingLock.unlock() }
        return pollingItems.insert(id).inserted
    }

    private func endPoll(_ id: String) {
        pollingLock.lock()
        pollingItems.remove(id)
        pollingLock.unlock()
    }

    /// 轮询单个数据项。对应 C# `PollItemAsync` 的模式分流。
    public func poll(_ item: DataDashboardItem, forceLaunch: Bool) async {
        // 手动值覆盖：外部已设置值时跳过轮询（含 API 模式），保持手动值直到解除
        if let vk = item.VarKey, !vk.isEmpty, getManualValue(vk) != nil {
            RuntimeLog.debug("[DataPolling] ↷ \"\(item.Label)\" has manual value, skipping poll")
            return
        }

        let engine: ValueEngine?
        if !(item.ApiMethod ?? "").isEmpty {
            engine = apiEngine
        } else if settingsProvider().DataConnectionMode.lowercased() == "extension" {
            engine = extensionEngine
        } else {
            engine = cdpEngine
        }
        guard let engine else {
            RuntimeLog.debug("[DataPolling] ↷ \"\(item.Label)\": no engine for this mode (not configured)")
            return
        }
        if forceLaunch { engine.resetLaunchBudget(for: item) }

        // 引擎内部已按 C# 各分支处理失败（清 "--" / 断连失效），此处只负责落值与广播
        if let next = await engine.fetch(item, forceLaunch: forceLaunch) {
            updateItemValue(item, next)
        }
    }

    /// 立即刷新指定数据项（手动触发：允许再试一次自动启动浏览器）
    public func refreshItem(_ item: DataDashboardItem) async {
        await poll(item, forceLaunch: true)
    }

    // MARK: - 连接状态

    /// 获取指定数据项的连接 key（未指定浏览器时为 "default"，与 C# 一致）
    public func getConnectionKey(_ item: DataDashboardItem) -> String {
        let browserId = item.BrowserId ?? ""
        if browserId.isEmpty { return "default" }
        return "\(browserId)_\(item.ProfileId ?? "")"
    }

    /// 获取指定数据项的连接状态
    public func getItemState(_ item: DataDashboardItem) -> ConnectionState {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections[getConnectionKey(item)]?.state ?? .disconnected
    }

    /// 获取指定连接 key 的连接
    public func getConnection(_ key: String) -> BrowserConnection? {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections[key]
    }

    /// 取出（不存在则登记）连接。供 CDP 引擎（A3）使用。
    public func obtainConnection(_ key: String) -> BrowserConnection {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        if let hit = connections[key] { return hit }
        let conn = BrowserConnection()
        conn.Key = key
        connections[key] = conn
        return conn
    }

    /// 断开指定连接：关闭会话，自启动的隐藏浏览器则终止进程。
    public func disconnectConnection(_ key: String) {
        connectionsLock.lock()
        let conn = connections.removeValue(forKey: key)
        connectionsLock.unlock()
        guard let conn else { return }
        conn.client?.close()
        if let p = conn.launchedProcess, p.isRunning { p.terminate() }
        setConnectionState(key, .disconnected)
        RuntimeLog.debug("[DataPolling] disconnected: \(key)")
    }

    /// 使指定连接失效（保留进程，下次可重连）
    public func invalidateConnection(_ key: String) {
        connectionsLock.lock()
        let conn = connections.removeValue(forKey: key)
        connectionsLock.unlock()
        conn?.client?.close()
        setConnectionState(key, .disconnected)
    }

    /// 设置连接状态并触发事件
    public func setConnectionState(_ key: String, _ state: ConnectionState) {
        connectionsLock.lock()
        connections[key]?.state = state
        connectionsLock.unlock()
        ConnectionStateChanged?(key, state)
    }

    // MARK: - 释放

    /// 释放所有资源：停定时器、关引擎持有的浏览器资源、断开连接。对应 C# `Dispose`。
    public func dispose() {
        for t in timers.values { t.stop() }
        timers.removeAll()
        apiEngine?.shutdown()
        extensionEngine?.shutdown()
        cdpEngine?.shutdown()

        connectionsLock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        connectionsLock.unlock()
        for conn in all {
            conn.client?.close()
            if let p = conn.launchedProcess, p.isRunning { p.terminate() }
        }
    }
}
