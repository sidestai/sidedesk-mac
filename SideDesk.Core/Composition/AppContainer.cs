using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;

namespace SideDesk.Composition;

/// <summary>
/// 组合根（ADR-0025）：应用启动时在此登记服务实例，消费方经 <see cref="Resolve{T}"/> 取用 ——
/// 取代散落的 <c>XxxService.Instance</c> 静态单例与裸 <c>new XxxService()</c>。
///
/// <para><b>为什么是手写字典而不是 DI 框架</b>：需求只有「启动装配 + 取用」两件事（无作用域、
/// 无拦截、无构造注入图）；而宿主程序集会被 <c>PluginBuildService</c> 作为**元数据引用**给插件作者，
/// 多一个第三方依赖就多一份插件侧的耦合面。百余行能说清的东西不必引包。</para>
///
/// <para><b>纪律</b>（ADR-0025）：① 本类是**全库唯一被允许的静态入口** —— 它的存在正是为了让
/// 其余服务不再是静态单例；② **新增代码不得再用 <c>XxxService.Instance</c>**，一律经容器取用
/// （<c>check-ui-decoupling</c> 的 <c>uiInstance</c> 计数只减不增，是这条纪律的门禁）；
/// ③ 登记只发生在 <c>App.OnStartup</c> 一处，别在业务代码里 <c>Register</c>（装配与使用分离，
/// 否则等于换了个名字的服务定位器）。</para>
///
/// <para><b>测试</b>：<see cref="Clear"/> 供用例隔离；未注册的解析会抛异常并点名类型，
/// 不静默返回 null —— 静默失败会把「忘了注册」拖到运行时深处。</para>
/// </summary>
public static class AppContainer
{
    private static readonly ConcurrentDictionary<Type, object> Services = new();

    /// <summary>登记一个**已构造**的实例（有状态服务走这条：生命周期由装配方决定）</summary>
    public static void Register<T>(T instance) where T : class
    {
        ArgumentNullException.ThrowIfNull(instance);
        Services[typeof(T)] = instance;
    }

    /// <summary>登记一个**工厂**（延迟构造：首次解析时才建，构造本身也是服务自己的事）</summary>
    public static void Register<T>(Func<T> factory) where T : class
    {
        ArgumentNullException.ThrowIfNull(factory);
        Services[typeof(T)] = new Lazy<T>(factory);
    }

    /// <summary>取用已登记的服务；未登记直接抛错并点名 —— 不静默降级</summary>
    public static T Resolve<T>() where T : class
    {
        if (Services.TryGetValue(typeof(T), out var entry))
        {
            if (entry is Lazy<T> lazy) return lazy.Value;
            if (entry is T hit) return hit;
        }
        throw new InvalidOperationException(
            $"服务 {typeof(T).Name} 未在组合根登记 —— 请在 App.OnStartup 里 Register（ADR-0025）。");
    }

    /// <summary>取用已登记的服务；未登记返回 false（调用方自己决定降级策略）</summary>
    public static bool TryResolve<T>(out T? service) where T : class
    {
        service = null;
        if (!Services.TryGetValue(typeof(T), out var entry)) return false;
        service = entry is Lazy<T> lazy ? lazy.Value : entry as T;
        return service != null;
    }

    /// <summary>是否已登记（诊断与测试用）</summary>
    public static bool IsRegistered<T>() where T : class => Services.ContainsKey(typeof(T));

    /// <summary>已登记的服务类型名（诊断用，按名排序）</summary>
    public static IReadOnlyList<string> RegisteredNames()
        => Services.Keys.Select(t => t.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();

    /// <summary>清空登记（测试隔离用；产品代码不要调用）</summary>
    public static void Clear() => Services.Clear();
}
