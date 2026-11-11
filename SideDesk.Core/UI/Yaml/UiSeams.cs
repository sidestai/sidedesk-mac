using System;
using System.Collections.Generic;

namespace SideDesk.UI.Yaml;

// Ported from SideDesk/UI/Yaml/UiSeams.cs. The two contracts (IUiDataSource /
// IUiActionHost) and DelegateUiActionHost are framework-agnostic and come over
// verbatim. The WPF-specific UiCardView (it holds a System.Windows.UIElement) is
// intentionally NOT ported -- each renderer backend owns its own card-view type
// (the AppKit backend's holds an NSView).

/// <summary>
/// 卡片的数据来源。刻意做窄：只有“按路径取值”+“变了通知”两件事。
/// 取不到就渲染成空并记一条日志（不抛），静默返回 null 才是要避免的。
/// </summary>
public interface IUiDataSource
{
    /// <summary>取绑定路径的值。返回 <c>false</c> 表示该路径未知。</summary>
    bool TryGet(string path, out object? value);

    /// <summary>数据变化。可能在后台线程触发 —— 订阅方负责切回 UI 线程。</summary>
    event Action? Changed;

    /// <summary>
    /// 取一个集合（<c>Repeat</c> 的 <c>repeat.source</c>）。每一项是它自己的数据源，
    /// 子节点在 <c>{as.field}</c> 里按字段名向它取值。不支持集合的数据源用默认实现即可。
    /// </summary>
    bool TryGetItems(string path, out IReadOnlyList<IUiDataSource> items)
    {
        items = Array.Empty<IUiDataSource>();
        return false;
    }
}

/// <summary>
/// 动作宿主：YAML 里的 <c>events: { click: &lt;动作名&gt; }</c> 只声明动作名，逻辑在宿主里。
/// 找不到动作名时报错而不是静默吞掉。
/// </summary>
public interface IUiActionHost
{
    /// <summary>执行一个动作。返回 <c>false</c> 表示该动作名未注册。</summary>
    bool TryInvoke(string action);

    /// <summary>带值调用（输入框这类“动作要带上用户给的东西”的节点）。默认回落无值调用。</summary>
    bool TryInvoke(string action, string? value) => TryInvoke(action);
}

/// <summary>把宿主的私有处理器包成 <see cref="IUiActionHost"/>。</summary>
public sealed class DelegateUiActionHost : IUiActionHost
{
    private readonly Func<string, bool> _invoke;
    private readonly Func<string, string?, bool>? _invokeWithValue;

    public DelegateUiActionHost(Func<string, bool> invoke) => _invoke = invoke;

    public DelegateUiActionHost(Func<string, string?, bool> invokeWithValue)
    {
        _invoke = action => invokeWithValue(action, null);
        _invokeWithValue = invokeWithValue;
    }

    public bool TryInvoke(string action, string? value) =>
        _invokeWithValue != null ? _invokeWithValue(action, value) : _invoke(action);

    public bool TryInvoke(string action) => _invoke(action);
}
