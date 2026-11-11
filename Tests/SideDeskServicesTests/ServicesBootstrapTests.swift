import XCTest
@testable import SideDeskServices
import SideDeskCore

/// T3 收口验收：服务层组合根登记 + 公开 Load()/EnsureDefault() 端到端跑通真实文件 DB。
final class ServicesBootstrapTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-bootstrap-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        LocalDbService.dirOverride = dir
        LocalDbService.accountUserIdProvider = nil
        AppContainer.shared.reset()
        Seam.resetSettings()
        Seam.resetProgramRegistry()
    }

    override func tearDown() {
        AppContainer.shared.reset()
        Seam.resetSettings()
        Seam.resetProgramRegistry()
        LocalDbService.dirOverride = nil
        LocalDbService.accountUserIdProvider = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    func testRegisterResolvesLoadedManagerWithSeededBar() {
        ServicesBootstrap.registerDefaults()
        let mgr = AppContainer.shared.resolve(WindowConfigManager.self)
        XCTAssertNotNil(mgr)
        XCTAssertEqual(mgr?.Windows.count, 1, "空库首启应播种一个示例 bar")
        XCTAssertTrue(LocalDbService.dbExists, "EnsureDefault 落库应创建 sidedesk.db")
    }

    func testLoadedIsSingleton() {
        ServicesBootstrap.registerDefaults()
        let a = AppContainer.shared.resolve(WindowConfigManager.self)
        let b = AppContainer.shared.resolve(WindowConfigManager.self)
        XCTAssertTrue(a === b, "工厂应只构造一次并缓存")
    }

    func testPollingServiceHasFetchEnginesWired() {
        ServicesBootstrap.registerDefaults()
        let svc = AppContainer.shared.resolve(DataPollingService.self)
        XCTAssertNotNil(svc?.apiEngine, "API 卡片不经浏览器取数，漏登记就永远显示初始值")
        XCTAssertNotNil(svc?.cdpEngine, "CDP 模式取数引擎须在组合根登记")
    }

    /// 变量集聚合的驱动接线（对应 C# `Init`）：构造即订阅数据更新，漏接则聚合变量只在启动算一次。
    func testVariableSetServiceSubscribesToPollingUpdates() {
        ServicesBootstrap.registerDefaults()
        _ = AppContainer.shared.resolve(VariableSetService.self)
        let poll = AppContainer.shared.resolve(DataPollingService.self)
        XCTAssertFalse(poll?.DataUpdated.isEmpty ?? true, "变量集聚合未订阅 DataUpdated")
    }

    /// 云端变量集拉取的两个后端来源须在组合根可解析，否则 `pullRemote` 永远拿到 nil。
    func testCloudVariableSetSourcesRegistered() {
        ServicesBootstrap.registerDefaults()
        XCTAssertNotNil(AppContainer.shared.resolve(DataVariableService.self))
        XCTAssertNotNil(AppContainer.shared.resolve(TeamService.self))
    }

    func testPublicLoadReloadsPersistedState() {
        ServicesBootstrap.registerDefaults()
        let mgr = AppContainer.shared.resolve(WindowConfigManager.self)!
        // 追加一个 bar 并改名 dock 持久化
        let extra = WindowConfig(); extra.Id = "bar-extra"; extra.Name = "Work"; extra.ShowInTabs = true
        mgr.AddToAllDocks(extra)

        // 全新实例走公开 Load()（非直接 loadManager）应重读到落库状态
        let reloaded = WindowConfigManager.Load()
        XCTAssertEqual(reloaded.Windows.count, 2)
        XCTAssertNotNil(reloaded.GetById("bar-extra"))
        XCTAssertTrue(reloaded.LeftDock.WindowIds.contains("bar-extra"))
    }

    // MARK: - 运行时实例登记（对应 C# RegisterRuntimeInstances）

    /// 宿主加载的设置与程序注册表必须与容器、`Seam` 指向同一实例：
    /// 各拿一份的话，UI 改了设置/登记表，服务侧读不到。
    func testRegisterRuntimeInstancesSharesOneInstance() {
        let settings = Settings()
        settings.AccountUserId = "u9"
        let registry = ProgramRegistryManager()
        ServicesBootstrap.registerRuntimeInstances(settings, registry)

        XCTAssertTrue(AppContainer.shared.resolve(Settings.self) === settings)
        XCTAssertTrue(AppContainer.shared.resolve(ProgramRegistryManager.self) === registry)
        XCTAssertTrue(Seam.settings === settings)
        XCTAssertTrue(Seam.programRegistry === registry)
    }

    /// 登记后 CDP 的浏览器解析才拿得到可执行文件与 userData——此前注册表无人登记，
    /// 指定了 BrowserId 的卡片一律静默回落默认浏览器。
    func testRegisteredRegistryFeedsBrowserConfigResolution() {
        ServicesBootstrap.registerDefaults()

        let browser = BrowserConfig()
        browser.Id = "b1"; browser.ExePath = "/Applications/Chrome.app"
        let profile = UserDataProfile()
        profile.Id = "p1"; profile.Directory = "/tmp/profile-p1"
        browser.Profiles = [profile]
        let registry = ProgramRegistryManager()
        registry.Browsers = [browser]
        ServicesBootstrap.registerRuntimeInstances(Settings(), registry)

        // 与 ServicesBootstrap 里 DataPollingService 工厂同一份 provider 闭包
        let resolver = BrowserConfigResolver()
        resolver.registryProvider = { AppContainer.shared.resolve(ProgramRegistryManager.self) }
        resolver.defaultBrowserExe = { "/usr/bin/false" }

        let item = DataDashboardItem(); item.BrowserId = "b1"; item.ProfileId = "p1"
        let cfg = resolver.resolve(item, Seam.settings)
        XCTAssertEqual(cfg.exePath, "/Applications/Chrome.app")
        XCTAssertEqual(cfg.userDataDir, "/tmp/profile-p1")

        // 未指定 BrowserId 仍走默认浏览器（回落语义没被登记动作改变）
        let plain = DataDashboardItem()
        XCTAssertEqual(resolver.resolve(plain, Seam.settings).exePath, "/usr/bin/false")
    }
}
