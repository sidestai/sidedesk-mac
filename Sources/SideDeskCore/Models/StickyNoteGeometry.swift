import Foundation

/// 桌面便签悬浮窗几何计算（对应 C# `StickyDesktopService.ResolveGeometry`）——纯函数、无 UI 依赖，可单测。
/// 坐标系与 AppKit 一致（屏幕左下角为原点，Y 向上）：`workArea` 传屏幕可见工作区，返回值即窗口 frame。
public enum StickyNoteGeometry {

    public static let defaultW: Double = 240
    public static let defaultH: Double = 240
    /// 小于此值视为「尚未调整过尺寸」（对应 C# MinSize）。
    public static let minSize: Double = 40

    /// 工作区矩形（左下原点）。用普通 Double 结构避免把 CoreGraphics 依赖带进 Core。
    public struct WorkArea {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double
        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
    }

    public struct Frame: Equatable {
        public var left: Double
        public var top: Double
        public var w: Double
        public var h: Double
    }

    /// 已调整过尺寸则还原上次位置/尺寸（并夹进工作区），否则用默认尺寸 + 级联位置（避免多张完全重叠）。
    public static func resolve(_ note: StickyNote, workArea: WorkArea, cascadeIndex: Int) -> Frame {
        let w = note.PinWidth >= minSize ? note.PinWidth : defaultW
        let h = note.PinHeight >= minSize ? note.PinHeight : defaultH

        var left: Double
        var top: Double
        if note.PinWidth >= minSize && note.PinHeight >= minSize {
            left = note.PinLeft
            top = note.PinTop
        } else {
            let step = 28.0
            let i = Double(((cascadeIndex % 8) + 8) % 8)
            left = workArea.minX + 80 + i * step
            top = workArea.minY + 80 + i * step
        }

        // 夹进工作区（还原到已拔掉的副屏、或级联溢出时兜底）
        if left + w > workArea.maxX { left = workArea.maxX - w - 20 }
        if top + h > workArea.maxY { top = workArea.maxY - h - 20 }
        if left < workArea.minX { left = workArea.minX + 20 }
        if top < workArea.minY { top = workArea.minY + 20 }
        return Frame(left: left, top: top, w: w, h: h)
    }
}
