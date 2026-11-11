import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

enum PanelEdge {
    case left, right
}

/// 侧栏当前渲染宽度（悬停展开时变宽）。根视图的 `.frame(width:)` 必须与窗口 frame 同源，
/// 否则展开后窗口变宽、内容仍是收起宽的窄条。侧栏自己持有并在宽度变化时发布。
/// 只在主线程读写（NSPanel 的 frame 路径），故不加 actor 隔离以免无谓的跨隔离报错。
final class PanelWidthModel: ObservableObject {
    @Published var width: CGFloat
    init(_ width: CGFloat) { self.width = width }
}

/// A borderless panel pinned to a screen edge (left or right) that slides in/out.
final class SidePanel: NSPanel {

    /// 停靠边（宿主按停靠模式决定该侧是否显示，见 `AppDelegate.updatePanelVisibility`）。
    let edge: PanelEdge

    /// 停靠宽度（对应 C# `App.CreatePanel`：按边取该显示器配置的 `LeftPanelWidth / RightPanelWidth`）。
    /// 每次都读配置，所以设置页改宽度后 `reposition()` 即生效（C# 是 `Host?.ApplyPanelWidths()`）。
    /// 5-500 的取值范围由设置页把关（C# `OnPanelWidth` 同一口径），这里不再二次夹取。
    /// 侧栏几何只认主屏，故取显示器 0 的配置；多屏独立宽度随 T4 落地。
    ///
    /// 这是**收起态**宽度，对应 C# `AppBarWidth`：悬停展开不改它，窗口夹取与「最大化」预留位
    /// 也一直按它算（C# `SetHoverExpanded` 只调 Left/Width、不重注册 AppBar）。
    var panelWidth: CGFloat { Self.width(for: edge) }

    /// 悬停展开开关（对应 C# `cfg.Left/RightHoverEnabled`）。
    var hoverEnabled: Bool { Self.hoverEnabled(for: edge) }

    /// 悬停展开宽度（对应 C# `ExpandedWidth` ← `cfg.Left/RightHoverWidth`）。
    var hoverWidth: CGFloat { Self.hoverWidth(for: edge) }

    /// 悬停展开态（对应 C# `_isHoverExpanded`）。
    private(set) var isHoverExpanded = false

    /// 当前渲染宽：展开取浮动宽、否则取停靠宽。窗口 frame 与内容宽度都走它。
    var liveWidth: CGFloat { isHoverExpanded ? hoverWidth : panelWidth }

    /// 内容宽度源（与 `liveWidth` 同步，见 `PanelWidthModel`）。
    let widthModel: PanelWidthModel

    private(set) var isVisibleState = false

    private static func width(for edge: PanelEdge) -> CGFloat {
        let monitor = Seam.settings.GetCurrentMonitor(0)
        return CGFloat(edge == .left ? monitor.LeftPanelWidth : monitor.RightPanelWidth)
    }

    private static func hoverEnabled(for edge: PanelEdge) -> Bool {
        let monitor = Seam.settings.GetCurrentMonitor(0)
        return edge == .left ? monitor.LeftHoverEnabled : monitor.RightHoverEnabled
    }

    private static func hoverWidth(for edge: PanelEdge) -> CGFloat {
        let monitor = Seam.settings.GetCurrentMonitor(0)
        return CGFloat(edge == .left ? monitor.LeftHoverWidth : monitor.RightHoverWidth)
    }

    /// 面板内「隐藏窗口」菜单项的回调，由宿主（AppDelegate）挂接。
    var onHideRequest: (() -> Void)?

    /// 面板标题栏「最大化」按钮的回调，由宿主（AppDelegate）挂接。
    var onMaximizeRequest: (() -> Void)?

    init(edge: PanelEdge, cards: BarCardsModel) {
        self.edge = edge
        self.widthModel = PanelWidthModel(Self.width(for: edge))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width(for: edge), height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // 不开窗口阴影：侧栏是 statusBar 层浮层，阴影会画在下方的最大化窗口边缘上，
        // 看起来像侧栏多出一圈 ~67px 的"外框"压着窗口。
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        animationBehavior = .none

        contentView = PanelHostingView(rootView: SidePanelRootView(
            onHide: { [weak self] in self?.onHideRequest?() },
            onMaximize: { [weak self] in self?.onMaximizeRequest?() },
            edge: edge,
            widthModel: widthModel,
            cards: cards))
        setFrame(hiddenFrame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Geometry

    /// Spans from the bottom edge up to just below the menu bar, flush to the
    /// panel's screen edge.
    private var shownFrame: NSRect {
        guard let screen = NSScreen.main else { return frame }
        let f = screen.frame
        let top = screen.visibleFrame.maxY           // underside of the menu bar
        let w = liveWidth
        // 外侧边缘钉死、向屏幕内侧延伸（对应 C# 右屏 `Left = monitorRight - width`、左屏 Left 不变）。
        let x = (edge == .left) ? f.minX : f.maxX - w
        return NSRect(x: x, y: f.minY, width: w, height: top - f.minY)
    }

    /// Same height, slid fully off the panel's edge.
    private var hiddenFrame: NSRect {
        guard let screen = NSScreen.main else { return frame }
        let f = screen.frame
        let top = screen.visibleFrame.maxY
        let w = panelWidth
        let x = (edge == .left) ? f.minX - w - 8 : f.maxX + 8
        return NSRect(x: x, y: f.minY, width: w, height: top - f.minY)
    }

    // MARK: - Hover expand

    /// 悬停展开/收回（对应 C# `SetHoverExpanded`）：只调窗口 frame 与内容宽度，不动停靠预留位。
    /// 开关被关掉时强制收回（对应 C# `ReloadConfig` 禁用分支的「先收回再停计时器」）。
    /// 不做动画：C# 同处也是直接改 Left/Width，120ms 一次，加动画会持续追尾抖动。
    func setHoverExpanded(_ expanded: Bool) {
        let target = expanded && hoverEnabled
        guard target != isHoverExpanded else { return }
        isHoverExpanded = target
        widthModel.width = liveWidth
        guard isVisibleState else { return }
        setFrame(shownFrame, display: true)
    }

    // MARK: - Show / hide

    /// 按当前屏幕几何重算 frame（显示器变化后用）：保持现有显隐状态，不做动画。
    func reposition() {
        widthModel.width = liveWidth
        setFrame(isVisibleState ? shownFrame : hiddenFrame, display: true)
    }

    func toggle() {
        setHidden(!isVisibleState, animated: true)
    }

    func setHidden(_ hidden: Bool, animated: Bool) {
        isVisibleState = !hidden
        // 收起时清掉悬停展开态：否则 `widthModel` 仍是浮动宽，下次唤出会按展开宽排布。
        if hidden { setHoverExpanded(false) }
        let target = hidden ? hiddenFrame : shownFrame
        guard animated else {
            setFrame(target, display: true)
            if hidden { orderOut(nil) }
            return
        }
        if !hidden { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fade(220)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            if hidden { self?.orderOut(nil) }
        })
    }
}

/// 侧栏宿主视图。侧栏是 `.nonactivatingPanel`（点击不抢焦点），而 SwiftUI `.contextMenu`
/// 只在窗口成为 key window 时才会响应右键——非激活面板永远不成为 key，导致所有右键菜单失效。
/// 这里在右键按下时把面板临时提为 key（`makeKey`，不 `activate`，故仍不抢占前台 App），
/// 再交给 super 走 SwiftUI 手势，菜单即可弹出。`acceptsFirstMouse` 让首次点击也能命中。
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        super.rightMouseDown(with: event)
    }
}
