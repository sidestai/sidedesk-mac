namespace SideDesk.Services;

/// <summary>
/// 虚拟主机资源 URL 约定接缝（全局，平台相关）。
///
/// Windows（WebView2）用 <c>SetVirtualHostNameToFolderMapping</c> 把 <c>https://&lt;host&gt;/</c>
/// 映射到本地目录；macOS（WKWebView）因 Apple 禁止 <c>WKURLSchemeHandler</c> 拦截 http/https，
/// 改用自定义 scheme <c>sdlocal://&lt;host&gt;/</c>。**主机名两端一致**（如 <c>sd-mdview.local</c>、
/// <c>sd-plugin-*.local</c>），仅 scheme 不同——本接缝把这一平台差异收敛到一处，
/// 使 <c>NoteImageStore</c>/插件宿主/Markdown 渲染统一经它构造资源 URL，而非各自硬编码 https。
///
/// 目录映射本身（host → 本地文件夹 + 实际服务文件）是**每个浏览器实例**的职责，
/// 见 <see cref="IWebBrowser.MapVirtualHostToFolder"/>；本接缝只负责「URL 长什么样」，
/// 无状态，可经 <see cref="Composition.AppContainer"/> 全局解析。
/// </summary>
public interface IWebResourceMapper
{
    /// <summary>平台相关的资源 scheme（Windows: "https"；macOS: "sdlocal"）。</summary>
    string Scheme { get; }

    /// <summary>
    /// 构造指向虚拟主机 <paramref name="host"/> 下 <paramref name="relativePath"/> 的资源 URL
    /// （形如 <c>{Scheme}://{host}/{relativePath}</c>；relativePath 前导 '/' 会被去除）。
    /// </summary>
    string BuildResourceUrl(string host, string relativePath);
}
