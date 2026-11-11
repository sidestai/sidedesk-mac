import Foundation

/// 组合根装配入口：把服务与原生接缝实现登记进 `AppContainer.shared`。
///
/// 对应 Windows C# 的 `Composition.AppBootstrap.RegisterDefaults()`——单一出处，
/// 应用壳启动时调用一次。随移植推进，领域服务（T2/T3）与 macOS 原生接缝
/// 实现（T4：Keychain / NSPasteboard / CGEventTap / AVAudioEngine /
/// SFSpeechRecognizer / LaunchAgent）都在此处登记，UI 与业务层只依赖协议接缝，
/// 不直接 new 平台对象（依赖倒置，与 Windows 分层决定一致）。
public enum CompositionRoot {

    /// 登记所有默认服务 / 接缝。当前为骨架：壳已就绪但尚无服务，
    /// 后续任务在此逐条 `AppContainer.shared.register(...)`。
    public static func registerDefaults() {
        // 例（后续任务启用）：
        //   AppContainer.shared.register(ISecretProtector.self) { KeychainSecretProtector() }
        //   AppContainer.shared.registerInstance(AppSettings.self, loadedSettings)
    }
}
