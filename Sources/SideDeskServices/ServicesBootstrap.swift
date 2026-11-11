import Foundation
import SideDeskCore

/// 服务层组合根登记入口。对应 C# 启动期把各 Manager 注册进 `AppContainer` 的那一步。
///
/// 与 `SideDeskCore.CompositionRoot`（平台原生接缝协议 → 实现的登记，T4）分工不同：
/// 本文件登记的是平台无关服务（SideDeskServices 里的具体类型）。Core 无法反向依赖
/// Services，故 Services 侧自持登记入口，由可执行壳启动时调用。
public enum ServicesBootstrap {

    /// 登记服务层默认单例（延迟构造：首次 `resolve` 时才触发加载）。
    public static func registerDefaults() {
        // 设置接缝：账号 id 提供器即登录作用域来源（未登录 → "local"）。
        LocalDbService.accountUserIdProvider = { Seam.settings.AccountUserId }

        // 窗口配置管理器：加载走 SQLite；空库首启播种示例面板。
        AppContainer.shared.register(WindowConfigManager.self) {
            let mgr = WindowConfigManager.Load()
            mgr.EnsureDefault()
            return mgr
        }
        // 快捷分组门面：注入全局配置管理器（对应 C# WindowConfigManager.Load 里 QuickGroupService.Init）。
        AppContainer.shared.register(QuickGroupService.self) {
            let svc = QuickGroupService()
            if let mgr = AppContainer.shared.resolve(WindowConfigManager.self) { svc.Init(mgr) }
            return svc
        }
        // 全局便签服务。
        AppContainer.shared.register(StickyNoteService.self) { StickyNoteService() }
        // 数据变量手动值层（外部写入的变量值，优先于轮询/聚合）。
        AppContainer.shared.register(ManualVariableStore.self) { ManualVariableStore() }

        // 数据轮询服务（对应 C# AppBootstrap 登记 + SyncFromConfigs 启动调用）。
        AppContainer.shared.register(DataPollingService.self) {
            let svc = DataPollingService()
            svc.manualStore = AppContainer.shared.resolve(ManualVariableStore.self)
            // 变量集虚拟项兜底：延迟解析，避免两个服务构造期互相等待
            svc.variableSetItemProvider = { AppContainer.shared.resolve(VariableSetService.self)?.findItem(byVarKey: $0) }
            svc.variableSetItemsProvider = { AppContainer.shared.resolve(VariableSetService.self)?.getItems() ?? [] }
            // API 直连取数通道：`ApiMethod` 非空的项不经浏览器（此前只登记了 CDP，API 卡片取不到数）
            svc.apiEngine = ApiEngine()
            // CDP 取数通道：浏览器配置解析 + 进程/隐藏窗口记账由引擎持有，服务只负责调度与落值
            let browserConfig = BrowserConfigResolver()
            browserConfig.registryProvider = { AppContainer.shared.resolve(ProgramRegistryManager.self) }
            svc.cdpEngine = CdpPollEngine(service: svc, channel: BrowserChannel(), browserConfig: browserConfig)
            if let mgr = AppContainer.shared.resolve(WindowConfigManager.self) { svc.syncFromConfigs(mgr) }
            return svc
        }

        // 后端只读接口（变量集拉取的两个来源）。
        AppContainer.shared.register(DataVariableService.self) { DataVariableService() }
        AppContainer.shared.register(TeamService.self) { TeamService() }

        // 云同步（结构对账 + 行级增量）。须在 AccountService 之前登记：后者工厂接线起停接缝。
        AppContainer.shared.register(CloudSyncService.self) { CloudSyncService() }

        // 后端 WS 事件分发（团队/分享即时清理 + 成员对账）。依赖经组合根延迟解析，登记顺序不敏感。
        AppContainer.shared.register(BackendEventDispatcher.self) { BackendEventDispatcher() }
        // 后端长连接：消息 → 分发器；连接建立 → 团队身份兜底对账
        // （对应 C# OnBackendWsMessage / OnBackendWsConnected；通知中心同步未移植，缺席）。
        AppContainer.shared.register(BackendWebSocketService.self) {
            let svc = BackendWebSocketService()
            svc.MessageReceived = { text in
                Task { await AppContainer.shared.resolve(BackendEventDispatcher.self)?.handle(text) }
            }
            svc.Connected = {
                Task { await AppContainer.shared.resolve(BackendEventDispatcher.self)?.reconcileTeamMembership() }
            }
            return svc
        }

        // 账号与本人资料（登录/登出/Token 校验/头像昵称同步）。
        AppContainer.shared.register(AccountService.self) {
            let svc = AccountService()
            svc.webSocketStart = { token in AppContainer.shared.resolve(BackendWebSocketService.self)?.Start(token) }
            svc.cloudSyncStart = { AppContainer.shared.resolve(CloudSyncService.self)?.start() }
            svc.cloudSyncStop = { AppContainer.shared.resolve(CloudSyncService.self)?.stop() }
            svc.cloudSyncReconcile = { pushLocal in
                Task { _ = await AppContainer.shared.resolve(CloudSyncService.self)?.reconcile(pushLocal: pushLocal) }
            }
            return svc
        }
        AppContainer.shared.register(ProfileService.self) { ProfileService() }

        // 变量集聚合：定义来自窗口配置；运行值/广播接到轮询服务（对应 C# 双向订阅）。
        AppContainer.shared.register(VariableSetService.self) {
            let svc = VariableSetService()
            svc.setsProvider = { AppContainer.shared.resolve(WindowConfigManager.self)?.VariableSets ?? [] }
            // 云端来源（C# 在 PullRemoteAsync 内自行 Resolve 两个服务，此处经组合根注入）
            svc.cloudListProvider = { corpId in
                await AppContainer.shared.resolve(DataVariableService.self)?.listSetsAsync(corpId: corpId)
            }
            svc.teamsProvider = {
                await AppContainer.shared.resolve(TeamService.self)?.listTeamsAsync()
            }
            if let store = AppContainer.shared.resolve(ManualVariableStore.self) {
                svc.manualValueProvider = { store.get($0) }
            }
            // 运行中变量：VarKey -> 该名下的全部运行值（同名重复变量的多个值都参与聚合）
            svc.runningValuesProvider = {
                var map: [String: [String]] = [:]
                for item in AppContainer.shared.resolve(DataPollingService.self)?.getAllItems() ?? [] {
                    guard let vk = item.VarKey, !vk.isEmpty else { continue }
                    map[vk.lowercased(), default: []].append(item.Value)
                }
                return map
            }
            svc.publishUpdate = { itemId, value in
                AppContainer.shared.resolve(DataPollingService.self)?.publishUpdate(itemId: itemId, value: value)
            }
            svc.rebuild()
            // C# `Init` 的驱动两步：订阅数据更新（同一轮合并重算）+ 5 秒兜底定时重算
            if let poll = AppContainer.shared.resolve(DataPollingService.self) {
                poll.addDataUpdatedObserver { [weak svc] id, value in svc?.onDataUpdated(id, value) }
            }
            svc.startFallbackTimer()
            return svc
        }
    }

    /// 登记宿主已加载的运行时实例。对应 C# `AppBootstrap.RegisterRuntimeInstances`。
    ///
    /// 为什么单列一步：服务工厂是延迟的，若让工厂自己 `Load()`，宿主与service 各拿一份实例，
    /// UI 改动就不会反映到服务侧（C# 的 #334 教训：加载必须前移到服务首次构造之前，且全进程一份）。
    /// 因此设置与程序注册表都由宿主加载后注入，`Seam` 与容器指向同一对象。
    public static func registerRuntimeInstances(_ settings: Settings, _ programRegistry: ProgramRegistryManager) {
        AppContainer.shared.registerInstance(Settings.self, settings)
        AppContainer.shared.registerInstance(ProgramRegistryManager.self, programRegistry)
        Seam.settings = settings
        Seam.programRegistry = programRegistry
    }
}
