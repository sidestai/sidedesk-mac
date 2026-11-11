import Foundation
import SideDeskCore

/// 云同步：结构化载荷构建与 ServerId 映射（对应 C# `CloudSyncService.Payload.cs`）。
extension CloudSyncService {

    // MARK: - 上传 DTO（nil 字段经 synthesized encodeIfPresent 省略，等价 C# NullValueHandling.Ignore）

    /// 云同步上传的 bar（窗口）DTO。
    struct SyncBar: Encodable {
        var LocalId: String = ""
        var ServerId: String?
        var Name: String = ""
        var BGColor: String?
        var OwnerType: String?
        var CorpId: String?
        var Items: [SyncItem] = []
        enum CodingKeys: String, CodingKey {
            case LocalId = "localId", ServerId = "serverId", Name = "name", BGColor = "bgColor"
            case OwnerType = "ownerType", CorpId = "corpId", Items = "items"
        }
    }

    /// 云同步上传的 item（模块）DTO；group 的子项放在 Items（仅一层）。
    struct SyncItem: Encodable {
        var LocalId: String = ""
        var ServerId: String?
        var `Type`: String = ""
        var Title: String?
        var BGColor: String?
        var CorpId: String?
        var Data: JSONValue = .object([:])
        var Items: [SyncItem]?
        enum CodingKeys: String, CodingKey {
            case LocalId = "localId", ServerId = "serverId", `Type` = "type", Title = "title"
            case BGColor = "bgColor", CorpId = "corpId", Data = "data", Items = "items"
        }
    }

    /// 数据看板变量 DTO（key-value；一个数据项可对应多个变量）。
    struct SyncVariable: Encodable {
        var ItemLocalId: String?
        var VarKey: String = ""
        var VarValue: String?
        var Label: String?
        var CorpId: String?
        enum CodingKeys: String, CodingKey {
            case ItemLocalId = "itemLocalId", VarKey = "varKey", VarValue = "varValue"
            case Label = "label", CorpId = "corpId"
        }
    }

    /// 数据看板数据项配置 DTO（名称/网址/选择器/间隔/浏览器/团队归属）。
    struct SyncDataItem: Encodable {
        var ItemLocalId: String?
        var Label: String?
        var TargetUrl: String?
        var Selector: String?
        var SelectorType: String?
        var RefreshInterval: Int?
        var BrowserId: String?
        var ProfileId: String?
        var TemplateId: String?
        var CorpId: String?
        enum CodingKeys: String, CodingKey {
            case ItemLocalId = "itemLocalId", Label = "label", TargetUrl = "targetUrl"
            case Selector = "selector", SelectorType = "selectorType", RefreshInterval = "refreshInterval"
            case BrowserId = "browserId", ProfileId = "profileId", TemplateId = "templateId", CorpId = "corpId"
        }
    }

    /// 数据看板变量集 DTO（多变量聚合配置）。
    struct SyncVariableSet: Encodable {
        var VarKey: String = ""
        var Op: String?
        var SourceKeys: [String]?
        var Pattern: String?
        var CorpId: String?
        enum CodingKeys: String, CodingKey {
            case VarKey = "varKey", Op = "op", SourceKeys = "sourceKeys", Pattern = "pattern", CorpId = "corpId"
        }
    }

    /// 全量结构上传载荷（对应 C# 的匿名对象；字段名即线格式）。
    private struct SyncPayload: Encodable {
        var app = "SideDesk"
        var machine: String
        var corpId: String?
        var syncedAt: String
        var syncProtocol: Int
        var bars: [SyncBar]
        var deletedBars: [String]
        var deletedItems: [String]
        var variables: [SyncVariable]
        var dataItems: [SyncDataItem]
        var variableSets: [SyncVariableSet]
    }

    // MARK: - 载荷构建

    /// 构建云同步结构化上传载荷。对应 C# `BuildSyncPayloadJson`。
    /// 必须显式声明 syncProtocol=2：新客户端恰好没有待上报墓碑时 deletedBars 为空，
    /// 服务端若靠列表存在性判版本会误判旧客户端退回「缺席即删除」对账。
    static func buildSyncPayload(mgr: WindowConfigManager, deletedBars: [String], deletedItems: [String]) -> JSONValue {
        // 同一 ServerId 模块出现在多个窗口时（自导入 reference 共存），上传只保留第一个
        // 窗口中的条目：避免服务端把模块归属在窗口间来回挪动，对账拉取反复「补齐」出重复模块
        var emittedServerIds = Set<String>()
        var bars: [SyncBar] = []
        for win in mgr.Windows {
            bars.append(buildSyncBar(win, emittedServerIds: &emittedServerIds))
        }

        // 数据看板变量（设置了变量名的数据项；含不绑定面板的后台数据项）
        var variables: [SyncVariable] = []
        for win in mgr.Windows {
            for p in win.Panels { collectVariables(p, into: &variables) }
        }
        for di in mgr.BackgroundDashboardItems { collectVariable(from: di, into: &variables) }

        // 数据看板数据项配置（全量，后端结构化记录；含后台数据项）
        var dataItems: [SyncDataItem] = []
        for win in mgr.Windows {
            for p in win.Panels { collectDataItems(p, into: &dataItems) }
        }
        for di in mgr.BackgroundDashboardItems { collectDataItem(from: di, into: &dataItems) }

        // 变量集配置（团队归属透传加密串，空=个人）
        var variableSets: [SyncVariableSet] = []
        for s in mgr.VariableSets {
            variableSets.append(SyncVariableSet(
                VarKey: s.VarKey, Op: s.Op, SourceKeys: s.SourceKeys,
                Pattern: s.Pattern.isEmpty ? nil : s.Pattern,
                CorpId: (s.TeamId ?? "").isEmpty ? nil : s.TeamId))
        }

        let payload = SyncPayload(
            machine: machine,
            corpId: Seam.settings.SelectedCorpId,
            syncedAt: isoO(Date()),
            syncProtocol: syncProtocolVersion,
            bars: bars,
            deletedBars: deletedBars,
            deletedItems: deletedItems,
            variables: variables,
            dataItems: dataItems,
            variableSets: variableSets)
        return jsonValue(payload)
    }

    /// 单窗口创建接口的 bar 载荷（对应 C# `CreateBarOnServerAsync` 里的 BuildSyncBar(win)）。
    static func buildSyncBarValue(_ win: WindowConfig) -> JSONValue {
        var emittedServerIds = Set<String>()
        return jsonValue(buildSyncBar(win, emittedServerIds: &emittedServerIds))
    }

    /// 将单个窗口配置转为 SyncBar（含其全部模块）。对应 C# `BuildSyncBar`。
    private static func buildSyncBar(_ win: WindowConfig, emittedServerIds: inout Set<String>) -> SyncBar {
        var bar = SyncBar(LocalId: win.Id, ServerId: win.ServerId, Name: win.Name, BGColor: win.BGColor)
        bar.OwnerType = win.OwnerType != "personal" ? win.OwnerType : nil
        // 团队 ID 为服务端加密串，直接透传，由后端解析
        if win.OwnerType == "team", let corp = win.CorpId, !corp.isEmpty { bar.CorpId = corp }
        for p in win.Panels {
            if let item = buildSyncItem(p, isInsideGroup: false, emittedServerIds: &emittedServerIds) {
                bar.Items.append(item)
            }
        }
        return bar
    }

    /// 将单个模块转为 SyncItem；group 的子项仅展开一层（group 内不再嵌套 group）。
    /// 共享 ServerId 已在前面窗口上传过时返回 nil（跳过）。对应 C# `BuildSyncItem`。
    private static func buildSyncItem(_ p: PanelItem, isInsideGroup: Bool, emittedServerIds: inout Set<String>) -> SyncItem? {
        if let sid = p.ServerId, !sid.isEmpty {
            guard emittedServerIds.insert(sid).inserted else { return nil }
        }
        var item = SyncItem(LocalId: p.Id, ServerId: p.ServerId, Type: p.`Type`.serverName,
                            Title: p.Title, BGColor: p.BGColor ?? p.GroupBGColor, Data: buildItemData(p))
        if p.OwnerType == "team", let tid = p.TeamId, !tid.isEmpty { item.CorpId = tid }
        if !isInsideGroup, p.`Type` == .Group, let children = p.ChildPanels, !children.isEmpty {
            var subItems: [SyncItem] = []
            for child in children {
                if let childItem = buildSyncItem(child, isInsideGroup: true, emittedServerIds: &emittedServerIds) {
                    subItems.append(childItem)
                }
            }
            item.Items = subItems
        }
        return item
    }

    /// 模块内容参数：仅保留模块级设置，排除身份元数据与列表数据（列表走行级端点）。
    /// 对应 C# `BuildItemData`。
    static func buildItemData(_ p: PanelItem) -> JSONValue {
        guard var o = jsonValue(p).objectValue else { return .object([:]) }
        for k in ["Id", "ServerId", "Type", "Title", "BGColor", "GroupBGColor", "ChildPanels",
                  "StickyNotes", "DeskNotes", "TodoItems", "TimerItems", "CountdownItems",
                  "SignalLights", "ClipboardItems", "FileItems", "Pomodoro", "DashboardItems",
                  "DigitalEmployeeIds", "FriendUserIds", "QuickItems", "CheckInItems"] {
            o.removeValue(forKey: k)
        }
        // C# 末尾剔除所有 null 属性（Swift 编码本就用 encodeIfPresent 省略 nil，此处兜底显式 null）
        for (k, v) in o where v == .null { o.removeValue(forKey: k) }
        return .object(o)
    }

    // MARK: - 数据看板收集

    /// 递归收集面板（含分组子面板）内设置了变量名的数据看板项。对应 C# `CollectVariables`。
    private static func collectVariables(_ p: PanelItem, into vars: inout [SyncVariable]) {
        if let items = p.DashboardItems {
            for di in items { collectVariable(from: di, into: &vars) }
        }
        if let children = p.ChildPanels {
            for c in children { collectVariables(c, into: &vars) }
        }
    }

    private static func collectVariable(from di: DataDashboardItem, into vars: inout [SyncVariable]) {
        guard let varKey = di.VarKey, !varKey.isEmpty else { return }
        vars.append(SyncVariable(
            ItemLocalId: di.Id, VarKey: varKey, VarValue: di.Value, Label: di.Label,
            CorpId: (di.TeamId ?? "").isEmpty ? nil : di.TeamId))
    }

    /// 递归收集面板内所有数据看板数据项配置。对应 C# `CollectDataItems`。
    private static func collectDataItems(_ p: PanelItem, into items: inout [SyncDataItem]) {
        if let list = p.DashboardItems {
            for di in list { collectDataItem(from: di, into: &items) }
        }
        if let children = p.ChildPanels {
            for c in children { collectDataItems(c, into: &items) }
        }
    }

    private static func collectDataItem(from di: DataDashboardItem, into items: inout [SyncDataItem]) {
        items.append(SyncDataItem(
            ItemLocalId: di.Id, Label: di.Label, TargetUrl: di.TargetUrl, Selector: di.Selector,
            SelectorType: di.SelectorType.isEmpty ? nil : di.SelectorType,
            RefreshInterval: di.RefreshIntervalSeconds,
            BrowserId: di.BrowserId, ProfileId: di.ProfileId, TemplateId: di.TemplateId,
            CorpId: (di.TeamId ?? "").isEmpty ? nil : di.TeamId))
    }

    // MARK: - ServerId 映射回写

    /// 解析服务器响应 data 中的 localId -> serverId 映射，写入 Settings.CloudIdMap
    /// （带账号作用域前缀，防切号泄漏）与模型 ServerId 字段。对应 C# `ApplyServerIdMappings`。
    /// 调用方已门控 r.ok；无 data/解析失败静默跳过，不影响同步成功状态。
    static func applyServerIdMappings(data: JSONValue?, settings: Settings, mgr: WindowConfigManager) {
        guard let data = data?.objectValue else { return }
        var changed = false
        let scopePrefix = LocalDbService.currentScope() + ":"

        if case .array(let barArr)? = data["bars"] {
            for entry in barArr {
                guard let e = entry.objectValue,
                      let localId = e["localId"]?.stringValue, !localId.isEmpty,
                      let serverId = e["serverId"]?.stringValue, !serverId.isEmpty else { continue }
                settings.CloudIdMap[scopePrefix + localId] = serverId
                mgr.GetById(localId)?.ServerId = serverId
                changed = true
            }
        }
        // items / groups -> PanelItem.ServerId（group 本质也是 PanelItem）
        for section in ["items", "groups"] {
            guard case .array(let arr)? = data[section] else { continue }
            for entry in arr {
                guard let e = entry.objectValue,
                      let localId = e["localId"]?.stringValue, !localId.isEmpty,
                      let serverId = e["serverId"]?.stringValue, !serverId.isEmpty else { continue }
                settings.CloudIdMap[scopePrefix + localId] = serverId
                findPanelItem(mgr, localId)?.ServerId = serverId
                changed = true
            }
        }

        if changed {
            settings.Save()
            mgr.Save()
            // 推迟：C# 此处 DedupPanelsSharingServerIdOnce——针对 Windows 遗留 xid- 密文污染
            // 数据的一次性修复，fresh Mac 无此历史数据，不移植
        }
    }

    /// 按 localId 在所有窗口的模块（含 group 一层子项）中查找。对应 C# `FindPanelItem`。
    static func findPanelItem(_ mgr: WindowConfigManager, _ localId: String) -> PanelItem? {
        for win in mgr.Windows {
            for p in win.Panels {
                if p.Id == localId { return p }
                if let children = p.ChildPanels {
                    for c in children where c.Id == localId { return c }
                }
            }
        }
        return nil
    }

    // MARK: - JSON 小工具

    /// Encodable → JSONValue（经 JSON 往返；失败回落 .null，调用方均按对象/数组存在性兜底）。
    static func jsonValue<T: Encodable>(_ v: T) -> JSONValue {
        guard let data = try? SideDeskJSON.encoder().encode(v),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }

    /// JSONValue → 稳定字符串（sortedKeys：快照对比要求同一份数据两次序列化结果一致，
    /// 普通 JSONEncoder 的字典序不确定，会造成「无变更也判有差异」的推送空转）。
    static func jsonString(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(v), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}