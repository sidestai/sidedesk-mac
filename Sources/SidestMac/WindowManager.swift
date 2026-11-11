import AppKit
import ApplicationServices

/// Continuously keeps every non-fullscreen window clear of the side bars' reserved
/// gutters, per the screen the window actually sits on (multi-display safe).
/// Fullscreen windows are left untouched and instead cause the bar to hide itself.
final class WindowManager {

    static let sideInset: CGFloat = 100

    /// Called on the main thread whenever the frontmost window enters/leaves
    /// native fullscreen.
    var onFullscreenChange: ((Bool) -> Void)?

    /// 由宿主提供「指定屏幕左右两侧各应为其它窗口保留的宽度」——跟随真实停靠布局与侧栏宽度，
    /// 且只在该侧面板实际可见并停靠在传入的这块屏时保留（隐藏/未停靠/不在该屏返回 0）。
    /// enforcement 夹取与最大化共用，保证「最大化后窗口正好贴住侧栏、不留死缝也不被侧栏盖住」。
    /// 未接线时回落到固定 `sideInset`。
    var insetsProvider: ((NSScreen) -> (left: CGFloat, right: CGFloat))?

    private func insets(for screen: NSScreen) -> (left: CGFloat, right: CGFloat) {
        insetsProvider?(screen) ?? (Self.sideInset, Self.sideInset)
    }

    private var observers: [pid_t: AXObserver] = [:]
    private var contexts: [pid_t: ObserverContext] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var trustTimer: Timer?
    private var started = false

    private var pendingPids = Set<pid_t>()
    private var enforceScheduled = false
    private var fullscreen = false

    // MARK: - Permission

    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Lifecycle

    /// Begin managing windows. If Accessibility isn't granted yet, poll until it
    /// is (the user may be flipping the switch in System Settings).
    func start() {
        guard !started, !beginScheduled else { return }
        if Self.isTrusted(prompt: true) {
            // 全量 AX 扫描不能留在 applicationDidFinishLaunching 的同步路径里：
            // 一个无响应的第三方应用就能把主线程堵死（实测 105 应用时 >20 秒不返回），
            // 面板显隐、热键与设置窗口全都排在它后面。
            beginScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.beginScheduled = false
                self?.begin()
            }
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Self.isTrusted() {
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.begin()
                }
            }
        }
    }

    /// 待处理的应用 pid 队列：启动扫描与空间切换后的全量重扫共用，每 tick 只处理一个
    /// （见 `pumpScanQueue` / `drainScanOne`）。
    private var scanQueue: [pid_t] = []
    private var scanScheduled = false
    private var beginScheduled = false

    private func begin() {
        started = true
        dbg("begin trusted=\(Self.isTrusted()) apps=\(NSWorkspace.shared.runningApplications.count)")
        let ownPid = ProcessInfo.processInfo.processIdentifier
        enqueueScan(NSWorkspace.shared.runningApplications
            .map { $0.processIdentifier }
            .filter { $0 != ownPid })

        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.addApp(app)
            }
        })
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.removeApp(pid: app.processIdentifier)
            }
        })
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFullscreen()
        })
        workspaceTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleFullScan()
            self?.refreshFullscreen()
        })

        refreshFullscreen()
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        contexts.removeAll()
        started = false
    }

    // MARK: - Per-app observers

    private func enqueueScan(_ pids: [pid_t]) {
        for pid in pids where pid != ProcessInfo.processInfo.processIdentifier && !scanQueue.contains(pid) {
            scanQueue.append(pid)
        }
        pumpScanQueue()
    }

    private func pumpScanQueue() {
        guard !scanScheduled, !scanQueue.isEmpty else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in self?.drainScanOne() }
    }

    /// 每个主队列 tick 只处理一个应用：AX 调用是同步跨进程的，一次性遍历全部应用
    /// 会让调用方按最慢的那个应用计时（实测 87 应用时启动路径卡死 >20 秒）。
    private func drainScanOne() {
        scanScheduled = false
        guard !scanQueue.isEmpty else { return }
        let pid = scanQueue.removeFirst()
        if observers[pid] != nil {
            enforceApp(axElement(pid: pid))
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            addApp(app)
        }
        pumpScanQueue()
    }

    /// AX 调用超时上限：无响应的应用不该拖住主线程（默认超时是系统级的，很长）。
    private func axElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return }
        if app.activationPolicy == .prohibited { return }
        if observers[pid] != nil { return }

        let axApp = axElement(pid: pid)
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success, let observer else { return }

        let context = ObserverContext(pid: pid, manager: self)
        contexts[pid] = context
        let ctx = Unmanaged.passUnretained(context).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, axApp, name as CFString, ctx)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer

        enforceApp(axApp)
    }

    private func removeApp(pid: pid_t) {
        contexts.removeValue(forKey: pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Non-capturing C callback; the context (pid + manager) comes from the refcon.
    private static let axCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        context.manager?.handleEvent(pid: context.pid, name: notification as String)
    }

    private func handleEvent(pid: pid_t, name: String) {
        scheduleEnforce(pid: pid)
        if name == (kAXWindowResizedNotification as String)
            || name == (kAXWindowMovedNotification as String) {
            refreshFullscreen()
        }
    }

    // MARK: - Enforcement

    private func scheduleEnforce(pid: pid_t) {
        pendingPids.insert(pid)
        guard !enforceScheduled else { return }
        enforceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.enforceScheduled = false
            let pids = self.pendingPids
            self.pendingPids.removeAll()
            for pid in pids {
                self.enforceApp(self.axElement(pid: pid))
            }
        }
    }

    private func scheduleFullScan() {
        enqueueScan(Array(observers.keys))
    }

    private func enforceApp(_ axApp: AXUIElement) {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref)
        guard result == .success, let windows = ref as? [AXUIElement] else {
            dbg("enforceApp copyWindows err=\(result.rawValue)")
            return
        }
        dbg("enforceApp windows=\(windows.count)")
        for window in windows {
            adjustWindow(window)
        }
    }

    private func adjustWindow(_ window: AXUIElement) {
        if isFullscreen(window) { return }
        guard var pos = getPoint(window, kAXPositionAttribute as CFString),
              var size = getSize(window, kAXSizeAttribute as CFString) else { return }

        // 多屏：窗口可能在任意一块屏上（AX 全局坐标里副屏可以是负数或远超主屏宽度），
        // 必须按窗口实际所在的屏夹取。只认主屏宽度会把副屏窗口错误限宽、甚至搬回主屏。
        guard let screen = screenForWindow(pos: pos, size: size) else { return }
        let (li, ri) = insets(for: screen)
        // AX 与 AppKit 的 x 轴同向同原点，横向边界直接取该屏 frame 的左右边。
        let minX = screen.frame.minX + li
        let maxX = screen.frame.maxX - ri

        let curLeft = pos.x
        let curRight = pos.x + size.width
        if curLeft >= minX - 0.5 && curRight <= maxX + 0.5 { return }   // clear — also breaks the notify loop

        let newLeft = max(curLeft, minX)
        let newRight = min(curRight, maxX)
        var newWidth = newRight - newLeft
        if newWidth < 120 { newWidth = max(120, size.width) }           // too narrow to shrink; just nudge
        pos.x = newLeft
        size.width = newWidth
        setPoint(window, kAXPositionAttribute as CFString, pos)
        setSize(window, kAXSizeAttribute as CFString, size)
    }

    /// 窗口实际所在的屏幕：AX 坐标（左上原点，主屏左上为 0,0）转 AppKit（左下原点）后
    /// 取含窗口中心的屏幕；中心不在任何屏内时回落到交集最大的屏；完全在所有屏之外返回 nil。
    private func screenForWindow(pos: CGPoint, size: CGSize) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = CGRect(x: pos.x, y: primaryHeight - pos.y - size.height,
                          width: size.width, height: size.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        return NSScreen.screens
            .map { ($0, $0.frame.intersection(rect)) }
            .filter { !$1.isEmpty }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
    }

    // MARK: - Maximize (title-bar button)

    /// 把前台应用的聚焦窗口铺满「enforcement 允许的最大矩形」——即工作区扣除两侧可见侧栏的
    /// 保留位（对应侧栏标题栏的「最大化」按钮）。侧栏是不抢焦点的浮层，故此刻的前台应用
    /// 仍是用户正在用的那个，最大化落到它身上正合预期。
    ///
    /// 目标矩形刻意与 `adjustWindow` 的常驻夹取口径一致（左右各取该屏 `insets`、纵向取 `visibleFrame`）：
    /// enforcement 会把任何越界窗口立刻夹回该矩形，若这里铺到更宽只会先盖住侧栏再被弹回（抖动）。
    /// 直接落到夹取后的稳态矩形，一次到位、无回弹。屏幕取目标窗口实际所在的那块（多屏下
    /// 前台窗口未必在 NSScreen.main 上），与 `adjustWindow` 同源。
    func maximizeFrontmostWindow() {
        // 四个 guard 都是「静默返回」，出问题时无从判断卡在哪一环，故每处留一条 dbg
        // （SIDEST_DEBUG=1 才写 stderr，发布版默认无输出）。
        guard Self.isTrusted() else { dbg("maximize: AX 未授权"); return }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication else {
            dbg("maximize: 取不到前台应用")
            return
        }
        guard front.processIdentifier != ownPid else {
            // 前台是我们自己（设置窗/各类对话框打开时会 NSApp.activate），此时「其他窗口」
            // 无从确定。侧栏显隐已不再激活进程，所以正常点按钮不会走到这里。
            dbg("maximize: 前台就是我们自己 pid=\(ownPid)，无目标可最大化")
            return
        }
        guard let window = frontmostWindow(axElement(pid: front.processIdentifier)) else {
            dbg("maximize: \(front.localizedName ?? "?") pid=\(front.processIdentifier) 取不到 AX 窗口")
            return
        }
        var windowScreen: NSScreen?
        if let pos = getPoint(window, kAXPositionAttribute as CFString),
           let size = getSize(window, kAXSizeAttribute as CFString) {
            windowScreen = screenForWindow(pos: pos, size: size)
        }
        guard let screen = windowScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            dbg("maximize: 取不到屏幕")
            return
        }

        let f = screen.frame
        let vf = screen.visibleFrame
        let (li, ri) = insets(for: screen)
        // 工作区（左下原点）→ AX（左上原点）：x = 工作区左边 + 左侧栏保留位；y = 屏幕顶到工作区顶（菜单栏高度）。
        let x = vf.minX + li
        let y = f.maxY - vf.maxY
        let width = max(vf.width - li - ri, 120)
        let height = vf.height
        dbg("maximize: \(front.localizedName ?? "?") → x=\(x) y=\(y) w=\(width) h=\(height) insets=(\(li),\(ri))")
        setPoint(window, kAXPositionAttribute as CFString, CGPoint(x: x, y: y))
        setSize(window, kAXSizeAttribute as CFString, CGSize(width: width, height: height))
    }

    /// 前台应用的聚焦窗口，取不到焦点窗口时回落到第一个窗口。
    private func frontmostWindow(_ axApp: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused {
            return (focused as! AXUIElement)
        }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    // MARK: - Fullscreen detection (drives bar auto-hide)

    private func refreshFullscreen() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            setFullscreen(false)
            return
        }
        let axApp = axElement(pid: front.processIdentifier)

        var fs = false
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused {
            fs = isFullscreen(focused as! AXUIElement)
        } else {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let windows = ref as? [AXUIElement] {
                fs = windows.contains { isFullscreen($0) }
            }
        }
        setFullscreen(fs)
    }

    private func setFullscreen(_ value: Bool) {
        guard value != fullscreen else { return }
        fullscreen = value
        onFullscreenChange?(value)
    }

    private func isFullscreen(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success else {
            return false
        }
        return (ref as? Bool) ?? false
    }

    // MARK: - AXValue helpers

    private func getPoint(_ e: AXUIElement, _ attr: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr, &ref) == .success, let ref else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private func getSize(_ e: AXUIElement, _ attr: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr, &ref) == .success, let ref else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    private func setPoint(_ e: AXUIElement, _ attr: CFString, _ p: CGPoint) {
        var pt = p
        if let v = AXValueCreate(.cgPoint, &pt) {
            let err = AXUIElementSetAttributeValue(e, attr, v)
            dbg("setPoint \(pt) -> \(err.rawValue)")
        }
    }

    private func setSize(_ e: AXUIElement, _ attr: CFString, _ s: CGSize) {
        var sz = s
        if let v = AXValueCreate(.cgSize, &sz) {
            let err = AXUIElementSetAttributeValue(e, attr, v)
            dbg("setSize \(sz) -> \(err.rawValue)")
        }
    }
}

private let debugEnabled = ProcessInfo.processInfo.environment["SIDEST_DEBUG"] != nil
private func dbg(_ msg: String) {
    if debugEnabled { FileHandle.standardError.write(Data("[SidestMac] \(msg)\n".utf8)) }
}

/// Refcon payload handed to each app's AXObserver callback.
private final class ObserverContext {
    let pid: pid_t
    weak var manager: WindowManager?
    init(pid: pid_t, manager: WindowManager) {
        self.pid = pid
        self.manager = manager
    }
}
