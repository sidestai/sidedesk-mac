import Foundation
import SideDeskCore

/// 云同步：行级数据推送（快照差分）与拉取合并（对应 C# `CloudSyncService.RowsPush.cs`
/// 与 `CloudSyncService.RowsPull.cs`）。
extension CloudSyncService {

    // MARK: - 有序行集合

    /// rowId -> 行内容 的有序映射。Swift Dictionary 无序，而 C# Dictionary 保持插入序——
    /// 行顺序影响列表展示与 replaceAll 的位置性比较，必须显式保序。
    /// 语义对齐 C#：同 id 后值覆盖前值，位置保持首次插入处。
    struct OrderedRows {
        private var map: [String: JSONValue] = [:]
        private(set) var keys: [String] = []

        init() {}

        /// 从行数组构建（对应 C# `ParseRowsFromJson` 的 JArray 遍历）：
        /// 取 Id/id 字段为键，空键跳过；非对象元素跳过。
        init(array: [JSONValue]) {
            for item in array {
                guard let o = item.objectValue else { continue }
                let id = o["Id"]?.stringValue ?? o["id"]?.stringValue ?? ""
                if id.isEmpty { continue }
                if map[id] == nil { keys.append(id) }
                map[id] = item
            }
        }

        subscript(id: String) -> JSONValue? {
            get { map[id] }
            set {
                if let newValue {
                    if map[id] == nil { keys.append(id) }
                    map[id] = newValue
                } else if map.removeValue(forKey: id) != nil {
                    keys.removeAll { $0 == id }
                }
            }
        }

        var values: [JSONValue] { keys.compactMap { map[$0] } }
        var count: Int { keys.count }
        func contains(_ id: String) -> Bool { map[id] != nil }
        var arrayValue: JSONValue { .array(values) }
    }

    // MARK: - JSON / 比较小工具

    /// 解析 JSON 字符串（失败回落 nil，对应 C# try/catch 包裹的 JArray/JObject.Parse）。
    static func parseJSON(_ s: String) -> JSONValue? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// JSONValue → 类型化模型（ISO8601 日期策略；失败回落 nil，对应 C# DeserializeObject ?? new）。
    static func decode<T: Decodable>(_ value: JSONValue, _ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? SideDeskJSON.decoder().decode(type, from: data)
    }

    /// 行列表宽容解码：C# Json.NET 先构造对象（字段初始化器生效）再只填 JSON 出现的字段，
    /// 缺键保留初始值；Swift 合成 Decodable 缺非可选键直接失败。调用方传入全新实例的
    /// 序列化形态（`jsonValue(Model())`）打底、服务端字段覆盖后再解码，对齐该语义。
    /// 典型场景：番茄钟同步行刻意剔除运行状态字段（见 `sanitizePomodoroForSync`），接收端必然缺键。
    static func decodeRows<T: Decodable>(_ value: JSONValue, _ type: T.Type, base: JSONValue) -> [T]? {
        guard case .array(let arr) = value, case .object(let defaults) = base else { return nil }
        var out: [T] = []
        for item in arr {
            guard var o = item.objectValue else { return nil }
            for (k, v) in defaults where o[k] == nil { o[k] = v }
            guard let m = decode(.object(o), T.self) else { return nil }
            out.append(m)
        }
        return out
    }

    /// 行内容比较（对应 C# `RowsContentEquals`）：对象逐键递归、数组按位递归；
    /// 数字跨 int/double 按数值等价（服务端 JS 数字往返会把 36.0 规范化为 36，
    /// 判不等会导致「合并判变更 → 再推送 → 再广播」的多端乒乓循环）。
    ///
    /// 日期串额外容忍（Swift 侧新增，C# 无此问题）：C# "o" 格式带 7 位小数秒，
    /// Swift iso8601 编码不带——同一 instant 的不同写法若判不等，Mac 与 Windows
    /// 客户端会互相改写对方的日期格式形成乒乓。两侧都能解析为日期时按整秒比较
    ///（Swift 编码本就把小数秒截断到整秒，语义等价）。
    static func rowsContentEquals(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let ao), .object(let bo)):
            if ao.count != bo.count { return false }
            for (k, v) in ao {
                guard let bv = bo[k], rowsContentEquals(v, bv) else { return false }
            }
            return true
        case (.array(let aa), .array(let ba)):
            if aa.count != ba.count { return false }
            for i in aa.indices {
                if !rowsContentEquals(aa[i], ba[i]) { return false }
            }
            return true
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.int(let x), .double(let y)): return Double(x) == y
        case (.double(let x), .int(let y)): return x == Double(y)
        case (.string(let x), .string(let y)):
            if x == y { return true }
            if let dx = parseISODate(x), let dy = parseISODate(y) {
                return floor(dx.timeIntervalSince1970) == floor(dy.timeIntervalSince1970)
            }
            return false
        default: return a == b
        }
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISODate(_ s: String) -> Date? {
        fractionalISO.date(from: s) ?? plainISO.date(from: s)
    }

    /// deletedAt 删除标记（对应 C#：JTokenType.Date 或非空字符串）。
    /// JSON 线格式没有 Date 类型，只有非空字符串才算已删除；null/缺失/其他类型不算。
    static func isDeletedFlag(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        if case .string(let s) = v { return !s.isEmpty }
        return false
    }

    // MARK: - 列表数据提取

    /// 提取模块的列表数据为 JSON 字符串（快照对比用）。对应 C# `GetListDataJson`。
    static func getListDataJson(_ p: PanelItem) -> String? {
        let list: JSONValue?
        switch p.`Type` {
        case .StickyNotes: list = p.StickyNotes.map { jsonValue($0) }
        case .Notes: list = p.DeskNotes.map { jsonValue($0) }
        case .TodoList: list = p.TodoItems.map { jsonValue($0) }
        case .Timer: list = p.TimerItems.map { jsonValue($0) }
        case .Countdown: list = p.CountdownItems.map { jsonValue($0) }
        case .SignalLight: list = p.SignalLights.map { jsonValue($0) }
        case .Clipboard: list = p.ClipboardItems.map { jsonValue($0) }
        case .FileArea: list = p.FileItems.map { jsonValue($0) }
        case .Pomodoro:
            // 番茄钟仅一条行记录，包装成单元素列表；剔除计时运行状态（云同步只带配置）
            list = p.Pomodoro.map { .array([sanitizePomodoroForSync($0)]) }
        case .DataDashboard: list = p.DashboardItems.map { jsonValue($0) }
        case .DigitalEmployee:
            // 引用 Id 列表包装为行对象；空 Id 过滤（C# 此处过滤，Friend 不过滤——口径保留）
            list = p.DigitalEmployeeIds.map { ids in
                .array(ids.filter { !$0.isEmpty }.map { id -> JSONValue in
                    let r = DigitalEmployeeRow(); r.Id = id; r.EmployeeId = id
                    return jsonValue(r)
                })
            }
        case .Friend:
            list = p.FriendUserIds.map { ids in
                .array(ids.map { id -> JSONValue in
                    let r = FriendUserRow(); r.Id = id; r.UserId = id
                    return jsonValue(r)
                })
            }
        case .QuickGroup: list = p.QuickItems.map { jsonValue($0) }
        case .CheckIn: list = p.CheckInItems.map { jsonValue($0) }
        default: list = nil
        }
        guard let list else { return nil }
        return jsonString(list)
    }

    /// 剔除番茄钟运行状态字段，仅保留番茄数、时长与行为配置。对应 C# `SanitizePomodoroForSync`。
    private static func sanitizePomodoroForSync(_ pom: PomodoroSettings) -> JSONValue {
        guard var o = jsonValue(pom).objectValue else { return .object([:]) }
        for k in ["Mode", "RemainingSeconds", "IsRunning", "StartTime"] { o.removeValue(forKey: k) }
        return .object(o)
    }

    /// 解析行集合 JSON 为有序映射。对应 C# `ParseRowsFromJson`。
    static func parseRowsFromJson(_ json: String) -> OrderedRows {
        guard let v = parseJSON(json), case .array(let arr) = v else { return OrderedRows() }
        return OrderedRows(array: arr)
    }

    // MARK: - 行级推送

    /// 行级推送：对比快照与当前数据，将变更行推送到服务端。
    /// 绑定同一 ServerId 的多个本地面板先取并集对齐后只推送一次，
    /// 避免多视图互相推送删除差异清空对方数据。对应 C# `PushAllRowsAsync`。
    func pushAllRows(mgr: WindowConfigManager, settings: Settings) async {
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return }
        guard claim(\.pushingRows) else { return }
        defer { release(\.pushingRows) }

        // 收集所有支持行同步的面板（含分组子面板），按 ServerId 分组（保首次出现序）
        var groups: [String: [PanelItem]] = [:]
        var groupOrder: [String] = []
        var unsynced: [PanelItem] = []
        for win in mgr.Windows {
            for p in WindowConfigManager.enumerateAllPanels(win.Panels) {
                guard RowChangeTracker.isRowSyncable(p.`Type`) else { continue }
                guard let sid = p.ServerId, !sid.isEmpty else { unsynced.append(p); continue }
                if groups[sid] == nil { groupOrder.append(sid) }
                groups[sid, default: []].append(p)
            }
        }
        for p in unsynced { await pushPanelRows(p, settings: settings) } // 内部记录日志并跳过
        for sid in groupOrder {
            let list = groups[sid]!
            if list.count == 1 {
                await pushPanelRows(list[0], settings: settings)
            } else {
                await pushSiblingGroup(list, settings: settings)
            }
        }
    }

    /// 单面板行推送：快照差分 → 组装载荷 → 发送 → 成功才更新快照。对应 C# `PushPanelRows`。
    private func pushPanelRows(_ p: PanelItem, settings: Settings) async {
        guard RowChangeTracker.isRowSyncable(p.`Type`) else { return }
        guard let serverId = p.ServerId, !serverId.isEmpty else {
            RuntimeLog.debug("[CloudSync] row push skipped (\(p.`Type`.serverName)): ServerId is empty (module not yet synced to server)")
            return
        }

        let currentJson = Self.getListDataJson(p) ?? "[]"
        // 无变化则静默跳过（Save/面板渲染会频繁触发本检查，跳过路径不打日志避免刷屏）
        if let lastJson = snapshot(for: p.Id), lastJson == currentJson { return }

        RuntimeLog.debug("[CloudSync] row push check (\(p.`Type`.serverName)) ServerId=\(serverId), dataLength=\(currentJson.count)")

        let oldRows = snapshot(for: p.Id).map { Self.parseRowsFromJson($0) } ?? OrderedRows()
        let newRows = Self.parseRowsFromJson(currentJson)
        let rowType = RowChangeTracker.getRowType(p.`Type`)
        // 更新/删除优先走缓存的服务端主键寻址
        let idMap = LocalDbService.getRowServerIds(newRows.keys + oldRows.keys)

        var changedRows: [JSONValue] = []
        var deletedRowIds: [String] = []
        var deletedRowServerIds: [String] = []

        for id in newRows.keys {
            let row = newRows[id]!
            if oldRows[id] == nil || !Self.rowsContentEquals(oldRows[id]!, row) {
                changedRows.append(Self.buildRowPayload(rowGuid: id, rowType: rowType, content: row, idMap: idMap))
            }
        }
        // 删除：已缓存 serverId（已同步到服务端）→ 主键删除；否则 GUID 兜底
        for key in oldRows.keys where !newRows.contains(key) {
            if let sids = idMap[key], let rsid = sids.rowServerId {
                deletedRowServerIds.append(rsid)
            } else {
                deletedRowIds.append(key)
            }
        }

        // 无变更则只更新快照（静默）
        if changedRows.isEmpty && deletedRowIds.isEmpty && deletedRowServerIds.isEmpty {
            setSnapshot(currentJson, for: p.Id)
            return
        }

        if await sendRowPush(serverId: serverId, changedRows: changedRows,
                             deletedRowIds: deletedRowIds, deletedRowServerIds: deletedRowServerIds,
                             settings: settings) {
            setSnapshot(currentJson, for: p.Id)
        }
    }

    /// 组装单行推送载荷：GUID 保留为新行临时身份/兜底，已缓存的 serverId 一并携带。
    /// 对应 C# `BuildRowPayload`。
    private static func buildRowPayload(rowGuid: String, rowType: String, content: JSONValue,
                                        idMap: [String: (rowServerId: String?, dataServerId: String?)]) -> JSONValue {
        var o: [String: JSONValue] = [
            "rowId": .string(rowGuid),
            "dataId": .string(rowGuid),
            "rowType": .string(rowType),
            "content": content,
            "updatedAt": .string(isoO(Date())),
        ]
        if let sids = idMap[rowGuid] {
            if let rsid = sids.rowServerId { o["rowServerId"] = .string(rsid) }
            if let dsid = sids.dataServerId { o["dataServerId"] = .string(dsid) }
        }
        return .object(o)
    }

    /// 推送行级变更载荷到服务端；成功返回 true。对应 C# `SendRowPushAsync`。
    private func sendRowPush(serverId: String, changedRows: [JSONValue],
                             deletedRowIds: [String], deletedRowServerIds: [String],
                             settings: Settings) async -> Bool {
        let payload = JSONValue.object([
            "itemServerId": .string(serverId),
            "rows": .array(changedRows),
            "deletedRowIds": .array(deletedRowIds.map { .string($0) }),
            "deletedRowServerIds": .array(deletedRowServerIds.map { .string($0) }),
        ])
        RuntimeLog.debug("[CloudSync] row push POST \(Self.rowPushEndpoint): \(changedRows.count) row changes, \(deletedRowServerIds.count) pk deletes, \(deletedRowIds.count) GUID fallback deletes")

        let r = await api.send("POST", Self.rowPushEndpoint, body: payload)
        if r.transportFailed {
            RuntimeLog.debug("[CloudSync] row push failed: \(r.transportError ?? "")")
            return false
        }
        // 业务层失败（HTTP 200 但 code≠200，如「无权操作此模块」）也视为推送失败：
        // 不更新快照，下次推送基于原快照重算差异重试；若误判成功数据会永久丢失
        if !r.ok {
            RuntimeLog.debug("[CloudSync] row push rejected by business layer: msg=\(r.msg)")
            // 「模块不存在」：服务端模块被对账软删而本地仍存在（多窗口/多设备上报竞态）。
            // 触发一次全量结构同步，服务端 processItems 会复活该模块；行数据不丢，后续重试即可成功。
            // 60 秒节流，避免多个面板同时被拒时连环触发全量同步。
            // 「模块不存在」是服务端协议哨兵文案（非用户可见 UI 串），与 C# 同口径硬编码匹配。
            if r.msg == "模块不存在", claimHealSync() {
                Task { [weak self] in await self?.syncNow(silent: true) }
            }
            return false
        }

        // 回填服务端返回的行主键映射：后续更新/删除即可改走 serverId 寻址
        if let rowIds = r.data?.objectValue?["rowIds"]?.objectValue {
            var entries: [(rowUid: String, rowServerId: String?, dataServerId: String?)] = []
            for (guid, v) in rowIds {
                let rsid = v.objectValue?["rowServerId"]?.stringValue
                let dsid = v.objectValue?["dataServerId"]?.stringValue
                if !guid.isEmpty && (rsid != nil || dsid != nil) {
                    entries.append((guid, rsid, dsid))
                }
            }
            if !entries.isEmpty { LocalDbService.saveRowServerIds(entries) }
        }
        return true
    }

    // MARK: - 同模块多视图推送

    /// 绑定同一 ServerId 的多个本地面板（原组件与导入组件共存场景）的推送处理：
    /// 取各视图当前数据的并集（某行在某视图快照中存在但已从该视图消失则视为删除），
    /// 与旧快照并集对比计算差异，只推送一次，成功后将所有视图对齐到合并结果。
    /// 对应 C# `PushSiblingGroupAsync`。
    private func pushSiblingGroup(_ group: [PanelItem], settings: Settings) async {
        // 1) 解析各视图的当前数据与快照
        var currents: [OrderedRows] = []
        var snaps: [OrderedRows] = []
        for p in group {
            currents.append(Self.parseRowsFromJson(Self.getListDataJson(p) ?? "[]"))
            snaps.append(snapshot(for: p.Id).map { Self.parseRowsFromJson($0) } ?? OrderedRows())
        }

        // 2) 并集：优先采纳「本地有改动」（快照≠当前）的视图的行——
        //    一个视图刚编辑、另一个视图还是旧数据时，旧视图不能覆盖新编辑
        var mergedRows = OrderedRows()
        for i in group.indices {
            for id in currents[i].keys {
                let row = currents[i][id]!
                let modified = snaps[i][id] == nil || !Self.rowsContentEquals(snaps[i][id]!, row)
                if modified { mergedRows[id] = row }
            }
        }
        // 未被任何视图改动的行：各视图内容一致，任取其一补齐
        for i in group.indices {
            for id in currents[i].keys where !mergedRows.contains(id) {
                mergedRows[id] = currents[i][id]!
            }
        }

        // 3) 删除优先：某行在某视图快照中存在但已从该视图当前数据消失，则从并集中移除
        for i in group.indices {
            for key in snaps[i].keys where !currents[i].contains(key) {
                mergedRows[key] = nil
            }
        }

        // 4) 与各视图旧快照的并集对比计算差异
        var oldUnion = OrderedRows()
        for s in snaps {
            for id in s.keys where !oldUnion.contains(id) { oldUnion[id] = s[id]! }
        }

        let rowType = RowChangeTracker.getRowType(group[0].`Type`)
        let idMap = LocalDbService.getRowServerIds(mergedRows.keys + oldUnion.keys)

        var changedRows: [JSONValue] = []
        for id in mergedRows.keys {
            let row = mergedRows[id]!
            if oldUnion[id] == nil || !Self.rowsContentEquals(oldUnion[id]!, row) {
                changedRows.append(Self.buildRowPayload(rowGuid: id, rowType: rowType, content: row, idMap: idMap))
            }
        }
        var deletedRowIds: [String] = []
        var deletedRowServerIds: [String] = []
        for key in oldUnion.keys where !mergedRows.contains(key) {
            if let sids = idMap[key], let rsid = sids.rowServerId {
                deletedRowServerIds.append(rsid)
            } else {
                deletedRowIds.append(key)
            }
        }

        if changedRows.isEmpty && deletedRowIds.isEmpty && deletedRowServerIds.isEmpty {
            alignSiblingGroup(group, mergedRows: mergedRows) // 无变更：也对齐各视图数据与快照
            return
        }

        if await sendRowPush(serverId: group[0].ServerId!, changedRows: changedRows,
                             deletedRowIds: deletedRowIds, deletedRowServerIds: deletedRowServerIds,
                             settings: settings) {
            alignSiblingGroup(group, mergedRows: mergedRows)
        }
        // 推送失败时不对齐：下次同步基于原快照重新计算差异并重试
    }

    /// 将绑定同一模块的多个视图的数据与快照对齐到合并结果；已对齐时直接跳过，
    /// 避免保存/刷新再次触发 notifyRowsChanged 形成循环空转。对应 C# `AlignSiblingGroup`。
    private func alignSiblingGroup(_ group: [PanelItem], mergedRows: OrderedRows) {
        let arr = mergedRows.arrayValue
        let json = Self.jsonString(arr)

        // 内容对比而非字符串对比：序列化往返（类型对象 ↔ JSONValue）的格式差异不影响判定
        var needAlign = false
        for p in group {
            let currentArr = Self.parseRowsFromJson(Self.getListDataJson(p) ?? "[]").arrayValue
            if !Self.rowsContentEquals(currentArr, arr) { needAlign = true; break }
            guard let snap = snapshot(for: p.Id) else { needAlign = true; break }
            if !Self.rowsContentEquals(Self.parseRowsFromJson(snap).arrayValue, arr) { needAlign = true; break }
        }
        if !needAlign { return }

        for p in group {
            Self.applyListDataToPanel(p, arr)
            setSnapshot(json, for: p.Id)
        }
        RuntimeLog.debug("[CloudSync] aligned \(group.count) views of the same module, \(mergedRows.count) rows in total")
        Seam.uiPost { [weak self] in
            guard let cfg = self?.configs() else { return }
            cfg.Save()
            Seam.refreshAllWindows?()
            // 行合并可能新增数据看板项（如分享/模板行落地）：重新登记轮询，免重启生效
            AppContainer.shared.resolve(DataPollingService.self)?.syncFromConfigs(cfg)
        }
    }

    // MARK: - 行级拉取

    /// 行级拉取：从服务器拉取全部条目行数据并合并到本地。
    /// 团队模块全量拉取，个人模块增量拉取。对应 C# `PullAllRowsAsync`。
    func pullAllRows(mgr: WindowConfigManager, settings: Settings) async {
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return }
        var anyChanged = false
        for win in mgr.Windows {
            for p in win.Panels {
                if await pullPanelRows(p, settings: settings) { anyChanged = true }
                // C# 此处只展开一层子面板（非递归）
                if let children = p.ChildPanels {
                    for c in children {
                        if await pullPanelRows(c, settings: settings) { anyChanged = true }
                    }
                }
            }
        }
        if anyChanged {
            Seam.uiPost { mgr.Save() }
            RuntimeLog.debug("[CloudSync] row pull completed, local data updated")
        }
    }

    /// 对单个模块做一次全量行拉取（不带 since），用于 reference 分享导入后初始化共享数据。
    /// 对应 C# `PullItemFullAsync`。
    @discardableResult
    public func pullItemFull(_ p: PanelItem) async -> Bool {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return false }
        let changed = await pullPanelRows(p, settings: settings, forceFull: true)
        if changed { Seam.uiPost { [weak self] in self?.configs()?.Save() } }
        return changed
    }

    /// 全量拉取但按增量合并语义（不整体删除未返回的本地行），用于 WS 实时刷新。
    /// 对应 C# `PullItemMergeFullAsync`。
    @discardableResult
    public func pullItemMergeFull(_ p: PanelItem) async -> Bool {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return false }
        let changed = await pullPanelRows(p, settings: settings, fullMerge: true)
        if changed { Seam.uiPost { [weak self] in self?.configs()?.Save() } }
        return changed
    }

    /// 拉取单个源模块的最新元数据（title/itemData）并写入本地 PanelItem。
    /// 用于 reference 分享收到 share_item_meta_updated 通知后刷新模块配置。
    /// 对应 C# `PullSharedItemMetaAsync`。
    @discardableResult
    public func pullSharedItemMeta(_ p: PanelItem) async -> Bool {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return false }
        guard let sid = p.ServerId, !sid.isEmpty else { return false }
        let r = await api.send("GET", Self.sharedItemEndpoint + "?serverId=" + BackendApiClient.queryValue(sid))
        guard r.ok, let data = r.data?.objectValue else { return false }

        var changed = false
        let newTitle = data["title"]?.stringValue
        if p.Title != newTitle { p.Title = newTitle; changed = true }
        if let itemData = data["itemData"], case .object = itemData {
            if Self.applyItemDataToPanel(p, itemData) { changed = true }
        }
        return changed
    }

    /// 拉取源窗口下所有模块结构，与入口窗口本地 Panels 做 diff：
    /// 服务端有本地无 → 新建（含分组挂载）并全量拉行；都有 → 更新元数据；
    /// 服务端无本地有 → 移除（源模块已被属主删除）。
    /// 用于 bar 级 reference 分享收到 share_source_bar_updated 通知。对应 C# `PullSharedSourceBarAsync`。
    @discardableResult
    public func pullSharedSourceBar(_ win: WindowConfig) async -> Bool {
        let settings = Seam.settings
        guard settings.EnableCloudSync, let token = settings.AccountToken, !token.isEmpty else { return false }
        guard let sourceBarId = win.SourceBarId, !sourceBarId.isEmpty else { return false }
        let r = await api.send("GET", Self.sharedBarItemsEndpoint + "?barServerId=" + BackendApiClient.queryValue(sourceBarId))
        guard r.ok, let data = r.data?.objectValue, case .array(let items)? = data["items"] else { return false }

        var changed = false
        var serverIds = Set<String>()
        var newPanels: [PanelItem] = []
        var panelMap: [String: PanelItem] = [:]

        // 第一遍：diff 既有面板元数据 + 收集新增面板
        for it in items {
            guard let item = it.objectValue,
                  let sid = item["serverId"]?.stringValue, !sid.isEmpty else { continue }
            serverIds.insert(sid)
            let existing = WindowConfigManager.enumerateAllPanels(win.Panels).first { $0.ServerId == sid }
            if let existing {
                let newTitle = item["title"]?.stringValue
                if existing.Title != newTitle { existing.Title = newTitle; changed = true }
                if let itemData = item["itemData"], case .object = itemData,
                   Self.applyItemDataToPanel(existing, itemData) { changed = true }
            } else {
                let newPanel = Self.buildPanelFromServerItem(item, win: win)
                // 分享属性：标记为引用导入（与 buildReferenceWindowPanels 一致）
                newPanel.ShareMode = win.ShareMode
                newPanel.ShareId = win.ShareId
                newPanel.ShareCode = win.ShareCode
                newPanel.AllowEdit = win.AllowEdit
                newPanel.AllowDelete = win.AllowDelete
                newPanel.AllowReShare = win.AllowReShare
                newPanels.append(newPanel)
                if let psid = newPanel.ServerId, !psid.isEmpty { panelMap[psid] = newPanel }
                changed = true
            }
        }

        // 第二遍：新增面板挂到窗口（分组子模块挂到父分组，其余追加到末尾）
        for it in items {
            guard let item = it.objectValue,
                  let sid = item["serverId"]?.stringValue, !sid.isEmpty,
                  let panel = panelMap[sid] else { continue }
            var parent: PanelItem?
            if let groupId = item["groupId"]?.stringValue, !groupId.isEmpty {
                parent = panelMap[groupId]
                    ?? WindowConfigManager.enumerateAllPanels(win.Panels).first { $0.ServerId == groupId }
            }
            if let parent, parent !== panel {
                if parent.ChildPanels == nil { parent.ChildPanels = [] }
                parent.ChildPanels!.append(panel)
            } else {
                win.Panels.append(panel)
            }
        }

        // 第三遍：移除服务端已不存在的本地共享面板（仅顶层、仅有 ServerId 的，不动本地自建面板）。
        // 这些面板是源模块引用，本地行硬删不打墓碑：删除意图一旦上报，源模块属团队且本机是其成员时会被真删
        var revokedUids: [String] = []
        for i in win.Panels.indices.reversed() {
            let p = win.Panels[i]
            guard let psid = p.ServerId, !psid.isEmpty else { continue }
            if !serverIds.contains(psid) {
                for c in WindowConfigManager.enumerateAllPanels([p]) { revokedUids.append(c.Id) }
                win.Panels.remove(at: i)
                changed = true
            }
        }
        if !revokedUids.isEmpty { LocalDbService.hardDeleteRows(itemUids: revokedUids) }

        // 第四遍：新增面板全量拉行
        for np in newPanels where RowChangeTracker.isRowSyncable(np.`Type`) {
            _ = await pullItemFull(np)
        }
        return changed
    }

    /// 拉取单面板行数据并合并。对应 C# `PullPanelRows`。
    /// forceFull=全量替换（分享导入/取消刷新）；fullMerge=全量但按合并语义（WS 实时刷新）。
    private func pullPanelRows(_ p: PanelItem, settings: Settings,
                               forceFull: Bool = false, fullMerge: Bool = false) async -> Bool {
        guard RowChangeTracker.isRowSyncable(p.`Type`) else { return false }
        guard let sid = p.ServerId, !sid.isEmpty else { return false }

        // 团队模块全量拉取，个人模块增量拉取
        var url = Self.rowPullEndpoint + "?itemServerId=" + BackendApiClient.queryValue(sid)
        if !forceFull, !fullMerge, p.OwnerType != "team", let since = settings.LastCloudSyncTime {
            url += "&since=" + BackendApiClient.queryValue(Self.isoO(since))
        }
        let r = await api.send("GET", url)
        guard r.ok else { return false }
        let rowsArr = r.data?.objectValue?["rows"]?.arrayValue ?? []
        // 非全量拉取时无新数据直接返回；全量拉取即使为空也要走替换逻辑（分享取消后不可见的行需从本地清除）
        if !forceFull && rowsArr.isEmpty { return false }

        let merged = mergeRowsIntoPanel(p, serverRows: rowsArr, replaceAll: forceFull)
        Self.cacheRowServerIds(rowsArr)
        return merged
    }

    /// 拉取回写：缓存服务端返回的行主键 ID，供后续按服务端主键精确删除。
    /// 对应 C# `CacheRowServerIds`（严格只认字符串形态，数字形态不缓存——与推送回写的宽口径不对称，保留）。
    static func cacheRowServerIds(_ rowsArr: [JSONValue]) {
        var entries: [(rowUid: String, rowServerId: String?, dataServerId: String?)] = []
        for r in rowsArr {
            guard let o = r.objectValue,
                  let rowUid = o["rowId"]?.stringValue, !rowUid.isEmpty else { continue }
            var rsid: String?
            var dsid: String?
            if case .string(let s)? = o["rowServerId"] { rsid = s }
            if case .string(let s)? = o["dataServerId"] { dsid = s }
            if rsid == nil && dsid == nil { continue }
            entries.append((rowUid, rsid, dsid))
        }
        if !entries.isEmpty { LocalDbService.saveRowServerIds(entries) }
    }

    // MARK: - 行合并

    /// 将服务端行数据合并到本地模块列表（增/改/删）；replaceAll=true 时整体替换。
    /// 对应 C# `MergeRowsIntoPanel`。
    private func mergeRowsIntoPanel(_ p: PanelItem, serverRows: [JSONValue], replaceAll: Bool) -> Bool {
        let currentJson = Self.getListDataJson(p) ?? "[]"
        var localRows = Self.parseRowsFromJson(currentJson)
        // 类型守卫：服务端返回模块下全部行类型，仅合并与本面板类型一致的行，
        // 防止历史错绑/残留的跨类型行被反序列化进本面板（如番茄行灌入便签变空便签）
        let expectedRowType = RowChangeTracker.getRowType(p.`Type`)

        if replaceAll {
            // 整体替换：本地只保留服务端可见的活跃行（不可见的行/墓碑均移除）
            var freshRows = OrderedRows()
            for rowToken in serverRows {
                guard let o = rowToken.objectValue,
                      let rowId = o["rowId"]?.stringValue, !rowId.isEmpty else { continue }
                if let rowType = o["rowType"]?.stringValue, !rowType.isEmpty, rowType != expectedRowType { continue }
                if Self.isDeletedFlag(o["deletedAt"]) { continue }
                var content = o["content"]?.objectValue ?? [:]
                content["Id"] = .string(rowId)
                freshRows[rowId] = .object(content)
            }
            let changed = !Self.rowsContentEquals(localRows.arrayValue, freshRows.arrayValue)
            if changed {
                let freshArr = freshRows.arrayValue
                Self.applyListDataToPanel(p, freshArr)
                // 同步更新快照，避免被移除的行被误判为本地待推送变更
                setSnapshot(Self.jsonString(freshArr), for: p.Id)
                mirrorToSiblingPanels(p, rows: freshArr)
            }
            return changed
        }

        var mergeChanged = false
        for rowToken in serverRows {
            guard let o = rowToken.objectValue,
                  let rowId = o["rowId"]?.stringValue, !rowId.isEmpty else { continue }
            if let rowType = o["rowType"]?.stringValue, !rowType.isEmpty, rowType != expectedRowType { continue }

            if Self.isDeletedFlag(o["deletedAt"]) {
                // 服务端已删除 → 本地也删除
                if localRows[rowId] != nil { localRows[rowId] = nil; mergeChanged = true }
            } else {
                var content = o["content"]?.objectValue ?? [:]
                content["Id"] = .string(rowId)
                let row = JSONValue.object(content)
                if let existing = localRows[rowId] {
                    // 已存在：内容不同则覆盖（C# 注释提到 updatedAt，实际实现按内容比较）
                    if !Self.rowsContentEquals(existing, row) {
                        localRows[rowId] = row
                        mergeChanged = true
                    }
                } else {
                    localRows[rowId] = row
                    mergeChanged = true
                }
            }
        }

        if mergeChanged {
            let mergedArr = localRows.arrayValue
            Self.applyListDataToPanel(p, mergedArr)
            setSnapshot(Self.jsonString(mergedArr), for: p.Id)
            mirrorToSiblingPanels(p, rows: mergedArr)
        }
        return mergeChanged
    }

    /// 将行数据写回 PanelItem 的对应列表字段。对应 C# `ApplyListDataToPanel`。
    static func applyListDataToPanel(_ p: PanelItem, _ rows: JSONValue) {
        switch p.`Type` {
        case .StickyNotes: p.StickyNotes = decodeRows(rows, StickyNote.self, base: jsonValue(StickyNote())) ?? []
        case .Notes: p.DeskNotes = decodeRows(rows, DeskNote.self, base: jsonValue(DeskNote())) ?? []
        case .TodoList: p.TodoItems = decodeRows(rows, TodoItem.self, base: jsonValue(TodoItem())) ?? []
        case .Timer: p.TimerItems = decodeRows(rows, TimerItem.self, base: jsonValue(TimerItem())) ?? []
        case .Countdown: p.CountdownItems = decodeRows(rows, CountdownItem.self, base: jsonValue(CountdownItem())) ?? []
        case .SignalLight: p.SignalLights = decodeRows(rows, SignalLightItem.self, base: jsonValue(SignalLightItem())) ?? []
        case .Clipboard: p.ClipboardItems = decodeRows(rows, ClipboardSavedItem.self, base: jsonValue(ClipboardSavedItem())) ?? []
        case .FileArea: p.FileItems = decodeRows(rows, FileAreaItem.self, base: jsonValue(FileAreaItem())) ?? []
        case .Pomodoro:
            if let pomodoros = decodeRows(rows, PomodoroSettings.self, base: jsonValue(PomodoroSettings())), let incoming = pomodoros.first {
                // 远端行不含运行状态：保留本地计时状态，避免同步拉取/对齐打断当前计时
                if let local = p.Pomodoro {
                    incoming.Mode = local.Mode
                    incoming.RemainingSeconds = local.RemainingSeconds
                    incoming.IsRunning = local.IsRunning
                    incoming.StartTime = local.StartTime
                } else {
                    // 首次拉取（如导入分享）：剩余时间对齐时长配置，避免停留在默认值
                    incoming.RemainingSeconds = Double(incoming.GetModeTotalSeconds())
                }
                p.Pomodoro = incoming
            }
        case .DataDashboard: p.DashboardItems = decodeRows(rows, DataDashboardItem.self, base: jsonValue(DataDashboardItem())) ?? []
        case .DigitalEmployee:
            let deRows = decodeRows(rows, DigitalEmployeeRow.self, base: jsonValue(DigitalEmployeeRow())) ?? []
            p.DigitalEmployeeIds = deRows.map { $0.EmployeeId }.filter { !$0.isEmpty }
        case .Friend:
            let fuRows = decodeRows(rows, FriendUserRow.self, base: jsonValue(FriendUserRow())) ?? []
            p.FriendUserIds = fuRows.map { $0.UserId }.filter { !$0.isEmpty }
        case .QuickGroup:
            // 服务端按 id 返回，需按 SortIndex 恢复用户自定义顺序
            var items = decodeRows(rows, QuickItem.self, base: jsonValue(QuickItem()))
            QuickGroupService.SortByIndex(&items)
            p.QuickItems = items ?? []
        case .CheckIn:
            let items = decodeRows(rows, CheckInItem.self, base: jsonValue(CheckInItem())) ?? []
            // OrderBy 是稳定排序：同 SortIndex 保持服务端返回顺序（Swift sorted 不保证稳定，用下标兜底）
            p.CheckInItems = items.enumerated()
                .sorted { ($0.element.SortIndex, $0.offset) < ($1.element.SortIndex, $1.offset) }
                .map { $0.element }
        default: break
        }
    }

    /// 将行数据同步到绑定同一 ServerId 的其他本地面板（多视图数据保持一致）。
    /// 对应 C# `MirrorToSiblingPanels`。
    private func mirrorToSiblingPanels(_ p: PanelItem, rows: JSONValue) {
        guard let cfg = configs(), let sid = p.ServerId, !sid.isEmpty else { return }
        let json = Self.jsonString(rows)
        var mirrored = false
        for win in cfg.Windows {
            for q in WindowConfigManager.enumerateAllPanels(win.Panels) {
                if q === p || q.ServerId != sid { continue }
                guard RowChangeTracker.isRowSyncable(q.`Type`) else { continue }
                Self.applyListDataToPanel(q, rows)
                setSnapshot(json, for: q.Id)
                mirrored = true
            }
        }
        if mirrored {
            RuntimeLog.debug("[CloudSync] mirrored row data to other views of the same module (\(p.`Type`.serverName))")
            Seam.uiPost { Seam.refreshAllWindows?() }
        }
    }
}