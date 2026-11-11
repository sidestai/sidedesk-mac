using System;
using System.Runtime.InteropServices;
using AVFoundation;
using Foundation;
using Speech;
using SideDesk.Composition;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IVoiceRecognizer"/> 的 macOS 实现，基于 Apple Speech 框架 <c>SFSpeechRecognizer</c>，
/// 取代 Windows 的 SenseVoice/Whisper/SAPI 三引擎（后两者为 Win-only）。中文 locale（zh-CN）。
///
/// 数据流：<see cref="IAudioCapture"/>（规范 16k/mono/int16 PCM 块）→ <see cref="WrapCanonical"/>
/// 包成 <c>AVAudioPcmBuffer</c> → <c>SFSpeechAudioBufferRecognitionRequest.Append</c>；识别器内部
/// 做 VAD/端点/流式解码，经回调产出部分/最终文本。
///
/// <b>授权：</b>需 Speech 识别授权（Info.plist <c>NSSpeechRecognitionUsageDescription</c>）+ 麦克风授权
/// （由采集接缝负责）。<see cref="StartMic"/> 在授权未决时异步发起请求并返回 false。
/// <b>离线：</b>识别器 <c>SupportsOnDeviceRecognition</c> 时置 <c>RequiresOnDeviceRecognition</c>，
/// 全程本地、不出网（隐私 + 免网络依赖）。
/// <b>线程：</b>文本事件在识别器回调线程触发；电平事件在采集线程触发——均非 UI 线程。
/// </summary>
public sealed class SFSpeechRecognizerVoiceRecognizer : IVoiceRecognizer
{
    // 规范音频格式描述（16k/mono/int16 交织）——不可变，可跨块共享。
    private static readonly AVAudioFormat CanonicalFormat =
        new(AVAudioCommonFormat.PCMInt16, VoiceAudioFormat.SampleRate, (uint)VoiceAudioFormat.Channels, true);

    private readonly object _gate = new();
    private readonly IAudioCapture? _capture;
    private SFSpeechRecognizer? _recognizer;
    private SFSpeechAudioBufferRecognitionRequest? _request;
    private SFSpeechRecognitionTask? _task;

    public SFSpeechRecognizerVoiceRecognizer() { }

    /// <summary>测试构造：注入采集接缝（无需容器）。</summary>
    internal SFSpeechRecognizerVoiceRecognizer(IAudioCapture capture) => _capture = capture;

    public string Name => "apple-speech";

    private IAudioCapture? Capture =>
        _capture ?? (AppContainer.TryResolve<IAudioCapture>(out var c) ? c : null);

    public bool IsAvailable
    {
        get
        {
            try
            {
                return SFSpeechRecognizer.AuthorizationStatus == SFSpeechRecognizerAuthorizationStatus.Authorized
                       && EnsureRecognizer()?.Available == true;
            }
            catch { return false; }
        }
    }

    public bool IsRecognizing { get; private set; }

    public event Action<string>? PartialResult;
    public event Action<string>? FinalResult;
    public event Action? Completed;
    public event Action<double>? InputLevel;

    public bool StartMic()
    {
        lock (_gate)
        {
            if (IsRecognizing) return true;

            if (!SpeechAuthorized())
            {
                Framework.RuntimeLog.Debug("[Voice] speech recognition not authorized; start deferred");
                return false;
            }

            var recognizer = EnsureRecognizer();
            if (recognizer == null || !recognizer.Available)
            {
                Framework.RuntimeLog.Debug("[Voice] recognizer unavailable");
                return false;
            }

            try
            {
                var request = new SFSpeechAudioBufferRecognitionRequest
                {
                    ShouldReportPartialResults = true,
                    AddsPunctuation = true,
                };
                if (recognizer.SupportsOnDeviceRecognition)
                    request.RequiresOnDeviceRecognition = true;

                _request = request;
                _task = recognizer.GetRecognitionTask(request, OnRecognitionResult);

                var capture = Capture;
                if (capture == null || !capture.Start(OnAudioBlock))
                {
                    Framework.RuntimeLog.Debug("[Voice] mic capture failed to start");
                    TeardownTask(cancel: true);
                    return false;
                }

                IsRecognizing = true;
                Framework.RuntimeLog.Debug("[Voice] recognition started (apple-speech)");
                return true;
            }
            catch (Exception ex)
            {
                Framework.RuntimeLog.Debug($"[Voice] StartMic error: {ex.Message}");
                TeardownTask(cancel: true);
                return false;
            }
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            if (!IsRecognizing && _task == null) return;
            try { Capture?.Stop(); } catch { }
            IsRecognizing = false;
            // EndAudio + Finish 让识别器收尾，触发最终结果与完成回调（异步）。
            try { _request?.EndAudio(); } catch { }
            try { _task?.Finish(); } catch { }
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            if (!IsRecognizing && _task == null) return;
            try { Capture?.Stop(); } catch { }
            IsRecognizing = false;
            TeardownTask(cancel: true);
            SafeInvoke(Completed);
        }
    }

    private void OnAudioBlock(byte[] buffer, int offset, int count)
    {
        var req = _request;
        if (req == null || count <= 0) return;
        try
        {
            var pcm = WrapCanonical(buffer, offset, count);
            if (pcm != null)
            {
                req.Append(pcm);
                pcm.Dispose();
            }
            SafeInvoke(InputLevel, ComputeLevel(buffer, offset, count));
        }
        catch { /* 单块失败丢弃，不中断会话 */ }
    }

    private void OnRecognitionResult(SFSpeechRecognitionResult? result, NSError? error)
    {
        if (result != null)
        {
            string text = result.BestTranscription?.FormattedString ?? "";
            if (result.Final)
            {
                if (text.Length > 0) SafeInvoke(FinalResult, text);
            }
            else if (text.Length > 0)
            {
                SafeInvoke(PartialResult, text);
            }
        }

        if (error != null)
        {
            // Cancel 触发的 "cancelled" 错误属正常收尾，不记为异常。
            if (!IsCancellation(error))
                Framework.RuntimeLog.Debug($"[Voice] recognition error: {error.LocalizedDescription}");
            FinishSession();
            return;
        }

        if (result?.Final == true) FinishSession();
    }

    private void FinishSession()
    {
        lock (_gate)
        {
            IsRecognizing = false;
            TeardownTask(cancel: false);
        }
        SafeInvoke(Completed);
    }

    /// <summary>结束/清理识别任务与请求（在锁内调用）。cancel=true 走 Cancel，否则 Finish。</summary>
    private void TeardownTask(bool cancel)
    {
        try { if (cancel) _task?.Cancel(); else _task?.Finish(); } catch { }
        _task?.Dispose();
        _task = null;
        _request?.Dispose();
        _request = null;
    }

    private SFSpeechRecognizer? EnsureRecognizer() =>
        _recognizer ??= new SFSpeechRecognizer(new NSLocale("zh-CN"));

    /// <summary>Speech 授权是否已具备；未决时异步发起请求（本次返回 false）。</summary>
    private static bool SpeechAuthorized()
    {
        try
        {
            var status = SFSpeechRecognizer.AuthorizationStatus;
            if (status == SFSpeechRecognizerAuthorizationStatus.Authorized) return true;
            if (status == SFSpeechRecognizerAuthorizationStatus.NotDetermined)
                SFSpeechRecognizer.RequestAuthorization(_ => { });
            return false;
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[Voice] authorization query failed: {ex.Message}");
            return false;
        }
    }

    private static bool IsCancellation(NSError error) =>
        error.Domain == "kAFAssistantErrorDomain" && error.Code == 216
        || error.LocalizedDescription?.Contains("cancel", StringComparison.OrdinalIgnoreCase) == true;

    private static void SafeInvoke<T>(Action<T>? handler, T arg)
    {
        try { handler?.Invoke(arg); } catch { }
    }
    private static void SafeInvoke(Action? handler)
    {
        try { handler?.Invoke(); } catch { }
    }

    /// <summary>
    /// 把规范 PCM 字节（16-bit LE）包成 <see cref="CanonicalFormat"/> 的 <c>AVAudioPcmBuffer</c>
    /// 供识别器 Append。帧数 = count/2；奇数尾字节丢弃。空/过短返回 null。
    /// </summary>
    internal static AVAudioPcmBuffer? WrapCanonical(byte[] pcm, int offset, int count)
    {
        if (pcm == null) return null;
        if (offset < 0 || count <= 1 || offset + count > pcm.Length) return null;
        int usable = count & ~1;                 // 对齐到偶数（16-bit 样本）
        int frames = usable / VoiceAudioFormat.BytesPerSample;
        if (frames <= 0) return null;

        var buf = new AVAudioPcmBuffer(CanonicalFormat, (uint)frames);
        IntPtr ch0 = Marshal.ReadIntPtr(buf.Int16ChannelData);
        if (ch0 == IntPtr.Zero) { buf.Dispose(); return null; }
        Marshal.Copy(pcm, offset, ch0, usable);
        buf.FrameLength = (uint)frames;
        return buf;
    }

    /// <summary>由一块 int16 PCM 估算 0..1 电平（RMS，带轻微增益并削顶），驱动 UI 声波。</summary>
    internal static double ComputeLevel(byte[] pcm, int offset, int count)
    {
        int frames = count / VoiceAudioFormat.BytesPerSample;
        if (frames <= 0) return 0;
        double sum = 0;
        for (int i = 0; i < frames; i++)
        {
            short s = (short)((pcm[offset + i * 2]) | (pcm[offset + i * 2 + 1] << 8));
            sum += (double)s * s;
        }
        double rms = Math.Sqrt(sum / frames);
        return Math.Min(1.0, rms / short.MaxValue * 3.0);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            try { Capture?.Stop(); } catch { }
            TeardownTask(cancel: true);
            _recognizer?.Dispose();
            _recognizer = null;
            IsRecognizing = false;
        }
    }
}
