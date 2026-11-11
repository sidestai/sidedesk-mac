using System;
using System.Runtime.InteropServices;
using AVFoundation;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// 设备原生 PCM（mac 输入节点通常 48kHz / float32 / 立体声）→ 规范格式
/// （<see cref="VoiceAudioFormat"/>：16kHz / 单声道 / 16-bit PCM 小端）的一步转换。
///
/// 用 Apple <c>AVAudioConverter</c> 完成重采样 + 下混 + 采样格式转换（比手写线性重采样质量高，
/// 且是 AVFoundation 惯用法）。单独成类以便**脱离麦克风**单测：喂一个合成的源格式
/// <c>AVAudioPcmBuffer</c> 即可验证整条转换与字节布局。
/// </summary>
internal sealed class PcmCanonicalConverter : IDisposable
{
    private readonly AVAudioConverter _conv;
    private readonly AVAudioFormat _dst;

    public PcmCanonicalConverter(AVAudioFormat sourceFormat)
    {
        _dst = new AVAudioFormat(
            AVAudioCommonFormat.PCMInt16,
            VoiceAudioFormat.SampleRate,
            (uint)VoiceAudioFormat.Channels,
            interleaved: true);
        _conv = new AVAudioConverter(sourceFormat, _dst);
    }

    /// <summary>把一块源格式 PCM 转为规范格式的字节（16-bit LE）；失败返回空数组。</summary>
    public byte[] Convert(AVAudioPcmBuffer src)
    {
        try
        {
            uint srcFrames = src.FrameLength;
            if (srcFrames == 0) return Array.Empty<byte>();

            // 输出容量按输入帧数给足（AVAudioConverter 要求 outputBuffer.frameCapacity >=
            // inputBuffer.frameLength；实际产出见转换后的 FrameLength）。
            using var outBuf = new AVAudioPcmBuffer(_dst, srcFrames);

            // 采样率转换必须走 block 版（一次性 convertToBuffer:fromBuffer: 不支持重采样，返回 -50）。
            // 供一次输入 buffer，随后报 EndOfStream。EndOfStream 会**锁存**到转换器上，故每块转换前
            // Reset() 清状态——tap 复用同一转换器连续转换多块，否则第二块起静默产出 0 帧。
            _conv.Reset();
            bool supplied = false;
            var status = _conv.ConvertToBuffer(outBuf, out var err,
                (uint np, out AVAudioConverterInputStatus inStatus) =>
                {
                    if (!supplied) { supplied = true; inStatus = AVAudioConverterInputStatus.HaveData; return src; }
                    inStatus = AVAudioConverterInputStatus.EndOfStream;
                    return null;
                });
            if (err != null || status == AVAudioConverterOutputStatus.Error)
                return Array.Empty<byte>();

            int frames = (int)outBuf.FrameLength;
            if (frames <= 0) return Array.Empty<byte>();

            // Int16ChannelData 是 int16**（各声道指针数组）；交织单声道下 [0] 即全部数据。
            IntPtr ch0 = Marshal.ReadIntPtr(outBuf.Int16ChannelData);
            if (ch0 == IntPtr.Zero) return Array.Empty<byte>();

            var bytes = new byte[frames * VoiceAudioFormat.BytesPerSample];
            Marshal.Copy(ch0, bytes, 0, bytes.Length);
            return bytes;
        }
        catch { return Array.Empty<byte>(); }
    }

    public void Dispose() => _conv?.Dispose();
}
