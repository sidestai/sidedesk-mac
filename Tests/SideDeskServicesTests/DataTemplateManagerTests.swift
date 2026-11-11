import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3-2 DataTemplateManager 验收：内置资源加载 + 用户模板往返 + 删除黑名单/恢复。
final class DataTemplateManagerTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-tpl-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
    }

    override func tearDown() {
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func makeTemplate(_ id: String, _ name: String) -> DataTemplate {
        let t = DataTemplate()
        t.Id = id
        t.Name = name
        t.Category = "测试"
        t.TargetUrl = "https://example.com"
        t.Selector = "//div[@id='v']"
        return t
    }

    func testLoadWithNoUserTemplates() {
        // 内置资源当前为空数组，无用户模板 → 空列表且不崩溃
        let mgr = DataTemplateManager.load()
        XCTAssertEqual(mgr.Templates.count, 0)
    }

    func testSaveUserTemplateRoundTrip() {
        let mgr = DataTemplateManager.load()
        mgr.saveUserTemplate(makeTemplate("u1", "自建一"))

        // 文件已落盘
        XCTAssertTrue(FileManager.default.fileExists(atPath: DataTemplateManager.userTemplatesFilePath))

        // 重新加载能取回
        let reloaded = DataTemplateManager.load()
        XCTAssertEqual(reloaded.Templates.count, 1)
        XCTAssertEqual(reloaded.Templates.first?.Id, "u1")
        XCTAssertEqual(reloaded.Templates.first?.Name, "自建一")

        // 更新同 Id 覆盖而非追加
        reloaded.saveUserTemplate(makeTemplate("u1", "改名"))
        let again = DataTemplateManager.load()
        XCTAssertEqual(again.Templates.count, 1)
        XCTAssertEqual(again.Templates.first?.Name, "改名")
    }

    func testLoadUserTemplatesOnly() {
        DataTemplateManager().saveUserTemplate(makeTemplate("u2", "二"))
        DataTemplateManager().saveUserTemplate(makeTemplate("u3", "三"))
        let users = DataTemplateManager.loadUserTemplates()
        XCTAssertEqual(Set(users.map { $0.Id }), ["u2", "u3"])
    }

    func testMarkDeletedFiltersAndSaveRestores() {
        // 先存一个用户模板
        let mgr = DataTemplateManager.load()
        mgr.saveUserTemplate(makeTemplate("d1", "待删"))
        XCTAssertEqual(DataTemplateManager.load().Templates.count, 1)

        // 标记删除 → load 时被过滤
        DataTemplateManager.markDeleted("d1")
        XCTAssertEqual(DataTemplateManager.load().Templates.count, 0)

        // 重新保存同 Id → 从黑名单移除，恢复可见
        let mgr2 = DataTemplateManager.load()
        mgr2.saveUserTemplate(makeTemplate("d1", "待删"))
        let restored = DataTemplateManager.load()
        XCTAssertEqual(restored.Templates.count, 1)
        XCTAssertEqual(restored.Templates.first?.Id, "d1")
    }

    func testMarkDeletedIdempotent() {
        DataTemplateManager.markDeleted("x")
        DataTemplateManager.markDeleted("x")
        // 黑名单不应重复
        let path = (AppPaths.dataDir as NSString).appendingPathComponent("deleted-builtins.json")
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        let ids = (try? SideDeskJSON.decoder().decode([String].self, from: data!)) ?? []
        XCTAssertEqual(ids.filter { $0 == "x" }.count, 1)
    }
}
