using System;

namespace SideDesk.Services;

/// <summary>
/// 语音识别引擎接缝（分层解耦，<b>平台无关</b>）：抽象 Windows 的 <c>IVoiceRecognizer</c>
/// （SenseVoice/Whisper/SAPI 三引擎），macOS 实现基于 Apple Speech 框架
/// <c>SFSpeechRecognizer</c>（<c>SideDesk.Platform.Mac.SFSpeechRecognizerVoiceRecognizer</c>）。
///
/// 与 Windows 版的差异：Apple 识别器**内部自带 VAD/端点检测/流式部分结果**，故本接缝不暴露
/// 分段/滑窗/解码调度，只把「麦克风 → 流式文本」收口成 Start/Stop + 三个文本事件。音频采集
/// 复用 <see cref="IAudioCapture"/> 接缝（规范 16k/mono/int16 PCM）。
///
/// <b>线程：</b>文本/电平事件在识别器回调线程触发（非 UI 线程）；订阅方须自行经
/// <c>ServiceSeam.UiPost</c> 调度到 UI。事件回调应轻量。
/// </summary>
public interface IVoiceRecognizer : IDisposable
{
    /// <summary>引擎名（用于设置/日志，如 "apple-speech"）。</summary>
    string Name { get; }

    /// <summary>
    /// 是否可用：语音识别授权已具备**且**识别器就绪。只读判定，不触发系统授权请求。
    /// （授权未决时 <see cref="StartMic"/> 会异步发起请求并返回 false，授权后重试。）
    /// </summary>
    bool IsAvailable { get; }

    /// <summary>当前是否正在识别（已启动采集且任务未结束）。</summary>
    bool IsRecognizing { get; }

    /// <summary>流式部分结果：当前累积的临时文本（会被后续结果覆盖/修正）。</summary>
    event Action<string>? PartialResult;

    /// <summary>一段最终结果：端点检测判定一句结束后的定稿文本。</summary>
    event Action<string>? FinalResult;

    /// <summary>会话结束（Stop/Cancel/出错/识别器自行完成）。</summary>
    event Action? Completed;

    /// <summary>输入电平 0..1（驱动 UI 声波动画）；在采集线程按块触发。</summary>
    event Action<double>? InputLevel;

    /// <summary>
    /// 从麦克风开始识别。返回 false 表示未启动（无授权 / 无输入设备 / 引擎不可用 / 启动失败）——
    /// 授权未决时会**异步发起系统授权请求**，本次仍返回 false。重复调用幂等。
    /// </summary>
    bool StartMic();

    /// <summary>结束当前会话：停止采集并让识别器收尾（会触发 <see cref="FinalResult"/>/<see cref="Completed"/>）。</summary>
    void Stop();

    /// <summary>取消当前会话：丢弃未定稿结果（触发 <see cref="Completed"/>，不保证 FinalResult）。</summary>
    void Cancel();
}
