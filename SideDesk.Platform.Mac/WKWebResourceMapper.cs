using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IWebResourceMapper"/> 的 macOS 实现：自定义 scheme <c>sdlocal</c>
/// （Apple 禁止 WKURLSchemeHandler 拦截 http/https，故不用 WebView2 的 https 虚拟主机）。
/// 主机名沿用 Windows 约定，仅 scheme 不同。无状态，全局单例注册进 AppContainer。
/// </summary>
public sealed class WKWebResourceMapper : IWebResourceMapper
{
    /// <summary>自定义资源 scheme（WKWebViewBrowser 以此注册 WKURLSchemeHandler）。</summary>
    public const string UrlScheme = "sdlocal";

    public string Scheme => UrlScheme;

    public string BuildResourceUrl(string host, string relativePath)
    {
        string h = (host ?? "").TrimEnd('/');
        string rel = (relativePath ?? "").TrimStart('/');
        return $"{UrlScheme}://{h}/{rel}";
    }
}
