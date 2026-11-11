import AppKit
import Carbon.HIToolbox
import SideDeskCore
import SideDeskServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panels: [SidePanel] = []
    private let layoutManager = WindowManager()

    /// 悬停展开驱动器（对应 C# `AppBarHoverTimer`：每个 AppBar 一个计时器，这里合并成一条遍历面板列表）
    private var hoverTimer: HoverTimer?

    /// 系统托盘（对应 C# `_notifyIcon`）：持有引用以维持 NSStatusItem 存活
    private var tray: TrayIcon?

    /// 窗口配置（本地 SQLite 持久化的内存树）。启动期解析一次，UI（T5）后续取用同一实例。
    private var configManager: WindowConfigManager?

    /// 两侧侧栏的卡片流宿主（持有引用以维持 SwiftUI 观察的同一实例）。
    private var cardsModels: [BarCardsModel] = []

    /// 取数轮询服务（启动期解析一次；退出时按同一引用回收，避免退出路径上再触发构造）
    private var polling: DataPollingService?

    /// 变量集聚合服务（启动期解析一次并挂上驱动；持有引用以维持 5 秒兜底定时器存活）
    private var variableSets: VariableSetService?

    private var hotKeyRef: EventHotKeyRef?
    /// Ctrl+1..9 切换虚拟屏幕的 9 个热键句柄（受 `EnableWindowSwitchHotkey` 门控，默认关时为空）。
    private var windowSwitchRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    /// 热键签名（'SDMC'）与 id 分配：1 = ⌥S 显隐面板；101..109 = Ctrl+1..9 切虚拟屏幕。
    private static let hotKeySignature = OSType(0x5344_4D43)
    private static let toggleHotKeyID: UInt32 = 1
    private static let windowSwitchIDBase: UInt32 = 100   // id = base + (序号+1)
    /// 主键盘 1~9 的 ANSI 键码（注意非连续：4/5、6/7、8/9 顺序在 Carbon 里是交错的）。
    private static let numberKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
    ]

    private var userWantsPanel = true
    private var hiddenByFullscreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 测试模式布置（对应 C# OnStartup 的首步 ApplyTestMode）：目录隔离必须在组合根装配、
        // Settings.Load、日志初始化以及任何服务取路径之前完成，否则隔离失效。
        let testLaunch = Self.applyTestMode(Array(CommandLine.arguments.dropFirst()))

        // 运行时配置模板（对应 C# OnStartup 的 RuntimeConfig.WriteTemplateIfMissing）：
        // 必须在目录覆盖布置之后——test-mode 下模板写进隔离目录，不污染产品目录。
        RuntimeConfig.writeTemplateIfMissing()

        // UI 宿主接缝（对应 WPF 里 Dispatcher 恒在）：服务层据此把合并后的重算投递到主线程。
        Seam.hasUiThread = { true }
        Seam.uiPost = { DispatchQueue.main.async(execute: $0) }
        // 系统浏览器打开（OAuth 登录 / 控制台免登交接等，对应 C# Process.Start(UseShellExecute)）
        Seam.openUrl = { NSWorkspace.shared.open($0) }
        // 账号作用域变更 → 进程内重载窗口数据（登录/登出/登录态失效，对应 C# ReloadWindowConfigsForNewScope）
        Seam.reloadWindowConfigs = { [weak self] in
            MainActor.assumeIsolated { self?.reloadWindowConfigsForNewScope() }
        }
        // 云同步合并后刷新两侧卡片流与标签（对应 C# RefreshAllWindows + RefreshAllWindowTabs）
        Seam.refreshAllWindows = { [weak self] in
            MainActor.assumeIsolated { self?.cardsModels.forEach { $0.reload() } }
        }
        // 管理器内存树被整棵替换/折叠后重绑 UI（对应 C# ReloadWindowsUiFromConfigs）
        Seam.reloadWindowsUi = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for model in self.cardsModels { model.rebindManager(self.configManager) }
            }
        }

        // 组合根装配（单一出处）：登记服务与原生接缝实现，须在面板/服务取用之前。
        CompositionRoot.registerDefaults()
        ServicesBootstrap.registerDefaults()

        // 启动耗时度量起点（对应 C# OnStartup 的 bootWatch）：组合根装配之后、实际启动动作之前
        let bootStart = DispatchTime.now()

        // 上次保存的设置与程序注册表（对应 C# OnStartup 的 Settings.Load + ProgramRegistryManager.Load
        // + RegisterRuntimeInstances）：均前移到服务首次构造之前，宿主与服务层全进程共用同一实例。
        // 程序注册表此前无人登记，CDP 的浏览器可执行文件/userData 解析一直静默回落默认浏览器。
        ServicesBootstrap.registerRuntimeInstances(Settings.Load(), ProgramRegistryManager.Load())

        // 运行时日志级别（对应 C# App 启动期 ApplyConfig）：Settings.LogLevel 生效，
        // 环境变量 SIDESK_LOG_LEVEL 优先。放在词典与业务日志之前，启动期自身的记录也不漏。
        RuntimeLog.applyConfig(Seam.settings.LogLevel)

        // 启动横幅（对应 C# App.OnStartup 的 Info("startup", ...)）：版本/区域/运行模式一行看清
        RuntimeLog.info("startup", "SideDesk starting: v\(Self.appVersion) "
                       + "apiRegion=\(Constants.apiRegion) mode=\(RuntimeMode.name)")

        // 词典装载（对应 C# 启动期 Lang.Init）：设置页文案全部走 Lang。
        Lang.initialize(Seam.settings.Language)

        // 主题装载（对应 C# `App.StartupServices.cs` 的 `ApplyTheme(AppSettings.ThemeMode)`
        // 与 `ThemeManager.RestoreFromName(AppSettings.Instance.CurrentTheme)`）：
        // 必须在任何 SwiftUI 视图构造之前，否则首帧拿到的是默认深色底座。
        // C# 的 IsSystemLightTheme 查注册表，这里换成 NSApp.effectiveAppearance 接缝。
        ThemeManager.systemIsLight = {
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }

        // 环境适应层接缝（issue #48，对应 C# `InitThemeEnvironment` 的 SystemPreferences.Init）：
        // mac 无注册表/SystemParameters，三项偏好都走 NSWorkspace 无障碍选项 + NSFont 首选字号。
        SystemPreferences.systemHighContrast = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        SystemPreferences.systemReduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        SystemPreferences.systemTextScale = { NSFont.preferredFont(forTextStyle: .body).pointSize / 13.0 }
        // 高对比度系统色（对应 C# SystemColors.*）：NSColor 系统色在「增强对比度」开启时自动切到高对比变体。
        ThemeManager.systemColors = { Self.systemColorSet() }
        SystemPreferences.initialize()

        ThemeManager.initialize(themeMode: Seam.settings.ThemeMode,
                                customThemeName: AppSettings.Instance.CurrentTheme)
        // 尺寸档位（issue #48 L2）+ 高对比度接管（对应 C# UpdateTierFromSettings + ApplyHighContrast，顺序在主题之后）
        updateTierScale()
        if SystemPreferences.highContrast { ThemeManager.applyHighContrast() }
        // 原生控件（NSMenu / Picker / TextField / Toggle）只认 NSAppearance，跟着主题走而不是跟系统走。
        ThemeAppearance.install()
        // 系统无障碍选项变化（对比度/动效/文本大小）→ 重读偏好并重装环境层
        // （对应 C# `SystemPreferences.Changed += OnSystemPreferencesChanged`）。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        // 开机自启（对应 C# `ApplyRenderAndAutostart` 的 `AutoStartService.Apply(AppSettings.Instance.RunAtStartup)`）：
        // 每次启动同步一次登录项状态；设置源是 Framework.AppSettings（settings.json），
        // 不是宿主主配置 `Settings`（app-settings.json）——两份配置的分工与 C# 相同。
        // test-mode 跳过——不动用户真实登录项。C# 同处的渲染管线回退（WPF 软件渲染）与
        // DeviceId 预热（WMI）在 macOS 无对应物，不搬。
        if !RuntimeMode.isTestMode {
            AutoStartService.apply(AppSettings.Instance.RunAtStartup)
        }

        // 日志保留策略（对应 C# InitLoggingCleanup）：清掉上一轮遗留的调试日志，
        // 放在其它日志器启动之前，本次运行新写的一行不动。
        RuntimeLog.clearDebugLogsOnStartup()

        // 加载窗口配置：首启播种示例，空库兜底至少一个 bar（与 C# 启动流程一致）。
        let mgr = AppContainer.shared.resolve(WindowConfigManager.self)
        mgr?.EnsureAtLeastOneBar()
        configManager = mgr

        // 启动取数：解析即触发 SyncFromConfigs + 重建各数据源的轮询定时器（对应 C# 面板首次 Resolve 那一步）。
        polling = AppContainer.shared.resolve(DataPollingService.self)

        // 变量集聚合启动（对应 C# `Resolve<VariableSetService>().Init(WindowConfigs)`）：
        // 解析即完成订阅数据更新与挂上 5 秒兜底重算定时器（见 ServicesBootstrap）。
        variableSets = AppContainer.shared.resolve(VariableSetService.self)
        // 拉取云端登记的变量集（对应 C# `PullRemoteAsync`）：未登录/后端不可达时服务内部静默回落；
        // 测试模式不发网络请求（门控与 C# 一致）。
        if !RuntimeMode.isTestMode, let variableSets {
            Task { await variableSets.pullRemote() }
        }

        // 窗口副作用门控（对应 C#：test-mode 跳过侧栏窗口/布局监听，--test-with-bars 只恢复窗口）
        let showBars = !RuntimeMode.isTestMode || (testLaunch?.withBars ?? false)
        if showBars {
            // 首次启动（无任何显示器配置）：默认主屏左侧停靠（对应 C# `App.xaml.cs:208-210`）。
            // 侧栏宽度也一并从旧版全局值搬进每屏配置——Swift 侧与 C# 同口径，宽度取
            // `GetCurrentMonitor(0)`（见 `SidePanel.panelWidth`），全局值只是老配置兼容锚点。
            if Seam.settings.Monitors.isEmpty {
                let monitor = Seam.settings.GetMonitor(0)
                monitor.Layout = .left
                monitor.LeftPanelWidth = Seam.settings.LeftPanelWidth
                monitor.RightPanelWidth = Seam.settings.RightPanelWidth
                Seam.settings.Save()
            }

            // 卡片流宿主（对应 C# 每侧栏一个 NativeModePanel）：左右各一个，共享同一份
            // WindowConfigManager 内存树；任一侧改动 bar 后让兄弟按同一棵树重取卡片
            // （对应 C# `BroadcastBarToOtherWindows`）。
            let leftCards = BarCardsModel(edge: .left, manager: mgr)
            let rightCards = BarCardsModel(edge: .right, manager: mgr)
            cardsModels = [leftCards, rightCards]
            BarCardsModel.onBarChanged = { [weak self] in
                self?.cardsModels.forEach { $0.reload() }
            }
            panels = [SidePanel(edge: .left, cards: leftCards),
                      SidePanel(edge: .right, cards: rightCards)]
            for panel in panels {
                panel.onHideRequest = { [weak self] in self?.hidePanels() }
                panel.onMaximizeRequest = { [weak self] in self?.maximizeFrontWindow() }
            }
            // 设置页改了停靠位置/侧栏宽度 → 重排（对应 C# `GeneralSeam.ApplyPanelWidth` 尾步的
            // `Host?.ApplyPanelWidths()`）
            SettingsLauncher.onPanelGeometryChanged = { [weak self] in
                self?.applyPanelGeometry()
            }
            // 设置 → 快捷键页切了「Ctrl+数字切换窗口」开关 → 即时注册/注销全局热键
            SettingsLauncher.onWindowSwitchHotkeyChanged = { [weak self] in
                self?.applyWindowSwitchHotkey()
            }
            layoutManager.onFullscreenChange = { [weak self] isFullscreen in
                guard let self else { return }
                self.hiddenByFullscreen = isFullscreen
                self.updatePanelVisibility(animated: true)
            }
            // 让 enforcement 夹取与「最大化」按真实停靠布局保留侧栏位：只在该侧面板可见
            // 且停靠在传入的这块屏时保留其实际宽度（多屏下没有侧栏的屏返回 0，不去夹取；
            // 隐藏/未停靠的一侧同样返回 0，否则会白留 100px 死缝）。
            layoutManager.insetsProvider = { [weak self] screen in
                guard let self else { return (WindowManager.sideInset, WindowManager.sideInset) }
                var left: CGFloat = 0
                var right: CGFloat = 0
                for panel in self.panels where panel.isVisibleState && panel.screen === screen {
                    if panel.edge == .left { left = panel.panelWidth }
                    else { right = panel.panelWidth }
                }
                return (left, right)
            }
            layoutManager.start()
            updatePanelVisibility(animated: true)
            // 悬停展开（对应 C# `AppBarHoverTimer` 起表）：任一侧开了「开启浮动」才轮询，
            // 两侧都关时不占主线程定时器。
            hoverTimer = HoverTimer { [weak self] in self?.panels ?? [] }
            hoverTimer?.reload()
        }
        // 全局热键走键盘事件监听（对应 C# 的全局钩子：test-mode 不装）
        if !RuntimeMode.isTestMode {
            registerHotKey()
        }

        // 启动耗时落点：首个侧栏已让位显示（对应 C# bootWatch.Stop + Info("startup", "boot done …")）
        // test-mode 无窗口时该点是「服务就绪」，与 C# 同一口径。
        let bootMs = (DispatchTime.now().uptimeNanoseconds - bootStart.uptimeNanoseconds) / 1_000_000
        RuntimeLog.info("startup", "boot done in \(bootMs)ms "
                        + "(first bar shown\(RuntimeMode.isTestMode ? ", test-mode" : ""))")

        // 显示器变化监听（对应 C# OnStartup 尾段 SystemEvents.DisplaySettingsChanged += …）
        if !RuntimeMode.isTestMode {
            watchDisplayChanges()
        }

        // 系统托盘（对应 C# OnStartup 尾段 InitNotifyIcon，test-mode 同 C# 跳过）
        if !RuntimeMode.isTestMode {
            let tray = TrayIcon()
            tray.install()
            self.tray = tray
        }

        // 启动云同步（对应 C# `StartupServiceBootstrapper.StartCloudSync`）：仅已登录且已开启时
        // 执行启动对账；test-mode 跳过——不发网络请求。后端 WS 的事件订阅已在 ServicesBootstrap
        // 工厂接线（MessageReceived → 分发器、Connected → 团队成员对账），此处无需再订。
        if !RuntimeMode.isTestMode, Seam.settings.EnableCloudSync,
           let token = Seam.settings.AccountToken, !token.isEmpty {
            AppContainer.shared.resolve(CloudSyncService.self)?.start()
        }

        // 启动时验证 Token 有效性（对应 C# `ValidateTokenOnStartupAsync`：服务内部延迟 2 秒，
        // 避免与其他启动任务争抢网络；无 Token 时以访客身份建后端 WS）。test-mode 跳过。
        if !RuntimeMode.isTestMode {
            Task { await AppContainer.shared.resolve(AccountService.self)?.validateTokenOnStartup() }
        }

        // 自动更新（对应 C# OnStartup 尾段 `EnableAutoUpdate` 为真时的静默检查+下载，#63）
        UpdateService.shared.start()

        // test-mode 退出机制（对应 C# OnStartup 尾步）：--test-timeout <秒>（默认 60）后干净退出，
        // 让 E2E 能验证完整生命周期而不必外部 kill。
        if let testLaunch {
            RuntimeLog.info("startup", "test-mode: auto shutdown in \(testLaunch.timeoutSeconds)s "
                            + "(override with --test-timeout <seconds>)")
            let deadline = DispatchTime.now() + .seconds(testLaunch.timeoutSeconds)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                Seam.uiPost { NSApplication.shared.terminate(nil) }
                // 硬退出兜底：退出依赖 willTerminate 全链路走完，任一环挂住进程就退不出去；
                // 测试数据目录是一次性临时目录，强退无持久化风险。
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
            }
        }
    }

    /// 账号作用域变更后在进程内切换窗口数据（对应 C# `App.ReloadWindowConfigsForNewScope`）：
    /// 按新作用域重载内存树、替换容器实例、重绑两侧卡片流。调用前提：作用域晋升已落库，
    /// 否则新作用域加载会缺刚晋升的数据，随后一次保存会把它们当「已删除」打墓碑上报。
    @MainActor private func reloadWindowConfigsForNewScope() {
        let mgr = WindowConfigManager.Load()
        mgr.EnsureDefault()
        mgr.EnsureAtLeastOneBar()
        AppContainer.shared.registerInstance(WindowConfigManager.self, mgr)
        configManager = mgr
        for model in cardsModels { model.rebindManager(mgr) }
        // C# 在 WindowConfigManager.Load 内做 QuickGroupService.Init；Swift 的 Load 推迟了它，此处补上
        AppContainer.shared.resolve(QuickGroupService.self)?.Init(mgr)
        // 新作用域的数据项重建轮询（旧作用域项不再取数）
        polling?.syncFromConfigs(mgr)
    }

    /// 测试模式布置（对应 C# `App.ApplyTestMode`）：隔离数据目录并置 `RuntimeMode.isTestMode`。
    /// 未带 `--test-mode` 返回 nil，启动流程一切照旧。
    /// C# 还置了 `ProgramCategoryManager.DirOverride`——该管理器在 Swift 侧尚未移植。
    private static func applyTestMode(_ args: [String]) -> TestModeLaunch? {
        guard let plan = TestModeArgs.parse(args, tempDir: NSTemporaryDirectory()) else { return nil }
        RuntimeMode.isTestMode = true
        // 清掉上一轮的测试目录：失败静默——一次性临时数据，删不掉不该阻断启动
        try? FileManager.default.removeItem(atPath: plan.dataDir)
        AppPaths.setOverride(plan.dataDir)
        Settings.DirOverride = plan.dataDir
        LocalDbService.dirOverride = plan.dataDir
        RuntimeLog.dirOverride = (plan.dataDir as NSString).appendingPathComponent("Logs")
        RuntimeConfig.dirOverride = plan.dataDir
        return plan
    }

    // MARK: - 显示器变化

    /// 上次看到的显示器数量（变化即视为插拔屏，对应 C# `_lastMonitorCount`）
    private var lastMonitorCount = 0
    /// 防抖用一次性定时器（对应 C# 的 500ms `DispatcherTimer`：每次事件 Stop+Start）
    private var displayChangeWork: DispatchWorkItem?

    /// 挂上显示器变化监听。macOS 的对应物是 `didChangeScreenParametersNotification`
    /// —— 分辨率、缩放、显示器增删都会触发（与 C# `SystemEvents.DisplaySettingsChanged` 同范围）。
    private func watchDisplayChanges() {
        lastMonitorCount = NSScreen.screens.count
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displayParametersChanged() {
        displayChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshLayoutOnDisplayChange() }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 防抖到点后重算面板几何。对应 C# `RefreshAppBarLayoutOnDisplayChange`：
    /// 显示器数量变化（插拔）走「重建停靠窗口」分支、仅分辨率/缩放变化走「重套宽度」分支——
    /// mac 侧只有固定左右两条面板，两条分支收敛为同一动作（按新屏幕重算 frame），
    /// 计数仍要更新，否则下一次插拔会被当成"数量没变"。
    private func refreshLayoutOnDisplayChange() {
        let count = max(NSScreen.screens.count, 1)
        RuntimeLog.debug("[App] display settings changed, monitors=\(count) (last=\(lastMonitorCount))")
        lastMonitorCount = count
        applyPanelGeometry(animated: false)
    }

    /// 按当前设置重排面板（宽度 + 停靠显隐）。宽度改动与显示器变化共用这一条路径。
    private func applyPanelGeometry(animated: Bool = true) {
        // 停靠宽度变了 → 尺寸档位跟着变（issue #48 L2，对应 C# 布局重建后 UpdateTierFromSettings）
        updateTierScale()
        for panel in panels {
            panel.reposition()
        }
        updatePanelVisibility(animated: animated)
        // 悬停配置（开关 / 浮动宽度）热重载（对应 C# `GeneralSeam` 尾步的 `Host?.ReloadHoverSettings()`）
        hoverTimer?.reload()
        // `reposition()` 只改了 NSWindow 的 frame；SwiftUI 根视图的 `.frame(width: panelWidth)`
        // 是渲染期读全局配置，不重渲染就仍是旧宽（窗口变宽但彩色内容不跟着变，看起来像没生效）。
        // 档位未跨档时 `updateTierScale` 不会 fireChanged，故这里补一条外观变更广播强制重读宽度。
        ThemeManager.notifyAppearanceChanged()
    }

    // MARK: - 环境适应层（issue #48）

    /// 按当前停靠布局取静息宽度并更新字号档位（对应 C# `UpdateTierFromSettings`：Right 布局取右宽，否则左宽）。
    /// 宽度源是宿主 `Seam.settings`——Core 不依赖 Services，故读取留在宿主。
    private func updateTierScale() {
        let s = Seam.settings
        ThemeManager.updateTierScale(s.Layout == .right ? s.RightPanelWidth : s.LeftPanelWidth)
    }

    /// 系统无障碍选项变化：重读偏好，高对比度开则接管、关则恢复用户主题（对应 C# `OnSystemPreferencesChanged`）。
    @objc private func accessibilityDisplayOptionsChanged() {
        SystemPreferences.refresh()
        if SystemPreferences.highContrast {
            ThemeManager.applyHighContrast()
        } else {
            ThemeManager.reapplyNormal(themeMode: Seam.settings.ThemeMode,
                                       customThemeName: AppSettings.Instance.CurrentTheme)
        }
    }

    /// NSColor 系统色 → 高对比度色集（对应 C# `SystemColors.*`）。系统色在「增强对比度」开启时自动切高对比变体。
    private static func systemColorSet() -> SystemColorSet {
        SystemColorSet(
            window: themeColor(NSColor.windowBackgroundColor),
            text: themeColor(NSColor.labelColor),
            highlight: themeColor(NSColor.selectedContentBackgroundColor),
            highlightText: themeColor(NSColor.alternateSelectedControlTextColor),
            border: themeColor(NSColor.separatorColor),
            control: themeColor(NSColor.controlBackgroundColor),
            menu: themeColor(NSColor.windowBackgroundColor)
        )
    }

    /// NSColor → ThemeColor（转 sRGB 分量，与 WPF Color 同口径）。取不到 sRGB 表示时回落黑色。
    private static func themeColor(_ c: NSColor) -> ThemeColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return .black }
        return ThemeColor(r: rgb.redComponent * 255, g: rgb.greenComponent * 255,
                          b: rgb.blueComponent * 255, a: rgb.alphaComponent * 255)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 对应 C# `App.OnExit` 的相对顺序：先解除系统级挂接（显示器监听、托盘图标），
        // 再停服务（后端 WS → 轮询 → 布局/热键），退出前末次云同步，最后落盘缺键翻译表。
        // C# 其余退出步骤（AgentGateway/本地 WS 服务端/MCP/HTTP Server/WindowUsage）未移植，缺席。
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tray?.uninstall()

        // 停后端 WebSocket（对应 C# OnExit 托盘之后的 BackendWebSocketService.Stop）
        AppContainer.shared.resolve(BackendWebSocketService.self)?.Stop()

        // 停轮询并回收自启动的隐藏浏览器进程，否则退出后 headless 进程成为孤儿
        polling?.dispose()
        hoverTimer?.stop()
        layoutManager.stop()
        unregisterHotKey()

        // 退出前执行一次云同步备份（对应 C# OnExit：仅开启且已登录时，线程池跑、至多等 8 秒）。
        // Task.detached 不继承主线程上下文：syncNow 在协作线程池推进，信号量阻塞主线程不影响它；
        // 超时即放弃（与 C# Wait(8s) 同口径）。test-mode 跳过——与启动门控一致，零网络副作用。
        if !RuntimeMode.isTestMode, Seam.settings.EnableCloudSync,
           let token = Seam.settings.AccountToken, !token.isEmpty,
           let sync = AppContainer.shared.resolve(CloudSyncService.self) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await sync.syncNow(silent: true)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 8)
        }

        // 本次运行的缺键翻译追加写入 Logs/lang-missing.log（对应 C# OnExit 尾步 Lang.DumpMissingKeys）
        Lang.dumpMissingKeys()
    }

    /// 版本号：取 bundle 的 CFBundleShortVersionString（打包时由 Info.plist 提供）。
    /// 裸 `swift run` 没有 bundle，回落 "dev"——避免把版本号常量在 plist 之外再抄一份。
    private static let appVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    // MARK: - Panel visibility

    private var panelShouldShow: Bool { userWantsPanel && !hiddenByFullscreen }

    /// 显隐两侧面板：除了「用户想看 + 非全屏让位」，还要按停靠模式过滤该侧
    /// （对应 C# `CurrentLayout`：Left / Right / Both / None）。
    /// 侧栏几何目前只认主屏，故取显示器 0 的配置；多屏独立停靠随 T4 落地。
    private func updatePanelVisibility(animated: Bool) {
        let show = panelShouldShow
        let layout = Seam.settings.GetCurrentMonitor(0).Layout
        for panel in panels {
            let sideOn: Bool
            switch layout {
            case .both:  sideOn = true
            case .left:  sideOn = panel.edge == .left
            case .right: sideOn = panel.edge == .right
            case .none:  sideOn = false
            }
            let visible = show && sideOn
            panel.setHidden(!visible, animated: animated)
        }
        // 停靠侧变了 → 悬停起停跟着变（未停靠侧不再空轮询，重新停靠后自动起表）
        hoverTimer?.reload()
        // 刻意不 NSApp.activate：面板是 .statusBar 层级 + hidesOnDeactivate=false，显示不依赖
        // 进程激活；一激活就会抢走用户正在用的前台应用，并让侧栏「最大化」找不到目标
        // （WindowManager 要求前台不是我们自己）。C# 侧栏 ShowActivated=false 同理。
    }

    @objc fileprivate func togglePanel() {
        userWantsPanel.toggle()
        updatePanelVisibility(animated: true)
    }

    /// 侧栏「更多 → 隐藏窗口」：只关不开关（与 ⌥S 的 toggle 区分开，菜单项语义是"收起"），
    /// 再唤出仍走 ⌥S。
    private func hidePanels() {
        userWantsPanel = false
        updatePanelVisibility(animated: true)
    }

    /// 侧栏标题栏「最大化」：把前台应用窗口铺满 enforcement 允许的最大矩形（工作区扣除两侧
    /// 可见侧栏的保留位）。侧栏是不抢焦点的浮层，点按钮时前台仍是用户在用的 app。
    private func maximizeFrontWindow() {
        layoutManager.maximizeFrontmostWindow()
    }

    // MARK: - Global hot keys (⌥S 显隐 + Ctrl+1..9 切虚拟屏幕)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // 单一事件处理器分发所有热键：按事件里的 EventHotKeyID.id 路由（⌥S vs Ctrl+数字）。
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                // 热键事件在主事件循环线程投递，故可安全进入 MainActor 分发到 @MainActor 的模型
                MainActor.assumeIsolated {
                    delegate.handleHotKey(id: id.id)
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        let toggleID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.toggleHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey),
            toggleID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        // Ctrl+1..9 按设置开关决定是否注册（默认关）
        applyWindowSwitchHotkey()
    }

    /// 按 `EnableWindowSwitchHotkey` 注册/注销 Ctrl+1..9（对应 C# `GlobalHotkeyService` 的窗口切换分支）。
    /// 幂等：先清旧句柄再按当前设置重装。Carbon 热键全局吞掉该组合键（与 C# LL 钩子同口径，
    /// 可能与浏览器/编辑器的 Ctrl+数字切标签冲突——故默认关，由用户在设置里显式开启）。
    fileprivate func applyWindowSwitchHotkey() {
        for ref in windowSwitchRefs { UnregisterEventHotKey(ref) }
        windowSwitchRefs.removeAll()
        guard Seam.settings.EnableWindowSwitchHotkey else { return }
        for (index, keyCode) in Self.numberKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.hotKeySignature,
                                   id: Self.windowSwitchIDBase + UInt32(index) + 1)
            let status = RegisterEventHotKey(keyCode, UInt32(controlKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { windowSwitchRefs.append(ref) }
        }
        RuntimeLog.debug("hotkey", "window-switch hotkeys: \(windowSwitchRefs.count) registered")
    }

    /// 热键分发（在主线程回调）：id=1 → 显隐面板；101..109 → 切到第 N 个虚拟屏幕。
    @MainActor fileprivate func handleHotKey(id: UInt32) {
        if id == Self.toggleHotKeyID {
            togglePanel()
        } else if id > Self.windowSwitchIDBase && id <= Self.windowSwitchIDBase + 9 {
            switchWindowTab(Int(id - Self.windowSwitchIDBase - 1))
        }
    }

    /// Ctrl+数字 切换虚拟屏幕（对应 C# `SwitchWindowTabByHotkey`）。
    /// mac 侧栏是不抢焦点的浮层、没有 C# 的「前台窗口」概念，故把所有面板的 dock 一起切到同一序号
    /// （左右两侧呈现同一虚拟屏幕，最直观）；序号越界的面板各自忽略。
    @MainActor private func switchWindowTab(_ index: Int) {
        var switched = false
        for model in cardsModels where model.tabs.indices.contains(index) {
            model.switchToTab(index)
            switched = true
        }
        if !switched {
            RuntimeLog.debug("hotkey", "window switch → tab \(index) ignored (out of range)")
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        for ref in windowSwitchRefs { UnregisterEventHotKey(ref) }
        windowSwitchRefs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
