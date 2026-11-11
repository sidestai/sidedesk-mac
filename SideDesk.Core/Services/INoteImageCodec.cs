namespace SideDesk.Services;

/// <summary>
/// 笔记图片**编解码接缝**（分层解耦）：把「任意格式图片文件 / 剪贴板位图」归一为 PNG 字节。
/// 这是 Windows 版 <c>NoteImageService</c> 里唯一平台专有的部分——WPF/WIC 用
/// <c>BitmapImage</c>/<c>BitmapSource</c>/<c>PngBitmapEncoder</c>/<c>IDataObject</c>，
/// macOS 换成 AppKit（<c>NSImage</c>/<c>NSBitmapImageRep</c>/<c>NSPasteboard</c>）。
///
/// 落盘/删除/URL 拼接等纯文件 IO 与平台无关，留在服务层的 <c>NoteImageStore</c>；
/// 本接缝只负责「像素 → PNG 字节」这一步，由各平台实现并注册进
/// <see cref="Composition.AppContainer"/>（Phase 3）。
/// </summary>
public interface INoteImageCodec
{
    /// <summary>把任意格式的图片文件解码并归一为 PNG 字节。失败返回 null。</summary>
    byte[]? LoadFileToPng(string path);

    /// <summary>从系统剪贴板读取位图并归一为 PNG 字节。无图/失败返回 null。</summary>
    byte[]? ReadClipboardPng();
}
