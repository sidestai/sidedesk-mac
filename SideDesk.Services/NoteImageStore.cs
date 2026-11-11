using System;
using System.IO;
using System.Security.Cryptography;
using SideDesk.Composition;

namespace SideDesk.Services;

/// <summary>
/// 笔记图片存取（平台无关部分）：落盘 / 去重 / 删除 / Markdown 同源引用拼接。
/// 对应 Windows 版 <c>Services/NoteImageService.cs</c> 里与 WPF 无关的逻辑——像素编解码
/// （文件/剪贴板 → PNG）已抽到接缝 <see cref="INoteImageCodec"/>，由各平台原生实现
/// （macOS: NSImage）注册进 <see cref="AppContainer"/>。
///
/// 图片落盘到 <c>{AppPaths.DataDir}/{note-images|desk-note-images}/&lt;noteId&gt;/&lt;hash&gt;.png</c>，
/// 正文插入同虚拟主机（sd-mdview.local）的 Markdown 引用，由预览宿主经资源拦截喂图。
/// 笔记删除时回收全部图片，避免孤儿文件（#216）。
/// </summary>
public static class NoteImageStore
{
    /// <summary>笔记图片虚拟主机名（两端一致；scheme 由平台接缝决定）。</summary>
    internal const string VirtualHost = "sd-mdview.local";

    /// <summary>取指定类型的图片根目录（与预览宿主虚拟主机映射同源）。</summary>
    internal static string GetImagesRoot(NoteImageKind kind) =>
        Path.Combine(Framework.AppPaths.DataDir,
            kind == NoteImageKind.DeskNote ? "desk-note-images" : "note-images");

    /// <summary>URL 路径前缀（用于拼接 Markdown 同源引用）。</summary>
    private static string UrlPrefix(NoteImageKind kind) =>
        kind == NoteImageKind.DeskNote ? "desk-note-images" : "note-images";

    private static string LogCategory(NoteImageKind kind) =>
        kind == NoteImageKind.DeskNote ? "DeskNoteMarkdown" : "StickyMarkdown";

    private static string KindLabel(NoteImageKind kind) =>
        kind == NoteImageKind.DeskNote ? "记事" : "便签";

    /// <summary>
    /// 保存已归一为 PNG 的字节到 <c>&lt;noteId&gt;/&lt;sha256 前 16 位&gt;.png</c>；同内容去重复用同一文件；
    /// 返回可插入正文、走同虚拟主机的 Markdown 引用。
    /// </summary>
    public static string SaveImage(NoteImageKind kind, string noteId, byte[] pngBytes)
    {
        using var sha = SHA256.Create();
        var hash = BitConverter.ToString(sha.ComputeHash(pngBytes)).Replace("-", "").ToLowerInvariant();
        var name = hash.Substring(0, 16) + ".png";
        var dir = Path.Combine(GetImagesRoot(kind), noteId);
        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, name);
        if (!File.Exists(file)) File.WriteAllBytes(file, pngBytes);
        return $"![]({BuildResourceUrl($"{UrlPrefix(kind)}/{noteId}/{name}")})";
    }

    /// <summary>
    /// 构造笔记图片的资源 URL：经平台接缝 <see cref="IWebResourceMapper"/> 决定 scheme
    /// （macOS: sdlocal://，Windows: https://）；未注册接缝时回落 WebView2 的 https 约定，
    /// 保证纯服务层测试/Windows 语义不破。
    /// </summary>
    private static string BuildResourceUrl(string relativePath)
    {
        var mapper = AppContainer.TryResolve<IWebResourceMapper>(out var m) ? m : null;
        return mapper != null
            ? mapper.BuildResourceUrl(VirtualHost, relativePath)
            : $"https://{VirtualHost}/{relativePath.TrimStart('/')}";
    }

    /// <summary>把任意格式图片文件解码并归一为 PNG 字节（经平台编解码接缝）。失败返回 null。</summary>
    public static byte[]? LoadImageFileToPng(NoteImageKind kind, string path)
    {
        var codec = ResolveCodec();
        if (codec == null)
        {
            Framework.RuntimeLog.Warn(LogCategory(kind), $"{KindLabel(kind)}图片解码失败: 无 INoteImageCodec 实现");
            return null;
        }
        try { return codec.LoadFileToPng(path); }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Warn(LogCategory(kind), $"{KindLabel(kind)}图片解码失败: {ex.Message}");
            return null;
        }
    }

    /// <summary>从系统剪贴板读取位图并归一为 PNG 字节（经平台编解码接缝）。无图/失败返回 null。</summary>
    public static byte[]? ReadClipboardPng(NoteImageKind kind)
    {
        var codec = ResolveCodec();
        if (codec == null) return null;
        try { return codec.ReadClipboardPng(); }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Warn(LogCategory(kind), $"{KindLabel(kind)}剪贴板位图读取失败: {ex.Message}");
            return null;
        }
    }

    /// <summary>笔记删除时回收该笔记的全部图片（孤儿清理）。</summary>
    public static void DeleteNoteImages(NoteImageKind kind, string noteId)
    {
        try
        {
            var dir = Path.Combine(GetImagesRoot(kind), noteId);
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Warn(LogCategory(kind), $"{KindLabel(kind)}图片清理失败: {ex.Message}");
        }
    }

    private static INoteImageCodec? ResolveCodec() =>
        AppContainer.TryResolve<INoteImageCodec>(out var c) ? c : null;
}
