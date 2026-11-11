using System;
using AVFoundation;
using Foundation;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IAudioCapture"/> 的 macOS 实现，基于 AVFoundation <c>AVAudioEngine</c>，
/// 取代 Windows 的 NAudio <c>WaveInEvent</c>。在输入节点装 tap 拿设备原生 PCM，经
/// <see cref="PcmCanonicalConverter"/> 转为规范 16kHz/mono/int16 后回调给消费方。
///
/// <b>权限：</b>采集需麦克风授权（<c>NSMicrophoneUsageDescription</c>）。首次 <see cref="Start"/>
/// 若未决会异步发起系统授权请求并返回 false，授权后重试即成功。
/// <b>线程：</b>tap 回调在音频实时线程触发——<see cref="PcmCanonicalConverter.Convert"/> 内只做
/// 内存转换、无托管分配以外的锁；消费方回调须自行保证轻量、勿碰 UI。
/// </summary>
public sealed class AVAudioEngineMicSource : IAudioCapture
{
    private readonly object _gate = new();
    private AVAudioEngine? _engine;
    private PcmCanonicalConverter? _converter;
    private AudioBlockHandler? _handler;

    public bool IsCapturing { get; private set; }

    public bool Start(AudioBlockHandler onBlock)
    {
        lock (_gate)
        {
            if (IsCapturing) { _handler = onBlock; return true; }  // 幂等：仅换回调
            _handler = onBlock;

            if (!MicPermissionGranted())
            {
                Framework.RuntimeLog.Debug("[Mic] permission not granted; start deferred");
                return false;
            }

            AVAudioEngine? engine = null;
            try
            {
                engine = new AVAudioEngine();
                var input = engine.InputNode;
                var srcFmt = input.GetBusOutputFormat((UIntPtr)0);
                if (srcFmt == null)
                {
                    Framework.RuntimeLog.Debug("[Mic] no input bus format (no input device?)");
                    Cleanup(engine);
                    return false;
                }

                _converter = new PcmCanonicalConverter(srcFmt);

                // 100ms 缓冲（按源采样率），下限 1024 帧避免过小频繁回调
                uint bufFrames = (uint)Math.Max(1024, (int)(srcFmt.SampleRate * 0.1));
                input.InstallTapOnBus((UIntPtr)0, bufFrames, srcFmt, OnTap);

                engine.Prepare();
                if (!engine.StartAndReturnError(out var err))
                {
                    Framework.RuntimeLog.Debug($"[Mic] engine start failed: {err?.LocalizedDescription}");
                    Cleanup(engine);
                    return false;
                }

                _engine = engine;
                IsCapturing = true;
                Framework.RuntimeLog.Debug($"[Mic] capture started @ {srcFmt.SampleRate}Hz -> {VoiceAudioFormat.SampleRate}Hz");
                return true;
            }
            catch (Exception ex)
            {
                Framework.RuntimeLog.Debug($"[Mic] Start error: {ex.Message}");
                Cleanup(engine);
                return false;
            }
        }
    }

    private void OnTap(AVAudioPcmBuffer buffer, AVAudioTime when)
    {
        var h = _handler;
        var c = _converter;
        if (h == null || c == null) return;
        try
        {
            var bytes = c.Convert(buffer);
            if (bytes.Length > 0) h(bytes, 0, bytes.Length);
        }
        catch { /* 单块转换失败丢弃，不中断采集 */ }
    }

    public void Stop()
    {
        lock (_gate)
        {
            Cleanup(_engine);
            IsCapturing = false;
            _handler = null;
        }
    }

    public void Dispose() => Stop();

    /// <summary>停止引擎、卸 tap、释放转换器（在锁内调用）。</summary>
    private void Cleanup(AVAudioEngine? engine)
    {
        try
        {
            if (engine != null)
            {
                try { engine.Stop(); } catch { }
                try { engine.InputNode?.RemoveTapOnBus((UIntPtr)0); } catch { }
                engine.Dispose();
            }
        }
        catch { }
        if (ReferenceEquals(engine, _engine)) _engine = null;
        _converter?.Dispose();
        _converter = null;
    }

    /// <summary>麦克风授权是否已具备；未决时异步发起请求（本次仍返回 false，授权后重试）。</summary>
    private static bool MicPermissionGranted()
    {
        try
        {
            var status = AVCaptureDevice.GetAuthorizationStatus(AVAuthorizationMediaType.Audio);
            if (status == AVAuthorizationStatus.Authorized) return true;
            if (status == AVAuthorizationStatus.NotDetermined)
                AVCaptureDevice.RequestAccessForMediaType(AVAuthorizationMediaType.Audio, _ => { });
            return false;
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[Mic] permission query failed: {ex.Message}");
            return false;
        }
    }
}
