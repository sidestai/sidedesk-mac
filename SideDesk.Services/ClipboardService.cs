using System;
using System.Collections.Generic;
using System.Linq;
using SideDesk.Composition;

namespace SideDesk.Services;

/// <summary>剪贴板内容类型（历史记录分类）。</summary>
public enum ClipboardContentType
{
    Text,       // 纯文本
    Image,      // 图片
    File,       // 文件/文件夹
    Html,       // HTML/文档
    Video,      // 视频链接
    Unknown     // 未知
}

/// <summary>一条剪贴板历史记录。</summary>
public class ClipboardEntry
{
    public string Text { get; set; } = string.Empty;
    public DateTime Time { get; set; }
    public ClipboardContentType ContentType { get; set; }
    /// <summary>文件类型时保存的完整路径列表（其余类型为 null）。</summary>
    public List<string>? FilePaths { get; set; }
}

/// <summary>
/// 剪贴板监控服务（<b>平台无关</b>）：监听系统剪贴板变化并维护历史记录。
///
/// 移植自 Windows 的 <c>ClipboardService</c>——把「变更通知机制」下沉到 <see cref="IClipboard"/>
/// 接缝（Win=WM_CLIPBOARDUPDATE 消息窗口，mac=changeCount 轮询定时器），本类只保留两平台一致的
/// 历史编排逻辑：类型判定（File→Image→Text→Html 优先级）、视频链接识别、HTML 提取纯文本、
/// 去重、上限裁剪。
///
/// 变更回调由接缝在 <b>UI 线程</b>触发（NSTimer 挂主 run loop / WPF 消息循环），故
/// <see cref="OnClipboardChanged"/> 内直接读剪贴板无需再调度。
/// </summary>
public sealed class ClipboardService
{
    /// <summary>历史记录保留上限（最近 <value/> 条复制记录）。</summary>
    public const int MaxItems = 100;

    private readonly List<ClipboardEntry> _clipboardHistory = new();
    private string? _lastClipboardText;
    private IClipboard? _clipboard;

    /// <summary>生产构造：剪贴板接缝经 <see cref="AppContainer"/> 惰性解析（组合根注册后生效）。</summary>
    public ClipboardService() { }

    /// <summary>测试构造：注入假剪贴板接缝即可驱动真实历史编排（无需平台权限）。</summary>
    internal ClipboardService(IClipboard clipboard)
    {
        _clipboard = clipboard;
    }

    /// <summary>惰性取剪贴板接缝（生产路径；注册晚于本服务构造时也能接上）。</summary>
    private IClipboard? Clipboard
    {
        get
        {
            if (_clipboard == null && AppContainer.TryResolve<IClipboard>(out var c))
                _clipboard = c;
            return _clipboard;
        }
    }

    /// <summary>剪贴板监控是否正在运行。</summary>
    public bool IsRunning => Clipboard?.IsMonitoring ?? false;

    /// <summary>剪贴板历史记录（只读访问，最新在前，最多 <see cref="MaxItems"/> 条）。</summary>
    public IReadOnlyList<ClipboardEntry> ClipboardHistory => _clipboardHistory;

    /// <summary>剪贴板内容变化事件（历史已更新后触发）。</summary>
    public event Action? ClipboardChanged;

    /// <summary>启动剪贴板监控。重复调用幂等。</summary>
    public void Start()
    {
        var c = Clipboard;
        if (c == null || c.IsMonitoring) return;
        try
        {
            c.StartMonitoring(OnClipboardChanged);
            Framework.RuntimeLog.Debug("[ClipboardService] clipboard monitor started");
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[ClipboardService] Start error: {ex.Message}");
        }
    }

    /// <summary>停止剪贴板监控。</summary>
    public void Stop()
    {
        var c = Clipboard;
        if (c == null || !c.IsMonitoring) return;
        try { c.StopMonitoring(); } catch { }
    }

    /// <summary>从历史记录中移除指定条目，并触发刷新。</summary>
    public void RemoveEntry(ClipboardEntry entry)
    {
        if (_clipboardHistory.Remove(entry))
            ClipboardChanged?.Invoke();
    }

    /// <summary>清空历史记录。</summary>
    public void ClearHistory()
    {
        _clipboardHistory.Clear();
        _lastClipboardText = null;
        ClipboardChanged?.Invoke();
    }

    private void OnClipboardChanged()
    {
        try
        {
            var c = Clipboard;
            if (c == null) return;

            var contentType = ClipboardContentType.Unknown;
            string? contentText;

            // 类型判定优先级：文件 → 图片 → 文本 → HTML（与 Windows 版一致）
            if (c.ContainsFileList())
            {
                contentType = ClipboardContentType.File;
                var filePaths = c.GetFileList().Where(f => !string.IsNullOrEmpty(f)).ToList();
                var fileNames = filePaths.Select(f => System.IO.Path.GetFileName(f));
                contentText = string.Join(", ", fileNames);

                Insert(new ClipboardEntry
                {
                    Text = contentText,
                    Time = DateTime.Now,
                    ContentType = contentType,
                    FilePaths = filePaths,
                });
                return;
            }
            if (c.ContainsImage())
            {
                contentType = ClipboardContentType.Image;
                var png = c.GetImagePng();
                if (png != null && TryReadPngSize(png, out int w, out int h))
                    contentText = Framework.Lang.TF("clipboard.imageX", w, h);
                else
                    contentText = Framework.Lang.T("common.image");
            }
            else if (c.ContainsText())
            {
                contentType = ClipboardContentType.Text;
                contentText = c.GetText();
                if (string.IsNullOrWhiteSpace(contentText)) return;
                contentText = contentText.Trim();
                if (IsVideoUrl(contentText)) contentType = ClipboardContentType.Video;
            }
            else if (c.ContainsHtml())
            {
                contentType = ClipboardContentType.Html;
                contentText = StripHtml(c.GetHtml() ?? "");
                if (string.IsNullOrWhiteSpace(contentText)) return;
                if (contentText.Length > 100)
                    contentText = contentText.Substring(0, 100) + "...";
            }
            else
            {
                return; // 不支持的类型
            }

            // 去重（相同文本内容跳过）——仅对文本/HTML 生效
            if (contentType == ClipboardContentType.Text || contentType == ClipboardContentType.Html)
            {
                if (contentText == _lastClipboardText) return;
                _lastClipboardText = contentText;
            }

            Insert(new ClipboardEntry
            {
                Text = contentText ?? "",
                Time = DateTime.Now,
                ContentType = contentType,
                FilePaths = null,
            });
        }
        catch { }
    }

    /// <summary>移除同文本旧项 → 插入队首 → 裁剪到上限 → 触发刷新（各类型统一的入库路径）。</summary>
    private void Insert(ClipboardEntry entry)
    {
        _clipboardHistory.RemoveAll(e => e.Text == entry.Text);
        _clipboardHistory.Insert(0, entry);
        if (_clipboardHistory.Count > MaxItems)
            _clipboardHistory.RemoveAt(_clipboardHistory.Count - 1);
        ClipboardChanged?.Invoke();
    }

    /// <summary>视频网站链接识别（http 前缀 + 常见视频域名）。</summary>
    private static bool IsVideoUrl(string text)
    {
        if (!text.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return false;
        return text.Contains("youtube.com") || text.Contains("bilibili.com") ||
               text.Contains("vimeo.com") || text.Contains("douyin.com") ||
               text.Contains("tiktok.com");
    }

    /// <summary>HTML → 纯文本：去标签 + 解常见实体 + trim。</summary>
    private static string StripHtml(string html)
    {
        var text = System.Text.RegularExpressions.Regex.Replace(html, "<[^>]+>", "");
        return text.Replace("&nbsp;", " ")
                   .Replace("&amp;", "&")
                   .Replace("&lt;", "<")
                   .Replace("&gt;", ">")
                   .Replace("&quot;", "\"")
                   .Replace("&#39;", "'")
                   .Trim();
    }

    /// <summary>
    /// 从 PNG 字节解析像素尺寸：IHDR 块紧跟 8 字节签名 + 4 字节长度 + 4 字节 "IHDR"，
    /// 宽/高各 4 字节大端，位于偏移 16 / 20。非 PNG 或过短返回 false。
    /// </summary>
    internal static bool TryReadPngSize(byte[] png, out int width, out int height)
    {
        width = height = 0;
        if (png.Length < 24) return false;
        // PNG 签名：89 50 4E 47 0D 0A 1A 0A
        if (png[0] != 0x89 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) return false;
        width = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
        height = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
        return width > 0 && height > 0;
    }

    /// <summary>内容类型对应的图标（emoji）。</summary>
    public static string GetContentTypeIcon(ClipboardContentType type) => type switch
    {
        ClipboardContentType.Text => "📝",
        ClipboardContentType.Image => "🖼️",
        ClipboardContentType.File => "📁",
        ClipboardContentType.Html => "📄",
        ClipboardContentType.Video => "🎬",
        _ => "📋",
    };
}
