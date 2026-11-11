import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3 后续：StickyNoteService（全局便签库）验收 —— db 往返、无 db JSON 兜底、排序、CRUD。
final class StickyNoteServiceTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-snote-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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

    private func mkNote(_ content: String) -> StickyNote {
        let n = StickyNote(); n.Content = content; return n
    }

    func testDbRoundTripAcrossInstances() {
        LocalDbService.open()?.close()          // 建立 db，使 dbExists 为真
        let svc = StickyNoteService()
        svc.Add(mkNote("first"))
        svc.Add(mkNote("second"))

        let reloaded = StickyNoteService().GetAll()
        XCTAssertEqual(Set(reloaded.map { $0.Content }), ["first", "second"])
    }

    func testGetAllSortedByUpdatedAtDesc() {
        LocalDbService.open()?.close()
        let svc = StickyNoteService()
        let old = mkNote("old"); old.UpdatedAt = Date(timeIntervalSince1970: 1000)
        let newer = mkNote("new"); newer.UpdatedAt = Date(timeIntervalSince1970: 2000)
        svc.Add(old); svc.Add(newer)
        XCTAssertEqual(svc.GetAll().first?.Content, "new", "应按 UpdatedAt 倒序")
    }

    func testUpdateMutatesContent() {
        LocalDbService.open()?.close()
        let svc = StickyNoteService()
        let n = mkNote("draft"); svc.Add(n)
        let toEdit = StickyNote(); toEdit.Id = n.Id; toEdit.Content = "final"
        svc.Update(toEdit)
        XCTAssertEqual(svc.GetById(n.Id)?.Content, "final")
    }

    func testDeleteRemoves() {
        LocalDbService.open()?.close()
        let svc = StickyNoteService()
        let a = mkNote("a"), b = mkNote("b"); svc.Add(a); svc.Add(b)
        svc.Delete(a.Id)
        XCTAssertNil(svc.GetById(a.Id))
        XCTAssertEqual(svc.GetAll().count, 1)
    }

    func testJsonFallbackWhenNoDb() {
        // 不建立 db：Add 落 sticky-notes.json；新实例仍从文件读回
        XCTAssertFalse(LocalDbService.dbExists)
        let svc = StickyNoteService()
        svc.Add(mkNote("from-json"))
        let jsonPath = (dir as NSString).appendingPathComponent("sticky-notes.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath))
        XCTAssertEqual(StickyNoteService().GetAll().first?.Content, "from-json")
    }

    func testEmptyTableMigratesLegacyJsonOnce() {
        // 先写旧 JSON，再建空 db：首次访问应把 JSON 迁入 db，之后从 db 读
        let json = "[{\"Id\":\"n1\",\"Content\":\"legacy\",\"CreatedAt\":\"2020-01-01T00:00:00Z\",\"UpdatedAt\":\"2020-01-01T00:00:00Z\"}]"
        let jsonPath = (dir as NSString).appendingPathComponent("sticky-notes.json")
        try? json.data(using: .utf8)?.write(to: URL(fileURLWithPath: jsonPath))
        LocalDbService.open()?.close()

        let all = StickyNoteService().GetAll()
        XCTAssertEqual(all.first?.Content, "legacy")
        // db 现在应含该便签
        XCTAssertEqual(LocalDbService.loadGlobalNotes().count, 1)
    }
}
