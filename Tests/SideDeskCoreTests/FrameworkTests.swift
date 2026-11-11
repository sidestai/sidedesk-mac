import XCTest
@testable import SideDeskCore

final class FrameworkTests: XCTestCase {

    // MARK: - AppPaths

    func testDataDirEndsWithSideDesk() {
        XCTAssertTrue(AppPaths.dataDir.hasSuffix("SideDesk"), "got \(AppPaths.dataDir)")
        XCTAssertTrue(AppPaths.dataDir.contains("Library/Application Support"))
    }

    func testDataDirOverride() {
        AppPaths.setOverride("/tmp/sidest-test-data")
        XCTAssertEqual(AppPaths.dataDir, "/tmp/sidest-test-data")
        AppPaths.setOverride(nil)
        XCTAssertTrue(AppPaths.dataDir.hasSuffix("SideDesk"))
    }

    // MARK: - RuntimeMode

    func testRuntimeModePriority() {
        // 环境变量显式覆盖优先
        XCTAssertTrue(RuntimeMode.detectCore("1", false, "/Applications/Foo.app"))
        XCTAssertTrue(RuntimeMode.detectCore("true", false, "/Applications/Foo.app"))
        XCTAssertFalse(RuntimeMode.detectCore("0", true, "/Applications/Foo.app"))
        // 无环境变量：调试器 / 构建目录启发式
        XCTAssertTrue(RuntimeMode.detectCore(nil, true, "/Applications/Foo.app"))
        XCTAssertTrue(RuntimeMode.detectCore(nil, false, "/x/.build/release/Foo.app"))
        XCTAssertFalse(RuntimeMode.detectCore(nil, false, "/Applications/Foo.app"))
    }

    // MARK: - RuntimeLog

    func testRuntimeLogWritesAndGates() throws {
        let tmp = NSTemporaryDirectory() + "sidest-log-\(UUID().uuidString)"
        RuntimeLog.dirOverride = tmp
        RuntimeLog.minLevel = .info
        defer { RuntimeLog.dirOverride = nil; RuntimeLog.minLevel = .info }

        RuntimeLog.debug("dbg", "should NOT land (below minLevel)")
        RuntimeLog.info("startup", "hello info")
        RuntimeLog.error("boom", "an error")

        let path = RuntimeLog.currentFilePath
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("[INFO] [startup] hello info"))
        XCTAssertTrue(content.contains("[ERROR] [boom] an error"))
        XCTAssertFalse(content.contains("should NOT land"), "debug must be gated out of the file")
    }

    /// 启动清日志（对应 C# `ClearDebugLogsOnStartup`）：只留 app/crash/windowlog，其余调试日志清掉。
    func testClearDebugLogsOnStartupKeepsRetainedLogs() throws {
        let tmp = NSTemporaryDirectory() + "sidest-logclean-\(UUID().uuidString)"
        RuntimeLog.dirOverride = tmp
        defer { RuntimeLog.dirOverride = nil }
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        for name in ["app.log", "app.1.log", "crash.log", "crash.1.log", "windowlog_20260101.txt",
                     "lang-missing.log", "http.log", "Http.log"] {
            try "x".write(toFile: tmp + "/" + name, atomically: true, encoding: .utf8)
        }

        RuntimeLog.clearDebugLogsOnStartup()

        let left = try FileManager.default.contentsOfDirectory(atPath: tmp).sorted()
        XCTAssertEqual(left, ["app.1.log", "app.log", "crash.1.log", "crash.log", "windowlog_20260101.txt"],
                       "保留项漏一条会丢掉崩溃证据，多一条会让调试日志越积越多")
    }

    /// 测试模式跳过破坏性文件操作（与 C# InitLoggingCleanup 的门控一致）。
    func testClearDebugLogsSkipsInTestMode() throws {
        let tmp = NSTemporaryDirectory() + "sidest-logclean-\(UUID().uuidString)"
        RuntimeLog.dirOverride = tmp
        RuntimeMode.isTestMode = true
        defer { RuntimeLog.dirOverride = nil; RuntimeMode.isTestMode = false }
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try "x".write(toFile: tmp + "/http.log", atomically: true, encoding: .utf8)

        RuntimeLog.clearDebugLogsOnStartup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/http.log"))
    }

    func testRuntimeLogParseLevel() {
        XCTAssertEqual(RuntimeLog.parseLevel("debug"), .debug)
        XCTAssertEqual(RuntimeLog.parseLevel("WARNING"), .warn)
        XCTAssertEqual(RuntimeLog.parseLevel("error"), .error)
        XCTAssertEqual(RuntimeLog.parseLevel(nil), .info)
        XCTAssertEqual(RuntimeLog.parseLevel("garbage"), .info)
    }

    // MARK: - Lang

    func testLangLoadsDictionaryFromBundle() {
        Lang.initialize("en")
        XCTAssertEqual(Lang.current, "en")
        // en.json 首个键（勘察时确认存在）
        XCTAssertEqual(Lang.t("addCard.catBasic"), "Basic")
    }

    func testLangFallbackToKeyItself() {
        Lang.initialize("en")
        XCTAssertEqual(Lang.t("this.key.does.not.exist"), "this.key.does.not.exist")
        XCTAssertEqual(Lang.t(""), "")
    }

    func testLangCrossLanguageFallbackToEnglish() {
        Lang.initialize("ja")
        XCTAssertEqual(Lang.current, "ja")
        // 任意 supported 语言都应能从 en 兜底或本语言词典拿到该键（不应回落键本身）
        let v = Lang.t("addCard.catBasic")
        XCTAssertNotEqual(v, "addCard.catBasic", "known key must resolve, not fall through")
    }

    /// 语言切换事件（宿主 UI——托盘菜单、设置页——的重绘驱动，对应 C# 的 `Lang.Changed`）。
    /// 订阅者是进程级全局列表且无退订 API（与 C# 一致），故只断言"本次订阅者的计数"，
    /// 结束时复位成 en，避免把全局语言状态留给其它用例。
    func testLangChangedFiresOnlyOnRealSwitch() {
        Lang.initialize(Lang.en)
        var fired = 0
        Lang.subscribeChanged { fired += 1 }

        Lang.apply(Lang.en)                       // 同语言：只重载词典，不触发事件
        XCTAssertEqual(fired, 0)

        Lang.apply(Lang.zhCN)                     // 真正的切换
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(Lang.current, Lang.zhCN)

        Lang.apply(Lang.en)
        XCTAssertEqual(fired, 2)
    }

    func testLangResolveUnknownPreferenceFallsToSystem() {
        XCTAssertEqual(Lang.resolve("en"), "en")
        XCTAssertEqual(Lang.resolve("zz-ZZ"), Lang.resolveSystemLanguage())
        XCTAssertEqual(Lang.resolve(Lang.auto), Lang.resolveSystemLanguage())
    }

    func testLangSupportedSet() {
        XCTAssertTrue(Lang.supported.contains("zh-CN"))
        XCTAssertTrue(Lang.supported.contains("pt-BR"))
        XCTAssertEqual(Lang.supported.count, 13)
    }
}
