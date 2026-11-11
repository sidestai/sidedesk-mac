import Foundation
import SideDeskCore

/// 全局便签库读写（对应 C# LocalDbService.LoadGlobalNotes/SaveGlobalNotes，表 local_global_note）。
///
/// 「全局便签」是 per-panel StickyNotes 之外的独立存储（桌面便签板用），与 StickyNoteService 配套。
/// 日期以 ISO8601 文本存列，与窗口树一致（复用 WindowTree 的 isoString/parseDate）。
extension LocalDbService {

    /// 读取当前作用域下的全部全局便签。
    public static func loadGlobalNotes() -> [StickyNote] {
        guard let conn = open() else { return [] }
        defer { conn.close() }
        let rows = conn.query(
            "SELECT uid, content, created_at, updated_at FROM local_global_note WHERE user_id=$scope",
            ["$scope": currentScope()])
        var list: [StickyNote] = []
        for r in rows {
            let n = StickyNote()
            n.Id = (r["uid"] ?? nil) ?? n.Id
            n.Content = (r["content"] ?? nil) ?? ""
            n.CreatedAt = parseDate(r["created_at"] ?? nil) ?? n.CreatedAt
            n.UpdatedAt = parseDate(r["updated_at"] ?? nil) ?? n.UpdatedAt
            list.append(n)
        }
        return list
    }

    /// 整表重写当前作用域下的全局便签（单事务：先删后插）。
    public static func saveGlobalNotes(_ notes: [StickyNote]) {
        let scope = currentScope()
        guard let conn = open() else { return }
        defer { conn.close() }
        conn.execute("BEGIN;")
        conn.run("DELETE FROM local_global_note WHERE user_id=$scope", ["$scope": scope])
        for n in notes {
            conn.run("""
            INSERT INTO local_global_note (uid, user_id, content, created_at, updated_at)
            VALUES ($uid, $scope, $content, $created, $updated);
            """, [
                "$uid": n.Id,
                "$scope": scope,
                "$content": n.Content,
                "$created": isoString(n.CreatedAt),
                "$updated": isoString(n.UpdatedAt),
            ])
        }
        conn.execute("COMMIT;")
    }
}
