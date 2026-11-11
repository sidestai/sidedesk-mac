using System;

namespace SideDesk.Services;

/// <summary>
/// 一块原始音频数据的回调（<paramref name="buffer"/> 的 [<paramref name="offset"/>, +<paramref name="count"/>)
/// 区间有效，且为**规范格式**：<see cref="VoiceAudioFormat"/> = 16kHz / 单声道 / 16-bit PCM 小端）。
/// 回调在采集线程触发——须零 UI、快速返回；重活（分段/识别）由消费方自行调度。
/// </summary>
public delegate void AudioBlockHandler(byte[] buffer, int offset, int count);

/// <summary>
/// 语音链路的规范音频格式（冻结协议，与 Windows ADR-0016 逐字一致）：所有采集/中继/识别环节
/// 都以此格式交换 PCM。移植时把「设备原生格式（mac 通常 48kHz/float32/立体声）→ 规范格式」的
/// 转换收口在平台实现内部，接缝之外只见规范格式。
/// </summary>
public static class VoiceAudioFormat
{
    public const int SampleRate = 16000;
    public const int Channels = 1;
    public const int BytesPerSample = 2;   // 16-bit PCM 小端
}

/// <summary>
/// 麦克风采集接缝（分层解耦）：抽象 Windows 的 NAudio <c>WaveInEvent</c>，macOS 实现基于
/// AVFoundation <c>AVAudioEngine</c>（<c>SideDesk.Platform.Mac.AVAudioEngineMicSource</c>）。
///
/// 只负责**产出规范格式的 PCM 块**（见 <see cref="AudioBlockHandler"/>）；降噪/VAD/分段/识别是
/// 其上平台无关的另一层。系统音频回环（loopback）两平台都未实现，不在本接缝范围内。
/// </summary>
public interface IAudioCapture : IDisposable
{
    /// <summary>当前是否正在采集。</summary>
    bool IsCapturing { get; }

    /// <summary>
    /// 开始采集，规范格式 PCM 块经 <paramref name="onBlock"/> 回调。返回 false 表示失败
    /// （无麦克风权限 / 无输入设备 / 引擎启动失败）——首次调用若无权限会**异步发起系统授权请求**，
    /// 本次仍返回 false，授权后由调用方重试。重复调用幂等（仅替换回调）。
    /// </summary>
    bool Start(AudioBlockHandler onBlock);

    /// <summary>停止采集并释放引擎。未采集时调用无副作用。</summary>
    void Stop();
}
