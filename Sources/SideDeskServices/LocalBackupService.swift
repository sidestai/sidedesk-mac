import Foundation
import SideDeskCore

/// 本地备份 / 恢复 / 导出。对应 C# `CloudSyncService.Local.cs` 的备份区域。
///
/// 备份为覆盖式 zip 包（仅保留最后一个）：
/// - `config-bundle.json`：数据目录下全部 *.json + 从内存实时序列化的 windows.json；
/// - `sidedesk.db`：SQLite 一致性快照（VACUUM INTO，已合并 WAL）。
/// 恢复先整体替换 SQLite，再写回 JSON 配置；其中 windows.json 会重新导入新 db，
/// 与备份时点一致（窗口主存储是 SQLite，只写回 JSON 不导入则重启后恢复不生效）。
///
/// 与 C# 的平台差异：
/// - zip 打包/解包走系统自带 /usr/bin/zip 与 /usr/bin/unzip（macOS 无 System.IO.Compression；
///   参数经 Process.arguments 传递，不经 shell 插值）；
/// - 备份键写回前做路径穿越守卫（备份文件是用户输入边界，C# 直接 Path.Combine 无此防护）。
public enum LocalBackupService {

    /// 备份目录（数据目录下 backup/，对应 C# %LocalAppData%\SideDesk\backup）
    public static var localBackupDir: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("backup")
    }
    static var lastBackupZip: String {
        (localBackupDir as NSString).appendingPathComponent("last-backup.zip")
    }
    /// 旧格式（纯 JSON bundle）：仅用于兼容恢复，新备份一律写 zip 并清理旧文件
    static var lastBackupFile: String {
        (localBackupDir as NSString).appendingPathComponent("last-backup.json")
    }

    /// 是否存在本地备份（新 zip 或旧 json 格式）。对应 C# HasLocalBackup。
    public static func hasLocalBackup() -> Bool {
        FileManager.default.fileExists(atPath: lastBackupZip)
            || FileManager.default.fileExists(atPath: lastBackupFile)
    }

    /// 最后一次本地备份的时间（无则 nil）。对应 C# GetLocalBackupTime。
    public static func getLocalBackupTime() -> Date? {
        for path in [lastBackupZip, lastBackupFile] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date { return date }
        }
        return nil
    }

    /// 创建本地备份（覆盖式，只保留最后一个）。返回是否成功。对应 C# CreateLocalBackup。
    @discardableResult
    public static func createLocalBackup() -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: localBackupDir, withIntermediateDirectories: true)
            try buildBackupZip(lastBackupZip)
            // 清理旧格式备份，避免恢复时二义
            if FileManager.default.fileExists(atPath: lastBackupFile) {
                try FileManager.default.removeItem(atPath: lastBackupFile)
            }
            return true
        } catch {
            RuntimeLog.debug("[Backup] backup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 导出备份 zip 到指定路径（设置页「导出」用，内容与本地备份一致）。对应 C# ExportBackupZip。
    public static func exportBackupZip(to destPath: String) throws {
        let dir = (destPath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try buildBackupZip(destPath)
    }

    /// 构建备份 zip：先写 .tmp 再替换，避免中途失败留下半截 zip。对应 C# BuildBackupZip。
    static func buildBackupZip(_ destZip: String) throws {
        let fm = FileManager.default
        let tmpZip = destZip + ".tmp"
        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sidedesk-backup-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(atPath: staging)
            if fm.fileExists(atPath: tmpZip) { try? fm.removeItem(atPath: tmpZip) }
        }
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        if fm.fileExists(atPath: tmpZip) { try fm.removeItem(atPath: tmpZip) }

        let bundlePath = (staging as NSString).appendingPathComponent("config-bundle.json")
        try buildConfigBundleJson(indented: true).write(toFile: bundlePath, atomically: true, encoding: .utf8)
        var entries = [bundlePath]

        // SQLite 快照（db 不存在时跳过，例如全新安装未落库）
        let dbSnap = (staging as NSString).appendingPathComponent("sidedesk.db")
        if LocalDbService.createSnapshot(dbSnap) { entries.append(dbSnap) }

        // -j：只存文件名（entry 即 config-bundle.json / sidedesk.db，与 C# zip 条目一致）
        guard runTool("/usr/bin/zip", ["-q", "-j", tmpZip] + entries) else {
            throw BackupError.zipToolFailed
        }
        if fm.fileExists(atPath: destZip) { try fm.removeItem(atPath: destZip) }
        try fm.moveItem(atPath: tmpZip, toPath: destZip)
    }

    /// 从最后一次本地备份恢复所有配置与数据库。返回恢复的文件数（-1 失败/无备份）。
    /// 对应 C# RestoreLocalBackup。
    @discardableResult
    public static func restoreLocalBackup() -> Int {
        if FileManager.default.fileExists(atPath: lastBackupZip) {
            return restoreFromZipFile(lastBackupZip)
        }
        guard FileManager.default.fileExists(atPath: lastBackupFile),
              let json = try? String(contentsOfFile: lastBackupFile, encoding: .utf8) else { return -1 }
        return restoreFromBundleJson(json)
    }

    /// 从任意 zip 备份包恢复（先替换 SQLite 快照，再写回 JSON 配置）。返回恢复的文件数（-1 失败）。
    /// 对应 C# RestoreFromZipFile。
    @discardableResult
    public static func restoreFromZipFile(_ zipPath: String) -> Int {
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sidedesk-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp) }
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            guard runTool("/usr/bin/unzip", ["-o", zipPath, "-d", tmp]) else { return -1 }
            let dbSnap = (tmp as NSString).appendingPathComponent("sidedesk.db")
            if fm.fileExists(atPath: dbSnap) {
                LocalDbService.replaceDb(withFile: dbSnap)
            }
            let bundle = (tmp as NSString).appendingPathComponent("config-bundle.json")
            guard fm.fileExists(atPath: bundle),
                  let json = try? String(contentsOfFile: bundle, encoding: .utf8) else { return 0 }
            return restoreFromBundleJson(json)
        } catch {
            RuntimeLog.debug("[Backup] restore from zip failed: \(error.localizedDescription)")
            return -1
        }
    }

    /// 从用户选择的备份文件恢复：.json 按配置包、其余（含无扩展名）按 zip 处理。
    /// 返回恢复的文件数（-1 失败）。对应 C# RestoreFromBackupFile。
    @discardableResult
    public static func restoreFromBackupFile(_ path: String) -> Int {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return -1 }
        if (path as NSString).pathExtension.lowercased() == "json" {
            guard let json = try? String(contentsOfFile: path, encoding: .utf8) else { return -1 }
            return restoreFromBundleJson(json)
        }
        return restoreFromZipFile(path)
    }

    /// 把打包 JSON 中的文件写回各自的原始位置，随后重导入 windows.json。返回写回的文件数。
    /// 对应 C# RestoreFromBundleJson。
    @discardableResult
    public static func restoreFromBundleJson(_ json: String) -> Int {
        guard let obj = CloudSyncService.parseJSON(json)?.objectValue,
              case .object(let files)? = obj["files"] else { return 0 }
        var count = 0
        for (key, value) in files {
            guard let content = value.stringValue, isSafeBackupKey(key) else { continue }
            let target = mapBackupKeyToPath(key)
            do {
                let dir = (target as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try content.write(toFile: target, atomically: true, encoding: .utf8)
                count += 1
            } catch {
                RuntimeLog.debug("[Backup] failed to write back \(key): \(error.localizedDescription)")
            }
        }

        // 窗口配置主存储是 SQLite：写回的 windows.json 须重新导入，否则重启后仍读旧 db
        let windowsJson = (AppPaths.dataDir as NSString).appendingPathComponent("windows.json")
        LocalDbService.reimportWindowsJsonIfExists(windowsJson)
        return count
    }

    /// 备份键 → 原始文件路径（键即文件名，与 buildConfigBundleJson 的收录口径一致）。
    static func mapBackupKeyToPath(_ key: String) -> String {
        (AppPaths.dataDir as NSString).appendingPathComponent(key)
    }

    /// 备份键安全守卫：只允许纯文件名（备份文件来自用户选择，属输入边界，防路径穿越写穿数据目录）。
    static func isSafeBackupKey(_ key: String) -> Bool {
        !key.isEmpty && key != "." && key != ".."
            && !key.contains("/") && !key.contains("\\")
    }

    // MARK: - 配置打包

    /// 收集本地全部配置文件打包成一个 JSON 负载。对应 C# BuildConfigBundleJson。
    /// 1) 数据目录下全部 *.json；2) windows.json 从内存实时序列化（主存储已迁 SQLite，停止写盘）。
    public static func buildConfigBundleJson(indented: Bool = false) -> String {
        var files: [String: String] = [:]
        let fm = FileManager.default
        let dir = AppPaths.dataDir
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            files[name] = content
        }
        // 内存实时序列化覆盖磁盘旧文件（键名沿用 windows.json，与恢复路径一致）
        if let mgr = AppContainer.shared.resolve(WindowConfigManager.self),
           let data = try? SideDeskJSON.encoder().encode(mgr),
           let json = String(data: data, encoding: .utf8) {
            files["windows.json"] = json
        }

        struct Payload: Encodable {
            let app: String
            let machine: String
            let syncedAt: String
            let files: [String: String]
        }
        let payload = Payload(app: "SideDesk",
                              machine: ProcessInfo.processInfo.hostName,
                              syncedAt: CloudSyncService.isoO(Date()),
                              files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = indented ? [.prettyPrinted] : []
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else { return #"{"app":"SideDesk","files":{}}"# }
        return json
    }

    // MARK: - 系统 zip 工具

    enum BackupError: Error { case zipToolFailed }

    /// 跑系统工具（参数不经 shell 插值）；输出丢弃避免管道写满阻塞。
    private static func runTool(_ launchPath: String, _ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            RuntimeLog.debug("[Backup] tool \(launchPath) failed: \(error.localizedDescription)")
            return false
        }
    }
}