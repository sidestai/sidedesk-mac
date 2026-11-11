import Foundation
import SideDeskCore

/// 后端 WebSocket 事件分发与本地即时清理。对应 C# `App.BackendWs.cs` 的消息分发 +
/// `App.TeamWs.cs` 的成员对账 + `App.xaml.cs` 的分享/团队清理段。
///
/// C# 把这些处理放在 App（UI 层）；Mac 侧落在服务层经 `Seam` 接缝投递 UI，
/// 换来无宿主可测（测试注入假 mgr/假后端即可驱动全部事件路径）。
///
/// 已实现事件：team_row_updated / structure_changed / share_item_meta_updated /
/// share_source_bar_updated / share_cancelled / bar_meta_updated /
/// team_membership_revoked / team_item_removed / team_bar_removed。
/// 好友、通知中心、团队申请/邀请类事件依赖尚未移植的子系统（FriendService /
/// NotificationService / TeamNotificationService），收到只记日志不动数据。
///
/// 清理的落盘次序是不变量：**先改内存 → 硬删本地库行 → mgr.Save()**。
/// Save 是「以内存为准」的全量重写，库里有而内存没有的行会打删除墓碑；
/// 引用卡片（ServerId 指向分享者/团队的源模块）必须先硬删，否则墓碑会把删除意图
/// 上报到源模块上，真删其他成员仍在使用的数据。
public final class BackendEventDispatcher {

    // MARK: - 依赖接缝（默认经组合根延迟解析；测试注入替身）

    private let manager: () -> WindowConfigManager?
    private let cloudSync: () -> CloudSyncService?
    private let pollingSync: (WindowConfigManager) -> Void
    private let listTeams: () async -> [Team]?
    private let purgeVariableSets: (String) -> Void

    public init(
        manager: @escaping () -> WindowConfigManager? = { AppContainer.shared.resolve(WindowConfigManager.self) },
        cloudSync: @escaping () -> CloudSyncService? = { AppContainer.shared.resolve(CloudSyncService.self) },
        pollingSync: @escaping (WindowConfigManager) -> Void = { mgr in
            AppContainer.shared.resolve(DataPollingService.self)?.syncFromConfigs(mgr)
        },
        listTeams: @escaping () async -> [Team]? = { await AppContainer.shared.resolve(TeamService.self)?.listTeamsAsync() },
        purgeVariableSets: @escaping (String) -> Void = { AppContainer.shared.resolve(VariableSetService.self)?.purgeTeam($0) }
    ) {
        self.manager = manager
        self.cloudSync = cloudSync
        self.pollingSync = pollingSync
        self.listTeams = listTeams
        self.purgeVariableSets = purgeVariableSets
    }

    // MARK: - 消息入口

    /// 处理一条后端 WS 推送（JSON 文本）。对应 C# OnBackendWsMessage 的分发段。
    /// 同步清理类事件经 `Seam.uiPost` 投递（等价 Dispatcher.BeginInvoke）；
    /// 拉取类事件直接 await（C# 是 fire-and-forget 的 `_ = HandleXxxAsync()`，
    /// 这里由调用方每条消息起一个 Task，语义一致且测试可确定性等待）。
    public func handle(_ message: String) async {
        guard let obj = CloudSyncService.parseJSON(message)?.objectValue else {
            RuntimeLog.debug("[BackendWS] message parse error: \(message)")
            return
        }
        let evt = obj["event"]?.stringValue ?? ""
        let data = obj["data"]?.objectValue

        switch evt {
        case "team_row_updated":
            guard let data, let itemServerId = data["itemServerId"]?.stringValue, !itemServerId.isEmpty else { return }
            let forceFull = data["forceFull"]?.boolValue == true
            await handleTeamRowUpdated(itemServerId, forceFull: forceFull)

        case "structure_changed":
            // 窗口/模块结构变更（同账号其他设备）：只拉不推，避免多设备循环触发
            _ = await cloudSync()?.reconcile(pushLocal: false)

        case "share_item_meta_updated":
            guard let data, let itemServerId = data["itemServerId"]?.stringValue, !itemServerId.isEmpty else { return }
            await handleShareItemMetaUpdated(itemServerId)

        case "share_source_bar_updated":
            guard let data, let sourceBarId = data["sourceBarId"]?.stringValue, !sourceBarId.isEmpty else { return }
            let action = data["action"]?.stringValue ?? "items_changed"
            await handleShareSourceBarUpdated(sourceBarId, action: action)

        case "share_cancelled":
            guard let data else { return }
            Seam.uiPost { [weak self] in self?.handleShareCancelled(data) }

        case "bar_meta_updated":
            guard let data, let barServerId = data["barServerId"]?.stringValue, !barServerId.isEmpty,
                  let title = data["title"]?.stringValue, !title.isEmpty else { return }
            Seam.uiPost { [weak self] in self?.handleBarMetaUpdated(barServerId, title: title) }

        case "team_membership_revoked":
            guard let data, let corpId = data["corpId"]?.stringValue, !corpId.isEmpty else { return }
            Seam.uiPost { [weak self] in self?.purgeTeamDataLocal(corpId) }

        case "team_item_removed":
            guard let data, let itemServerId = data["itemServerId"]?.stringValue, !itemServerId.isEmpty else { return }
            Seam.uiPost { [weak self] in self?.removeTeamItemLocal(itemServerId) }

        case "team_bar_removed":
            guard let data, let barServerId = data["barServerId"]?.stringValue, !barServerId.isEmpty else { return }
            Seam.uiPost { [weak self] in self?.removeTeamWindowLocal(barServerId) }

        case "friend_request", "friend_request_result", "friend_online", "friend_offline",
             "friend_profile_updated", "notification", "notification_progress",
             "team_join_request", "team_application_result", "team_invite", "team_member_joined",
             "team_membership_notice", "team_item_notice", "share_revoked_notice":
            // 依赖未移植子系统（好友/通知中心/团队通知）：只记日志，不动本地数据
            RuntimeLog.debug("[BackendWS] event skipped (subsystem not ported): \(evt)")

        default:
            RuntimeLog.debug("[BackendWS] unhandled event: \(evt)")
        }
    }

    // MARK: - 拉取类事件

    /// 团队模块行数据更新：拉受影响模块的最新行并刷新 UI。对应 C# HandleTeamRowUpdatedAsync。
    /// forceFull=true（如分享取消）：全量替换本地行，让不可见的行从本地消失。
    func handleTeamRowUpdated(_ itemServerId: String, forceFull: Bool) async {
        guard let mgr = manager(), loggedIn, let sync = cloudSync() else { return }
        guard let target = findPanel(in: mgr, serverId: itemServerId) else { return }

        if forceFull {
            let changed = await sync.pullItemFull(target)
            RuntimeLog.debug("[App] forced full refresh \(changed ? "changed" : "no change"): \(target.`Type`)")
            Seam.uiPost { Seam.refreshAllWindows?() }
            return
        }
        // 合并语义：只增改、经墓碑删除；绑定同一 ServerId 的其他视图由 CloudSyncService 内部镜像
        let changed = await sync.pullItemMergeFull(target)
        RuntimeLog.debug("[App] team row update applied: \(target.`Type`), \(changed ? "changed" : "no change")")
        if changed { Seam.uiPost { Seam.refreshAllWindows?() } }
    }

    /// reference 分享：源模块元数据变更（title/itemData/type/groupId）。对应 C# HandleShareItemMetaUpdatedAsync。
    func handleShareItemMetaUpdated(_ itemServerId: String) async {
        guard let mgr = manager(), loggedIn, let sync = cloudSync() else { return }
        guard let target = findPanel(in: mgr, serverId: itemServerId) else { return }

        let metaChanged = await sync.pullSharedItemMeta(target)
        let rowsChanged = await sync.pullItemMergeFull(target)
        RuntimeLog.debug("[App] share item meta update applied: \(target.`Type`), meta=\(metaChanged), rows=\(rowsChanged)")
        if metaChanged || rowsChanged { Seam.uiPost { Seam.refreshAllWindows?() } }
    }

    /// bar 级 reference 分享：源窗口结构变更。对应 C# HandleShareSourceBarUpdatedAsync。
    /// bar_removed → 移除入口窗口（等同 share_cancelled(bar)）；items_changed → 重拉源 bar items diff。
    func handleShareSourceBarUpdated(_ sourceBarId: String, action: String) async {
        guard let mgr = manager(), loggedIn else { return }

        if action == "bar_removed" {
            Seam.uiPost { [weak self] in
                guard let self, let mgr = self.manager(),
                      let win = mgr.Windows.first(where: { $0.SourceBarId == sourceBarId }) else { return }
                self.removeEntryWindow(win, mgr: mgr)
                RuntimeLog.debug("[App] share source bar removed: \(win.Name)")
            }
            return
        }

        guard let entry = mgr.Windows.first(where: { $0.SourceBarId == sourceBarId }),
              let sync = cloudSync() else { return }
        let changed = await sync.pullSharedSourceBar(entry)
        RuntimeLog.debug("[App] share source bar items changed: \(entry.Name), \(changed ? "updated" : "no change")")
        if changed {
            mgr.Save()
            Seam.uiPost { Seam.refreshAllWindows?() }
        }
    }

    // MARK: - 同步清理类事件

    /// Web 端修改微屏元数据（当前为改名）：按 ServerId 回写窗口名、落盘并刷新标签。
    /// 对应 C# bar_meta_updated 分支。
    func handleBarMetaUpdated(_ barServerId: String, title: String) {
        guard let mgr = manager(),
              let target = mgr.Windows.first(where: { $0.ServerId == barServerId }),
              target.Name != title else { return }
        target.Name = title
        mgr.Save()
        Seam.refreshAllWindows?()
    }

    /// 分享取消：移除本地导入的组件（item 级）或导入的窗口（bar 级）。对应 C# HandleShareCancelled。
    /// localId 为导入时上报的本地 GUID；为空时回退按 ServerId/SourceBarId 匹配（仅 reference 有效）。
    func handleShareCancelled(_ data: [String: JSONValue]) {
        guard let mgr = manager() else { return }
        let shareLevel = data["shareLevel"]?.stringValue ?? "item"
        let itemServerId = data["itemServerId"]?.stringValue ?? ""
        let sourceBarId = data["sourceBarId"]?.stringValue ?? ""
        let localId = data["localId"]?.stringValue ?? ""

        if shareLevel == "bar" {
            var win: WindowConfig?
            if !localId.isEmpty { win = mgr.Windows.first { $0.Id == localId } }
            if win == nil && !sourceBarId.isEmpty { win = mgr.Windows.first { $0.SourceBarId == sourceBarId } }
            guard let win else { return }
            removeEntryWindow(win, mgr: mgr)
            RuntimeLog.debug("[App] share cancelled: removing imported window localId=\(win.Id)")
        } else {
            var refItemUids: [String] = []
            var removed = false
            for w in mgr.Windows {
                let r = Self.removeSharedPanels(&w.Panels, localId: localId, itemServerId: itemServerId, sink: &refItemUids)
                removed = removed || r
            }
            guard removed else { return }
            // 引用卡片硬删避免墓碑误伤源数据（见文件头部落盘次序说明）
            LocalDbService.hardDeleteRows(itemUids: refItemUids)
            mgr.Save()
            pollingSync(mgr)
            Seam.refreshAllWindows?()
            RuntimeLog.debug("[App] share cancelled: removing imported component localId=\(localId), ServerId=\(itemServerId), panels=\(refItemUids.count)")
        }
    }

    /// 移除导入的入口窗口（share_cancelled(bar) 与 share_source_bar_updated(bar_removed) 共用）。
    /// 窗口下卡片均为源模块引用 → 本地行硬删不留墓碑；窗口自身保留墓碑让服务端软删入口空壳
    /// （否则下次结构拉取会把它补回来，复活→再清理反复抖动）。
    private func removeEntryWindow(_ win: WindowConfig, mgr: WindowConfigManager) {
        var refItemUids: [String] = []
        for p in win.Panels { Self.collectPanelUids(p, sink: &refItemUids) }
        mgr.Windows.removeAll { $0.Id == win.Id }
        Self.removeDockEntries([win.Id], mgr: mgr)
        LocalDbService.hardDeleteRows(itemUids: refItemUids)
        mgr.Save()
        pollingSync(mgr)
        Seam.refreshAllWindows?()
    }

    // MARK: - 团队数据即时清理

    /// 团队成员身份失效（被移出/主动退出/团队解散）：清除该团队在本机的全部数据。
    /// 对应 C# PurgeTeamDataLocal。本地库走行级硬删（不打墓碑）：服务端数据仍归属团队/作者，
    /// 本设备只是失去访问权，上报删除意图会软删其他成员仍在使用的团队数据。
    func purgeTeamDataLocal(_ corpId: String) {
        guard let mgr = manager() else { return }
        var removedBarUids: [String] = []
        var removedItemUids: [String] = []

        // 1) 团队窗口：整个窗口消失，其下卡片（无论归属）一并移除
        let teamWindows = mgr.Windows.filter { $0.OwnerType == "team" && $0.CorpId == corpId }
        for win in teamWindows {
            removedBarUids.append(win.Id)
            for p in win.Panels { Self.collectPanelUids(p, sink: &removedItemUids) }
        }
        let removedBarIds = Set(removedBarUids)
        mgr.Windows.removeAll { removedBarIds.contains($0.Id) }
        Self.removeDockEntries(removedBarUids, mgr: mgr)

        // 2) 个人窗口里归属该团队的卡片（团队卡片可被放进个人窗口的分组内）
        for win in mgr.Windows { Self.removeTeamPanels(&win.Panels, corpId: corpId, sink: &removedItemUids) }

        // 3) 后台数据项与变量集定义（团队作用域）
        let bgBefore = mgr.BackgroundDashboardItems.count
        mgr.BackgroundDashboardItems.removeAll { $0.TeamId == corpId }
        let bgRemoved = bgBefore - mgr.BackgroundDashboardItems.count
        let setBefore = mgr.VariableSets.count
        mgr.VariableSets.removeAll { $0.TeamId == corpId }
        let setRemoved = setBefore - mgr.VariableSets.count

        // 4) 当前选中团队即被清除的团队 → 回落个人，避免继续按该团队拉团队库/云盘
        let s = Seam.settings
        let selectionReset = s.SelectedCorpId == corpId
        if selectionReset {
            s.SelectedCorpId = nil
            s.SelectedCorpName = nil
            s.Save()
        }

        // 5) 团队云盘源（S3/WebDAV）：Mac 侧尚未移植云盘子系统，缺席。

        // 6) 团队数据模板（用户自建；内置模板无团队归属，不动）
        Self.purgeTeamUserTemplates(corpId)

        // 7) 落盘：先硬删本地库行（不生成墓碑），再全量保存，随后重建轮询与变量聚合。
        // 仅在窗口/卡片结构确实变动时才 Save（只改模板/选中团队没必要重写，也避开启动早期内存未就绪的误删风险）。
        let configChanged = !removedBarUids.isEmpty || !removedItemUids.isEmpty || bgRemoved > 0 || setRemoved > 0
        if configChanged {
            LocalDbService.hardDeleteRows(barUids: removedBarUids, itemUids: removedItemUids)
            mgr.Save()
            pollingSync(mgr)
        }
        purgeVariableSets(corpId)

        // 8) UI：dock 已在步骤 1 摘除并随 Save 落盘，这里重绘两侧卡片/标签。
        // 团队下拉刷新（NotifySettingsTeamChanged）与云盘窗口关闭依赖未移植的设置页/云盘 UI，缺席。
        Seam.refreshAllWindows?()

        RuntimeLog.debug("[App] team data purged: corp=\(corpId), windows=\(teamWindows.count), items=\(removedItemUids.count), "
                         + "bgItems=\(bgRemoved), varSets=\(setRemoved), selectionReset=\(selectionReset)")
    }

    /// 团队卡片被作者删除或改归属到其他团队：从本机所有窗口移除该卡片（连同子面板）。
    /// 对应 C# RemoveTeamItemLocal（服务端已由作者完成删除/改归属，本地硬删不留墓碑）。
    func removeTeamItemLocal(_ itemServerId: String) {
        guard let mgr = manager() else { return }
        var removedItemUids: [String] = []
        var removed = false
        for win in mgr.Windows {
            let r = Self.removePanelsByServerId(&win.Panels, serverId: itemServerId, sink: &removedItemUids)
            removed = removed || r
        }
        guard removed else { return }
        LocalDbService.hardDeleteRows(itemUids: removedItemUids)
        mgr.Save()
        pollingSync(mgr)
        Seam.refreshAllWindows?()
        RuntimeLog.debug("[App] team item removed: serverId=\(itemServerId), panels=\(removedItemUids.count)")
    }

    /// 团队窗口被删除：成员端移除本地对应窗口（含其下全部卡片与 dock 占用）。对应 C# RemoveTeamWindowLocal。
    func removeTeamWindowLocal(_ barServerId: String) {
        guard let mgr = manager(),
              let win = mgr.Windows.first(where: { $0.ServerId == barServerId }) else { return }
        var removedItemUids: [String] = []
        for p in win.Panels { Self.collectPanelUids(p, sink: &removedItemUids) }
        mgr.Windows.removeAll { $0.Id == win.Id }
        Self.removeDockEntries([win.Id], mgr: mgr)
        LocalDbService.hardDeleteRows(barUids: [win.Id], itemUids: removedItemUids)
        mgr.Save()
        pollingSync(mgr)
        Seam.refreshAllWindows?()
        RuntimeLog.debug("[App] team window removed: \(win.Name) (serverId=\(barServerId))")
    }

    /// 清除用户自建数据模板中归属该团队的模板。对应 C# PurgeTeamUserTemplates。
    private static func purgeTeamUserTemplates(_ corpId: String) {
        let path = DataTemplateManager.userTemplatesFilePath
        guard FileManager.default.fileExists(atPath: path) else { return }
        var list = DataTemplateManager.loadUserTemplates()
        let before = list.count
        list.removeAll { $0.TeamId == corpId }
        guard list.count != before else { return }
        guard let data = try? SideDeskJSON.encoder().encode(list) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - 成员身份兜底对账

    /// 每次 WS 连接建立（含重连）对账一次团队身份：成员被移出时客户端可能离线/正在重启，
    /// 错过 team_membership_revoked 推送后本地团队数据会永久残留（拉取对账只补缺不删多余），
    /// 故按服务端团队列表清理本机已无身份的团队数据。仅在列表成功取回时执行——
    /// 接口失败/未登录返回 nil，宁可保留数据也绝不误删。对应 C# ReconcileTeamMembershipAsync。
    /// （C# 连接时还同步通知中心已读状态 NotificationSyncService.SyncAsync，该子系统未移植，缺席。）
    public func reconcileTeamMembership() async {
        guard loggedIn, let teams = await listTeams() else { return }
        let joined = Set(teams.map { $0.Id }.filter { !$0.isEmpty })

        // 本机带团队归属的全部 corpId（收集团队窗口/卡片/后台数据项/变量集/当前选中团队；
        // S3/WebDAV 云盘源未移植，缺席）。C# 经 Dispatcher 收集，这里等价投递到 UI 线程取值。
        let local: Set<String>
        if Seam.hasUiThread() {
            local = await withCheckedContinuation { cont in
                Seam.uiPost { cont.resume(returning: self.collectLocalTeamIds()) }
            }
        } else {
            local = collectLocalTeamIds()
        }

        for corpId in local where !joined.contains(corpId) {
            RuntimeLog.debug("[App] team membership lost (offline reconcile), purging corp=\(corpId)")
            Seam.uiPost { [weak self] in self?.purgeTeamDataLocal(corpId) }
        }
    }

    private func collectLocalTeamIds() -> Set<String> {
        var local = Set<String>()
        guard let mgr = manager() else { return local }
        for w in mgr.Windows {
            if w.OwnerType == "team", let corpId = w.CorpId, !corpId.isEmpty { local.insert(corpId) }
            for p in w.Panels { Self.collectPanelTeamIds(p, sink: &local) }
        }
        for d in mgr.BackgroundDashboardItems {
            if let tid = d.TeamId, !tid.isEmpty { local.insert(tid) }
        }
        for v in mgr.VariableSets {
            if let tid = v.TeamId, !tid.isEmpty { local.insert(tid) }
        }
        if let corpId = Seam.settings.SelectedCorpId, !corpId.isEmpty { local.insert(corpId) }
        return local
    }

    private var loggedIn: Bool {
        let t = Seam.settings.AccountToken
        return t != nil && !t!.isEmpty
    }

    // MARK: - 面板树工具（对应 C# App.xaml.cs 的递归静态助手）

    private func findPanel(in mgr: WindowConfigManager, serverId: String) -> PanelItem? {
        for win in mgr.Windows {
            if let p = Self.findPanelByServerId(win.Panels, serverId: serverId) { return p }
        }
        return nil
    }

    /// 递归收集面板（含子面板）的本地 uid，供硬删本地库行。对应 C# CollectPanelUids。
    static func collectPanelUids(_ p: PanelItem, sink: inout [String]) {
        sink.append(p.Id)
        guard let children = p.ChildPanels else { return }
        for c in children { collectPanelUids(c, sink: &sink) }
    }

    /// 递归收集面板树中归属团队的 corpId。对应 C# CollectPanelTeamIds。
    static func collectPanelTeamIds(_ p: PanelItem, sink: inout Set<String>) {
        if p.OwnerType == "team", let tid = p.TeamId, !tid.isEmpty { sink.insert(tid) }
        guard let children = p.ChildPanels else { return }
        for c in children { collectPanelTeamIds(c, sink: &sink) }
    }

    /// 递归移除归属指定团队的卡片。对应 C# RemoveTeamPanels。
    static func removeTeamPanels(_ panels: inout [PanelItem], corpId: String, sink: inout [String]) {
        for i in panels.indices.reversed() {
            let p = panels[i]
            if p.OwnerType == "team" && p.TeamId == corpId {
                collectPanelUids(p, sink: &sink)
                panels.remove(at: i)
                continue
            }
            if var children = p.ChildPanels {
                removeTeamPanels(&children, corpId: corpId, sink: &sink)
                p.ChildPanels = children
            }
        }
    }

    /// 按 ServerId 递归移除卡片（连同子面板），返回是否移除了至少一个。对应 C# RemovePanelsByServerId。
    static func removePanelsByServerId(_ panels: inout [PanelItem], serverId: String, sink: inout [String]) -> Bool {
        var removed = false
        for i in panels.indices.reversed() {
            let p = panels[i]
            if p.ServerId == serverId {
                collectPanelUids(p, sink: &sink)
                panels.remove(at: i)
                removed = true
                continue
            }
            if var children = p.ChildPanels {
                let r = removePanelsByServerId(&children, serverId: serverId, sink: &sink)
                p.ChildPanels = children
                removed = removed || r
            }
        }
        return removed
    }

    /// 递归移除匹配的导入面板：优先 localId 精确匹配，无 localId 时按 ServerId。对应 C# RemoveSharedPanels。
    static func removeSharedPanels(_ panels: inout [PanelItem], localId: String, itemServerId: String, sink: inout [String]) -> Bool {
        var removed = false
        for i in panels.indices.reversed() {
            let p = panels[i]
            let match = !localId.isEmpty
                ? p.Id == localId
                : (!itemServerId.isEmpty && p.ServerId == itemServerId)
            if match {
                collectPanelUids(p, sink: &sink)
                panels.remove(at: i)
                removed = true
                continue
            }
            if var children = p.ChildPanels {
                let r = removeSharedPanels(&children, localId: localId, itemServerId: itemServerId, sink: &sink)
                p.ChildPanels = children
                removed = removed || r
            }
        }
        return removed
    }

    /// 按 ServerId 递归查找面板。对应 C# FindPanelByServerId。
    static func findPanelByServerId(_ panels: [PanelItem], serverId: String) -> PanelItem? {
        for p in panels {
            if p.ServerId == serverId { return p }
            if let children = p.ChildPanels,
               let found = findPanelByServerId(children, serverId: serverId) { return found }
        }
        return nil
    }

    /// 从两侧 dock 摘除窗口 id 并收敛越界 ActiveIndex（等价 C# 逐主窗口 RemoveSharedWindowById；
    /// Mac 的 dock 状态随 mgr.Save 落盘，故须在 Save 之前调用）。
    private static func removeDockEntries(_ ids: [String], mgr: WindowConfigManager) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        mgr.LeftDock.WindowIds.removeAll { idSet.contains($0) }
        mgr.RightDock.WindowIds.removeAll { idSet.contains($0) }
        mgr.RepairDockMembership()
    }
}