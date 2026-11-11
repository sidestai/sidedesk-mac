import XCTest
@testable import SideDeskCore

/// issue #48 环境适应层的纯逻辑（对应 C# `SystemPreferences.ReadTextScaleFactor` / `Motion.Fade`）。
/// 全局偏好用接缝驱动，用例结束还原，避免污染主题字号相关的其它用例。
final class EnvironmentTests: XCTestCase {

    func testReadTextScaleFactor() {
        SystemPreferences.systemTextScale = { 1.0 }
        defer { SystemPreferences.systemTextScale = { 1.0 }; SystemPreferences.refresh() }
        // 环境覆盖按百分比解析
        XCTAssertEqual(SystemPreferences.readTextScaleFactor("150"), 1.5, accuracy: 0.0001)
        XCTAssertEqual(SystemPreferences.readTextScaleFactor("50"), 1.0, "下钳到 1.0")
        XCTAssertEqual(SystemPreferences.readTextScaleFactor("999"), 2.25, "上钳到 2.25")
        XCTAssertEqual(SystemPreferences.readTextScaleFactor("0"), 1.0, "<=0 回落 1.0")
        XCTAssertEqual(SystemPreferences.readTextScaleFactor("abc"), 1.0, "非法回落 1.0")
        XCTAssertEqual(SystemPreferences.readTextScaleFactor(nil), 1.0, "无覆盖走接缝")
        // 系统接缝值也钳到 1.0~2.25
        SystemPreferences.systemTextScale = { 3.0 }
        XCTAssertEqual(SystemPreferences.readTextScaleFactor(nil), 2.25)
    }

    func testRefreshEnvForceOverridesSeam() {
        // 无环境强制时读接缝
        SystemPreferences.systemHighContrast = { true }
        SystemPreferences.systemReduceMotion = { true }
        SystemPreferences.refresh()
        XCTAssertTrue(SystemPreferences.highContrast)
        XCTAssertTrue(SystemPreferences.reduceMotion)
        SystemPreferences.systemHighContrast = { false }
        SystemPreferences.systemReduceMotion = { false }
        SystemPreferences.refresh()
        XCTAssertFalse(SystemPreferences.highContrast)
        XCTAssertFalse(SystemPreferences.reduceMotion)
    }

    func testMotionFadeRespectsReduceMotion() {
        defer { SystemPreferences.systemReduceMotion = { false }; SystemPreferences.refresh() }
        SystemPreferences.systemReduceMotion = { false }
        SystemPreferences.refresh()
        XCTAssertEqual(Motion.fade(220), 0.22, accuracy: 0.0001)
        SystemPreferences.systemReduceMotion = { true }
        SystemPreferences.refresh()
        XCTAssertEqual(Motion.fade(220), 0, "减少动效 → 时长 0（瞬时）")
    }
}
