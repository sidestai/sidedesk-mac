using System;
using System.Collections.Generic;

namespace SideDesk.Services;

/// <summary>
/// 系统剪贴板访问接缝（分层解耦）：抽象 Windows 的 <c>System.Windows.Clipboard</c> 静态类，
/// macOS 实现基于 AppKit <c>NSPasteboard</c>（<c>SideDesk.Platform.Mac.NSPasteboardClipboard</c>）。
/// 覆盖代码库实际用到的能力：文本读写、HTML 读取、图片（→PNG）、文件路径列表、清空。
///
/// <b>线程约束：</b>原始读写须在 UI 线程调用（NSPasteboard/Clipboard 均要求）；后台线程经
/// <c>ServiceSeam.UiInvoke</c> 调度回主线程。图片解码复用 <see cref="INoteImageCodec"/>。
///
/// <b>变更监控（<see cref="StartMonitoring"/>）：</b>隐藏平台差异——Windows 走
/// WM_CLIPBOARDUPDATE 消息推送，macOS 无对应通知，用定时器轮询 <c>changeCount</c>。两者都在
/// 变更时回调 <c>onChanged</c>（约定在 UI 线程触发），历史记录编排见
/// <c>SideDesk.Services.ClipboardService</c>（平台无关）。
/// </summary>
public interface IClipboard
{
    /// <summary>开始监控剪贴板变更；每次变更在 UI 线程回调 <paramref name="onChanged"/>。重复调用幂等。</summary>
    void StartMonitoring(Action onChanged);
    /// <summary>停止监控。未监控时调用无副作用。</summary>
    void StopMonitoring();
    /// <summary>当前是否正在监控。</summary>
    bool IsMonitoring { get; }

    /// <summary>剪贴板是否含纯文本。</summary>
    bool ContainsText();
    /// <summary>取纯文本；无则返回空串。</summary>
    string GetText();
    /// <summary>写入纯文本（替换剪贴板内容）。</summary>
    void SetText(string text);

    /// <summary>剪贴板是否含 HTML。</summary>
    bool ContainsHtml();
    /// <summary>取 HTML 文本；无则返回 null。</summary>
    string? GetHtml();

    /// <summary>剪贴板是否含图片。</summary>
    bool ContainsImage();
    /// <summary>取图片并归一为 PNG 字节；无图/失败返回 null。</summary>
    byte[]? GetImagePng();

    /// <summary>剪贴板是否含文件列表。</summary>
    bool ContainsFileList();
    /// <summary>取文件绝对路径列表；无则返回空列表。</summary>
    IReadOnlyList<string> GetFileList();
    /// <summary>写入文件路径列表（替换剪贴板内容）。</summary>
    void SetFileList(IEnumerable<string> paths);

    /// <summary>清空剪贴板。</summary>
    void Clear();
}
