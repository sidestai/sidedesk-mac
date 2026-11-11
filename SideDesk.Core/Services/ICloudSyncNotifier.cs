namespace SideDesk.Services;

/// <summary>
/// 云同步行级通知接缝（分层解耦）：Windows 的 <c>WindowConfigManager.Save()</c> 在配置写库后
/// 反向调用 <c>CloudSyncService.NotifyRowsChanged()</c>（防抖推送）。CloudSyncService 本体是
/// 3000+ 行的网络同步层（且依赖 <c>System.Windows.Threading.Dispatcher</c>），不在 Phase 2
/// 存储核心的范围内。故此处只抽出被存储层消费的**通知能力**为接口：
///  - 存储层（WindowConfigManager）依赖本抽象，经 <see cref="Composition.AppContainer"/> 取用；
///  - 具体的 CloudSyncService 在后续阶段实现本接口并注册（届时另需一个跨平台 Dispatcher 接缝
///    替换 System.Windows.Threading）。
/// 未注册时存储层静默跳过通知（本地写库不受影响）。
/// </summary>
public interface ICloudSyncNotifier
{
    /// <summary>通知：行级数据已变更，触发（防抖）云推送。</summary>
    void NotifyRowsChanged();
}
