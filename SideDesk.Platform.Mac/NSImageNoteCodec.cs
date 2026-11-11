using System;
using System.IO;
using AppKit;
using Foundation;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="INoteImageCodec"/> 的 macOS 实现：用 AppKit（<c>NSImage</c>/<c>NSBitmapImageRep</c>/
/// <c>NSPasteboard</c>）把「图片文件 / 剪贴板位图」归一为 PNG 字节，取代 Windows 的 WPF/WIC
/// （<c>BitmapImage</c>/<c>PngBitmapEncoder</c>/<c>IDataObject</c>）。契约与 Windows 版一致：
/// 成功返回 PNG 字节，无图/解码失败返回 null（上层 <c>NoteImageStore</c> 已包 try/catch 并记日志）。
///
/// 归一路径：源 → TIFF（<c>NSImage.AsTiff</c>，AppKit 通用中间格式）→ <c>NSBitmapImageRep</c>
/// → PNG（<c>RepresentationUsingTypeProperties(Png)</c>）。剪贴板若已是 PNG/TIFF 数据则直接建 rep，
/// 省去一次 NSImage 往返。
///
/// 线程约束：AppKit 的 <c>NSBitmapImageRep</c>/<c>NSPasteboard</c> 只能在 UI 线程调用
/// （否则抛 <c>AppKitThreadAccessException</c>），故本实现须在主线程运行——生产外壳
/// （NSApplication 主循环）天然满足；后台线程需要时应经 ServiceSeam.UiInvoke 调度回主线程。
/// </summary>
public sealed class NSImageNoteCodec : INoteImageCodec
{
    public byte[]? LoadFileToPng(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        using var image = new NSImage(path);
        if (!image.IsValid) return null;
        using var tiff = image.AsTiff();
        if (tiff == null) return null;
        using var rep = new NSBitmapImageRep(tiff);
        return PngFromRep(rep);
    }

    public byte[]? ReadClipboardPng()
    {
        var pb = NSPasteboard.GeneralPasteboard;
        // 剪贴板已是 PNG：直接返回原始字节，免二次「解码→再编码」——极端尺寸/灰度色彩空间下
        // 再编码可能 CGImageDestinationFinalize 失败，且对 PNG 源毫无必要。
        using (var png = pb.GetDataForType("public.png"))
        {
            if (png != null && png.Length > 0) return png.ToArray();
        }
        // 否则回退 TIFF（许多原生 App 复制图片时仅/同时放 TIFF），解码后归一为 PNG。
        if (pb.GetAvailableTypeFromArray(new[] { "public.tiff" }) == null) return null;
        using var data = pb.GetDataForType("public.tiff");
        if (data == null) return null;
        using var rep = new NSBitmapImageRep(data);
        return PngFromRep(rep);
    }

    private static byte[]? PngFromRep(NSBitmapImageRep rep)
    {
        if (rep == null) return null;
        using var png = rep.RepresentationUsingTypeProperties(NSBitmapImageFileType.Png);
        return png?.ToArray();
    }
}
