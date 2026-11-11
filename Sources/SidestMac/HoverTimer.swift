import AppKit

/// 侧栏**悬停展开/收回**驱动器（对应 C# `AppBarHoverTimer`，见 `.qoder/` ADR-0011 下从
/// `MainWindow` 拆出的真职责）：一个 120ms 计时器轮询光标位置，落在侧栏矩形内就展到浮动宽、
/// 出界就收回停靠宽。
///
/// C# 侧每个 `AppBarWindow` 各持一个计时器；macOS 端只有一条计时器遍历 `AppDelegate` 的面板列表，
/// 逐面板判定（面板数 ≤2，省掉重复唤醒）。
///
/// **#693**：弹出层（右键菜单 / 下拉 / 独立对话框）是**独立窗口**——只按侧栏矩形判「出界」会让
/// 侧栏在用户伸手去点菜单时收回，卡片跟着重排、菜单的放置目标移位，用户瞄准的那一下点空。
/// 故光标落在**本进程的弹出层窗口**上算「仍在交互区」。C# 用 `WindowFromPoint` + 进程 ID 校验，
/// macOS 端 `NSApp.windows` 本来就只含本进程窗口，直接逐个做矩形包含判定即可（数组极小，无跨进程扫描）；
/// 判定时排除侧栏自身，见 `tick()`。
final class HoverTimer {

    /// 悬停判定间隔：与 C# `Interval` 同口径——120ms 响应够快，又不至于让光标移动产生高频布局。
    private static let interval: TimeInterval = 0.12

    private let panelsProvider: () -> [SidePanel]
    private var timer: Timer?

    init(panelsProvider: @escaping () -> [SidePanel]) {
        self.panelsProvider = panelsProvider
    }

    /// 按当前悬停配置动态起停（对应 C# `ReloadConfig`）：设置页改了开关 / 浮动宽度、或侧栏显隐后
    /// 由宿主热重载调用。
    func reload() {
        var hoverable = false
        for panel in panelsProvider() {
            // 「可悬停」= 该侧开了浮动 **且** 该侧确实停靠可见：C# 未停靠侧根本没有窗口，也就不起表；
            // 这里两侧面板常驻，故按可见态过滤，免得为空侧白轮询。
            let active = panel.hoverEnabled && panel.isVisibleState
            if active {
                hoverable = true
            } else {
                // 不该展开的先收回（对应 C#「禁用：若正处于展开态先收回，再停计时器」）。
                // 只收回、不展开——展开与否只由光标位置决定（`tick`）。
                panel.setHoverExpanded(false)
            }
        }
        if hoverable { start() } else { stop() }
    }

    /// 幂等启动（C# `_timer == null` 才新建）。
    private func start() {
        if timer != nil { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 默认模式：菜单跟踪（NSMenu 的嵌套 modal runloop）期间不触发——侧栏在菜单打开时保持原状，
        // 菜单关闭后再判。这也让 #693 的自有窗口豁免只覆盖 SwiftUI `Menu` 之外的独立对话框窗口。
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    /// 停掉并释放计时器（退出时调用；幂等）。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let cursor = NSEvent.mouseLocation      // 屏幕坐标，左下原点，与 `window.frame` 同一空间
        // 弹出层豁免：本进程**非侧栏**的可见窗口（对话框 / 独立便签 / 设置窗）。
        // 与 C# 的一处刻意差异：C# 的 `WindowFromPoint` 会把「另一条侧栏」也当自有窗口，
        // 于是「左右双侧」布局下光标点一条会让两条同时展宽；这里排除侧栏自身，只豁免弹出层。
        let popups = NSApp.windows.filter { !($0 is SidePanel) && $0.isVisible }
        for panel in panelsProvider() {
            guard panel.isVisibleState else {
                panel.setHoverExpanded(false)
                continue
            }
            let inside = panel.frame.contains(cursor) || popups.contains { $0.frame.contains(cursor) }
            panel.setHoverExpanded(inside)
        }
    }
}
