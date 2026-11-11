import Foundation
import SideDeskCore

/// LocalDbService 的云同步专属持久化（对应 C# LocalDbService 的
/// SaveRowServerIds/GetRowServerIds/LoadPendingDeleteTombstones/MarkTombstonesSynced/
/// HardDeleteRows/PurgeOldTombstones 一族）。
extension LocalDbService {

    // MARK: - 服务端行 ID 回写 / 查询

    /// 拉取/推送回写：缓存服务端行 ID（row_uid → rowServerId/dataServerId）。
    /// 写入映射表（不依赖行已落库），并尽力同步更新当前行表。对应 C# `SaveRowServerIds`。
    public static func saveRowServerIds(_ entries: [(rowUid: String, rowServerId: String?, dataServerId: String?)]) {
        let scope = currentScope()
        guard let conn = open() else { return }
        defer { conn.close() }
        conn.execute("BEGIN;")
        for e in entries where !e.rowUid.isEmpty {
            conn.run("""
            INSERT INTO local_row_id_map (row_uid, user_id, row_server_id, data_server_id)
            VALUES ($uid, $scope, $rsid, $dsid)
            ON CONFLICT(row_uid) DO UPDATE SET
              user_id = excluded.user_id,
              row_server_id = COALESCE(excluded.row_server_id, local_row_id_map.row_server_id),
              data_server_id = COALESCE(excluded.data_server_id, local_row_id_map.data_server_id);
            """, ["$uid": e.rowUid, "$scope": scope, "$rsid": e.rowServerId, "$dsid": e.dataServerId])
            conn.run("""
            UPDATE local_item_row
            SET row_server_id = COALESCE($rsid, row_server_id),
                data_server_id = COALESCE($dsid, data_server_id)
            WHERE row_uid = $uid;
            """, ["$uid": e.rowUid, "$rsid": e.rowServerId, "$dsid": e.dataServerId])
        }
        conn.execute("COMMIT;")
    }

    /// 批量查询已缓存的服务端行 ID：local_item_row 先查，local_row_id_map（拉取回写的
    /// 权威源）覆盖。推送前用于组装 serverId 寻址载荷。对应 C# `GetRowServerIds`。
    public static func getRowServerIds(_ rowUids: [String]) -> [String: (rowServerId: String?, dataServerId: String?)] {
        var result: [String: (String?, String?)] = [:]
        let uids = Array(Set(rowUids.filter { !$0.isEmpty }))
        guard !uids.isEmpty, let conn = open() else { return result }
        defer { conn.close() }
        let scope = currentScope()
        var params: [String: String?] = ["$scope": scope]
        var names: [String] = []
        for (i, u) in uids.enumerated() {
            names.append("$u\(i)")
            params["$u\(i)"] = u
        }
        let inList = names.joined(separator: ",")
        for table in ["local_item_row", "local_row_id_map"] {
            for r in conn.query("SELECT row_uid, row_server_id, data_server_id FROM \(table) WHERE user_id=$scope AND row_uid IN (\(inList))", params) {
                guard let uid = r["row_uid"] ?? nil else { continue }
                result[uid] = (r["row_server_id"] ?? nil, r["data_server_id"] ?? nil)
            }
        }
        return result
    }

    // MARK: - 删除墓碑（云同步显式删除凭据）

    /// 墓碑保留天数：上报确认后仍保留一段时间供事后追查数据流向，到期硬删。
    private static let tombstoneRetentionDays = 30

    /// 到期墓碑清理是否已在本进程执行过
    private static let purgeLock = SyncLock()
    private static var tombstonesPurged = false

    /// 读取当前作用域内待上报的删除墓碑（deleted_at 非空且尚未确认上报），返回其 server_id 列表。
    /// 只取 server_id 非空的行——从未同步到服务端的本地行，服务端不认识，既无需也无法删。
    /// 对应 C# `LoadPendingDeleteTombstones`。
    public static func loadPendingDeleteTombstones() -> (bars: [String], items: [String]) {
        guard let conn = open() else { return ([], []) }
        defer { conn.close() }
        let scope = currentScope()
        func collect(_ table: String) -> [String] {
            conn.query("""
            SELECT server_id FROM \(table) WHERE user_id=$scope AND deleted_at IS NOT NULL
              AND deleted_synced=0 AND server_id IS NOT NULL AND server_id<>''
            """, ["$scope": scope]).compactMap { $0["server_id"] ?? nil }
        }
        return (collect("local_bar"), collect("local_item"))
    }

    /// 把指定墓碑标为已确认（结构上传成功后调用）。只标本次真正上报过的 server_id，
    /// 不按作用域批量标——否则上传期间新产生的墓碑会被误标为已确认，删除意图静默丢失。
    /// 不立即硬删：保留 30 天供追查，到期由 `purgeOldTombstones` 清理。对应 C# `MarkTombstonesSynced`。
    public static func markTombstonesSynced(barServerIds: [String], itemServerIds: [String]) {
        guard !barServerIds.isEmpty || !itemServerIds.isEmpty, let conn = open() else { return }
        defer { conn.close() }
        let scope = currentScope()
        conn.execute("BEGIN;")
        mark(conn, "local_bar", scope, barServerIds)
        mark(conn, "local_item", scope, itemServerIds)
        conn.execute("COMMIT;")
    }

    private static func mark(_ conn: SQLiteConnection, _ table: String, _ scope: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        var params: [String: String?] = ["$scope": scope]
        var names: [String] = []
        for (i, id) in ids.enumerated() {
            names.append("$s\(i)")
            params["$s\(i)"] = id
        }
        conn.run("""
        UPDATE \(table) SET deleted_synced=1 WHERE user_id=$scope AND deleted_at IS NOT NULL
          AND server_id IN (\(names.joined(separator: ",")))
        """, params)
    }

    /// 硬删指定 uid 的窗口/模块行，**不打删除墓碑**（语义与 tombstoneMissing 相反）。
    /// 用于「本设备失去访问权」而非「用户主动删除」的场景：被移出团队后清理该团队的窗口/卡片，
    /// 或收到 team_item_removed / team_bar_removed 后移除作者已删除、已改归属的团队卡片。
    /// 这些数据在服务端仍归属团队或作者，若留下墓碑，下次结构上传会把删除意图上报到服务端，
    /// 进而软删其他成员仍在使用的团队窗口/卡片。
    /// 调用顺序：先从内存移除 → 调本方法 → 再 WindowConfigManager.Save()（此时 tombstoneMissing 已找不到这些行）。
    /// 行级数据由随后的 Save 全量重写自动清理，此处不单独处理。对应 C# `HardDeleteRows`。
    public static func hardDeleteRows(barUids: [String]? = nil, itemUids: [String]? = nil) {
        let bars = Array(Set((barUids ?? []).filter { !$0.isEmpty }))
        let items = Array(Set((itemUids ?? []).filter { !$0.isEmpty }))
        guard !bars.isEmpty || !items.isEmpty, let conn = open() else { return }
        defer { conn.close() }
        let scope = currentScope()
        conn.execute("BEGIN;")
        deleteBatch(conn, "local_bar", scope, bars)
        deleteBatch(conn, "local_item", scope, items)
        conn.execute("COMMIT;")
    }

    /// 只删当前作用域的行；按 IN 分批规避 SQLite 参数上限
    private static func deleteBatch(_ conn: SQLiteConnection, _ table: String, _ scope: String, _ uids: [String]) {
        let batch = 400
        var start = 0
        while start < uids.count {
            let slice = Array(uids[start..<min(start + batch, uids.count)])
            var params: [String: String?] = ["$scope": scope]
            var names: [String] = []
            for (i, u) in slice.enumerated() {
                names.append("$u\(i)")
                params["$u\(i)"] = u
            }
            conn.run("DELETE FROM \(table) WHERE user_id=$scope AND local_uid IN (\(names.joined(separator: ",")))", params)
            start += batch
        }
    }

    /// 硬删超过保留期的已确认墓碑（每进程一次，由 loadManager 启动加载时触发）。
    /// 只清 deleted_synced=1 的——未确认的墓碑必须留到成功上报为止，否则删除意图丢失、已删窗口会在拉取时复活。
    /// 对应 C# `PurgeOldTombstones`。cutoff 与墓碑写入同为 UTC 无小数秒 ISO，字典序即时间序。
    public static func purgeOldTombstones() {
        let claimed = purgeLock.withLock { () -> Bool in
            if tombstonesPurged { return false }
            tombstonesPurged = true
            return true
        }
        guard claimed, let conn = open() else { return }
        defer { conn.close() }
        let cutoff = isoString(Date().addingTimeInterval(-Double(tombstoneRetentionDays) * 86400))
        conn.execute("BEGIN;")
        var total = 0
        for table in ["local_bar", "local_item"] {
            conn.run("""
            DELETE FROM \(table) WHERE deleted_synced=1 AND deleted_at IS NOT NULL AND deleted_at<$cutoff
            """, ["$cutoff": cutoff])
            total += conn.lastChanges
        }
        conn.execute("COMMIT;")
        if total > 0 { RuntimeLog.debug("[LocalDb] purged \(total) expired delete tombstones") }
    }
}