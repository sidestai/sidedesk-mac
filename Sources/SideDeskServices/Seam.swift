import Foundation
import SideDeskCore

/// 周期计时器接缝。对应 C# `IServiceTimer`。
public protocol ServiceTimer: AnyObject {
    func start()
    func stop()
}

/// 默认实现：后台串行队列上的 `DispatchSourceTimer`（对应 C# `ThreadingServiceTimer`——
/// 没有 UI 宿主也能跑，回调不绑主线程）。
public final class BackgroundTimer: ServiceTimer {
    private let interval: TimeInterval
    private let action: () -> Void
    private let queue = DispatchQueue(label: "sidedesk.service.timer", qos: .utility)
    private var source: DispatchSourceTimer?

    public init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = max(interval, 0.01)
        self.action = action
    }

    public func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeTimerSource(queue: queue)
        src.schedule(deadline: .now() + interval, repeating: interval)
        src.setEventHandler(handler: action)
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

/// 同步互斥包装：把 `lock()/unlock()` 收进非异步方法里。
///
/// 服务层的状态表既要在异步取数路径上读写、又要在回调线程里读写，`NSLock.lock()`
/// 直接出现在 async 上下文会被标记为不可用（Swift 6 是错误）；统一经 `withLock` 调用即可。
public struct SyncLock {
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 服务层静态接缝：宿主在启动时注入一次（对应 C# `ServiceSeam`）。
///
/// 纪律同 C#：只放"服务层需要、但由宿主提供"的依赖，不放业务状态。
public enum Seam {
    private static var settingsCache: Settings?

    /// 当前设置（宿主持有的那一份）。缺省惰性从磁盘加载——与 C#"没注入过就表现为一份空设置"同语义。
    public static var settings: Settings {
        get {
            if let s = settingsCache { return s }
            let s = Settings.Load()
            settingsCache = s
            return s
        }
        set { settingsCache = newValue }
    }

    /// 丢弃设置缓存（测试隔离 / 外部改盘后重载）
    public static func resetSettings() { settingsCache = nil }

    private static var programRegistryCache: ProgramRegistryManager?

    /// 程序注册表（宿主持有的那一份，对应 C# `ServiceSeam.ProgramRegistry`）。
    /// 缺省惰性从磁盘加载——与 `settings` 同一语义：没注入过也有一份可读的表。
    public static var programRegistry: ProgramRegistryManager {
        get {
            if let r = programRegistryCache { return r }
            let r = ProgramRegistryManager.Load()
            programRegistryCache = r
            return r
        }
        set { programRegistryCache = newValue }
    }

    /// 丢弃程序注册表缓存（测试隔离 / 外部改盘后重载）
    public static func resetProgramRegistry() { programRegistryCache = nil }

    /// 周期计时器工厂（UI 宿主可注入主线程实现；测试注入假计时器以确定性驱动回调）
    public static var timerFactory: (TimeInterval, @escaping () -> Void) -> ServiceTimer = {
        BackgroundTimer(interval: $0, action: $1)
    }

    /// 投递到 UI 线程（等价 `Dispatcher.BeginInvoke`）。缺省什么都不做——
    /// 与 C# 无 UI 宿主时 `Application.Current?.Dispatcher` 直接短路一致，是语义不是偷懒。
    public static var uiPost: (@escaping () -> Void) -> Void = { _ in }

    /// 当下有没有 UI 线程（调用点据此分流，见 C# `VariableSetService.OnDataUpdated`）
    public static var hasUiThread: () -> Bool = { false }

    /// 用系统默认浏览器打开 URL（等价 C# `Process.Start(UseShellExecute)`）。
    /// 缺省返回 false——无 UI 宿主时打不开浏览器，与 C# 无 shell 时降级一致。
    public static var openUrl: (URL) -> Bool = { _ in false }

    /// 账号作用域变更后重载窗口数据并重绑 UI（等价 C# `App.ReloadWindowConfigsForNewScope`
    /// 的纯重载部分）。调用前提：作用域晋升已落库。宿主未注入时静默缺席。
    public static var reloadWindowConfigs: (() -> Void)?

    /// 刷新两侧面板卡片流（等价 C# `RefreshAllWindows` + `RefreshAllWindowTabs`：
    /// 按内存树重取卡片/标签，不换管理器实例）。宿主未注入时静默缺席。
    public static var refreshAllWindows: (() -> Void)?

    /// 从容器重绑窗口数据并刷新 UI（等价 C# `ReloadWindowsUiFromConfigs`：
    /// 管理器实例已被替换后的整树重绑）。宿主未注入时静默缺席。
    public static var reloadWindowsUi: (() -> Void)?
}
