using System;
using System.Collections.Generic;
using System.Linq;
using AppKit;
using Foundation;
using ObjCRuntime;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IClipboard"/> 的 macOS 实现，基于 AppKit <c>NSPasteboard.GeneralPasteboard</c>，
/// 取代 Windows 的 <c>System.Windows.Clipboard</c>。图片解码复用 <see cref="NSImageNoteCodec"/>
/// （剪贴板图片 → PNG 的 NSImage 归一逻辑单一来源）。
///
/// 类型标识用系统 UTI 常量（<c>NSPasteboardTypeString/HTML/PNG/TIFF/FileUrl</c>）。
/// <b>线程约束：</b>须在 UI 线程调用。
/// </summary>
public sealed class NSPasteboardClipboard : IClipboard
{
    private readonly NSImageNoteCodec _codec = new();

    private static NSPasteboard Pb => NSPasteboard.GeneralPasteboard;

    // 变更监控：macOS 无 WM_CLIPBOARDUPDATE 之类的推送通知，用主运行循环上的定时器轮询
    // GeneralPasteboard.ChangeCount（每次剪贴板写入自增）。回调约定在 UI 线程触发——
    // NSTimer 挂在主 run loop 上，天然满足。轮询周期 0.5s：够快捕捉复制，且开销可忽略。
    private NSTimer? _monitorTimer;
    private Action? _onChanged;
    private nint _lastChangeCount;

    public bool IsMonitoring => _monitorTimer != null;

    public void StartMonitoring(Action onChanged)
    {
        if (_monitorTimer != null) { _onChanged = onChanged; return; } // 幂等：仅换回调
        _onChanged = onChanged;
        _lastChangeCount = Pb.ChangeCount; // 以当前为基线，避免启动即误报一次
        _monitorTimer = NSTimer.CreateRepeatingScheduledTimer(0.5, _ =>
        {
            var cc = Pb.ChangeCount;
            if (cc == _lastChangeCount) return;
            _lastChangeCount = cc;
            _onChanged?.Invoke();
        });
    }

    public void StopMonitoring()
    {
        _monitorTimer?.Invalidate();
        _monitorTimer?.Dispose();
        _monitorTimer = null;
        _onChanged = null;
    }

    // 系统 UTI 字面量（等价 NSPasteboardTypeString/HTML/PNG/TIFF/FileUrl；用字面量免去过时
    // 常量的 CS0618 且与图片类型写法一致，取值稳定）
    private const string TStr = "public.utf8-plain-text";
    private const string THtml = "public.html";
    private const string TFileUrl = "public.file-url";
    private static readonly string[] ImageTypes = { "public.png", "public.tiff" };

    public bool ContainsText() => Pb.GetAvailableTypeFromArray(new[] { TStr }) != null;

    public string GetText() => ContainsText() ? (Pb.GetStringForType(TStr) ?? "") : "";

    public void SetText(string text)
    {
        Pb.ClearContents();
        Pb.SetStringForType(text ?? "", TStr);
    }

    public bool ContainsHtml() => Pb.GetAvailableTypeFromArray(new[] { THtml }) != null;

    public string? GetHtml() => ContainsHtml() ? Pb.GetStringForType(THtml) : null;

    public bool ContainsImage() => Pb.CanReadItemWithDataConformingToTypes(ImageTypes);

    public byte[]? GetImagePng() => _codec.ReadClipboardPng();

    public bool ContainsFileList() => Pb.CanReadItemWithDataConformingToTypes(new[] { TFileUrl });

    public IReadOnlyList<string> GetFileList()
    {
        try
        {
            if (!ContainsFileList()) return Array.Empty<string>();
            var objs = Pb.ReadObjectsForClasses(new[] { new Class(typeof(NSUrl)) }, null!);
            if (objs == null) return Array.Empty<string>();
            var paths = new List<string>();
            foreach (var o in objs)
            {
                if (o is NSUrl url && url.IsFileUrl)
                {
                    string? p = url.Path;
                    if (!string.IsNullOrEmpty(p)) paths.Add(p!);
                }
            }
            return paths;
        }
        catch { return Array.Empty<string>(); }
    }

    public void SetFileList(IEnumerable<string> paths)
    {
        var urls = (paths ?? Enumerable.Empty<string>())
            .Where(p => !string.IsNullOrEmpty(p))
            .Select(p => (INSPasteboardWriting)NSUrl.FromFilename(p))
            .ToArray();
        Pb.ClearContents();
        if (urls.Length > 0) Pb.WriteObjects(urls);
    }

    public void Clear() => Pb.ClearContents();
}
