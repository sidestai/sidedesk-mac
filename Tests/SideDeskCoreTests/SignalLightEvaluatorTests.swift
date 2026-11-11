import XCTest
@testable import SideDeskCore

/// 信号灯三态求值状态机验收（逐式对齐 C# `SignalLightBoard.cs`）：
/// 状态优先级、AND/OR 组合、EQ/GT/LT/MISSING 操作符、数值提取、熄灭压暗。
final class SignalLightEvaluatorTests: XCTestCase {

    /// 固定变量表的值提供者。
    private func provider(_ table: [String: String]) -> SignalLightEvaluator.ValueProvider {
        { key in table[key] }
    }

    private func cond(_ key: String, _ op: String, _ value: String = "") -> SignalLightCondition {
        let c = SignalLightCondition()
        c.VarKey = key; c.Op = op; c.Value = value
        return c
    }

    // MARK: - 状态优先级：闪烁 > 关 > 开 > 手动 IsOn

    func testStatePriorityBlinkOverOffAndOn() {
        let l = SignalLightItem()
        l.IsOn = false
        l.OnConditions = [cond("v", "EQ", "1")]
        l.OffConditions = [cond("v", "EQ", "1")]
        l.BlinkConditions = [cond("v", "EQ", "1")]
        l.BlinkIntervalSeconds = 1
        let p = provider(["v": "1"])
        // 间隔 1s => 1000ms；nowMs=0 落在第 0 个半周期（偶）=> 相位亮。
        let s0 = SignalLightEvaluator.state(for: l, value: p, nowMs: 0)
        XCTAssertTrue(s0.blinking)
        XCTAssertTrue(s0.lit)
        // nowMs=1000 落在第 1 个半周期（奇）=> 相位灭，但仍属闪烁态。
        let s1 = SignalLightEvaluator.state(for: l, value: p, nowMs: 1000)
        XCTAssertTrue(s1.blinking)
        XCTAssertFalse(s1.lit)
    }

    func testStateOffOverOn() {
        let l = SignalLightItem()
        l.IsOn = true
        l.OnConditions = [cond("v", "EQ", "1")]
        l.OffConditions = [cond("v", "EQ", "1")]
        let s = SignalLightEvaluator.state(for: l, value: provider(["v": "1"]), nowMs: 0)
        XCTAssertFalse(s.lit)
        XCTAssertFalse(s.blinking)
    }

    func testStateOnOverManualIsOn() {
        let l = SignalLightItem()
        l.IsOn = false
        l.OnConditions = [cond("v", "EQ", "1")]
        let s = SignalLightEvaluator.state(for: l, value: provider(["v": "1"]), nowMs: 0)
        XCTAssertTrue(s.lit)
    }

    func testStateFallsBackToManualIsOn() {
        let on = SignalLightItem(); on.IsOn = true
        let off = SignalLightItem(); off.IsOn = false
        XCTAssertTrue(SignalLightEvaluator.state(for: on, value: provider([:]), nowMs: 0).lit)
        XCTAssertFalse(SignalLightEvaluator.state(for: off, value: provider([:]), nowMs: 0).lit)
    }

    // MARK: - AND / OR 组合

    func testCondsMetEmptyIsFalse() {
        XCTAssertFalse(SignalLightEvaluator.condsMet([], mode: "OR", value: provider([:])))
        XCTAssertFalse(SignalLightEvaluator.condsMet(nil, mode: "AND", value: provider([:])))
    }

    func testCondsMetOrAny() {
        let conds = [cond("a", "EQ", "1"), cond("b", "EQ", "1")]
        XCTAssertTrue(SignalLightEvaluator.condsMet(conds, mode: "OR", value: provider(["b": "1"])))
        XCTAssertFalse(SignalLightEvaluator.condsMet(conds, mode: "OR", value: provider(["c": "1"])))
    }

    func testCondsMetAndAll() {
        let conds = [cond("a", "EQ", "1"), cond("b", "EQ", "1")]
        XCTAssertTrue(SignalLightEvaluator.condsMet(conds, mode: "AND", value: provider(["a": "1", "b": "1"])))
        XCTAssertFalse(SignalLightEvaluator.condsMet(conds, mode: "AND", value: provider(["a": "1"])))
    }

    // MARK: - 操作符

    func testCondMetEmptyVarKeyIsFalse() {
        XCTAssertFalse(SignalLightEvaluator.condMet(cond("", "EQ", "1"), value: provider(["": "1"])))
    }

    func testCondMetMissing() {
        let m = cond("v", "MISSING")
        XCTAssertTrue(SignalLightEvaluator.condMet(m, value: provider([:])))          // 不存在
        XCTAssertTrue(SignalLightEvaluator.condMet(m, value: provider(["v": ""])))     // 空
        XCTAssertTrue(SignalLightEvaluator.condMet(m, value: provider(["v": "--"])))   // 占位
        XCTAssertFalse(SignalLightEvaluator.condMet(m, value: provider(["v": "x"])))   // 有值
    }

    func testCondMetEqCaseInsensitive() {
        let c = cond("v", "EQ", "OK")
        XCTAssertTrue(SignalLightEvaluator.condMet(c, value: provider(["v": "ok"])))
        XCTAssertFalse(SignalLightEvaluator.condMet(c, value: provider(["v": "no"])))
        // 值缺失时非 MISSING 操作符 = false
        XCTAssertFalse(SignalLightEvaluator.condMet(c, value: provider([:])))
    }

    func testCondMetGtLtNumeric() {
        XCTAssertFalse(SignalLightEvaluator.condMet(cond("v", "GT", "10"), value: provider(["v": "5"])))
        XCTAssertTrue(SignalLightEvaluator.condMet(cond("v", "GT", "10"), value: provider(["v": "20"])))
        XCTAssertTrue(SignalLightEvaluator.condMet(cond("v", "LT", "10"), value: provider(["v": "5"])))
        XCTAssertFalse(SignalLightEvaluator.condMet(cond("v", "LT", "10"), value: provider(["v": "20"])))
    }

    func testCondMetGtLtFallsBackToOrdinalWhenNotNumeric() {
        // "apple" vs "banana" 均不可解析为数值 => 按字节序；apple < banana。
        XCTAssertTrue(SignalLightEvaluator.condMet(cond("v", "LT", "banana"), value: provider(["v": "apple"])))
        XCTAssertFalse(SignalLightEvaluator.condMet(cond("v", "GT", "banana"), value: provider(["v": "apple"])))
    }

    // MARK: - 数值提取

    func testExtractNumber() {
        XCTAssertEqual(SignalLightEvaluator.extractNumber("42"), 42)
        XCTAssertEqual(SignalLightEvaluator.extractNumber(" 3.5 "), 3.5)
        XCTAssertEqual(SignalLightEvaluator.extractNumber("abc-7.25def"), -7.25)
        XCTAssertEqual(SignalLightEvaluator.extractNumber("temp 12C"), 12)
        XCTAssertNil(SignalLightEvaluator.extractNumber("no digits"))
    }

    // MARK: - 熄灭压暗

    func testDimmedRGBRemovesWhiteThenScales() {
        // 纯红 (255,0,0)：min=0，max=255 => 缩放到 130 => (130,0,0)。
        let r = SignalLightEvaluator.dimmedRGB(r: 255, g: 0, b: 0)
        XCTAssertEqual(r.r, 130); XCTAssertEqual(r.g, 0); XCTAssertEqual(r.b, 0)
        // 带白分量 (200,100,100)：min=100 去白 => (100,0,0)，max=100 缩放到 130 => (130,0,0)。
        let w = SignalLightEvaluator.dimmedRGB(r: 200, g: 100, b: 100)
        XCTAssertEqual(w.r, 130); XCTAssertEqual(w.g, 0); XCTAssertEqual(w.b, 0)
    }

    func testDimmedRGBGrayScalesBy04() {
        // 纯灰 (100,100,100)：去白后 max=0 => 整体 ×0.4 => (40,40,40)。
        let g = SignalLightEvaluator.dimmedRGB(r: 100, g: 100, b: 100)
        XCTAssertEqual(g.r, 40); XCTAssertEqual(g.g, 40); XCTAssertEqual(g.b, 40)
    }

    // MARK: - 闪烁相位

    func testBlinkPhaseIntervalFloor() {
        let l = SignalLightItem()
        l.BlinkIntervalSeconds = 0   // 低于下限 => 取 0.1s = 100ms
        XCTAssertTrue(SignalLightEvaluator.blinkPhaseOn(l, nowMs: 0))     // 0/100=0 偶
        XCTAssertFalse(SignalLightEvaluator.blinkPhaseOn(l, nowMs: 100))  // 100/100=1 奇
        XCTAssertTrue(SignalLightEvaluator.blinkPhaseOn(l, nowMs: 200))   // 2 偶
    }
}
