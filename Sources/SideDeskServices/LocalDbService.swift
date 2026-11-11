import Foundation
import SideDeskCore

/// 本地 SQLite 持久层（对应 C# Services.LocalDbService 的地基部分）。
///
/// 已移植：连接/PRAGMA、建表 schema、作用域与晋升（`adoptScope`）、一次性状态标记、
/// 通用业务数据 KV（local_app_state）、关系型窗口树（见 `LocalDbService+WindowTree`）、
/// 数据变量手动值表（local_data_variable）。
/// 云同步专属（墓碑同步/行 ID 回传）与屏幕时长、键鼠计数表仍待后续批次。
public enum LocalDbService {

    /// 测试接缝：目录覆盖（隔离真实数据目录；nil = 真实路径）
    public static var dirOverride: String?

    /// 云账号 id 提供者（登录服务在 T3 后续批次注入）；nil/空 → "local" 作用域。
    /// 对应 C# 里 CurrentScope 读取 ServiceSeam.Settings.AccountUserId。
    public static var accountUserIdProvider: (() -> String?)?

    private static var dir: String {
        dirOverride ?? AppPaths.dataDir
    }

    public static var dbPath: String {
        (dir as NSString).appendingPathComponent("sidedesk.db")
    }

    public static var dbExists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    // MARK: - 作用域

    /// 当前数据作用域：登录后 "u:{密文}"，未登录 "local"。
    public static func currentScope() -> String {
        if let id = accountUserIdProvider?(), !id.isEmpty {
            return "u:" + id
        }
        return "local"
    }

    static func scopedKey(_ key: String, _ scope: String) -> String { key + "@" + scope }

    /// 需要按作用域隔离的应用级状态 key（晋升时随行迁移）
    private static let scopedStateKeys = ["left_dock", "right_dock", "background_dashboard_items", "variable_sets"]

    // MARK: - 连接 / schema

    /// 打开连接并初始化 PRAGMA / 建表。失败返回 nil。
    public static func open() -> SQLiteConnection? {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let conn = SQLiteConnection(path: dbPath) else { return nil }
        conn.execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        ensureSchema(conn)
        return conn
    }

    static func ensureSchema(_ conn: SQLiteConnection) {
        // 兼容早期构建：表曾用名 sidedesk_* → local_*
        renameLegacyTable(conn, "sidedesk_bar", "local_bar")
        renameLegacyTable(conn, "sidedesk_item", "local_item")
        renameLegacyTable(conn, "sidedesk_item_row", "local_item_row")
        addColumnIfMissing(conn, "local_item_row", "row_server_id", "TEXT")
        addColumnIfMissing(conn, "local_item_row", "data_server_id", "TEXT")
        addColumnIfMissing(conn, "local_item", "corp_id", "TEXT")
        // 账号作用域隔离
        addColumnIfMissing(conn, "local_bar", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_item", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_item_row", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_sticky_note", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_desk_note", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_global_note", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_todo_item", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_clipboard_item", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        addColumnIfMissing(conn, "local_row_id_map", "user_id", "TEXT NOT NULL DEFAULT 'local'")
        // 删除墓碑标记
        addColumnIfMissing(conn, "local_bar", "deleted_synced", "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing(conn, "local_item", "deleted_synced", "INTEGER NOT NULL DEFAULT 0")
        // 每条侧边栏独立的鼠键记录器开关
        addColumnIfMissing(conn, "local_bar", "keymouse_recorder", "INTEGER NOT NULL DEFAULT 0")

        conn.execute("""
        CREATE TABLE IF NOT EXISTS local_bar (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          local_uid     TEXT NOT NULL UNIQUE,
          user_id       TEXT NOT NULL DEFAULT 'local',
          server_id     TEXT,
          title         TEXT,
          bg_color      TEXT,
          window_type   INTEGER NOT NULL DEFAULT 0,
          url           TEXT,
          is_edit_mode  INTEGER NOT NULL DEFAULT 0,
          is_app_mode   INTEGER NOT NULL DEFAULT 0,
          show_in_tabs  INTEGER NOT NULL DEFAULT 1,
          owner_type    TEXT NOT NULL DEFAULT 'personal',
          corp_id       TEXT,
          share_mode    TEXT,
          source_bar_id TEXT,
          enabled_tools TEXT,
          keymouse_recorder INTEGER NOT NULL DEFAULT 0,
          created_at    TEXT,
          updated_at    TEXT,
          deleted_at    TEXT,
          deleted_synced INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS local_item (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          local_uid   TEXT NOT NULL UNIQUE,
          user_id     TEXT NOT NULL DEFAULT 'local',
          server_id   TEXT,
          bar_uid     TEXT NOT NULL,
          parent_uid  TEXT,
          sort_order  INTEGER NOT NULL DEFAULT 0,
          title       TEXT,
          item_type   TEXT NOT NULL,
          group_id    TEXT,
          item_data   TEXT,
          owner_type  TEXT NOT NULL DEFAULT 'personal',
          team_id     TEXT,
          team_name   TEXT,
          corp_id     TEXT,
          created_at  TEXT,
          updated_at  TEXT,
          deleted_at  TEXT,
          deleted_synced INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_item_bar ON local_item(bar_uid, sort_order);
        CREATE TABLE IF NOT EXISTS local_item_row (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id       TEXT NOT NULL DEFAULT 'local',
          item_uid      TEXT NOT NULL,
          row_uid       TEXT NOT NULL,
          row_type      TEXT NOT NULL,
          content       TEXT,
          sort_order    INTEGER NOT NULL DEFAULT 0,
          row_server_id TEXT,
          data_server_id TEXT,
          created_at    TEXT,
          updated_at    TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_row_item_rowuid ON local_item_row(item_uid, row_uid);
        CREATE TABLE IF NOT EXISTS local_row_id_map (
          row_uid        TEXT PRIMARY KEY,
          user_id        TEXT NOT NULL DEFAULT 'local',
          row_server_id  TEXT,
          data_server_id TEXT
        );
        CREATE TABLE IF NOT EXISTS local_sticky_note (
          uid        TEXT PRIMARY KEY,
          user_id    TEXT NOT NULL DEFAULT 'local',
          content    TEXT,
          created_at TEXT,
          updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS local_global_note (
          uid        TEXT PRIMARY KEY,
          user_id    TEXT NOT NULL DEFAULT 'local',
          content    TEXT,
          created_at TEXT,
          updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS local_desk_note (
          uid        TEXT PRIMARY KEY,
          user_id    TEXT NOT NULL DEFAULT 'local',
          content    TEXT,
          created_at TEXT,
          updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS local_todo_item (
          uid                   TEXT PRIMARY KEY,
          user_id               TEXT NOT NULL DEFAULT 'local',
          text                  TEXT,
          description           TEXT,
          is_done               INTEGER NOT NULL DEFAULT 0,
          due_time              TEXT,
          remind_before_minutes INTEGER NOT NULL DEFAULT -1,
          reminded              INTEGER NOT NULL DEFAULT 0,
          created_at            TEXT
        );
        CREATE TABLE IF NOT EXISTS local_clipboard_item (
          uid          TEXT PRIMARY KEY,
          user_id      TEXT NOT NULL DEFAULT 'local',
          content_type TEXT NOT NULL DEFAULT 'Text',
          content      TEXT,
          saved_at     TEXT
        );
        CREATE TABLE IF NOT EXISTS local_app_state (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        CREATE TABLE IF NOT EXISTS local_screen_time_hourly (
          date    TEXT NOT NULL,
          hour    INTEGER NOT NULL,
          process TEXT NOT NULL,
          seconds INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (date, hour, process)
        );
        CREATE TABLE IF NOT EXISTS local_key_count_daily (
          date      TEXT PRIMARY KEY,
          key_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS local_data_variable (
          user_id    TEXT NOT NULL DEFAULT 'local',
          var_key    TEXT NOT NULL,
          var_value  TEXT,
          corp_id    TEXT,
          updated_at TEXT,
          PRIMARY KEY (user_id, var_key)
        );
        CREATE TABLE IF NOT EXISTS local_mouse_distance_daily (
          date           TEXT PRIMARY KEY,
          distance_pixel INTEGER NOT NULL DEFAULT 0
        );
        """)

        // local_data_variable 主键升级：旧表（var_key 单列主键，无 user_id）→ (user_id, var_key)
        let tableExists = (conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='local_data_variable'") ?? 0) > 0
        if tableExists {
            let hasUserId = (conn.scalarInt("SELECT COUNT(*) FROM pragma_table_info('local_data_variable') WHERE name='user_id'") ?? 0) > 0
            if !hasUserId {
                conn.execute("""
                ALTER TABLE local_data_variable RENAME TO local_data_variable_old;
                CREATE TABLE local_data_variable (
                  user_id    TEXT NOT NULL DEFAULT 'local',
                  var_key    TEXT NOT NULL,
                  var_value  TEXT,
                  corp_id    TEXT,
                  updated_at TEXT,
                  PRIMARY KEY (user_id, var_key)
                );
                INSERT INTO local_data_variable (user_id, var_key, var_value, corp_id, updated_at)
                  SELECT 'local', var_key, var_value, corp_id, updated_at FROM local_data_variable_old;
                DROP TABLE local_data_variable_old;
                """)
            }
        }
    }

    /// 旧表名存在且新表名不存在时无损改名
    static func renameLegacyTable(_ conn: SQLiteConnection, _ oldName: String, _ newName: String) {
        let oldCount = conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$n", ["$n": oldName]) ?? 0
        let newCount = conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$n", ["$n": newName]) ?? 0
        if oldCount > 0 && newCount == 0 {
            conn.execute("ALTER TABLE \(oldName) RENAME TO \(newName);")
        }
    }

    /// 表缺列时补列（表不存在则跳过，全新库由 CREATE TABLE 建出含新列的表）
    static func addColumnIfMissing(_ conn: SQLiteConnection, _ table: String, _ column: String, _ colType: String) {
        let tableExists = (conn.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$n", ["$n": table]) ?? 0) > 0
        guard tableExists else { return }
        let has = (conn.scalarInt("SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name=$c", ["$c": column]) ?? 0) > 0
        if !has {
            conn.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(colType);")
        }
    }

    // MARK: - 应用级状态 KV（local_app_state）

    static func getState(_ conn: SQLiteConnection, _ key: String) -> String? {
        conn.scalarString("SELECT value FROM local_app_state WHERE key=$k", ["$k": key])
    }

    static func upsertState(_ conn: SQLiteConnection, _ key: String, _ value: String) {
        conn.run("""
        INSERT INTO local_app_state (key, value) VALUES ($k, $v)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value;
        """, ["$k": key, "$v": value])
    }

    private static func deleteState(_ conn: SQLiteConnection, _ key: String) {
        conn.run("DELETE FROM local_app_state WHERE key=$k", ["$k": key])
    }

    /// 读取当前作用域的一次性初始化标记（失败返回 false 不影响业务）
    public static func getStateFlag(_ key: String) -> Bool {
        guard let conn = open() else { return false }
        defer { conn.close() }
        return getState(conn, scopedKey(key, currentScope())) == "1"
    }

    /// 任意作用域是否已置过该一次性标记（含无后缀的早期 key）
    public static func anyScopeStateFlag(_ key: String) -> Bool {
        guard let conn = open() else { return false }
        defer { conn.close() }
        return conn.exists("SELECT 1 FROM local_app_state WHERE key=$k OR key LIKE $p LIMIT 1",
                           ["$k": key, "$p": key + "@%"])
    }

    /// 置位当前作用域的一次性初始化标记（置位后永不回退）
    public static func setStateFlag(_ key: String) {
        guard let conn = open() else { return }
        defer { conn.close() }
        upsertState(conn, scopedKey(key, currentScope()), "1")
    }

    // MARK: - 通用业务数据 KV

    /// 读取业务数据 JSON（无值返回 nil）
    public static func loadBusinessData(_ key: String) -> String? {
        guard let conn = open() else { return nil }
        defer { conn.close() }
        return getState(conn, key)
    }

    /// 单行 upsert 写入业务数据 JSON
    public static func saveBusinessData(_ key: String, _ json: String) {
        guard let conn = open() else { return }
        defer { conn.close() }
        upsertState(conn, key, json)
    }

    /// 删除业务数据 KV
    public static func deleteBusinessData(_ key: String) {
        guard let conn = open() else { return }
        defer { conn.close() }
        deleteState(conn, key)
    }

    // MARK: - 数据变量手动值（local_data_variable，按作用域隔离）

    /// 作用域下的全部本地数据变量（手动值层）。对应 C# `LocalDbService.LoadDataVariables`。
    public static func loadDataVariables(_ scope: String) -> [(varKey: String, varValue: String, corpId: String?)] {
        guard let conn = open() else { return [] }
        defer { conn.close() }
        return conn.query("SELECT var_key, var_value, corp_id FROM local_data_variable WHERE user_id=$s",
                          ["$s": scope]).compactMap { r -> (varKey: String, varValue: String, corpId: String?)? in
            guard let k = r["var_key"] ?? nil, !k.isEmpty else { return nil }
            return (k, (r["var_value"] ?? nil) ?? "", r["corp_id"] ?? nil)
        }
    }

    /// 单变量 upsert（按 作用域+变量名 定位）。corpId 传 nil 时保留行上已有值
    /// （WS 推送不带作用域信息）。对应 C# `LocalDbService.UpsertDataVariable`。
    public static func upsertDataVariable(_ scope: String, _ varKey: String, _ varValue: String?, _ corpId: String?) {
        guard let conn = open() else { return }
        defer { conn.close() }
        conn.run("""
        INSERT INTO local_data_variable (user_id, var_key, var_value, corp_id, updated_at)
        VALUES ($s, $k, $v, $c, $u)
        ON CONFLICT(user_id, var_key) DO UPDATE SET
          var_value  = excluded.var_value,
          corp_id    = COALESCE(excluded.corp_id, local_data_variable.corp_id),
          updated_at = excluded.updated_at;
        """, ["$s": scope, "$k": varKey, "$v": varValue, "$c": corpId, "$u": timestamp()])
    }

    /// 删除指定作用域下的数据变量，返回是否存在过记录。对应 C# `LocalDbService.DeleteDataVariable`。
    @discardableResult
    public static func deleteDataVariable(_ scope: String, _ varKey: String) -> Bool {
        guard let conn = open() else { return false }
        defer { conn.close() }
        conn.run("DELETE FROM local_data_variable WHERE user_id=$s AND var_key=$k", ["$s": scope, "$k": varKey])
        return conn.lastChanges > 0
    }

    /// `updated_at` 列文本格式，沿用 C# 的 `DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")`（本地时区）。
    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - 作用域晋升

    /// 作用域晋升：把 `from` 作用域下的布局与内容数据归入 `to` 作用域（未归属 local 数据"跟人走"）。
    /// 内容表直接 UPDATE；作用域化 state keys 仅当目标作用域尚无该状态时才采用源值，随后删除源 key。
    /// 对应 C# `LocalDbService.AdoptScope`。
    public static func adoptScope(from: String, to: String) {
        if from.isEmpty || to.isEmpty || from == to { return }
        guard let conn = open() else { return }
        defer { conn.close() }
        conn.execute("BEGIN;")

        // 兜底空 bar 不晋升：登出回 local 时 EnsureAtLeastOneBar 会建一个空 bar 防零 bar 死状态，
        // 它不是用户数据；随晋升进入账号作用域会让每次登出/登入循环多出一个空窗口。
        // 无存活内容且未同步（server_id 空）即判定为兜底/空建，硬删无损。
        conn.run("""
        DELETE FROM local_bar
        WHERE user_id=$from AND server_id IS NULL AND deleted_at IS NULL
          AND local_uid NOT IN (SELECT bar_uid FROM local_item WHERE user_id=$from AND deleted_at IS NULL);
        """, ["$from": from])

        for table in ["local_bar", "local_item", "local_item_row", "local_row_id_map",
                      "local_sticky_note", "local_desk_note", "local_global_note",
                      "local_todo_item", "local_clipboard_item"] {
            conn.run("UPDATE \(table) SET user_id=$to WHERE user_id=$from;", ["$to": to, "$from": from])
        }

        // 作用域化 state keys 迁移：早期构建无后缀的 key 视为 'local' 作用域
        for key in scopedStateKeys {
            let src = getState(conn, scopedKey(key, from)) ?? (from == "local" ? getState(conn, key) : nil)
            guard let src else { continue }
            let dstKey = scopedKey(key, to)
            // 目标已有则保留目标：否则「登出→再登入同一账号」会把账号真实的 dock 状态冲成兜底空值
            if getState(conn, dstKey) == nil { upsertState(conn, dstKey, src) }
            deleteState(conn, scopedKey(key, from))
            if from == "local" { deleteState(conn, key) }
        }
        conn.execute("COMMIT;")
    }

    // MARK: - 快照 / 恢复

    /// 生成一致性快照（VACUUM INTO，自动合并 WAL）。db 不存在或失败返回 false。
    public static func createSnapshot(_ targetPath: String) -> Bool {
        guard dbExists, let conn = open() else { return false }
        defer { conn.close() }
        try? FileManager.default.removeItem(atPath: targetPath)
        // VACUUM INTO 文件名不支持参数绑定，内联并转义单引号（本地受控路径）
        let escaped = targetPath.replacingOccurrences(of: "'", with: "''")
        conn.execute("VACUUM INTO '\(escaped)';")
        return FileManager.default.fileExists(atPath: targetPath)
    }

    /// 用快照文件整体替换现有数据库（删主库与 WAL/SHM 边车 → 快照落位）
    public static func replaceDb(withFile snapshotPath: String) {
        for suffix in ["", "-wal", "-shm"] {
            let p = dbPath + suffix
            if FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(atPath: p) }
        }
        try? FileManager.default.moveItem(atPath: snapshotPath, toPath: dbPath)
    }

    /// 备份恢复后：若存在待导入的 windows.json，按当前作用域全量导入 SQLite，
    /// 成功后原文件改名 .bak-migrated（与 C# ImportFromJsonFile + ReimportJsonIfExists 一致）。
    @discardableResult
    public static func reimportWindowsJsonIfExists(_ jsonPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: jsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let mgr = try? SideDeskJSON.decoder().decode(WindowConfigManager.self, from: data) else { return false }
        saveManager(mgr)
        let bak = jsonPath + ".bak-migrated"
        try? FileManager.default.removeItem(atPath: bak)
        try? FileManager.default.moveItem(atPath: jsonPath, toPath: bak)
        return true
    }
}
