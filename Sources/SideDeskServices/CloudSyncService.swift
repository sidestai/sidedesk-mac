import Foundation
import SideDeskCore

/// 云同步状态。对应 C# `CloudSyncState`。
public enum CloudSyncState {
    case Idle
    case Syncing
    case Success
    case Failed
    case NotLoggedIn
}

/// 云同步服务（事件驱动模型，对应 C# `CloudSyncService` 主文件）：
/// - 启动时对账：推送本地未同步结构 → 拉取服务端全量结构补齐本地 → 拉取行级数据；
/// - 运行中：本地编辑经防抖行级推送即时更新服务端，远端变更由 WebSocket 通知后拉取；
/// - 退出/手动同步时做一次全量上传兜底（改名、移动等低频结构变更）。
///
/// 分文件：载荷构建与映射回写见 `+Payload`，结构拉取/共享清理见 `+Structure`，
/// 行级推送/拉取见 `+Rows`。
///
/// 与 C# 的一处口径差异（更安全）：C# 多处只判 HTTP 2xx 即继续（业务 code≠200 时
/// 内部映射/删除标记仍会执行）；Swift 统一经 `BackendApiClient.Envelope.ok`
/// （HTTP 2xx 且 code==200）门控——业务失败视为失败，不标墓碑、不回写映射。
public final class CloudSyncService {

    // MARK: - 端点（基址由 BackendApiClient 统一收口 Constants.URLs.serverBaseUrl）

    static let syncEndpoint = "/api/sidebar/sync"
    static let deleteEndpoint = "/api/sidebar/sync/delete"
    static let createBarEndpoint = "/api/sidebar/sync/bar"
    static let settingSyncEndpoint = "/api/sidebar/setting/sync"
    static let settingListEndpoint = "/api/sidebar/setting/list"
    static let itemOwnerEndpoint = "/api/sidebar/sync/item-owner"
    static let teamLibraryEndpoint = "/api/sidebar/item/team-library"
    static let rowPushEndpoint = "/api/sidebar/item-row/push"
    static let rowPullEndpoint = "/api/sidebar/item-row/pull"
    static let resourcePosEndpoint = "/api/sidebar/resource-pos/save"
    static let createItemEndpoint = "/api/sidebar/sync/item"
    static let structurePullEndpoint = "/api/sidebar/sync/pull"
    static let shareImportsEndpoint = "/api/sidebar/share/imports/mine"
    static let sharedItemEndpoint = "/api/sidebar/sync/shared-item"
    static let sharedBarItemsEndpoint = "/api/sidebar/sync/shared-bar-items"

    /// 本客户端声明的云同步结构协议版本（对应 C# `SyncProtocolVersion`）。
    /// 2 = 上报显式删除墓碑，服务端只按墓碑删，不再做「缺席即删除」对账。
    public static let syncProtocolVersion = 2

    let api: BackendApiClient

    /// 由组合根构造；测试可注入替身 api。
    public init(api: BackendApiClient? = nil) {
        self.api = api ?? BackendApiClient(logTag: "[CloudSync]", timeout: 30)
    }

    // MARK: - 状态与并发锁

    /// 同步状态变化通知（状态, 说明文本），供 UI 显示。对应 C# `StatusChanged` 事件。
    public var statusChanged: ((CloudSyncState, String) -> Void)?
    public private(set) var lastState: CloudSyncState = .Idle
    public private(set) var lastMessage: String = ""

    func setStatus(_ state: CloudSyncState, _ message: String) {
        lastState = state
        lastMessage = message
        statusChanged?(state, message)
    }

    private let flagLock = SyncLock()
    private var syncing = false
    private var reconciling = false
    // +Rows 分文件经 claim/release 键路径访问，需模块内可见
    var pushingRows = false

    /// 原子占锁：已占用返回 false（对应 C# 的 _syncing/_reconciling/_pushingRows 检查+置位）。
    func claim(_ kp: ReferenceWritableKeyPath<CloudSyncService, Bool>) -> Bool {
        flagLock.withLock {
            if self[keyPath: kp] { return false }
            self[keyPath: kp] = true
            return true
        }
    }

    func release(_ kp: ReferenceWritableKeyPath<CloudSyncService, Bool>) {
        flagLock.withLock { self[keyPath: kp] = false }
    }

    /// 行级同步快照：每个模块上次同步时的列表数据 JSON（差异对比用）。key=PanelItem.Id。
    private let snapshotLock = SyncLock()
    private var rowSnapshots: [String: String] = [:]

    func snapshot(for id: String) -> String? { snapshotLock.withLock { rowSnapshots[id] } }
    func setSnapshot(_ json: String, for id: String) { snapshotLock.withLock { rowSnapshots[id] = json } }

    /// 上次因「模块不存在」触发愈合同步的时间（60 秒节流，对应 C# `_lastHealSyncUtc`）。
    private let healLock = SyncLock()
    private var lastHealSync: Date?

    func claimHealSync() -> Bool {
        healLock.withLock {
            let now = Date()
            if let last = lastHealSync, now.timeIntervalSince(last) <= 60 { return false }
            lastHealSync = now
            return true
        }
    }

    /// 即时行推送防抖定时器（2 秒内多次编辑合并为一次推送，对应 C# `_rowPushDebounceTimer`）。
    private let timerLock = SyncLock()
    private var rowPushDebounceTimer: ServiceTimer?

    // MARK: - 起停

    /// 开启云同步：执行一次启动对账（不再定时全量上传）。对应 C# `Start`。
    public func start() {
        Task { [weak self] in _ = await self?.reconcile(pushLocal: true) }
    }

    /// 停止云同步（已无定时任务，保留空实现兼容既有调用方）。对应 C# `Stop`。
    public func stop() {}

    /// 取当前窗口配置（对应 C# `ServiceSeam.TryGetWindowConfigs`：从组合根解析同一实例）。
    func configs() -> WindowConfigManager? {
        AppContainer.shared.resolve(WindowConfigManager.self)
    }

    /// 机器名（对应 C# `Environment.MachineName`）。
    static var machine: String { ProcessInfo.processInfo.hostName }

    // MARK: - 作用域守卫

    /// 内存窗口配置与当前账号作用域是否已脱节（登录态已变更、窗口尚未按新作用域重载）。
    /// 对应 C# `IsManagerScopeStale`。
    static func isManagerScopeStale(_ mgr: WindowConfigManager) -> Bool {
        guard let loaded = mgr.LoadedScope, !loaded.isEmpty else { return false }
        return loaded != LocalDbService.currentScope()
    }

    /// 结构上传是否必须拒绝（对应 C# `MustRejectStructureUpload`）：
    /// 1) 内存作用域脱节；2) 已持有 Token 但内存数据仍属未归属的 local 作用域
    /// （「登出重启后重新登录」必经态：Token 先存、AccountUserId 等 userinfo 回来才写）。
    /// 此时上报会让服务端 bar 级对账软删该账号全部窗口——必须先晋升作用域并重载再上报。
    static func mustRejectStructureUpload(_ mgr: WindowConfigManager, _ settings: Settings) -> Bool {
        if isManagerScopeStale(mgr) { return true }
        return !(settings.AccountToken ?? "").isEmpty && mgr.LoadedScope == "local"
    }

    // MARK: - 对账 / 手动同步

    /// 启动对账 / 结构刷新（对应 C# `ReconcileAsync`）：
    /// 1) pushLocal=true 先上传本地未同步结构与行级离线变更（先推后拉，避免全量拉取覆盖本地新数据）；
    /// 2) 拉取全量结构合并，新建模块全量拉行；3) 清理失效共享；4) 拉行级数据与团队模块数据。
    /// 启动时与收到 structure_changed WS 通知（pushLocal=false）时调用。
    @discardableResult
    public func reconcile(pushLocal: Bool) async -> Bool {
        guard claim(\.reconciling) else { return false }
        defer { release(\.reconciling) }

        let settings = Seam.settings
        guard let cfg = configs() else { return false }
        guard let token = settings.AccountToken, !token.isEmpty else {
            setStatus(.NotLoggedIn, Lang.t("cloudDrive.cannotSyncNotLogged"))
            return false
        }
        if Self.mustRejectStructureUpload(cfg, settings) {
            RuntimeLog.debug("[CloudSync] reconcile skipped: structure upload unsafe (scope stale or still 'local' while authenticated)")
            return false
        }

        setStatus(.Syncing, Lang.t("cloudDrive.syncing"))

        // 1) 推送本地未同步的结构与行级离线变更
        if pushLocal {
            _ = await uploadStructure(settings: settings, mgr: cfg)
            await pushAllRows(mgr: cfg, settings: settings)
        }

        // 2) 拉取全量结构并合并；新建模块需要全量拉行（增量 since 拉不到旧行）
        var newPanels: [PanelItem] = []
        var pulledItemServerIds = Set<String>()
        var structureChanged = await pullAndMergeStructure(mgr: cfg, settings: settings,
                                                           newPanelsOut: &newPanels,
                                                           pulledItemServerIdsOut: &pulledItemServerIds)
        for np in newPanels where RowChangeTracker.isRowSyncable(np.Type) && !(np.ServerId ?? "").isEmpty {
            _ = await pullItemFull(np)
        }

        // 2.5) 清理已失效的共享组件（弥补离线时错过 WS 取消通知的场景）
        if pushLocal {
            let cleaned = await cleanupRevokedShares(mgr: cfg, settings: settings, structureItemIds: pulledItemServerIds)
            structureChanged = structureChanged || cleaned
        }

        // 3) 拉取行级数据 + 团队模块数据
        await pullAllRows(mgr: cfg, settings: settings)
        await pullTeamItems(mgr: cfg)

        settings.LastCloudSyncTime = Date()
        settings.Save()

        if structureChanged {
            // 合并进来的窗口可能不在 dock 中：先自愈 dock 成员再落盘刷新，免重启立即可见。
            cfg.RepairDockMembership()
            Seam.uiPost { cfg.Save() }
            Seam.uiPost { Seam.refreshAllWindows?() }
            // 结构变更可能增删数据看板项：重新登记轮询（refreshAllWindows 在 mac 侧已含标签刷新）
            AppContainer.shared.resolve(DataPollingService.self)?.syncFromConfigs(cfg)
        }

        setStatus(.Success, Self.syncedText(settings.LastCloudSyncTime ?? Date()))
        return true
    }

    /// 立即执行一次全量同步（兜底路径：全量结构上传 + 行推送 + 行拉取）。
    /// 退出前、分享导入后与手动同步使用。对应 C# `SyncNowAsync`。
    /// silent 参数沿用 C# 签名（C# 当前实现亦未使用）。
    @discardableResult
    public func syncNow(silent: Bool = false) async -> Bool {
        guard claim(\.syncing) else { return false }
        defer { release(\.syncing) }

        let settings = Seam.settings
        guard let cfg = configs() else { return false }
        guard let token = settings.AccountToken, !token.isEmpty else {
            setStatus(.NotLoggedIn, Lang.t("cloudDrive.cannotSyncNotLogged"))
            return false
        }
        if Self.mustRejectStructureUpload(cfg, settings) {
            RuntimeLog.debug("[CloudSync] sync skipped: structure upload unsafe (scope stale or still 'local' while authenticated)")
            return false
        }

        setStatus(.Syncing, Lang.t("cloudDrive.syncing"))
        guard await uploadStructure(settings: settings, mgr: cfg) else {
            setStatus(.Failed, Lang.t("cloudDrive.syncFailedUpload"))
            return false
        }

        settings.LastCloudSyncTime = Date()
        settings.Save()

        await pushAllRows(mgr: cfg, settings: settings)
        await pullAllRows(mgr: cfg, settings: settings)

        setStatus(.Success, Self.syncedText(settings.LastCloudSyncTime ?? Date()))
        return true
    }

    /// 上传本地全量结构（bars/items），回写映射并同步设置项。对应 C# `UploadStructureAsync`。
    func uploadStructure(settings: Settings, mgr: WindowConfigManager) async -> Bool {
        // 兜底守卫（入口已拦，此处防新增调用点遗漏，如 notifyRowsChanged 的 needStructure 分支）
        if Self.mustRejectStructureUpload(mgr, settings) {
            RuntimeLog.debug("[CloudSync] structure upload rejected: scope stale or still 'local' while authenticated")
            return false
        }
        // 折叠：本地无 serverId 的 bar 不上传成新 bar——组件并入第一个已同步 bar 后删除该本地 bar
        if Self.foldUnboundBarsIntoFirstBar(mgr) {
            // 被折叠删除的可能正是正在显示的 bar：自愈 dock 后重绑 UI，免重启
            mgr.RepairDockMembership()
            Seam.uiPost { Seam.reloadWindowsUi?() }
        }

        // 显式删除墓碑：服务端删除只认这份列表——「内存里没有」不再被解读为「用户删了」
        let (deletedBars, deletedItems) = LocalDbService.loadPendingDeleteTombstones()
        let payload = Self.buildSyncPayload(mgr: mgr, deletedBars: deletedBars, deletedItems: deletedItems)
        let r = await api.send("POST", Self.syncEndpoint, body: payload)
        guard r.ok else {
            RuntimeLog.debug("[CloudSync] structure upload failed: \(r.transportError ?? r.msg)")
            return false
        }

        // 回写 localId -> serverId 映射（Envelope 已保证 code==200 且 data 存在）
        Self.applyServerIdMappings(data: r.data, settings: settings, mgr: mgr)

        // 墓碑已被服务端受理：只标本次上报过的，保留到期后清理；失败或未涵盖的保持待上报
        LocalDbService.markTombstonesSynced(barServerIds: deletedBars, itemServerIds: deletedItems)

        // 窗口同步成功后追加设置项同步（对应 C# UploadStructureAsync 尾步 SyncSettingsAsync）
        await syncSettingsUpload(settings)
        return true
    }

    // MARK: - 删除 / 单窗口创建 / 单模块创建

    /// 通知服务器软删除 bar 或 item。对应 C# `DeleteOnServerAsync`。
    @discardableResult
    public func deleteOnServer(type: String, serverId: String) async -> Bool {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty, !serverId.isEmpty else { return false }
        let r = await api.send("POST", Self.deleteEndpoint,
                               body: .object(["type": .string(type), "serverId": .string(serverId)]))
        return r.ok
    }

    /// 通知服务器删除 bar（连带软删其下所有 items）。
    @discardableResult
    public func deleteBarOnServer(_ serverId: String) async -> Bool {
        await deleteOnServer(type: "bar", serverId: serverId)
    }

    /// 通知服务器删除 item（Group 连带软删其子 items）。
    @discardableResult
    public func deleteItemOnServer(_ serverId: String) async -> Bool {
        await deleteOnServer(type: "item", serverId: serverId)
    }

    /// 将单个新建窗口（含其模块）提交到专用接口，不做全量同步。对应 C# `CreateBarOnServerAsync`。
    @discardableResult
    public func createBarOnServer(_ win: WindowConfig) async -> Bool {
        guard let cfg = configs() else { return false }
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return false }
        let payload = JSONValue.object([
            "app": .string("SideDesk"),
            "machine": .string(Self.machine),
            "corpId": settings.SelectedCorpId.map { JSONValue.string($0) } ?? .null,
            "bar": Self.buildSyncBarValue(win),
        ])
        let r = await api.send("POST", Self.createBarEndpoint, body: payload)
        guard r.ok else { return false }
        Self.applyServerIdMappings(data: r.data, settings: settings, mgr: cfg)
        return true
    }

    /// 轻量接口：确保单个模块已同步到服务端，返回 serverId。对应 C# `EnsureItemServerIdAsync`。
    /// 已有 ServerId 直接返回；否则 POST /sidebar/sync/item 创建（载荷与全量同步一致）。
    public func ensureItemServerId(_ item: PanelItem, barServerId: String) async -> String? {
        if let sid = item.ServerId, !sid.isEmpty { return sid }
        let settings = Seam.settings
        guard let token = settings.AccountToken, !token.isEmpty, !barServerId.isEmpty else { return nil }

        // 团队 ID 为服务端加密串，直接透传，由后端解析
        var corpId = JSONValue.null
        if item.OwnerType == "team", let tid = item.TeamId, !tid.isEmpty { corpId = .string(tid) }
        let payload = JSONValue.object([
            "barServerId": .string(barServerId),
            "item": .object([
                "localId": .string(item.Id),
                "type": .string(item.`Type`.serverName),
                "title": item.Title.map { JSONValue.string($0) } ?? .null,
                "corpId": corpId,
                "data": Self.buildItemData(item),
            ]),
        ])
        let r = await api.send("POST", Self.createItemEndpoint, body: payload)
        guard r.ok, case .object(let data)? = r.data,
              let serverId = data["serverId"]?.stringValue, !serverId.isEmpty else { return nil }
        item.ServerId = serverId
        return serverId
    }

    // MARK: - 模块归属变更（个人 ↔ 团队）

    /// 最近一次归属推送的失败原因（对应 C# `LastOwnershipError`）。
    public private(set) var LastOwnershipError: String?

    /// 实时推送模块归属变更到服务器。对应 C# `UpdateItemOwnershipAsync`。
    /// 返回：true=成功；false=尝试过但失败（原因见 LastOwnershipError）；nil=未尝试（未登录/未开云同步/他人模块）。
    public func updateItemOwnership(_ item: PanelItem, win: WindowConfig? = nil) async -> Bool? {
        LastOwnershipError = nil
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return nil }

        // 窗口尚未同步：先把整个窗口（含模块）提交，corpId 随载荷落库
        if let win, (win.ServerId ?? "").isEmpty {
            if await !createBarOnServer(win) {
                LastOwnershipError = Lang.t("cloudDrive.syncWindowFailed")
                return false
            }
        }

        // 模块尚未同步：先创建（创建时已携带 corpId）；窗口不可用则留给全量同步
        if (item.ServerId ?? "").isEmpty {
            guard let win, let barSid = win.ServerId, !barSid.isEmpty else { return nil }
            let sid = await ensureItemServerId(item, barServerId: barSid)
            if (sid ?? "").isEmpty {
                LastOwnershipError = Lang.t("cloudDrive.syncModuleFailed")
                return false
            }
            return true
        }

        var corpId = JSONValue.null
        if item.OwnerType == "team", let tid = item.TeamId, !tid.isEmpty { corpId = .string(tid) }
        let payload = JSONValue.object(["serverId": .string(item.ServerId!), "corpId": corpId])
        let r = await api.send("POST", Self.itemOwnerEndpoint, body: payload)
        if r.transportFailed {
            LastOwnershipError = r.transportError ?? ""
            return false
        }
        if !r.ok {
            // 他人创建的模块：服务端归属保持原样（导入组件本就不应改归属），视为无需同步，不报错。
            // 「仅创建者」是服务端协议哨兵文案（非用户可见 UI 串），与 C# 同口径硬编码匹配。
            if r.msg.contains("仅创建者") { return nil }
            // Envelope 不携带 HTTP 状态码：HTTP 层失败（msg 空）回落通用文案
            LastOwnershipError = r.msg.isEmpty ? Lang.t("cloudDrive.serverProcessingFailed") : r.msg
            return false
        }
        return true
    }

    // MARK: - 团队组件库

    /// 从服务器拉取团队组件库数据，更新本地团队模块到服务端最新版本。对应 C# `PullTeamItemsAsync`。
    public func pullTeamItems(mgr: WindowConfigManager) async {
        let settings = Seam.settings
        guard let token = settings.AccountToken, !token.isEmpty else { return }
        guard let corp = settings.SelectedCorpId, !corp.isEmpty else { return }

        let r = await api.send("GET", Self.teamLibraryEndpoint + "?corpId=" + BackendApiClient.queryValue(corp))
        guard r.ok, case .array(let dataArr)? = r.data else { return }

        // 构建 serverId -> itemData 映射（itemData 可能是 JSON 字符串或已展开的对象）
        var serverDataMap: [String: JSONValue] = [:]
        for entry in dataArr {
            guard case .object(let e) = entry,
                  let serverId = e["itemServerId"]?.stringValue, !serverId.isEmpty else { continue }
            let parsed: JSONValue?
            if case .string(let s)? = e["itemData"] {
                parsed = Self.parseJSON(s)
            } else {
                parsed = e["itemData"]
            }
            guard let data = parsed, case .object = data else { continue }
            serverDataMap[serverId] = data
        }
        if serverDataMap.isEmpty { return }

        var changed = false
        for win in mgr.Windows {
            for p in win.Panels {
                if Self.applyTeamItemData(p, serverDataMap: serverDataMap) { changed = true }
            }
        }
        if changed {
            Seam.uiPost { mgr.Save() }
            RuntimeLog.debug("[CloudSync] team module data updated to latest server version")
        }
    }

    /// 递归匹配团队模块并应用服务端数据（含分组子模块）。对应 C# `ApplyTeamItemData`。
    /// C# 用 PopulateObject 覆盖后恢复元数据；Swift 等价走 applyItemDataToPanel
    /// （元数据/行列表本就不复制），且按实际变化返回（避免无差异也 Save）。
    static func applyTeamItemData(_ p: PanelItem, serverDataMap: [String: JSONValue]) -> Bool {
        var changed = false
        if p.OwnerType == "team", let sid = p.ServerId, !sid.isEmpty,
           var data = serverDataMap[sid]?.objectValue {
            // 行级同步类型的列表/对象已改由行表读取，剔除服务端旧快照避免覆盖本地行数据。
            // C# 此处剔除 13 键（不含 CheckInItems）——服务端 itemData 本就不含行列表，口径等效。
            for k in ["StickyNotes", "DeskNotes", "TodoItems", "TimerItems", "CountdownItems",
                      "SignalLights", "ClipboardItems", "FileItems", "Pomodoro", "DashboardItems",
                      "DigitalEmployeeIds", "FriendUserIds", "QuickItems"] {
                data.removeValue(forKey: k)
            }
            // C# PopulateObject 后恢复 OwnerType/TeamId/TeamName（Id/ServerId/Type 本就不在
            // itemData 应用范围内）；等价于应用前剔除——团队归属以本地为准
            for k in ["OwnerType", "TeamId", "TeamName"] { data.removeValue(forKey: k) }
            if applyItemDataToPanel(p, .object(data)) { changed = true }
        }
        if let children = p.ChildPanels {
            for c in children {
                if applyTeamItemData(c, serverDataMap: serverDataMap) { changed = true }
            }
        }
        return changed
    }

    // MARK: - 上传前折叠

    /// 本地无 serverId 的 personal bar 不上传为新 bar——全部组件并入第一个已同步 personal bar
    /// 末尾后删除该本地 bar（用户规则：不随便新增 bar）。对应 C# `FoldUnboundBarsIntoFirstBar`。
    /// 无已同步 bar 时不折叠（内容无处可去，保留原样由上传新建第一个 bar）。
    /// bar 删除不打墓碑（server_id 空）服务端无感知；返回是否发生折叠（调用方据此重绑 UI）。
    static func foldUnboundBarsIntoFirstBar(_ mgr: WindowConfigManager) -> Bool {
        guard let target = mgr.Windows.first(where: { !($0.ServerId ?? "").isEmpty && $0.OwnerType == "personal" }) else {
            return false
        }
        let unbound = mgr.Windows.filter { $0.ServerId == nil && $0.OwnerType == "personal" && $0.ShareMode == nil }
        if unbound.isEmpty { return false }
        for bar in unbound {
            if !bar.Panels.isEmpty {
                target.Panels.append(contentsOf: bar.Panels)
                bar.Panels = []
            }
            // Windows + 两侧 dock 移除并落库；无 serverId 不打墓碑，服务端无感知
            mgr.Remove(bar.Id)
            RuntimeLog.debug("[CloudSync] folded unsynced bar into first bar: \(bar.Name) -> \(target.Name)")
        }
        return true
    }

    // MARK: - 行变更通知（防抖推送入口）

    /// 通知行数据已变更（UI 编辑/Save 后调用）。防抖 2 秒后自动推送。对应 C# `NotifyRowsChanged`。
    /// 无需指定模块——触发时自动扫描所有有 ServerId 的行同步模块。
    public func notifyRowsChanged() {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return }
        timerLock.withLock {
            if rowPushDebounceTimer == nil {
                rowPushDebounceTimer = Seam.timerFactory(2) { [weak self] in
                    guard let self else { return }
                    self.timerLock.withLock { self.rowPushDebounceTimer?.stop() }
                    Task { await self.instantRowPush() }
                }
            }
            // 重置防抖（BackgroundTimer stop+start = 重新起算 2 秒）
            rowPushDebounceTimer?.stop()
            rowPushDebounceTimer?.start()
        }
    }

    /// 防抖到点：存在尚未取得 ServerId 的行同步模块时先上传结构，再推行。
    private func instantRowPush() async {
        let settings = Seam.settings
        // 定时器排队期间开关可能被关闭：触发时再次检查
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return }
        guard let cfg = configs() else { return }
        var needStructure = false
        for win in cfg.Windows {
            for p in WindowConfigManager.enumerateAllPanels(win.Panels) {
                if RowChangeTracker.isRowSyncable(p.`Type`) && (p.ServerId ?? "").isEmpty {
                    needStructure = true
                    break
                }
            }
            if needStructure { break }
        }
        if needStructure {
            RuntimeLog.debug("[CloudSync] unsynced modules exist, uploading structure first to obtain ServerId")
            _ = await uploadStructure(settings: settings, mgr: cfg)
        }
        await pushAllRows(mgr: cfg, settings: settings)
    }

    // MARK: - 文案 / 时间小工具

    /// 「已同步 · 时间」文案。C# 走 Lang.TF 的 string.Format（支持 {0:yyyy-MM-dd HH:mm}）；
    /// Swift 的 Lang.tf 只替换 {i}，故手动替换格式占位符（兼容纯 {0} 词典）。
    static func syncedText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        let text = f.string(from: date)
        var s = Lang.t("cloudDrive.synced")
        s = s.replacingOccurrences(of: "{0:yyyy-MM-dd HH:mm}", with: text)
        s = s.replacingOccurrences(of: "{0}", with: text)
        return s
    }

    /// C# `DateTime.ToString("o")` 等价：带小数秒的 UTC ISO8601（载荷 syncedAt/行 updatedAt/since 共用）。
    static func isoO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - JSONValue 取值便利（服务层内部用）

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}