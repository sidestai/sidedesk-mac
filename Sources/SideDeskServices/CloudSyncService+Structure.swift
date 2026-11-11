import Foundation
import SideDeskCore

/// 云同步：结构拉取与对账、引用整窗口导入、失效共享清理
/// （对应 C# `CloudSyncService.Structure.cs`）。
extension CloudSyncService {

    // MARK: - 结构拉取与合并

    /// 拉取服务端全量窗口/模块结构并增量合并到本地：缺失的个人窗口自动补齐，
    /// 已有窗口补齐缺失模块；团队窗口不自动新建（由用户主动添加）。
    /// 新建模块收集到 newPanelsOut，由调用方全量拉行。对应 C# `PullAndMergeStructureAsync`。
    func pullAndMergeStructure(mgr: WindowConfigManager, settings: Settings,
                               newPanelsOut: inout [PanelItem],
                               pulledItemServerIdsOut: inout Set<String>) async -> Bool {
        var url = Self.structurePullEndpoint
        if let corp = settings.SelectedCorpId, !corp.isEmpty {
            url += "?corpId=" + BackendApiClient.queryValue(corp)
        }
        let r = await api.send("GET", url)
        guard r.ok, let data = r.data?.objectValue, case .array(let serverBars)? = data["bars"] else { return false }

        // 收集服务端全量模块 ServerId（含团队窗口），供失效共享清理判断归属
        for barToken in serverBars {
            for itemToken in barToken.objectValue?["items"]?.arrayValue ?? [] {
                if let sid = itemToken.objectValue?["serverId"]?.stringValue, !sid.isEmpty {
                    pulledItemServerIdsOut.insert(sid)
                }
            }
        }

        // 本地删除墓碑：本设备已明确删除、服务端尚未确认受理的窗口/模块。
        // 拉取合并必须对它们免疫——否则服务端回灌会把已删项重新建回内存，随后 Save 的
        // upsert 复活语义（deleted_at=NULL）会抹掉墓碑，删除意图永久丢失、已删窗口两端复活。
        let (tombBars, tombItems) = LocalDbService.loadPendingDeleteTombstones()
        let tombBarSet = Set(tombBars)
        let tombItemSet = Set(tombItems)

        var changed = false
        for barToken in serverBars {
            guard let bar = barToken.objectValue,
                  let barServerId = bar["serverId"]?.stringValue, !barServerId.isEmpty else { continue }
            // 已打墓碑的窗口不接受回灌：等墓碑上报确认，服务端自然不再返回它
            if tombBarSet.contains(barServerId) { continue }
            let items = bar["items"]?.arrayValue ?? []

            var localWin = mgr.Windows.first { $0.ServerId == barServerId }
            if localWin == nil {
                // 团队窗口不自动创建；个人窗口直接新建并补齐模块
                if bar["ownerType"]?.stringValue == "team" { continue }
                let barTitle = bar["title"]?.stringValue ?? Lang.t("cloudDrive.cloudWindows")

                // 认领优先：本地存在未同步的同名个人窗口时回写 ServerId，
                // 避免每次拉取都因匹配失败而重复新建整套窗口
                if let w = mgr.Windows.first(where: { $0.ServerId == nil && $0.ShareMode == nil && $0.Name == barTitle }) {
                    w.ServerId = barServerId
                    localWin = w
                    RuntimeLog.debug("[CloudSync] claimed local unsynced window: \(w.Name) -> \(barServerId)")
                }

                if localWin == nil {
                    let win = WindowConfig()
                    win.ServerId = barServerId
                    win.Name = barTitle
                    win.OwnerType = "personal"
                    if Self.mergeServerItemsIntoWindow(win, items, &newPanelsOut, tombItemSet) || items.isEmpty {
                        // 云端补齐的窗口同步进入两侧 dock，所有窗口顶部标签可见
                        mgr.AddToAllDocks(win)
                        changed = true
                        RuntimeLog.debug("[CloudSync] restored missing window from cloud: \(win.Name) (\(items.count) modules)")
                    }
                    continue
                }

                // 认领成功：回写 ServerId 需持久化，防止中途失败后下次拉取再次新建
                mgr.Save()
                changed = true
            }

            // 窗口已存在：补齐缺失模块
            if Self.mergeServerItemsIntoWindow(localWin!, items, &newPanelsOut, tombItemSet) {
                changed = true
                RuntimeLog.debug("[CloudSync] backfilled new cloud modules for window \(localWin!.Name)")
            }
        }
        return changed
    }

    /// 将服务端模块清单补齐到窗口（已存在 ServerId 的跳过，本地版本优先）；
    /// group 子模块（groupId 非空）挂到父分组下。返回是否有新增模块。
    /// deletedServerIds 为本地未确认的删除墓碑，命中一律跳过（不接受回灌复活）。
    /// 对应 C# `MergeServerItemsIntoWindow`。
    static func mergeServerItemsIntoWindow(_ win: WindowConfig, _ items: [JSONValue],
                                           _ newPanelsOut: inout [PanelItem],
                                           _ deletedServerIds: Set<String>) -> Bool {
        var existingServerIds = Set<String>()
        for p in WindowConfigManager.enumerateAllPanels(win.Panels) {
            if let sid = p.ServerId, !sid.isEmpty { existingServerIds.insert(sid) }
        }

        // 第一遍：构建所有缺失模块
        var newPanels: [String: PanelItem] = [:]
        var order: [[String: JSONValue]] = []
        for itemToken in items {
            guard let item = itemToken.objectValue,
                  let serverId = item["serverId"]?.stringValue, !serverId.isEmpty,
                  !existingServerIds.contains(serverId),
                  !deletedServerIds.contains(serverId) else { continue }
            newPanels[serverId] = buildPanelFromServerItem(item, win: win)
            order.append(item)
        }
        if newPanels.isEmpty { return false }

        // 第二遍：分组子模块挂到父分组，其余按服务端顺序追加到窗口末尾
        for item in order {
            let serverId = item["serverId"]!.stringValue!
            let panel = newPanels[serverId]!
            newPanelsOut.append(panel)

            var parent: PanelItem?
            if let groupId = item["groupId"]?.stringValue, !groupId.isEmpty {
                parent = newPanels[groupId]
                    ?? WindowConfigManager.enumerateAllPanels(win.Panels).first { $0.ServerId == groupId }
            }
            if let parent {
                if parent.ChildPanels == nil { parent.ChildPanels = [] }
                parent.ChildPanels!.append(panel)
            } else {
                win.Panels.append(panel)
            }
        }
        return true
    }

    /// 从服务端模块结构构建 PanelItem（itemData 逐字段应用，列表数据由行级拉取另行填充）。
    /// 供引用整窗口导入复用。对应 C# `BuildPanelFromServerItem`。
    static func buildPanelFromServerItem(_ item: [String: JSONValue], win: WindowConfig) -> PanelItem {
        let panel = PanelItem()
        panel.ServerId = item["serverId"]?.stringValue
        panel.`Type` = PanelType.from(serverName: item["itemType"]?.stringValue ?? "StickyNotes")
        panel.Title = item["title"]?.stringValue
        // 团队窗口内的模块继承团队归属
        if win.OwnerType == "team" {
            panel.OwnerType = "team"
            panel.TeamId = win.CorpId
        }
        if let data = item["itemData"] { applyItemDataToPanel(panel, data) }
        return panel
    }

    /// 将服务端 itemData 字段映射到既有 PanelItem（对应 C# `ApplyItemDataToPanel` 的反射赋值）：
    /// 排除身份元数据与行级列表字段，null 值跳过；逐字段容错由 PanelItem 宽松解码保证。
    /// 实现：当前面板编码为底 +  incoming 覆盖 → 解码出新实例 → copyModuleSettings 按实际变化回写。
    /// 返回是否有字段实际变化（用于决定是否需要刷新 UI）。
    @discardableResult
    static func applyItemDataToPanel(_ panel: PanelItem, _ itemData: JSONValue) -> Bool {
        guard let incoming = itemData.objectValue,
              var merged = jsonValue(panel).objectValue else { return false }
        // 元数据字段以本地为准；行级同步类型的列表/对象由行表读取，服务端旧快照不得回灌
        let excluded: Set<String> = ["Id", "ServerId", "Type", "ChildPanels", "Pomodoro",
                                     "StickyNotes", "DeskNotes", "TodoItems", "TimerItems", "CountdownItems",
                                     "SignalLights", "ClipboardItems", "FileItems", "DashboardItems",
                                     "DigitalEmployeeIds", "FriendUserIds", "QuickItems", "CheckInItems"]
        for (k, v) in incoming {
            if excluded.contains(k) || v == .null { continue }
            merged[k] = v
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(merged)),
              let updated = try? SideDeskJSON.decoder().decode(PanelItem.self, from: data) else { return false }
        return panel.copyModuleSettings(from: updated)
    }

    // MARK: - 引用整窗口导入

    /// 按服务端返回的源模块明细在窗口内建 panels（ServerId=源 itemId，直接绑源数据），
    /// 处理分组挂载，再逐个全量拉行。返回建好的模块数。对应 C# `BuildReferenceWindowPanelsAsync`。
    @discardableResult
    public func buildReferenceWindowPanels(win: WindowConfig, items: [JSONValue],
                                           shareMode: String, shareId: String?, shareCode: String?,
                                           allowEdit: Bool, allowDelete: Bool, allowReShare: Bool) async -> Int {
        var panelMap: [String: PanelItem] = [:]
        var ordered: [(item: [String: JSONValue], panel: PanelItem)] = []
        for tok in items {
            guard let it = tok.objectValue else { continue }
            let sid = it["serverId"]?.stringValue ?? ""
            if sid.isEmpty || panelMap[sid] != nil { continue }
            let p = Self.buildPanelFromServerItem(it, win: win)
            // 分享属性：标记为引用导入，客户端据此拦截编辑/删除、并支持再分享判断
            p.ShareMode = shareMode
            p.ShareId = shareId
            p.ShareCode = shareCode
            p.AllowEdit = allowEdit
            p.AllowDelete = allowDelete
            p.AllowReShare = allowReShare
            panelMap[sid] = p
            ordered.append((it, p))
        }
        // 分组子模块挂到父分组，其余按服务端顺序加入窗口
        for entry in ordered {
            if let gid = entry.item["groupId"]?.stringValue, !gid.isEmpty,
               let parent = panelMap[gid], parent !== entry.panel {
                if parent.ChildPanels == nil { parent.ChildPanels = [] }
                parent.ChildPanels!.append(entry.panel)
            } else {
                win.Panels.append(entry.panel)
            }
        }
        // 逐个全量拉行（pullItemFull 内部按类型/ServerId 自行跳过不可同步的模块）
        for entry in ordered {
            _ = await pullItemFull(entry.panel)
        }
        return panelMap.count
    }

    // MARK: - 失效共享清理

    /// 启动对账时清理已失效的共享组件（弥补接收者离线时错过 share_cancelled WS 通知的场景）：
    /// 拉取当前用户仍有效的导入记录，与服务端结构比对——
    /// 1) 导入的引用窗口（有 SourceBarId）分享已失效则整个移除；
    /// 2) 个人窗口内「不属于自己云端结构、也不在有效导入记录中」的共享面板移除。
    /// 团队窗口不参与清理，避免误删。对应 C# `CleanupRevokedSharesAsync`。
    func cleanupRevokedShares(mgr: WindowConfigManager, settings: Settings, structureItemIds: Set<String>) async -> Bool {
        // 结构拉取失败时不能清理（无法判断归属，避免误删）
        if structureItemIds.isEmpty { return false }

        let r = await api.send("GET", Self.shareImportsEndpoint)
        guard r.ok, case .array(let imports)? = r.data else { return false }

        var validItemServerIds = Set<String>()
        var validImportLocalIds = Set<String>()
        var validSourceBarIds = Set<String>()
        for imp in imports {
            guard let o = imp.objectValue else { continue }
            if let sid = o["itemServerId"]?.stringValue, !sid.isEmpty { validItemServerIds.insert(sid) }
            if let lid = o["localId"]?.stringValue, !lid.isEmpty { validImportLocalIds.insert(lid) }
            if let sb = o["sourceBarId"]?.stringValue, !sb.isEmpty { validSourceBarIds.insert(sb) }
        }

        var changed = false
        // 失效引用窗口下的卡片、窗口内残留的共享面板，ServerId 都指向分享者的源模块：
        // 本地行必须硬删（不打墓碑），否则下次结构上传会把删除意图报到源模块上，
        // 源模块属团队且本机是其成员时服务端会判定有删除权 → 真删源模块（分享者与其他成员一起丢数据）。
        // 窗口自身保留墓碑：入口空壳归本人所有，需让服务端软删，否则下次结构拉取会把它补回来。
        var revokedItemUids: [String] = []

        // 1) 窗口级：导入的引用窗口分享已失效 → 移除整个窗口
        for i in mgr.Windows.indices.reversed() {
            let w = mgr.Windows[i]
            guard let sourceBar = w.SourceBarId, !sourceBar.isEmpty else { continue }
            let valid = validImportLocalIds.contains(w.Id) || validSourceBarIds.contains(sourceBar)
            if !valid {
                for p in WindowConfigManager.enumerateAllPanels(w.Panels) { revokedItemUids.append(p.Id) }
                mgr.Windows.remove(at: i)
                changed = true
                RuntimeLog.debug("[CloudSync] share expired, removing imported window: \(w.Name)")
            }
        }

        // 2) 模块级：个人窗口内残留的失效共享面板
        for w in mgr.Windows {
            if w.OwnerType == "team" { continue }
            if Self.removeRevokedSharedPanels(&w.Panels, structureItemIds, validItemServerIds, validImportLocalIds, &revokedItemUids) {
                changed = true
                RuntimeLog.debug("[CloudSync] share expired, cleaned leftover shared components in window \(w.Name)")
            }
        }

        if changed {
            // 先硬删引用行再 Save：Save 内的 tombstoneMissing 找不到这些行，墓碑无从生成
            if !revokedItemUids.isEmpty { LocalDbService.hardDeleteRows(itemUids: revokedItemUids) }
            Seam.uiPost { mgr.Save() }
            // mac 无每 bar 独立窗口：C# RemoveSharedWindowsByIds 的关窗语义由标签/卡片流重取覆盖
            Seam.uiPost { Seam.refreshAllWindows?() }
        }
        return changed
    }

    /// 递归移除失效共享面板：ServerId 非空、非团队模块、不在自己云端结构、也不在有效导入记录中。
    /// sink 收集被移除面板（含子面板）的本地 uid，供调用方硬删本地库行。
    /// 对应 C# `RemoveRevokedSharedPanels`。
    private static func removeRevokedSharedPanels(_ panels: inout [PanelItem],
                                                  _ structureItemIds: Set<String>,
                                                  _ validItemServerIds: Set<String>,
                                                  _ validImportLocalIds: Set<String>,
                                                  _ sink: inout [String]) -> Bool {
        var removed = false
        for i in panels.indices.reversed() {
            let p = panels[i]
            let candidate = !(p.ServerId ?? "").isEmpty
                && p.OwnerType != "team"
                && !structureItemIds.contains(p.ServerId!)
                && !validItemServerIds.contains(p.ServerId!)
                && !validImportLocalIds.contains(p.Id)
            if candidate {
                for c in WindowConfigManager.enumerateAllPanels([p]) { sink.append(c.Id) }
                panels.remove(at: i)
                removed = true
                continue
            }
            if var children = p.ChildPanels {
                // Swift 的 || 会短路 inout 递归的副作用：先算递归结果再合并标记
                let childRemoved = removeRevokedSharedPanels(&children, structureItemIds, validItemServerIds, validImportLocalIds, &sink)
                if childRemoved { removed = true }
                p.ChildPanels = children
            }
        }
        return removed
    }
}