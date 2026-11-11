import Foundation
import SideDeskCore

/// 浏览器进程启动与"后台隐藏窗口"登记：CDP 通道与扩展通道共用的一层。
/// 对应 C# `DataPollingService` 的 `LaunchHiddenBrowserAsync` / `LaunchAppModeProcess` /
/// `_appModeHiddenHwnds` 那一组成员（Win32 句柄在 macOS 无对应物，这里改为按进程/PID 记账）。
///
/// **平台接缝**：Windows 用 `ShowWindow(SW_HIDE)` + 窗口枚举白名单把自动打开的窗口压回隐藏；
/// macOS 没有等价的无权限做法，本层用两条可用手段：
/// 1. 启动即落屏外 `--window-position=-32000,-32000`（Chromium 系浏览器在 mac 同样消费该开关）；
/// 2. `windowHider` 接缝（T4 注入 NSRunningApplication/AX 隐藏实现）——缺省 no-op，
///    与 C# "没有 UI 宿主就短路" 的接缝纪律一致。
public final class BrowserChannel {

    /// 与 HTTP 抓取共用的普通 UA：headless 默认 UA 含 HeadlessChrome，部分站点边缘层直接 403。
    /// 对应 C# `FaviconService.NormalUserAgent`（Windows 串换成 mac 串，保持"真实浏览器 UA"意图）。
    public static let normalUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    // MARK: - 平台接缝（宿主启动时注入；缺省为可运行的 Foundation 实现）

    /// 默认浏览器可执行文件路径解析（对应 C# 注册表 UserChoice 读取）。
    /// 缺省实现：`SIDESK_BROWSER_PATH` 环境变量 > Chromium 系常见安装路径 > 空串（视为无浏览器）。
    public static var defaultBrowserResolver: () -> String = BrowserChannel.findDefaultBrowserExe

    /// 把一个已启动进程的窗口隐藏（对应 `ShowWindow(SW_HIDE)`）。缺省 no-op，由 T4 注入。
    public static var windowHider: (pid_t) -> Void = { _ in }

    /// 进程是否存活（对应 `IsWindow`）。缺省用 `kill(pid, 0)` 探测。
    public static var processAlive: (pid_t) -> Bool = { kill($0, 0) == 0 }

    // MARK: - 记账

    /// 自动打开的后台窗口记录：所属看板分组 + 承载 URL + 进程 PID（用于复活检测与关闭）
    public struct HiddenWindow {
        public let groupKey: String
        public let urls: [String]
        public let pid: pid_t
        public let process: Process?
    }

    private var hiddenWindows: [String: HiddenWindow] = [:]      // key = groupKey|urls 哈希用的记录 id
    private var launchedProcesses: [Process] = []
    private let lock = NSLock()

    public init() {}

    /// 自启动隐藏浏览器（headless 或屏外窗口模式）。对应 C# `LaunchHiddenBrowserAsync` 的进程启动部分。
    /// 返回已启动进程；CDP 就绪探测与建连由调用方完成（失败时调用方负责终止进程）。
    public func launchHiddenBrowser(exePath: String, userDataDir: String, port: Int, url: String, mode: String, key: String) -> Process? {
        // 未指定 userData 目录时使用专属目录，避免与用户正在使用的浏览器冲突
        var dataDir = userDataDir
        if dataDir.isEmpty {
            dataDir = Self.headlessProfileRoot() + "/" + key.replacingOccurrences(of: "_", with: "-")
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        }

        var args: [String]
        if mode == "headless" {
            args = ["--headless=new", "--user-agent=\(Self.normalUserAgent)",
                    "--remote-debugging-port=\(port)", "--user-data-dir=\(dataDir)",
                    "--no-first-run", "--no-default-browser-check", "--disable-extensions"]
        } else {
            // 非 headless：mac 无 SW_HIDE，用屏外位置近似"隐藏"
            args = ["--remote-debugging-port=\(port)", "--user-data-dir=\(dataDir)",
                    "--no-first-run", "--no-default-browser-check", "--window-position=-32000,-32000"]
        }
        if !url.isEmpty { args.append(url) }
        return launch(exePath: exePath, args: args)
    }

    /// 在已运行的浏览器里打开目标页窗口（app 窗口 / 新窗口多 tab）。
    /// 对应 C# `LaunchAppModeProcess`：`useNewWindow` 时一个 `--new-window` 窗口内开多 URL 作多 tab。
    public func launchAppWindow(exePath: String, userDataDir: String, urls: [String], groupKey: String,
                                useNewWindow: Bool, hideWindow: Bool) -> Process? {
        guard let first = urls.first else { return nil }
        var args: [String] = useNewWindow
            ? ["--new-window"] + urls
            : ["--app=\(first)"]
        if hideWindow { args.append("--window-position=-32000,-32000") }
        if !userDataDir.isEmpty { args.append("--user-data-dir=\(userDataDir)") }

        guard let proc = launch(exePath: exePath, args: args) else { return nil }
        if hideWindow {
            let record = HiddenWindow(groupKey: groupKey.isEmpty ? "solo:" + first : groupKey,
                                      urls: urls, pid: proc.processIdentifier, process: proc)
            lock.lock()
            hiddenWindows[record.groupKey] = record
            lock.unlock()
            // 窗口出现后压回隐藏（接缝未注入时依赖屏外位置）
            DispatchQueue.global().async {
                for i in 0..<60 {
                    if proc.isRunning == false { return }   // 已委托给运行中的浏览器，窗口不归本进程管
                    Self.windowHider(proc.processIdentifier)
                    if i > 20 { usleep(200_000) } else { usleep(50_000) }
                }
            }
        }
        return proc
    }

    /// 该看板分组的后台窗口是否还活着（活着就不重复开窗）
    public func hiddenWindowAlive(groupKey: String) -> Bool {
        lock.lock()
        let hit = hiddenWindows[groupKey]
        lock.unlock()
        guard let hit else { return false }
        if let p = hit.process { return p.isRunning }
        return Self.processAlive(hit.pid)
    }

    /// 取数前把可能被浏览器重新显示的窗口再压回隐藏。对应 C# `ReassertHiddenAppWindows`。
    public func reassertHidden(url: String) {
        lock.lock()
        let targets = hiddenWindows.values.filter { $0.urls.contains { u in Self.urlMatches(u, url) } }
        lock.unlock()
        for w in targets {
            if let p = w.process {
                if !p.isRunning { removeHidden(groupKey: w.groupKey); continue }
            } else if !Self.processAlive(w.pid) {
                removeHidden(groupKey: w.groupKey)
                continue
            }
            Self.windowHider(w.pid)
        }
    }

    /// 关闭已无对应数据项的后台窗口（数据项/看板删除时清理）。对应 C# `CloseOrphanedHiddenWindows`：
    /// 分组窗口按"组是否仍有存活项"判断，solo/CDP 窗口按 URL 是否仍被引用判断。
    public func closeOrphanedWindows(liveGroupKeys: Set<String>, liveUrls: Set<String>) {
        lock.lock()
        let targets = hiddenWindows.values.filter { rec in
            if liveGroupKeys.contains(rec.groupKey) { return false }
            return !rec.urls.contains { liveUrls.contains($0.lowercased()) }
        }
        for rec in targets { hiddenWindows.removeValue(forKey: rec.groupKey) }
        lock.unlock()

        for rec in targets {
            if let p = rec.process {
                if p.isRunning { p.terminate() }
            } else if Self.processAlive(rec.pid) {
                kill(rec.pid, SIGTERM)
            }
            RuntimeLog.debug("[DataPolling] 🧹 hidden data window closed (item/dashboard removed): pid=\(rec.pid)")
        }
    }

    private func removeHidden(groupKey: String) {
        lock.lock()
        hiddenWindows.removeValue(forKey: groupKey)
        lock.unlock()
    }

    /// 记录并返回自启动的进程（供连接对象持有、断开时终止）
    private func launch(exePath: String, args: [String]) -> Process? {
        guard !exePath.isEmpty, FileManager.default.isExecutableFile(atPath: exePath) else {
            RuntimeLog.debug("[DataPolling] ✗ browser executable not found: \(exePath)")
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            RuntimeLog.debug("[DataPolling] launching browser: \(exePath) \(args.joined(separator: " "))")
            try proc.run()
            lock.lock()
            launchedProcesses.append(proc)
            lock.unlock()
            return proc
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ failed to launch browser: \(error.localizedDescription)")
            return nil
        }
    }

    /// 终止全部自启动进程并清空窗口记录。对应 C# 退出时的清理。
    public func shutdown() {
        lock.lock()
        let procs = launchedProcesses
        let records = Array(hiddenWindows.values)
        launchedProcesses.removeAll()
        hiddenWindows.removeAll()
        lock.unlock()
        for p in procs where p.isRunning { p.terminate() }
        for r in records where r.process == nil && Self.processAlive(r.pid) { kill(r.pid, SIGTERM) }
    }

    // MARK: - 路径与匹配

    /// 自启动隐藏浏览器的专属 userData 根目录（对应 C# `LocalAppData/SideDesk/HeadlessProfile`）。
    public static func headlessProfileRoot() -> String { AppPaths.dataDir + "/HeadlessProfile" }

    /// 用户数据目录根（`~/Library/Application Support`）
    static func appSupportRoot() -> String {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
         ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")).path
    }

    /// URL 归属匹配（大小写不敏感前缀，与 C# `UrlMatches` 同口径：去掉尾部斜杠后比较）
    static func urlMatches(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let y = b.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// 默认浏览器解析：环境变量优先，其次常见 Chromium 系安装位置（mac 无注册表可读）
    static func findDefaultBrowserExe() -> String {
        if let env = ProcessInfo.processInfo.environment["SIDESK_BROWSER_PATH"], !env.isEmpty { return env }
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
            "/Applications/Opera.app/Contents/MacOS/Opera",
            "/Applications/Arc.app/Contents/MacOS/Arc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}
