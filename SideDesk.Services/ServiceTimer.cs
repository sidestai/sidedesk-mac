using System;
using System.Threading;

namespace SideDesk.Services;

/// <summary>
/// 周期计时器（服务层用）：宿主注入 WPF <c>DispatcherTimer</c> 实现时，回调跑在 UI 线程
/// （与既有行为一致）；缺省（无 UI 宿主，如单测）用线程池计时器。
///
/// <para><b>为什么要有这条接缝</b>：一批服务把 <c>DispatcherTimer</c> 当**状态**持有
/// （<c>private DispatcherTimer? _timer</c>）——那不只是"切个线程"，而是把一个 WPF 类型
/// 编进了服务的字段。要它们不依赖 UI，就得连计时器一起收口。</para>
/// </summary>
public interface IServiceTimer : IDisposable
{
    /// <summary>开始周期触发。</summary>
    void Start();

    /// <summary>停止（可再 Start）。</summary>
    void Stop();

    /// <summary>
    /// 当前是否在跑。有些调用点靠它判断（「只 Stop 没置 null」时要不要复活），
    /// 所以不能省——省了就变成"每次调用都重新 Start"，语义不同。
    /// </summary>
    bool IsEnabled { get; }
}

/// <summary>缺省实现：<see cref="System.Threading.Timer"/>（回调跑在线程池上）。</summary>
internal sealed class ThreadingServiceTimer : IServiceTimer
{
    private readonly TimeSpan _interval;
    private readonly Action _tick;
    private Timer? _timer;

    internal ThreadingServiceTimer(TimeSpan interval, Action tick)
    {
        _interval = interval;
        _tick = tick;
    }

    /// <summary>缺省工厂（<see cref="ServiceSeam.TimerFactory"/> 的初值）。</summary>
    internal static IServiceTimer Create(TimeSpan interval, Action tick) =>
        new ThreadingServiceTimer(interval, tick);

    public bool IsEnabled => _timer != null;

    public void Start()
    {
        _timer ??= new Timer(_ => _tick(), null, _interval, _interval);
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public void Dispose() => Stop();
}
