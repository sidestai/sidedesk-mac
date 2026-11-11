import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3-1 本地持久化地基验收：SQLite 连接/schema、状态标记、业务数据 KV、作用域、
/// 快照/恢复、DigitalEmployeeManager 往返与迁移。
final class LocalDbServiceTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-db-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
    }

    override func tearDown() {
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testOpenCreatesSchema() {
        XCTAssertFalse(LocalDbService.dbExists)
        let conn = LocalDbService.open()
        XCTAssertNotNil(conn)
        conn?.close()
        XCTAssertTrue(LocalDbService.dbExists, "open() 应创建 db 文件")

        // 关键表存在
        let c2 = LocalDbService.open()!
        for table in ["local_bar", "local_item", "local_item_row", "local_app_state",
                      "local_sticky_note", "local_todo_item", "local_clipboard_item", "local_data_variable"] {
            let n = c2.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$n", ["$n": table]) ?? 0
            XCTAssertEqual(n, 1, "缺少表 \(table)")
        }
        c2.close()
    }

    func testSchemaIdempotent() {
        // 多次 open 不应报错（CREATE TABLE IF NOT EXISTS + AddColumnIfMissing）
        for _ in 0..<3 {
            let c = LocalDbService.open()
            XCTAssertNotNil(c)
            c?.close()
        }
    }

    func testBusinessDataKVRoundTrip() {
        XCTAssertNil(LocalDbService.loadBusinessData("greeting"))
        LocalDbService.saveBusinessData("greeting", "{\"hi\":\"世界\"}")
        XCTAssertEqual(LocalDbService.loadBusinessData("greeting"), "{\"hi\":\"世界\"}")
        // upsert 覆盖
        LocalDbService.saveBusinessData("greeting", "v2")
        XCTAssertEqual(LocalDbService.loadBusinessData("greeting"), "v2")
        LocalDbService.deleteBusinessData("greeting")
        XCTAssertNil(LocalDbService.loadBusinessData("greeting"))
    }

    func testStateFlagsScoped() {
        XCTAssertFalse(LocalDbService.getStateFlag("seeded"))
        XCTAssertFalse(LocalDbService.anyScopeStateFlag("seeded"))
        LocalDbService.setStateFlag("seeded")
        XCTAssertTrue(LocalDbService.getStateFlag("seeded"))
        XCTAssertTrue(LocalDbService.anyScopeStateFlag("seeded"))

        // 换作用域：当前作用域标记为假，但任意作用域仍为真
        LocalDbService.accountUserIdProvider = { "cipherABC" }
        XCTAssertEqual(LocalDbService.currentScope(), "u:cipherABC")
        XCTAssertFalse(LocalDbService.getStateFlag("seeded"), "新作用域应无此标记")
        XCTAssertTrue(LocalDbService.anyScopeStateFlag("seeded"), "全库只播一次")
    }

    func testCurrentScopeDefault() {
        XCTAssertEqual(LocalDbService.currentScope(), "local")
        LocalDbService.accountUserIdProvider = { "" }
        XCTAssertEqual(LocalDbService.currentScope(), "local")
        LocalDbService.accountUserIdProvider = { "abc" }
        XCTAssertEqual(LocalDbService.currentScope(), "u:abc")
    }

    func testSnapshotAndReplace() {
        LocalDbService.saveBusinessData("k", "original")
        let snap = (dir as NSString).appendingPathComponent("snap.db")
        XCTAssertTrue(LocalDbService.createSnapshot(snap))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snap))

        // 改动后从快照恢复
        LocalDbService.saveBusinessData("k", "mutated")
        XCTAssertEqual(LocalDbService.loadBusinessData("k"), "mutated")
        LocalDbService.replaceDb(withFile: snap)
        XCTAssertEqual(LocalDbService.loadBusinessData("k"), "original")
    }

    // MARK: - DigitalEmployeeManager

    func testDigitalEmployeeManagerRoundTrip() {
        // 触发建库
        LocalDbService.open()?.close()
        let mgr = DigitalEmployeeManager.load()
        XCTAssertTrue(mgr.Employees.isEmpty)
        mgr.ensureDefault()
        XCTAssertEqual(mgr.Employees.count, 3)

        // 从 KV 重新加载
        let reloaded = DigitalEmployeeManager.load()
        XCTAssertEqual(reloaded.Employees.count, 3)
        XCTAssertEqual(reloaded.Employees.first?.Name, "小智")

        let added = reloaded.add(name: "测试员工")
        XCTAssertEqual(reloaded.Employees.count, 4)
        XCTAssertNotNil(reloaded.getById(added.Id))

        reloaded.remove(added.Id)
        let final = DigitalEmployeeManager.load()
        XCTAssertEqual(final.Employees.count, 3)
        XCTAssertNil(final.getById(added.Id))
    }

    func testDigitalEmployeeManagerJsonFileFallback() {
        // db 不存在时走 JSON 文件存储
        XCTAssertFalse(LocalDbService.dbExists)
        let mgr = DigitalEmployeeManager()
        mgr.Employees.append(DigitalEmployee())
        mgr.save()
        let path = (AppPaths.dataDir as NSString).appendingPathComponent("digital-employees.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "无 db 时应写 JSON 文件")

        let reloaded = DigitalEmployeeManager.load()
        XCTAssertEqual(reloaded.Employees.count, 1)
    }
}
