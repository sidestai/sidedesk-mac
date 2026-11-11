import Foundation
import SQLite3
import SideDeskCore

/// SQLite 命名参数绑定需要传入「在语句生命周期内有效」的析构器；
/// SQLITE_TRANSIENT(-1) 让 SQLite 立即拷贝绑定值，避免悬垂指针。
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type?.self)

/// 轻量 SQLite 连接封装（对齐 C# 用 Microsoft.Data.Sqlite 的最小面）。
/// 只覆盖本地持久化地基所需：DDL 执行、命名参数 DML、标量查询、行查询。
public final class SQLiteConnection {
    private var db: OpaquePointer?
    public let path: String

    public init?(path: String) {
        self.path = path
        if sqlite3_open(path, &db) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            self.db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// 显式关闭连接（幂等）。ARC 释放时亦会在 deinit 关闭。
    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// 执行无参数 SQL（DDL / PRAGMA / 多语句脚本）。失败记日志并返回 false。
    @discardableResult
    public func execute(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            if let err {
                RuntimeLog.debug("SQLite", "exec failed: \(String(cString: err))")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }

    /// 最近一次 `run` 实际影响的行数（对应 C# `ExecuteNonQuery()` 的返回值）。
    public private(set) var lastChanges: Int = 0

    /// 执行带命名参数（如 `$k`）的 DML，返回是否成功。
    @discardableResult
    public func run(_ sql: String, _ params: [String: String?] = [:]) -> Bool {
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        lastChanges = Int(sqlite3_changes(db))
        guard rc == SQLITE_DONE || rc == SQLITE_OK else {
            RuntimeLog.debug("SQLite", "run failed(\(rc)): \(lastError)")
            return false
        }
        return true
    }

    /// 查询单值文本（对应 ExecuteScalar as string）。无行/NULL 返回 nil。
    public func scalarString(_ sql: String, _ params: [String: String?] = [:]) -> String? {
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    /// 查询单值整数（对应 Convert.ToInt64(ExecuteScalar())）。无行返回 nil。
    public func scalarInt(_ sql: String, _ params: [String: String?] = [:]) -> Int? {
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 是否存在满足条件的行（SELECT 1 … LIMIT 1）。
    public func exists(_ sql: String, _ params: [String: String?] = [:]) -> Bool {
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 查询多行，按列名返回文本字典（NULL → nil）。
    public func query(_ sql: String, _ params: [String: String?] = [:]) -> [[String: String?]] {
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [[String: String?]] = []
        let cols = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for i in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = columnText(stmt, i)
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - private

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            RuntimeLog.debug("SQLite", "prepare failed: \(lastError)")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [String: String?]) {
        for (name, value) in params {
            let idx = sqlite3_bind_parameter_index(stmt, name)
            guard idx > 0 else { continue }
            if let value {
                sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private var lastError: String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: msg)
    }
}
