import Foundation
import SideDeskCore

/// LocalDbService 的窗口树持久化（对应 C# LocalDbService.SaveManager/LoadManager 及其
/// Upsert*/SaveItemRows/AttachRowsToPanels/TombstoneMissing 一族，ADR-0011）。
///
/// 本批移植「以内存为准」的全量重写 + 读取组装，含删除墓碑（deleted_at）与作用域隔离。
/// 云同步专属的墓碑/行 ID API 见 `LocalDbService+Sync`；QuickGroupService 遗留迁移、
/// CloudSync.NotifyRowsChanged 接线在 WindowConfigManager.Save。服务端行 ID 映射
/// （LoadRowServerIdMap）予以保留，以免每次保存丢失已有 server_id。
extension LocalDbService {

    // MARK: - 时间戳（列 TEXT，ISO8601）

    private static let _iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let _isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func isoString(_ d: Date) -> String { _iso.string(from: d) }
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return _isoFrac.date(from: s) ?? _iso.date(from: s)
    }

    // MARK: - JSON 小工具

    private static func enc<T: Encodable>(_ v: T) -> String {
        guard let data = try? SideDeskJSON.encoder().encode(v),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private static func dec<T: Decodable>(_ json: String?, _ t: T.Type) -> T? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? SideDeskJSON.decoder().decode(T.self, from: data)
    }

    private static func decList<T: Decodable>(_ json: String?, _ t: T.Type) -> [T]? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? SideDeskJSON.decoder().decode([T].self, from: data)
    }

    /// item_data 序列化时排除 ChildPanels 与行列表数据（子面板/行数据以独立行存储）。
    /// 镜像 C# PanelItemContractResolver 的 _excludedItemDataProps（注意 DeskNotes 不在排除集，与 C# 一致）。
    private static let excludedItemDataKeys: Set<String> = [
        "ChildPanels", "StickyNotes", "TodoItems", "ClipboardItems", "TimerItems",
        "CountdownItems", "SignalLights", "FileItems", "Pomodoro", "DashboardItems",
        "DigitalEmployeeIds", "FriendUserIds", "QuickItems", "CheckInItems"
    ]

    static func encodeItemData(_ p: PanelItem) -> String {
        guard let data = try? SideDeskJSON.encoder().encode(p),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        for k in excludedItemDataKeys { obj.removeValue(forKey: k) }
        guard let out = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: out, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 深度优先遍历面板树（含子面板）
    static func enumerateAllPanels(_ panels: [PanelItem]) -> [PanelItem] {
        var out: [PanelItem] = []
        for p in panels {
            out.append(p)
            if let children = p.ChildPanels { out.append(contentsOf: enumerateAllPanels(children)) }
        }
        return out
    }

    // MARK: - SaveManager

    /// 以内存为准的全量重写（单事务）：bar/item 树 upsert + 差集打墓碑 + 行表整表重写 + 应用级状态。
    public static func saveManager(_ mgr: WindowConfigManager) {
        let scope = currentScope()

        // 作用域一致性守卫：内存实例在别的作用域下加载（登出/登录后窗口尚未重载）→ 拒绝保存，绝不毁数据。
        if let loaded = mgr.LoadedScope, !loaded.isEmpty, loaded != scope {
            RuntimeLog.debug("[LocalDb] save rejected: manager scope '\(loaded)' != current scope '\(scope)'")
            return
        }

        guard let conn = open() else { return }
        defer { conn.close() }
        conn.execute("BEGIN;")

        let now = isoString(Date())
        var liveBarUids = Set<String>()
        var liveItemUids = Set<String>()

        for win in mgr.Windows {
            liveBarUids.insert(win.Id)
            upsertBar(conn, win, now, scope)
            var order = 0
            for p in win.Panels {
                saveItemTree(conn, p, win.Id, nil, &order, now, &liveItemUids, scope)
            }
        }

        tombstoneMissing(conn, "local_bar", "local_uid", liveBarUids, scope, now)
        tombstoneMissing(conn, "local_item", "local_uid", liveItemUids, scope, now)

        // 行级数据全量重写：先留存服务端行 ID 映射，删表后按内存重插并回填
        let serverIdMap = loadRowServerIdMap(conn, scope)
        conn.run("""
        DELETE FROM local_item_row WHERE user_id=$scope;
        DELETE FROM local_sticky_note WHERE user_id=$scope;
        DELETE FROM local_desk_note WHERE user_id=$scope;
        DELETE FROM local_todo_item WHERE user_id=$scope;
        DELETE FROM local_clipboard_item WHERE user_id=$scope;
        """, ["$scope": scope])
        for win in mgr.Windows {
            for p in enumerateAllPanels(win.Panels) {
                saveItemRows(conn, p, now, serverIdMap, scope)
            }
        }
        upsertState(conn, "row_storage_migrated", "1")

        // 应用级状态（按作用域隔离）
        upsertState(conn, scopedKey("left_dock", scope), enc(mgr.LeftDock))
        upsertState(conn, scopedKey("right_dock", scope), enc(mgr.RightDock))
        upsertState(conn, scopedKey("background_dashboard_items", scope), enc(mgr.BackgroundDashboardItems))
        upsertState(conn, scopedKey("variable_sets", scope), enc(mgr.VariableSets))

        conn.execute("COMMIT;")
    }

    private static func saveItemTree(_ conn: SQLiteConnection, _ p: PanelItem, _ barUid: String,
                                     _ parentUid: String?, _ order: inout Int, _ now: String,
                                     _ liveUids: inout Set<String>, _ scope: String) {
        liveUids.insert(p.Id)
        upsertItem(conn, p, barUid, parentUid, order, now, scope)
        order += 1
        if let children = p.ChildPanels {
            var childOrder = 0
            for c in children {
                saveItemTree(conn, c, barUid, p.Id, &childOrder, now, &liveUids, scope)
            }
        }
    }

    private static func upsertBar(_ conn: SQLiteConnection, _ win: WindowConfig, _ now: String, _ scope: String) {
        conn.run("""
        INSERT INTO local_bar
          (local_uid, user_id, server_id, title, bg_color, window_type, url, is_edit_mode, is_app_mode,
           show_in_tabs, owner_type, corp_id, share_mode, source_bar_id, enabled_tools, keymouse_recorder, created_at, updated_at)
        VALUES
          ($uid, $scope, $sid, $title, $bg, $wtype, $url, $edit, $app, $tabs, $owner, $corp, $share, $src, $tools, $keymouse, $created, $updated)
        ON CONFLICT(local_uid) DO UPDATE SET
          user_id=excluded.user_id, server_id=excluded.server_id, title=excluded.title, bg_color=excluded.bg_color,
          window_type=excluded.window_type, url=excluded.url, is_edit_mode=excluded.is_edit_mode,
          is_app_mode=excluded.is_app_mode, show_in_tabs=excluded.show_in_tabs, owner_type=excluded.owner_type,
          corp_id=excluded.corp_id, share_mode=excluded.share_mode, source_bar_id=excluded.source_bar_id,
          enabled_tools=excluded.enabled_tools, keymouse_recorder=excluded.keymouse_recorder, updated_at=excluded.updated_at,
          deleted_at=NULL, deleted_synced=0;
        """, [
            "$uid": win.Id,
            "$scope": scope,
            "$sid": win.ServerId,
            "$title": win.Name,
            "$bg": win.BGColor,
            "$wtype": String(win.`Type`.rawValue),
            "$url": win.Url,
            "$edit": win.IsEditMode ? "1" : "0",
            "$app": win.IsAppMode ? "1" : "0",
            "$tabs": win.ShowInTabs ? "1" : "0",
            "$owner": win.OwnerType,
            "$corp": win.CorpId,
            "$share": win.ShareMode,
            "$src": win.SourceBarId,
            "$tools": enc(win.EnabledTools),
            "$keymouse": win.KeyMouseRecorderEnabled ? "1" : "0",
            "$created": isoString(win.CreatedAt),
            "$updated": now
        ])
    }

    private static func upsertItem(_ conn: SQLiteConnection, _ p: PanelItem, _ barUid: String,
                                   _ parentUid: String?, _ order: Int, _ now: String, _ scope: String) {
        let corp = (p.OwnerType == "team" && !(p.TeamId ?? "").isEmpty) ? p.TeamId : nil
        conn.run("""
        INSERT INTO local_item
          (local_uid, user_id, server_id, bar_uid, parent_uid, sort_order, title, item_type, group_id,
           item_data, owner_type, team_id, team_name, corp_id, created_at, updated_at)
        VALUES
          ($uid, $scope, $sid, $bar, $parent, $order, $title, $type, $group, $data, $owner, $team, $teamname, $corp, $created, $updated)
        ON CONFLICT(local_uid) DO UPDATE SET
          user_id=excluded.user_id, server_id=excluded.server_id, bar_uid=excluded.bar_uid, parent_uid=excluded.parent_uid,
          sort_order=excluded.sort_order, title=excluded.title, item_type=excluded.item_type,
          group_id=excluded.group_id, item_data=excluded.item_data, owner_type=excluded.owner_type,
          team_id=excluded.team_id, team_name=excluded.team_name, corp_id=excluded.corp_id, updated_at=excluded.updated_at,
          deleted_at=NULL, deleted_synced=0;
        """, [
            "$uid": p.Id,
            "$scope": scope,
            "$sid": p.ServerId,
            "$bar": barUid,
            "$parent": parentUid,
            "$order": String(order),
            "$title": p.Title,
            "$type": String(p.`Type`.rawValue),
            "$group": p.GroupId,
            "$data": encodeItemData(p),
            "$owner": p.OwnerType,
            "$team": p.TeamId,
            "$teamname": p.TeamName,
            "$corp": corp,
            "$created": now,
            "$updated": now
        ])
    }

    // MARK: - 行级数据写入

    private static func loadRowServerIdMap(_ conn: SQLiteConnection, _ scope: String) -> [String: (row: String?, data: String?)] {
        var map: [String: (String?, String?)] = [:]
        for row in conn.query("SELECT row_uid, row_server_id, data_server_id FROM local_item_row WHERE (row_server_id IS NOT NULL OR data_server_id IS NOT NULL) AND user_id=$scope", ["$scope": scope]) {
            if let uid = row["row_uid"] ?? nil { map[uid] = (row["row_server_id"] ?? nil, row["data_server_id"] ?? nil) }
        }
        for row in conn.query("SELECT row_uid, row_server_id, data_server_id FROM local_row_id_map WHERE user_id=$scope", ["$scope": scope]) {
            if let uid = row["row_uid"] ?? nil { map[uid] = (row["row_server_id"] ?? nil, row["data_server_id"] ?? nil) }
        }
        return map
    }

    private static func insertRow(_ conn: SQLiteConnection, _ itemUid: String, _ rowUid: String,
                                  _ rowType: String, _ content: String, _ order: Int, _ now: String,
                                  _ rowServerId: String?, _ dataServerId: String?, _ scope: String) {
        conn.run("""
        INSERT INTO local_item_row
          (item_uid, row_uid, user_id, row_type, content, sort_order, row_server_id, data_server_id, created_at, updated_at)
        VALUES ($item, $row, $scope, $type, $content, $order, $rsid, $dsid, $created, $updated)
        """, [
            "$item": itemUid, "$row": rowUid, "$scope": scope, "$type": rowType,
            "$content": content, "$order": String(order), "$rsid": rowServerId, "$dsid": dataServerId,
            "$created": now, "$updated": now
        ])
    }

    private static func saveItemRows(_ conn: SQLiteConnection, _ p: PanelItem, _ now: String,
                                     _ serverIdMap: [String: (row: String?, data: String?)], _ scope: String) {
        func insert(_ rowUid: String, _ rowType: String, _ content: String, _ order: Int) {
            let sids = serverIdMap[rowUid]
            insertRow(conn, p.Id, rowUid, rowType, content, order, now, sids?.row, sids?.data, scope)
        }

        if let notes = p.StickyNotes {
            for (i, n) in notes.enumerated() {
                insert(n.Id, "sticky_note", enc(n), i)
                upsertStickyNote(conn, n, scope)
            }
        }
        if let notes = p.DeskNotes {
            for (i, n) in notes.enumerated() {
                insert(n.Id, "desk_note", enc(n), i)
                upsertDeskNote(conn, n, scope)
            }
        }
        if let todos = p.TodoItems {
            for (i, t) in todos.enumerated() {
                insert(t.Id, "todo", enc(t), i)
                upsertTodoItem(conn, t, scope)
            }
        }
        if let clips = p.ClipboardItems {
            for (i, c) in clips.enumerated() {
                insert(c.Id, "clipboard", enc(c), i)
                upsertClipboardItem(conn, c, scope)
            }
        }
        if let timers = p.TimerItems {
            for (i, t) in timers.enumerated() { insert(t.Id, "timer", enc(t), i) }
        }
        if let cds = p.CountdownItems {
            for (i, c) in cds.enumerated() { insert(c.Id, "countdown", enc(c), i) }
        }
        if let lights = p.SignalLights {
            for (i, s) in lights.enumerated() { insert(s.Id, "signal_light", enc(s), i) }
        }
        if let files = p.FileItems {
            for (i, f) in files.enumerated() { insert(f.Id, "file_area", enc(f), i) }
        }
        if let pom = p.Pomodoro {
            insert(pom.Id, "pomodoro", enc(pom), 0)
        }
        if let dash = p.DashboardItems {
            for (i, d) in dash.enumerated() { insert(d.Id, "dashboard", enc(d), i) }
        }
        if let ids = p.DigitalEmployeeIds {
            var o = 0
            for id in ids where !id.isEmpty {
                let row = DigitalEmployeeRow(); row.Id = id; row.EmployeeId = id
                insert(id, "digital_employee", enc(row), o); o += 1
            }
        }
        if let ids = p.FriendUserIds {
            var o = 0
            for id in ids where !id.isEmpty {
                let row = FriendUserRow(); row.Id = id; row.UserId = id
                insert(id, "friend_user", enc(row), o); o += 1
            }
        }
        if let quicks = p.QuickItems {
            for (i, q) in quicks.enumerated() { insert(q.Id, "shortcut", enc(q), i) }
        }
        if let checkins = p.CheckInItems {
            for (i, c) in checkins.enumerated() { insert(c.Id, "check_in", enc(c), i) }
        }
    }

    private static func upsertStickyNote(_ conn: SQLiteConnection, _ n: StickyNote, _ scope: String) {
        conn.run("""
        INSERT INTO local_sticky_note (uid, user_id, content, created_at, updated_at)
        VALUES ($uid, $scope, $content, $created, $updated)
        ON CONFLICT(uid) DO UPDATE SET user_id=excluded.user_id, content=excluded.content, updated_at=excluded.updated_at;
        """, ["$uid": n.Id, "$scope": scope, "$content": n.Content,
              "$created": isoString(n.CreatedAt), "$updated": isoString(n.UpdatedAt)])
    }

    private static func upsertDeskNote(_ conn: SQLiteConnection, _ n: DeskNote, _ scope: String) {
        conn.run("""
        INSERT INTO local_desk_note (uid, user_id, content, created_at, updated_at)
        VALUES ($uid, $scope, $content, $created, $updated)
        ON CONFLICT(uid) DO UPDATE SET user_id=excluded.user_id, content=excluded.content, updated_at=excluded.updated_at;
        """, ["$uid": n.Id, "$scope": scope, "$content": n.Content,
              "$created": isoString(n.CreatedAt), "$updated": isoString(n.UpdatedAt)])
    }

    private static func upsertTodoItem(_ conn: SQLiteConnection, _ t: TodoItem, _ scope: String) {
        conn.run("""
        INSERT INTO local_todo_item
          (uid, user_id, text, description, is_done, due_time, remind_before_minutes, reminded, created_at)
        VALUES ($uid, $scope, $text, $desc, $done, $due, $remind, $reminded, $created)
        ON CONFLICT(uid) DO UPDATE SET
          user_id=excluded.user_id, text=excluded.text, description=excluded.description, is_done=excluded.is_done,
          due_time=excluded.due_time, remind_before_minutes=excluded.remind_before_minutes, reminded=excluded.reminded;
        """, ["$uid": t.Id, "$scope": scope, "$text": t.Text, "$desc": t.Description,
              "$done": t.IsDone ? "1" : "0", "$due": t.DueTime.map { isoString($0) },
              "$remind": String(t.RemindBeforeMinutes), "$reminded": t.Reminded ? "1" : "0",
              "$created": isoString(t.CreatedAt)])
    }

    private static func upsertClipboardItem(_ conn: SQLiteConnection, _ c: ClipboardSavedItem, _ scope: String) {
        conn.run("""
        INSERT INTO local_clipboard_item (uid, user_id, content_type, content, saved_at)
        VALUES ($uid, $scope, $type, $content, $saved)
        ON CONFLICT(uid) DO UPDATE SET user_id=excluded.user_id, content_type=excluded.content_type, content=excluded.content, saved_at=excluded.saved_at;
        """, ["$uid": c.Id, "$scope": scope, "$type": c.ContentType, "$content": c.Content,
              "$saved": isoString(c.SavedAt)])
    }

    private static func tombstoneMissing(_ conn: SQLiteConnection, _ table: String, _ column: String,
                                         _ liveUids: Set<String>, _ scope: String, _ now: String) {
        var dbUids: [String] = []
        for row in conn.query("SELECT \(column) AS uid FROM \(table) WHERE user_id=$scope AND deleted_at IS NULL", ["$scope": scope]) {
            if let uid = row["uid"] ?? nil { dbUids.append(uid) }
        }
        let dead = dbUids.filter { !liveUids.contains($0) }
        guard !dead.isEmpty else { return }
        var params: [String: String?] = ["$scope": scope, "$now": now]
        var names: [String] = []
        for (i, d) in dead.enumerated() {
            names.append("$d\(i)")
            params["$d\(i)"] = d
        }
        conn.run("UPDATE \(table) SET deleted_at=$now, deleted_synced=0 WHERE user_id=$scope AND \(column) IN (\(names.joined(separator: ",")))", params)
    }

    // MARK: - LoadManager

    public static func loadManager() -> WindowConfigManager {
        // 到期墓碑清理（每进程一次）：在打开本次连接前做完，避免与加载过程交叠（对应 C# LoadManager 首步）
        purgeOldTombstones()
        let mgr = WindowConfigManager()
        let scope = currentScope()
        guard let conn = open() else { mgr.LoadedScope = scope; return mgr }
        defer { conn.close() }

        // 1) bars
        var barOrder: [WindowConfig] = []
        let barRows = conn.query("""
        SELECT local_uid, server_id, title, bg_color, window_type, url, is_edit_mode, is_app_mode,
               show_in_tabs, owner_type, corp_id, share_mode, source_bar_id, enabled_tools, keymouse_recorder, created_at
        FROM local_bar WHERE deleted_at IS NULL AND user_id=$scope ORDER BY id
        """, ["$scope": scope])
        for r in barRows {
            let win = WindowConfig()
            win.Id = (r["local_uid"] ?? nil) ?? win.Id
            win.ServerId = r["server_id"] ?? nil
            win.Name = (r["title"] ?? nil) ?? Lang.t("common.newWindow")
            win.BGColor = r["bg_color"] ?? nil
            win.`Type` = WindowType(rawValue: Int((r["window_type"] ?? nil) ?? "0") ?? 0) ?? .Native
            win.Url = r["url"] ?? nil
            win.IsEditMode = (r["is_edit_mode"] ?? nil) != "0"
            win.IsAppMode = (r["is_app_mode"] ?? nil) != "0"
            win.ShowInTabs = (r["show_in_tabs"] ?? nil) != "0"
            win.OwnerType = (r["owner_type"] ?? nil) ?? "personal"
            win.CorpId = r["corp_id"] ?? nil
            win.ShareMode = r["share_mode"] ?? nil
            win.SourceBarId = r["source_bar_id"] ?? nil
            win.EnabledTools = decList(r["enabled_tools"] ?? nil, String.self) ?? ["AIChat"]
            win.KeyMouseRecorderEnabled = (r["keymouse_recorder"] ?? nil) != "0"
            win.CreatedAt = parseDate(r["created_at"] ?? nil) ?? Date()
            barOrder.append(win)
        }

        // 2) items（全部读出后按 bar_uid/parent_uid 组装树）
        var items: [String: PanelItem] = [:]
        var parentOf: [String: String?] = [:]
        var barRoots: [(barUid: String, panel: PanelItem, order: Int)] = []

        let itemRows = conn.query("""
        SELECT local_uid, bar_uid, parent_uid, sort_order, item_data
        FROM local_item WHERE deleted_at IS NULL AND user_id=$scope ORDER BY sort_order, id
        """, ["$scope": scope])
        for r in itemRows {
            let uid = (r["local_uid"] ?? nil) ?? ""
            guard !uid.isEmpty else { continue }
            let barUid = (r["bar_uid"] ?? nil) ?? ""
            let parentUid = r["parent_uid"] ?? nil
            let order = Int((r["sort_order"] ?? nil) ?? "0") ?? 0
            let dataJson = r["item_data"] ?? nil

            let p = dec(dataJson, PanelItem.self) ?? PanelItem()
            p.Id = uid
            items[uid] = p
            parentOf[uid] = parentUid
            if parentUid == nil { barRoots.append((barUid, p, order)) }
        }

        // 组装父子关系
        for (uid, parentUid) in parentOf {
            guard let parentUid, let parent = items[parentUid], let child = items[uid] else { continue }
            if parent.ChildPanels == nil { parent.ChildPanels = [] }
            parent.ChildPanels?.append(child)
        }

        // 挂到各 bar
        for win in barOrder {
            win.Panels = barRoots.filter { $0.barUid == win.Id }
                .sorted { $0.order < $1.order }
                .map { $0.panel }
            mgr.Windows.append(win)
        }

        // 2.5) 行级数据组装
        if getState(conn, "row_storage_migrated") == "1" {
            attachRowsToPanels(conn, Array(items.values), scope)
        }

        // 3) 应用级状态（无后缀旧 key 作为未作用域化存量回退）
        let left = getState(conn, scopedKey("left_dock", scope)) ?? getState(conn, "left_dock")
        let right = getState(conn, scopedKey("right_dock", scope)) ?? getState(conn, "right_dock")
        let bgDash = getState(conn, scopedKey("background_dashboard_items", scope)) ?? getState(conn, "background_dashboard_items")
        let varSets = getState(conn, scopedKey("variable_sets", scope)) ?? getState(conn, "variable_sets")
        if let d = dec(left, DockWindowState.self) { mgr.LeftDock = d }
        if let d = dec(right, DockWindowState.self) { mgr.RightDock = d }
        if let l = decList(bgDash, DataDashboardItem.self) { mgr.BackgroundDashboardItems = l }
        if let l = decList(varSets, VariableSet.self) { mgr.VariableSets = l }

        mgr.LoadedScope = scope
        return mgr
    }

    /// 面板类型是否走行级同步存储（单一出处：RowChangeTracker，镜像 C# 同名函数）
    static func isRowSyncable(_ type: PanelType) -> Bool {
        RowChangeTracker.isRowSyncable(type)
    }

    private static func attachRowsToPanels(_ conn: SQLiteConnection, _ panels: [PanelItem], _ scope: String) {
        var rowsByItem: [String: [(type: String, content: String?)]] = [:]
        let rows = conn.query("SELECT item_uid, row_type, content FROM local_item_row WHERE user_id=$scope ORDER BY sort_order, id", ["$scope": scope])
        for r in rows {
            guard let itemUid = (r["item_uid"] ?? nil) else { continue }
            let rowType: String = (r["row_type"] ?? nil) ?? ""
            let content: String? = r["content"] ?? nil
            rowsByItem[itemUid, default: []].append((type: rowType, content: content))
        }

        for p in panels {
            let rows = rowsByItem[p.Id] ?? []
            p.StickyNotes = rowsToList(rows, "sticky_note", StickyNote.self)
            p.DeskNotes = rowsToList(rows, "desk_note", DeskNote.self)
            p.TodoItems = rowsToList(rows, "todo", TodoItem.self)
            p.ClipboardItems = rowsToList(rows, "clipboard", ClipboardSavedItem.self)
            p.TimerItems = rowsToList(rows, "timer", TimerItem.self)
            p.CountdownItems = rowsToList(rows, "countdown", CountdownItem.self)
            p.SignalLights = rowsToList(rows, "signal_light", SignalLightItem.self)
            p.FileItems = rowsToList(rows, "file_area", FileAreaItem.self)

            if let checkIns = rowsToList(rows, "check_in", CheckInItem.self) {
                p.CheckInItems = checkIns.sorted { $0.SortIndex < $1.SortIndex }
            }
            if let pomodoros = rowsToList(rows, "pomodoro", PomodoroSettings.self), let first = pomodoros.first {
                p.Pomodoro = first
            }
            if let dashboards = rowsToList(rows, "dashboard", DataDashboardItem.self) {
                p.DashboardItems = dashboards
            }
            if let deRows = rowsToList(rows, "digital_employee", DigitalEmployeeRow.self) {
                p.DigitalEmployeeIds = deRows.map { $0.EmployeeId }.filter { !$0.isEmpty }
            }
            if let fuRows = rowsToList(rows, "friend_user", FriendUserRow.self) {
                p.FriendUserIds = fuRows.map { $0.UserId }.filter { !$0.isEmpty }
            }
            if var shortcuts = rowsToList(rows, "shortcut", QuickItem.self) {
                shortcuts.sort { ($0.SortIndex, $0.CreatedAt) < ($1.SortIndex, $1.CreatedAt) }
                p.QuickItems = shortcuts
            }

            // 行同步类型面板无行时兜底空列表（区别于从未初始化的 nil）
            if isRowSyncable(p.`Type`) {
                switch p.`Type` {
                case .StickyNotes: if p.StickyNotes == nil { p.StickyNotes = [] }
                case .Notes: if p.DeskNotes == nil { p.DeskNotes = [] }
                case .TodoList: if p.TodoItems == nil { p.TodoItems = [] }
                case .Clipboard: if p.ClipboardItems == nil { p.ClipboardItems = [] }
                case .Timer: if p.TimerItems == nil { p.TimerItems = [] }
                case .Countdown: if p.CountdownItems == nil { p.CountdownItems = [] }
                case .SignalLight: if p.SignalLights == nil { p.SignalLights = [] }
                case .FileArea: if p.FileItems == nil { p.FileItems = [] }
                case .Pomodoro: if p.Pomodoro == nil { p.Pomodoro = PomodoroSettings() }
                case .DataDashboard: if p.DashboardItems == nil { p.DashboardItems = [] }
                case .DigitalEmployee: if p.DigitalEmployeeIds == nil { p.DigitalEmployeeIds = [] }
                case .Friend: if p.FriendUserIds == nil { p.FriendUserIds = [] }
                case .QuickGroup: if p.QuickItems == nil { p.QuickItems = [] }
                case .CheckIn: if p.CheckInItems == nil { p.CheckInItems = [] }
                default: break
                }
            }
        }
    }

    private static func rowsToList<T: Decodable>(_ rows: [(type: String, content: String?)], _ rowType: String, _ t: T.Type) -> [T]? {
        var list: [T]?
        for r in rows {
            guard r.type == rowType, let content = r.content, !content.isEmpty,
                  let data = content.data(using: .utf8),
                  let item = try? SideDeskJSON.decoder().decode(T.self, from: data) else { continue }
            if list == nil { list = [] }
            list?.append(item)
        }
        return list
    }
}
