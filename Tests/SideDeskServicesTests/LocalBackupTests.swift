import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 本地备份/恢复/导出验收：zip 内容（配置包 + db 快照）、恢复回环（db 替换 + JSON 写回 +
/// windows.json 重导入）、旧格式 json 兼容恢复与清理、扩展名分流、路径穿越守卫、导出独立性。
final class LocalBackupTests: XCTestCase {

    private var dir: String!
    private var originalTimerFactory: ((TimeInterval, @escaping () -> Void) -> ServiceTimer)!

    private final class NoopTimer: ServiceTimer {
        func start() {}
        func stop() {}
    }

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-backup-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
        Settings.DirOverride = dir
        Seam.resetSettings()
        Seam.settings = Settings()
        Seam.uiPost = { $0() }
        Seam.hasUiThread = { false }
        originalTimerFactory = Seam.timerFactory
        Seam.timerFactory = { _, _ in NoopTimer() }
        AppContainer.shared.reset()
    }

    override func tearDown() {
        AppContainer.shared.reset()
        Seam.resetSettings()
        Seam.uiPost = { _ in }
        Seam.hasUiThread = { false }
        Seam.timerFactory = originalTimerFactory
        Settings.DirOverride = nil
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - 助手

    /// 带一个待办窗口的管理器：登记进容器并落库（备份的 db 快照来源）。
    private func makeManager(_ windowIds: [String] = ["w1"]) -> WindowConfigManager {
        let mgr = WindowConfigManager()
        mgr.Windows = windowIds.map { id in
            let win = WindowConfig(); win.Id = id
            let p = PanelItem(); p.Id = "p-\(id)"; p.`Type` = .TodoList
            let t = TodoItem(); t.Id = "t-\(id)"; t.Text = "text-\(id)"
            p.TodoItems = [t]
            win.Panels = [p]
            return win
        }
        mgr.LeftDock.WindowIds = windowIds
        mgr.RightDock.WindowIds = windowIds
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)
        mgr.Save()
        return mgr
    }

    private func unzip(_ zipPath: String, to dest: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        return runTool("/usr/bin/unzip", ["-o", zipPath, "-d", dest])
    }

    private func runTool(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private func bundleFiles(_ json: String) -> [String: String]? {
        guard let obj = CloudSyncService.parseJSON(json)?.objectValue,
              case .object(let files)? = obj["files"] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in files { if let s = v.stringValue { out[k] = s } }
        return out
    }

    private func makeBundleJson(files: [String: String]) -> String {
        let payload: [String: Any] = ["app": "SideDesk", "files": files]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    private func managerJson(_ mgr: WindowConfigManager) -> String {
        String(data: try! SideDeskJSON.encoder().encode(mgr), encoding: .utf8)!
    }

    private var backupDir: String {
        (dir as NSString).appendingPathComponent("backup")
    }

    // MARK: - 创建备份

    func testCreateBackupProducesZipWithBundleAndDb() throws {
        _ = makeManager()
        XCTAssertTrue(LocalBackupService.createLocalBackup())

        let zip = (backupDir as NSString).appendingPathComponent("last-backup.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip))
        XCTAssertTrue(LocalBackupService.hasLocalBackup())
        XCTAssertNotNil(LocalBackupService.getLocalBackupTime())
        // .tmp 中间产物不残留
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip + ".tmp"))

        let extracted = (dir as NSString).appendingPathComponent("extracted")
        XCTAssertTrue(unzip(zip, to: extracted))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (extracted as NSString).appendingPathComponent("config-bundle.json")))
        let db = (extracted as NSString).appendingPathComponent("sidedesk.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db))
        XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: db)[.size] as? Int) ?? 0, 0)

        let bundle = try String(contentsOfFile: (extracted as NSString).appendingPathComponent("config-bundle.json"),
                                encoding: .utf8)
        let files = try XCTUnwrap(bundleFiles(bundle))
        let windows = try XCTUnwrap(files["windows.json"])
        XCTAssertTrue(windows.contains("w1"))
    }

    func testCreateBackupWithoutDbStillSucceeds() throws {
        // 全新安装未落库：只有配置包，没有 db 条目
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "mem-only"
        mgr.Windows = [win]
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)
        XCTAssertTrue(LocalBackupService.createLocalBackup())

        let extracted = (dir as NSString).appendingPathComponent("extracted")
        let zip = (backupDir as NSString).appendingPathComponent("last-backup.zip")
        XCTAssertTrue(unzip(zip, to: extracted))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (extracted as NSString).appendingPathComponent("sidedesk.db")))
        let bundle = try String(contentsOfFile: (extracted as NSString).appendingPathComponent("config-bundle.json"),
                                encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(bundleFiles(bundle)?["windows.json"]).contains("mem-only"))
    }

    func testLegacyJsonBackupRemovedAfterNewBackup() throws {
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let legacy = (backupDir as NSString).appendingPathComponent("last-backup.json")
        try makeBundleJson(files: [:]).write(toFile: legacy, atomically: true, encoding: .utf8)
        XCTAssertTrue(LocalBackupService.hasLocalBackup())

        XCTAssertTrue(LocalBackupService.createLocalBackup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (backupDir as NSString).appendingPathComponent("last-backup.zip")))
    }

    // MARK: - 恢复回环

    func testRestoreRoundTrip() {
        let mgr = makeManager(["w1"])
        XCTAssertTrue(LocalBackupService.createLocalBackup())

        // 备份后新增窗口并落库 → 恢复应回到备份时点
        let extra = WindowConfig(); extra.Id = "w2"
        mgr.Windows.append(extra)
        mgr.Save()
        XCTAssertEqual(WindowConfigManager.Load().Windows.map { $0.Id }, ["w1", "w2"])

        XCTAssertGreaterThanOrEqual(LocalBackupService.restoreLocalBackup(), 1)
        let loaded = WindowConfigManager.Load()
        XCTAssertEqual(loaded.Windows.map { $0.Id }, ["w1"])
        XCTAssertEqual(loaded.Windows.first?.Panels.first?.TodoItems?.first?.Text, "text-w1")
    }

    func testRestoreFromBundleJsonWritesFilesAndReimportsWindows() throws {
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "orig"
        mgr.Windows = [win]
        let bundle = makeBundleJson(files: [
            "app-settings.json": #"{"LogLevel":"Debug"}"#,
            "windows.json": managerJson(mgr),
        ])
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        try bundle.write(toFile: (backupDir as NSString).appendingPathComponent("last-backup.json"),
                         atomically: true, encoding: .utf8)

        XCTAssertEqual(LocalBackupService.restoreLocalBackup(), 2)
        // JSON 写回原位
        let settings = try String(contentsOfFile: (dir as NSString).appendingPathComponent("app-settings.json"),
                                  encoding: .utf8)
        XCTAssertEqual(settings, #"{"LogLevel":"Debug"}"#)
        // windows.json 重导入 SQLite 后改名留存
        XCTAssertFalse(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("windows.json")))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("windows.json.bak-migrated")))
        XCTAssertEqual(WindowConfigManager.Load().Windows.map { $0.Id }, ["orig"])
    }

    func testRestoreZipWithoutBundleReplacesDbOnly() throws {
        _ = makeManager(["w1"])
        // 手工构造只含 db 的 zip（模拟旧版/手工备份包）
        let staging = (dir as NSString).appendingPathComponent("staging")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let snap = (staging as NSString).appendingPathComponent("sidedesk.db")
        XCTAssertTrue(LocalDbService.createSnapshot(snap))
        let zip = (staging as NSString).appendingPathComponent("dbonly.zip")
        XCTAssertTrue(runTool("/usr/bin/zip", ["-q", "-j", zip, snap]))

        let mgr = AppContainer.shared.resolve(WindowConfigManager.self)!
        let extra = WindowConfig(); extra.Id = "w2"
        mgr.Windows.append(extra)
        mgr.Save()

        XCTAssertEqual(LocalBackupService.restoreFromZipFile(zip), 0)
        XCTAssertEqual(WindowConfigManager.Load().Windows.map { $0.Id }, ["w1"])
    }

    // MARK: - 文件分流 / 边界

    func testRestoreFromBackupFileDetectsExtension() throws {
        _ = makeManager()
        XCTAssertTrue(LocalBackupService.createLocalBackup())
        let zip = (backupDir as NSString).appendingPathComponent("last-backup.zip")
        XCTAssertGreaterThanOrEqual(LocalBackupService.restoreFromBackupFile(zip), 1)

        let jsonPath = (dir as NSString).appendingPathComponent("legacy.json")
        try makeBundleJson(files: ["extra.json": "{}"]).write(toFile: jsonPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalBackupService.restoreFromBackupFile(jsonPath), 1)

        XCTAssertEqual(LocalBackupService.restoreFromBackupFile(""), -1)
        XCTAssertEqual(LocalBackupService.restoreFromBackupFile((dir as NSString).appendingPathComponent("missing.zip")), -1)
    }

    func testNoBackupReturnsMinusOne() {
        XCTAssertFalse(LocalBackupService.hasLocalBackup())
        XCTAssertNil(LocalBackupService.getLocalBackupTime())
        XCTAssertEqual(LocalBackupService.restoreLocalBackup(), -1)
    }

    func testRestoreFromInvalidZipReturnsMinusOne() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bad = (dir as NSString).appendingPathComponent("bad.zip")
        try "not a zip".write(toFile: bad, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalBackupService.restoreFromZipFile(bad), -1)
    }

    func testInvalidBundleJsonReturnsZero() {
        XCTAssertEqual(LocalBackupService.restoreFromBundleJson("not json"), 0)
        XCTAssertEqual(LocalBackupService.restoreFromBundleJson(#"{"app":"SideDesk"}"#), 0)
    }

    // MARK: - 安全守卫

    func testPathTraversalKeysRejected() throws {
        let bundle = makeBundleJson(files: [
            "../evil.json": "x",
            "..\\evil.json": "x",
            "sub/x.json": "x",
            "..": "x",
            "": "x",
            "ok.json": "fine",
        ])
        XCTAssertEqual(LocalBackupService.restoreFromBundleJson(bundle), 1)
        XCTAssertEqual(try String(contentsOfFile: (dir as NSString).appendingPathComponent("ok.json"),
                                  encoding: .utf8), "fine")
        // 数据目录之外与子目录路径均不落盘
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("evil.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("sub")))
    }

    // MARK: - 配置打包 / 导出

    func testBundleCollectsJsonFilesAndMemoryWindowsOverride() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"a":1}"#.write(toFile: (dir as NSString).appendingPathComponent("extra.json"),
                              atomically: true, encoding: .utf8)
        // 磁盘上的陈旧 windows.json 应被内存实时序列化覆盖
        try "stale".write(toFile: (dir as NSString).appendingPathComponent("windows.json"),
                          atomically: true, encoding: .utf8)
        let mgr = WindowConfigManager()
        let win = WindowConfig(); win.Id = "mem"
        mgr.Windows = [win]
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)

        let files = try XCTUnwrap(bundleFiles(LocalBackupService.buildConfigBundleJson()))
        XCTAssertEqual(files["extra.json"], #"{"a":1}"#)
        let windows = try XCTUnwrap(files["windows.json"])
        XCTAssertTrue(windows.contains("mem"))
        XCTAssertFalse(windows.contains("stale"))
    }

    func testExportBackupZipIndependentOfLocalBackup() throws {
        _ = makeManager()
        let dest = (dir as NSString).appendingPathComponent("export/nested/backup.zip")
        try LocalBackupService.exportBackupZip(to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest))
        // 导出不产生本地备份记录
        XCTAssertFalse(LocalBackupService.hasLocalBackup())

        let extracted = (dir as NSString).appendingPathComponent("extracted")
        XCTAssertTrue(unzip(dest, to: extracted))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (extracted as NSString).appendingPathComponent("config-bundle.json")))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (extracted as NSString).appendingPathComponent("sidedesk.db")))
        // 导出的包可直接恢复
        XCTAssertGreaterThanOrEqual(LocalBackupService.restoreFromBackupFile(dest), 1)
    }
}