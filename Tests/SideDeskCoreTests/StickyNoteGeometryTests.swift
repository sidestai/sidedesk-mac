import XCTest
@testable import SideDeskCore

/// 桌面便签悬浮窗几何计算（对应 C# `StickyDesktopService.ResolveGeometry`）验收——纯函数、无 UI。
final class StickyNoteGeometryTests: XCTestCase {

    private let work = StickyNoteGeometry.WorkArea(minX: 0, minY: 0, maxX: 1440, maxY: 900)

    private func note(w: Double = 0, h: Double = 0, left: Double = 0, top: Double = 0) -> StickyNote {
        let n = StickyNote()
        n.PinWidth = w; n.PinHeight = h; n.PinLeft = left; n.PinTop = top
        return n
    }

    func testFreshNoteUsesDefaultSizeAndCascadeOrigin() {
        let g0 = StickyNoteGeometry.resolve(note(), workArea: work, cascadeIndex: 0)
        XCTAssertEqual(g0, .init(left: 80, top: 80, w: 240, h: 240))

        let g3 = StickyNoteGeometry.resolve(note(), workArea: work, cascadeIndex: 3)
        XCTAssertEqual(g3, .init(left: 80 + 3 * 28, top: 80 + 3 * 28, w: 240, h: 240))
    }

    func testCascadeIndexWrapsAtEight() {
        let g8 = StickyNoteGeometry.resolve(note(), workArea: work, cascadeIndex: 8)
        XCTAssertEqual(g8.left, 80, "cascade 计数模 8：第 8 张回到起点")
        let gNeg = StickyNoteGeometry.resolve(note(), workArea: work, cascadeIndex: -1)
        XCTAssertEqual(gNeg.left, 80 + 7 * 28, "负索引也应落入 0..7")
    }

    func testSizedNoteRestoresSavedGeometry() {
        let g = StickyNoteGeometry.resolve(note(w: 300, h: 200, left: 100, top: 120), workArea: work, cascadeIndex: 5)
        XCTAssertEqual(g, .init(left: 100, top: 120, w: 300, h: 200))
    }

    func testOnlyOneDimensionSavedFallsBackToDefault() {
        // 只调过宽没调过高（或反之）视为「尚未调整过尺寸」→ 默认尺寸 + 级联位置
        let g = StickyNoteGeometry.resolve(note(w: 300, h: 0, left: 500, top: 500), workArea: work, cascadeIndex: 0)
        XCTAssertEqual(g.w, 300, "宽已保存则沿用")
        XCTAssertEqual(g.h, 240, "高未保存回落默认")
        XCTAssertEqual(g.left, 80, "位置未整体保存 → 级联位置")
    }

    func testClampedIntoWorkArea() {
        // 右溢出
        let right = StickyNoteGeometry.resolve(note(w: 240, h: 240, left: 1400, top: 100), workArea: work, cascadeIndex: 0)
        XCTAssertEqual(right.left, 1440 - 240 - 20)
        // 上溢出（AppKit Y 向上：top+h 超过 maxY）
        let topOver = StickyNoteGeometry.resolve(note(w: 240, h: 240, left: 100, top: 800), workArea: work, cascadeIndex: 0)
        XCTAssertEqual(topOver.top, 900 - 240 - 20)
        // 左/下越界
        let neg = StickyNoteGeometry.resolve(note(w: 240, h: 240, left: -100, top: -100), workArea: work, cascadeIndex: 0)
        XCTAssertEqual(neg.left, 20)
        XCTAssertEqual(neg.top, 20)
    }
}
