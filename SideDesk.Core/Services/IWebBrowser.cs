using System;
using System.Threading.Tasks;

namespace SideDesk.Services;

/// <summary>
/// 内嵌浏览器接缝（分层解耦）：抽象 WebView2 的 <c>CoreWebView2</c> 表面，
/// 让上层（插件宿主 / 卡片渲染 / 聊天 / Markdown 预览）与具体引擎解耦。
/// Windows 实现基于 <c>Microsoft.Web.WebView2</c>，macOS 实现基于 WebKit 的
/// <c>WKWebView</c>（<c>SideDesk.Platform.Mac.WKWebViewBrowser</c>）。
///
/// <b>JS 互操作契约（两端必须一致）：</b>沿用 WebView2 约定，网页侧用
/// <c>window.chrome.webview.postMessage(obj)</c> 发消息给宿主、用
/// <c>window.chrome.webview.addEventListener('message', e =&gt; ...)</c> 收宿主消息。
/// macOS 端由实现注入 JS shim 在 <c>window.webkit.messageHandlers</c> 之上复刻这套 API，
/// 故既有卡片/插件前端零改动即可运行。
///
/// <b>消息编码：</b><see cref="PostWebMessageAsJson"/> 收 JSON 文本，网页监听器拿到的
/// <c>e.data</c> 即其解析后的对象（等价 WebView2 PostWebMessageAsJson）；
/// <see cref="WebMessageReceived"/> 参数是网页 postMessage 内容的 JSON 文本
/// （等价 <c>e.WebMessageAsJson</c>）。<see cref="ExecuteScriptAsync"/> 返回脚本结果的
/// JSON 编码（等价 WebView2 ExecuteScriptAsync）。
///
/// <b>线程约束：</b>所有成员须在 UI 线程调用（WebView2/WKWebView 均要求）；
/// 后台线程经 <c>ServiceSeam.UiInvoke</c> 调度回主线程后再调用。
/// </summary>
public interface IWebBrowser
{
    /// <summary>浏览器视图是否已就绪（可导航/执行脚本）。</summary>
    bool IsReady { get; }

    /// <summary>导航到指定 URL。</summary>
    void Navigate(string url);

    /// <summary>以 HTML 字符串作为文档加载（等价 WebView2 NavigateToString，base 为 about:blank）。</summary>
    void NavigateToString(string html);

    /// <summary>重新加载当前文档。</summary>
    void Reload();

    /// <summary>在当前文档执行脚本，返回结果的 JSON 编码（无返回值为 "null"）。</summary>
    Task<string?> ExecuteScriptAsync(string script);

    /// <summary>宿主 → 网页：投递 JSON 消息，触发网页 <c>window.chrome.webview</c> 的 message 监听器。</summary>
    void PostWebMessageAsJson(string json);

    /// <summary>网页 → 宿主：收到 <c>window.chrome.webview.postMessage(...)</c> 时触发，参数为其 JSON 文本。</summary>
    event Action<string> WebMessageReceived;

    /// <summary>注册在每个文档创建时执行的脚本（等价 WebView2 AddScriptToExecuteOnDocumentCreatedAsync；对后续加载生效）。</summary>
    void AddScriptToExecuteOnDocumentCreated(string script);

    /// <summary>
    /// 把虚拟主机映射到本地目录，使该浏览器能解析 <c>{scheme}://{host}/...</c> 下的静态资源
    /// （等价 WebView2 SetVirtualHostNameToFolderMapping，只读）。host 大小写不敏感；
    /// scheme 由平台的 <see cref="IWebResourceMapper"/> 决定（macOS: sdlocal）。
    /// 可在导航前后调用，请求发生时按最新注册表解析。
    /// </summary>
    void MapVirtualHostToFolder(string host, string folderPath);
}
