using System;
using AppKit;
using CoreFoundation;
using Foundation;
using SideDesk.Composition;
using SideDesk.Platform.Mac;
using SideDesk.Services;

namespace SideDesk.App;

/// <summary>
/// macOS 组合根（ADR-0025 的 mac 装配入口）：应用启动时调用一次 <see cref="RegisterRuntimeInstances"/>
/// 与 <see cref="RegisterDefaults"/>，把平台无关服务与 macOS 原生接缝实现登记进 <see cref="AppContainer"/>，
/// 消费方一律经容器取用。对应 Windows 的 <c>Composition/AppBootstrap</c>——但只登记 SidestMac 已移植的部分，
/// 随迁移推进逐步补齐。
///
/// <para>登记纪律同 ADR-0025：① 装配只发生在此一处；② 无状态服务给实例，有状态/有副作用者给工厂
/// （延迟到首次取用才构造）；③ 多实例资源（如内嵌浏览器，每个控件一份）登记**工厂委托**而非单例。</para>
/// </summary>
public static class MacComposition
{
    /// <summary>
    /// 登记运行时实例（<see cref="Settings"/>）并接线服务层静态接缝（UI 编组）。
    /// 须在任何依赖 <see cref="ServiceSeam.Settings"/> 的服务被取用前调用。
    /// </summary>
    public static void RegisterRuntimeInstances(Settings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        AppContainer.Register(settings);
        ServiceSeam.Settings = settings;

        // UI 编组：mac 主线程 = main dispatch queue。
        // UiPost 恒异步投递（对齐 Windows Dispatcher.BeginInvoke 语义）；
        // UiInvoke 同步——已在主线程则直调，避免 DispatchSync 自我死锁。
        ServiceSeam.UiPost = action => DispatchQueue.MainQueue.DispatchAsync(action);
        ServiceSeam.UiInvoke = action =>
        {
            if (NSThread.Current.IsMainThread) action();
            else DispatchQueue.MainQueue.DispatchSync(action);
        };
        ServiceSeam.HasUiThread = () => true;
    }

    /// <summary>登记全部启动期服务与接缝（幂等：同类型后者覆盖前者）。</summary>
    public static void RegisterDefaults()
    {
        // ---- macOS 原生接缝实现 ----

        // 密钥保护：Keychain 主密钥 + AES-GCM 信封加密。惰性加载主密钥，注册工厂延迟构造。
        AppContainer.Register<ISecretProtector>(() => new KeychainSecretProtector());

        // 图片编解码：AppKit NSImage/NSBitmapImageRep 归一为 PNG。无状态，单例。
        AppContainer.Register<INoteImageCodec>(new NSImageNoteCodec());

        // Web 资源映射：sdlocal:// 自定义 scheme 的 URL 构造。无状态，单例。
        AppContainer.Register<IWebResourceMapper>(new WKWebResourceMapper());

        // 内嵌浏览器：WKWebView。**每个控件一实例**且须 UI 线程构造，故登记工厂委托——
        // 消费方 Resolve<Func<IWebBrowser>>() 后按需 Invoke 取得新实例（不是单例）。
        AppContainer.Register<Func<IWebBrowser>>(() => () => new WKWebViewBrowser());

        // 剪贴板：NSPasteboard 原始读写。无状态，单例。
        AppContainer.Register<IClipboard>(new NSPasteboardClipboard());

        // 全局按键捕获：CGEventTap（需辅助功能授权）。进程级单例、有状态（持事件搭句柄），工厂延迟构造。
        AppContainer.Register<IGlobalKeyTap>(() => new CGEventKeyTap());

        // 开机自启：用户级 LaunchAgent（~/Library/LaunchAgents/<bundleid>.plist）。无状态，单例。
        AppContainer.Register<IAutoStart>(new LaunchAgentAutoStart());

        // 麦克风采集：AVAudioEngine（需麦克风授权），产出规范 16k/mono/int16 PCM 块。
        // 有状态（持引擎/tap），工厂延迟构造；Start() 时才拉起引擎。
        AppContainer.Register<IAudioCapture>(() => new AVAudioEngineMicSource());

        // 语音识别：Apple Speech（SFSpeechRecognizer，zh-CN，支持 on-device）。消费 IAudioCapture，
        // 产出流式部分/最终文本。有状态（持识别任务），工厂延迟构造；StartMic() 时才拉起。
        AppContainer.Register<IVoiceRecognizer>(() => new SFSpeechRecognizerVoiceRecognizer());

        // ---- 平台无关编排服务 ----

        // 全局热键编排：消费 IGlobalKeyTap，产出语音启停/取消与窗口切换事件。工厂延迟构造。
        AppContainer.Register(() => new GlobalHotkeyService());

        // 剪贴板历史/监控编排：消费 IClipboard（changeCount 轮询），维护最近 100 条记录。
        // 有状态（持历史列表），工厂延迟构造；Start() 时才拉起监控。
        AppContainer.Register(() => new ClipboardService());
    }
}
