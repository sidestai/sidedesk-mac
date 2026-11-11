import XCTest
@testable import SideDeskCore

/// `--test-mode` 一族启动参数的解析验收（对应 C# `App.ApplyTestMode` / `ParseTestDirArg` /
/// OnStartup 尾部的 `--test-timeout` 读取）。目录布置的副作用在宿主壳里，由真机启动验证。
final class TestModeLaunchTests: XCTestCase {

    private let temp = "/tmp/sidest-test"

    // MARK: - 开关

    func testAbsentFlagYieldsNil() {
        XCTAssertNil(TestModeArgs.parse([], tempDir: temp))
        XCTAssertNil(TestModeArgs.parse(["--test-dir", "/x", "--test-timeout", "5"], tempDir: temp),
                     "只带从属参数不进入测试模式")
    }

    func testDefaults() {
        let plan = TestModeArgs.parse(["--test-mode"], tempDir: temp)
        XCTAssertEqual(plan?.dataDir, "\(temp)/SideDesk-test", "缺省目录固定，向后兼容既有 E2E")
        XCTAssertEqual(plan?.withBars, false)
        XCTAssertEqual(plan?.timeoutSeconds, 60)
    }

    func testFlagsAreCaseInsensitive() {
        let plan = TestModeArgs.parse(["--TEST-MODE", "--Test-With-Bars"], tempDir: temp)
        XCTAssertEqual(plan?.withBars, true, "对应 C# OrdinalIgnoreCase")
    }

    // MARK: - --test-dir

    func testTestDirBothForms() {
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-dir=/a/b"], tempDir: temp)?.dataDir, "/a/b")
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-dir", "/a/b"], tempDir: temp)?.dataDir, "/a/b")
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--TEST-DIR=/a/b"], tempDir: temp)?.dataDir, "/a/b")
    }

    func testTestDirTrimsQuotesOnly() {
        // 只剥首尾双引号，内部空格保留（与 C# Trim('"') 一致）
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-dir=\"/a b/c\""], tempDir: temp)?.dataDir, "/a b/c")
    }

    func testBlankTestDirFallsBackToDefault() {
        for args in [["--test-mode", "--test-dir="], ["--test-mode", "--test-dir", "\"\""],
                     ["--test-mode", "--test-dir"], ["--test-mode", "--test-dir", "   "]] {
            XCTAssertEqual(TestModeArgs.parse(args, tempDir: temp)?.dataDir, "\(temp)/SideDesk-test",
                           "空白/缺值视为未指定：\(args)")
        }
    }

    // MARK: - --test-timeout

    func testTimeoutParsing() {
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-timeout", "5"], tempDir: temp)?.timeoutSeconds, 5)
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--TEST-TIMEOUT", "5"], tempDir: temp)?.timeoutSeconds, 5)
        // 非正数、非数字、缺值一律回落 60
        for bad in ["abc", "0", "-3", "1.5"] {
            XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-timeout", bad], tempDir: temp)?.timeoutSeconds, 60,
                           "非法值回落默认 60: \(bad)")
        }
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-timeout"], tempDir: temp)?.timeoutSeconds, 60)
    }

    func testTimeoutEqualsFormIsNotSupported() {
        // C# 只认空格双参形式（SkipWhile+Skip(1)）；`--test-timeout=9` 落回默认——照抄这个怪癖
        XCTAssertEqual(TestModeArgs.parse(["--test-mode", "--test-timeout=9"], tempDir: temp)?.timeoutSeconds, 60)
    }

    func testParamsCombine() {
        let plan = TestModeArgs.parse(["--test-mode", "--test-with-bars", "--test-dir=/g/uuid1",
                                       "--test-timeout", "3"], tempDir: temp)
        XCTAssertEqual(plan, TestModeLaunch(withBars: true, dataDir: "/g/uuid1", timeoutSeconds: 3))
    }
}
