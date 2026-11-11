import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 运行时配置模板落盘验收（对应 C# `RuntimeConfig.WriteTemplateIfMissing`）。
final class RuntimeConfigTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-rc-\(UUID().uuidString)"
        RuntimeConfig.dirOverride = dir
        RuntimeConfig.reset()
    }

    override func tearDown() {
        RuntimeConfig.dirOverride = nil
        RuntimeConfig.reset()
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testTemplateIsWrittenWhenMissing() throws {
        RuntimeConfig.writeTemplateIfMissing()

        let data = try Data(contentsOf: URL(fileURLWithPath: RuntimeConfig.templatePath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["ws.port"] as? Int, RuntimeConfig.webSocketPortDefault,
                       "模板内容 = 全量默认键值（自文档化）")
        // 写模板后读到的是文件值，而不是硬编码兜底
        RuntimeConfig.reset()
        XCTAssertEqual(RuntimeConfig.getInt("ws.port", 1), RuntimeConfig.webSocketPortDefault)
    }

    func testExistingConfigIsNotOverwritten() throws {
        // 用户改动优先：已有文件（哪怕端口非法）一律不动
        let userJSON = #"{"ws.port":9999}"#
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try userJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: RuntimeConfig.templatePath))

        RuntimeConfig.writeTemplateIfMissing()

        let onDisk = try String(contentsOfFile: RuntimeConfig.templatePath, encoding: .utf8)
        XCTAssertEqual(onDisk, userJSON)
        RuntimeConfig.reset()
        XCTAssertEqual(RuntimeConfig.getInt("ws.port", 1), 9999)
    }

    func testMissingKeysFallBackToCodeDefaults() throws {
        // 文件只写了一部分键：缺失键回落代码默认（升级新增键无需迁移旧文件）
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try #"{"other":"x"}"#.data(using: .utf8)!
            .write(to: URL(fileURLWithPath: RuntimeConfig.templatePath))
        RuntimeConfig.reset()

        XCTAssertEqual(RuntimeConfig.getInt("ws.port", 4242), 4242, "模板外的未知键走调用方默认")
        XCTAssertEqual(RuntimeConfig.getString("mcp.host", "127.0.0.1"), "127.0.0.1")
    }

    func testUnwritableTargetFailsSilently() throws {
        // 无写权限 / 路径被普通文件占位 → 静默，配置仍可用代码默认（不抛、不阻断启动）
        let blocker = dir + "/blocked"
        try FileManager.default.createDirectory(atPath: (blocker as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: blocker))
        RuntimeConfig.dirOverride = blocker + "/sub"

        RuntimeConfig.writeTemplateIfMissing()

        XCTAssertFalse(FileManager.default.fileExists(atPath: RuntimeConfig.templatePath))
        XCTAssertEqual(RuntimeConfig.getInt("ws.port", 7), 7, "写不成也要能读到默认值")
    }

    func testTemplatePathFollowsDirOverride() {
        RuntimeConfig.dirOverride = "/tmp/aaa"
        XCTAssertEqual(RuntimeConfig.templatePath, "/tmp/aaa/runtime-config.json")
        RuntimeConfig.dirOverride = nil
        XCTAssertEqual(RuntimeConfig.templatePath, AppPaths.dataDir + "/runtime-config.json",
                       "无覆盖时落数据目录——macOS 上不能往 .app 包内写")
    }
}
