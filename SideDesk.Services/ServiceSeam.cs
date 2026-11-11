using System;
using System.Threading.Tasks;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// **服务层的静态接缝**：宿主在启动时把服务层需要的运行时依赖注入一次（#670）。
///
/// <para><b>为什么需要它</b>：一批服务的读取路径是**静态方法链**（<c>private static string GetToken()</c>
/// → <c>CreateRequest</c> → …），改成构造函数注入会把整条链的调用者一起改掉（级联到几十处）。
/// 而它们的实际诉求只有一件：读当前设置。这类"服务层要、但由宿主提供"的东西，
/// 仓内的既有做法就是**静态接缝 + 启动注入**——
/// <c>PluginInstallPipeline.UiDispatcher</c>、<c>PluginMarketBridge.GetAccountToken</c> 都是这么接的
/// （见 <see cref="Composition.AppBootstrap"/> 的 <c>WireUiCallbacks</c>）。本条把同一做法收成一处。</para>
///
/// <para><b>与 <c>I*Seam</c> 那一族的区别</b>：`IAccountSeam` / `IGeneralSeam` 是**面向 VM 的接口**
/// （为单测注入替身），实例化、按需替换；本类面向**服务层的静态链**，进程级注入一次。
/// 两者解决的不是同一个问题，别混用。</para>
///
/// <para><b>纪律</b>：只放"服务层需要、宿主才知道"的依赖；**不**在这里塞业务状态。
/// 新增一项时同步 <see cref="Composition.AppBootstrap"/> 的注入点与 <c>docs/registry.json</c>。</para>
/// </summary>
public static class ServiceSeam
{
    /// <summary>
    /// 当前设置（宿主持有的那一份实例；组合根在 <c>RegisterRuntimeInstances</c> 注入）。
    ///
    /// <para>缺省是**空设置**而不是 <c>null</c>：取值点遍布各服务的静态方法，与其每处判空，
    /// 不如让"没注入过"表现为一份空设置（读出来是默认值）。测试替身直接赋值即可。</para>
    /// </summary>
    public static Settings Settings { get; set; } = new();

    /// <summary>
    /// **同步**切 UI 线程（等价 <c>Dispatcher.Invoke</c>）。宿主持有 Dispatcher 时注入真实现。
    ///
    /// <para><b>缺省是"什么都不做"</b>——这不是偷懒，是**忠实**：既有代码写的是
    /// <c>Application.Current?.Dispatcher.Invoke(...)</c>，没有 UI 宿主时它本来就直接短路。
    /// 换接缝不许顺手改掉这个语义（重构的硬要求是行为不变）。</para>
    /// </summary>
    public static Action<Action> UiInvoke { get; set; } = _ => { };

    /// <summary>
    /// **投递**到 UI 线程（等价 <c>Dispatcher.BeginInvoke</c>：不等结果）。缺省同样什么都不做，
    /// 理由同 <see cref="UiInvoke"/>。
    /// </summary>
    public static Action<Action> UiPost { get; set; } = _ => { };

    /// <summary>
    /// **当下有没有 UI 线程**。有些调用点不是"投递一下"，而是**按它分流**
    /// （如 <c>VariableSetService.OnDataUpdated</c>：没有 UI 线程就直接放弃这一轮并复位合并标志）。
    /// 那种地方只给 no-op 的 <see cref="UiPost"/> 会把状态卡住——所以要能问。
    /// </summary>
    public static Func<bool> HasUiThread { get; set; } = () => false;

    /// <summary>程序登记表（宿主启动时注入；未注入为 <c>null</c>）。</summary>
    public static ProgramRegistryManager? ProgramRegistry { get; set; }

    /// <summary>
    /// 周期计时器的工厂。宿主持有 UI 线程时注入 <c>DispatcherTimer</c> 实现（回调跑 UI 线程，
    /// **与既有行为一致**）；缺省走线程池（<see cref="ThreadingServiceTimer"/>），无 UI 宿主也能跑。
    /// </summary>
    public static Func<TimeSpan, Action, IServiceTimer> TimerFactory { get; set; } =
        ThreadingServiceTimer.Create;

    /// <summary>
    /// 窗口配置管理器（宿主持有的那一份）。
    ///
    /// <para><b>是委托不是值</b>：<c>App.WindowConfigs</c> 在启动/加载过程中会被整体替换，
    /// 捕获实例会拿到过期对象——每次现取。</para>
    /// </summary>
    public static Func<WindowConfigManager?> WindowConfigs { get; set; } = () => null;

    /// <summary>刷新所有主窗口（宿主注入；缺省什么都不做——与「没有 UI 宿主就短路」一致）。</summary>
    public static Action RefreshAllWindows { get; set; } = () => { };

    /// <summary>按当前配置重载所有窗口的 UI（同上，缺省什么都不做）。</summary>
    public static Action ReloadWindowsUiFromConfigs { get; set; } = () => { };

    /// <summary>
    /// 取窗口配置；没有宿主（无 UI 环境）时返回 <c>false</c> 并记一条日志。
    /// 把"取不到就别干活"这件事收进接缝：调用点一行，且**不会退化成空引用崩**。
    /// </summary>
    public static bool TryGetWindowConfigs(string where, out WindowConfigManager configs)
    {
        var hit = WindowConfigs();
        if (hit != null)
        {
            configs = hit;
            return true;
        }
        Framework.RuntimeLog.Debug($"[seam] {where}: 没有宿主窗口配置（无 UI 环境），本次跳过");
        configs = null!;
        return false;
    }

    /// <summary>刷新所有窗口的顶部标签栏（同上，缺省什么都不做）。</summary>
    public static Action RefreshAllWindowTabs { get; set; } = () => { };

    /// <summary>按 id 移除共享窗口（同上，缺省什么都不做）。</summary>
    public static Action<IEnumerable<string>> RemoveSharedWindowsByIds { get; set; } = _ => { };
}
