import AppKit
import Sparkle
import SideDeskCore
import SideDeskServices

/// 自动更新（对应 C# `Services/VelopackUpdateService` 的流程 + `AboutSettingsViewModel` 的更新卡）。
/// macOS 侧框架换成 Sparkle 2（#63），映射关系：
///  - `SimpleWebSource(.../updates)` 的 `RELEASES` 清单 → appcast.xml，由 Info.plist `SUFeedURL` 指定
///  - Velopack 包签名 → Sparkle EdDSA 签名，公钥在 Info.plist `SUPublicEDKey`
///  - `StartSilentUpdateCheckAndDownloadAsync` → 启动时 `checkForUpdatesInBackground()` + `SUAutomaticallyUpdate`
///  - `EnableAutoUpdate` → `automaticallyChecksForUpdates`（持久化源仍是 app-settings.json，同 C#）
///  - `ApplyAndRestart` → `willInstallUpdateOnQuit` 交回的立即安装句柄
///  - `RuntimeMode.IsDev` / `UpdateManager.IsInstalled` 跳过 → `RuntimeMode.isDev` / `isTestMode` 跳过
///
/// 一处必然差异：Velopack 回调给百分比、Sparkle 的下载进度只画在它自己的 UI 里（委托协议没有
/// 逐字节回调），故关于页的进度区是不确定态进度条，不是 C# 的数字百分比。
@MainActor
final class UpdateService: NSObject, ObservableObject {

    /// 全局唯一更新器（对应 C# 组合根里 `VelopackUpdateService` 的单例身份：宿主、托盘与关于页取同一实例）。
    /// 惰性初始化：首次取用发生在启动流程里，此时 `Seam.settings` 已就绪。
    static let shared = UpdateService()

    /// 状态行（初值与 C# 一致：`settings.checkUpdateAction`）
    @Published private(set) var statusText = Lang.t("settings.checkUpdateAction")
    @Published private(set) var isBusy = false
    @Published private(set) var isUpdateReady = false
    /// 下载进度区可见（对应 C# `AboutSettingsViewModel.DownloadProgressVisible`：
    /// 确认有新版并已开始下载 → 可见；下载完成或失败 → 收起）。
    @Published private(set) var isDownloading = false

    /// 「启动时自动检测和下载更新」（对应 C# `AutoUpdateEnabled`，切换即落盘）
    @Published var autoUpdateEnabled: Bool {
        didSet {
            guard autoUpdateEnabled != oldValue else { return }
            Seam.settings.EnableAutoUpdate = autoUpdateEnabled
            Seam.settings.Save()
            applyAutoUpdateFlag()
        }
    }

    private var controller: SPUStandardUpdaterController?

    /// Sparkle 交回的「立即安装并重启」句柄（对应 C# `ApplyAndRestart` 的 mac 等价物）。
    /// 只在拿到更新、且我们接管安装时才有值。
    private var immediateInstall: (() -> Void)?

    override init() {
        autoUpdateEnabled = Seam.settings.EnableAutoUpdate
        super.init()
    }

    /// 起更新器（对应 C# `App.OnStartup` 里解析服务 + 订阅 + 静默检查那一段）。
    /// dev / test-mode 不起表：C# 同处理由跳过调试期的自动更新重启。
    func start() {
        guard !RuntimeMode.isDev, !RuntimeMode.isTestMode else {
            RuntimeLog.info("update", "跳过自动更新（\(RuntimeMode.name) 模式）")
            return
        }
        // `SPUUpdater.delegate` 只能在初始化时传入，故 self 就绪后才建控制器；
        // `startingUpdater: false` 让我们先同步开关再启动，免得用 Sparkle 自己存的旧值跑一轮检查。
        let updater = SPUStandardUpdaterController(startingUpdater: false,
                                                   updaterDelegate: self, userDriverDelegate: nil)
        controller = updater
        applyAutoUpdateFlag()
        updater.startUpdater()
        RuntimeLog.info("update", "Sparkle 更新器已启动; feed=\(Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "无")"
                        + " 公钥=\(Bundle.main.infoDictionary?["SUPublicEDKey"] == nil ? "缺失" : "已内置")"
                        + " 自动检查=\(Seam.settings.EnableAutoUpdate)")
        // 「每次启动都静默检查」是 C# 的行为；Sparkle 默认按 `SUScheduledCheckInterval` 定时，
        // 官方文档指明：想在每次启动都查，就在起表后立即调这一句。
        if Seam.settings.EnableAutoUpdate {
            isBusy = true
            updater.updater.checkForUpdatesInBackground()
        }
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// 用户主动检查（对应 C# `CheckUpdateCommand`：检查到新版本即开始下载，界面由 Sparkle 承担）。
    func checkForUpdates() {
        guard let updater = controller?.updater else {
            statusText = Lang.t("update.updateManagerNotInitialized")
            return
        }
        statusText = Lang.t("update.checkingForUpdates")
        isBusy = true
        isUpdateReady = false
        isDownloading = false
        updater.checkForUpdates()
    }

    /// 应用更新并重启（对应 C# `ApplyUpdateAndRestart`：没有就绪更新时提示而非静默返回）。
    func applyAndRestart() {
        guard let install = immediateInstall else {
            showNotice(Lang.tf("settings.noUpdateInformationFound"))
            return
        }
        install()
    }

    // MARK: - 开关同步

    /// 把「启动时自动检测和下载更新」同步给 Sparkle（值不同才写，避免覆盖用户其它偏好）。
    private func applyAutoUpdateFlag() {
        guard let updater = controller?.updater else { return }
        if updater.automaticallyChecksForUpdates != autoUpdateEnabled {
            updater.automaticallyChecksForUpdates = autoUpdateEnabled
        }
        if updater.automaticallyDownloadsUpdates != autoUpdateEnabled {
            updater.automaticallyDownloadsUpdates = autoUpdateEnabled
        }
    }

    private func showNotice(_ text: String) {
        let alert = NSAlert()
        alert.messageText = Lang.t("common.notice")
        alert.informativeText = text
        alert.runModal()
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateService: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusText = Lang.tf("update.newVersionFound", item.displayVersionString)
        // Sparkle 确认新版本后即开始下载（对应 C# 检查到新版本就跟着起下载）
        isDownloading = true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        // 只有「确实没有新版本」才报最新；网络/解析错误留给 `didFinishUpdateCycle` 统一转文案。
        if (error as NSError).code == SUError.noUpdateError.rawValue {
            statusText = Lang.t("update.alreadyLatest")
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        isDownloading = false
        isUpdateReady = true
        statusText = Lang.tf("update.updateReady", item.displayVersionString)
        // 对应 C# `UpdateReadyChanged` → 托盘气泡。mac 端通知中心子系统未移植（需签名 entitlement），
        // 先落日志 + 状态行，关于页出现「立即重启并应用」。
        RuntimeLog.info("update", "新版本已下载就绪: \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        isDownloading = false
        statusText = Lang.tf("update.failedToDownloadUpdate", (error as NSError).localizedDescription)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        statusText = Lang.t("update.applyingUpdateRestartingSoon")
    }

    /// 接管安装时机（对应 C# 的「应用更新并重启」按钮）：返回 YES 表示由我们调 `immediateInstallHandler`。
    /// 注意即便如此，Sparkle 仍会在进程退出时兜底安装，用户不点按钮也不会丢更新。
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        immediateInstall = immediateInstallationBlock
        isDownloading = false
        isUpdateReady = true
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        isBusy = false
        isDownloading = false
        // C# 检查完在 finally 里按 `IsUpdateReady` 复原就绪区；mac 侧同一个事实看立即安装句柄。
        if immediateInstall != nil {
            isUpdateReady = true
        }
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue {
            // 对应 C# 的 catch → RuntimeLog.Error；feed 404 / 无公钥 / 网络失败都走这里。
            RuntimeLog.warn("update", "更新周期失败: \((error as NSError).code) \((error as NSError).localizedDescription)")
            statusText = Lang.tf("settings.checkFailed", (error as NSError).localizedDescription)
        }
    }
}
