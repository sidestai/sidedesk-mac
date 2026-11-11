using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using AppKit;
using CoreGraphics;
using Foundation;
using Newtonsoft.Json;
using SideDesk.Services;
using WebKit;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IWebBrowser"/> 的 macOS 实现，基于 WebKit <c>WKWebView</c>，取代 Windows 的 WebView2。
///
/// <b>JS 契约复刻：</b>既有卡片/插件前端用 <c>window.chrome.webview.postMessage</c> /
/// <c>addEventListener('message')</c>（WebView2 专有）。WKWebView 原生是
/// <c>window.webkit.messageHandlers.&lt;name&gt;.postMessage</c>（JS→原生）且**无**原生→JS 通道。
/// 故本实现在文档创建时注入 <see cref="Shim"/>，在 messageHandlers 之上重建 <c>window.chrome.webview</c>：
///  - <c>postMessage(obj)</c> → <c>JSON.stringify</c> 后经 messageHandlers.sidedesk 发给原生，
///    原生直接把该 JSON 文本作为 <see cref="IWebBrowser.WebMessageReceived"/> 参数（等价 <c>e.WebMessageAsJson</c>）；
///  - 原生 <see cref="PostWebMessageAsJson"/> → 执行 JS 调 <c>__dispatch(JSON.parse(json))</c>，
///    分发 <c>{data: obj}</c> 给所有 message 监听器（等价 WebView2 语义）。
///
/// <b>线程约束：</b>WKWebView 只能在 UI 线程操作；且加载/脚本回调需主 RunLoop 泵动
/// （生产外壳的 NSApplication 主循环天然满足）。
/// </summary>
public sealed class WKWebViewBrowser : IWebBrowser, IDisposable
{
    // JS→原生 messageHandlers 通道名（shim 与此处必须一致）。
    private const string HandlerName = "sidedesk";

    private readonly WKWebView _view;
    private readonly MessageHandler _handler;
    private readonly SchemeHandler _schemeHandler;
    // 虚拟主机 → 本地目录注册表（per-browser，等价 WebView2 的 SetVirtualHostNameToFolderMapping）。
    private readonly ConcurrentDictionary<string, string> _hostFolders = new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    /// <summary>供 AppKit UI 层承载的原生视图（WKWebView 本身即 NSView）。UI 层负责布局/加入视图层级。</summary>
    public NSView View => _view;

    public WKWebViewBrowser()
    {
        var config = new WKWebViewConfiguration();
        var ucc = config.UserContentController;

        // 文档创建前注入 shim，确保网页脚本首次运行前 window.chrome.webview 已就位。
        ucc.AddUserScript(new WKUserScript((NSString)Shim, WKUserScriptInjectionTime.AtDocumentStart, false));

        _handler = new MessageHandler(this);
        ucc.AddScriptMessageHandler(_handler, HandlerName);

        // 自定义 scheme 服务本地目录（必须在 WKWebView 创建前注册；请求时按 _hostFolders 解析）。
        _schemeHandler = new SchemeHandler(_hostFolders);
        config.SetUrlSchemeHandler(_schemeHandler, WKWebResourceMapper.UrlScheme);

        _view = new WKWebView(CGRect.Empty, config)
        {
            AutoresizingMask = NSViewResizingMask.WidthSizable | NSViewResizingMask.HeightSizable,
        };
    }

    public bool IsReady => !_disposed && _view.Handle != IntPtr.Zero;

    public void Navigate(string url)
    {
        if (string.IsNullOrEmpty(url)) return;
        _view.LoadRequest(new NSUrlRequest(new NSUrl(url)));
    }

    public void NavigateToString(string html) =>
        _view.LoadHtmlString(html ?? "", null!);

    public void Reload() => _view.Reload();

    public Task<string?> ExecuteScriptAsync(string script)
    {
        var tcs = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _view.EvaluateJavaScript(script ?? "", (NSObject result, NSError error) =>
        {
            if (error != null) tcs.TrySetResult(null);
            else tcs.TrySetResult(ToJson(result));
        });
        return tcs.Task;
    }

    public void PostWebMessageAsJson(string json)
    {
        if (string.IsNullOrEmpty(json)) return;
        // 把 json 文本编码为 JS 字符串字面量，网页侧 JSON.parse 还原为对象后分发。
        string literal = JsonConvert.SerializeObject(json);
        _view.EvaluateJavaScript(
            $"window.chrome.webview && window.chrome.webview.__dispatch(JSON.parse({literal}));",
            (NSObject result, NSError error) => { });
    }

    public event Action<string>? WebMessageReceived;

    public void AddScriptToExecuteOnDocumentCreated(string script)
    {
        if (string.IsNullOrEmpty(script)) return;
        // 追加到内容控制器：对**后续**加载的文档生效（与 WebView2 语义一致）。
        _view.Configuration.UserContentController.AddUserScript(
            new WKUserScript((NSString)script, WKUserScriptInjectionTime.AtDocumentStart, false));
    }

    public void MapVirtualHostToFolder(string host, string folderPath)
    {
        if (string.IsNullOrEmpty(host) || string.IsNullOrEmpty(folderPath)) return;
        _hostFolders[host.TrimEnd('/')] = folderPath;
    }

    // shim 收到消息 → 由 MessageHandler 回调进来，在 UI 线程触发事件。
    private void OnScriptMessage(NSObject? body)
    {
        // shim 始终以字符串（JSON 文本）postMessage，故 body 通常是 NSString；容错处理其他类型。
        string json = body switch
        {
            null or NSNull => "null",
            NSString s => s.ToString(),
            _ when NSJsonSerialization.IsValidJSONObject(body) =>
                NSString.FromData(NSJsonSerialization.Serialize(body, 0, out _), NSStringEncoding.UTF8)?.ToString() ?? "null",
            _ => JsonConvert.SerializeObject(body.ToString()),
        };
        WebMessageReceived?.Invoke(json);
    }

    /// <summary>把 evaluateJavaScript 的结果对象转为 JSON 文本（对齐 WebView2 ExecuteScriptAsync 返回）。</summary>
    private static string? ToJson(NSObject? r)
    {
        if (r == null || r is NSNull) return "null";
        if (r is NSString s) return JsonConvert.SerializeObject(s.ToString());
        if (r is NSNumber n) return NumberToJson(n);
        if (NSJsonSerialization.IsValidJSONObject(r))
        {
            var data = NSJsonSerialization.Serialize(r, 0, out _);
            if (data != null) return NSString.FromData(data, NSStringEncoding.UTF8)?.ToString();
        }
        return JsonConvert.SerializeObject(r.ToString());
    }

    private static string NumberToJson(NSNumber n)
    {
        string t = n.ObjCType;   // 'c'/'B'=BOOL, 'd'/'f'=浮点, 其余按整型
        if (t == "c" || t == "B") return n.BoolValue ? "true" : "false";
        if (t == "d" || t == "f") return n.DoubleValue.ToString(CultureInfo.InvariantCulture);
        return n.Int64Value.ToString(CultureInfo.InvariantCulture);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            _view.Configuration.UserContentController.RemoveScriptMessageHandler(HandlerName);
            _view.Configuration.UserContentController.RemoveAllUserScripts();
            _handler.Detach();
            _view.Dispose();
        }
        catch { }
    }

    /// <summary>WKScriptMessageHandler 桥：把 WebKit 回调转给宿主实例；Detach 后置空避免回调已释放对象。</summary>
    private sealed class MessageHandler : WKScriptMessageHandler
    {
        private WKWebViewBrowser? _owner;
        public MessageHandler(WKWebViewBrowser owner) => _owner = owner;
        public void Detach() => _owner = null;
        public override void DidReceiveScriptMessage(WKUserContentController userContentController, WKScriptMessage message)
            => _owner?.OnScriptMessage(message.Body);
    }

    /// <summary>
    /// 自定义 scheme（sdlocal://）的文件服务：把 <c>sdlocal://{host}/{relativePath}</c> 解析到
    /// 已注册目录并回吐文件字节，取代 WebView2 的 https 虚拟主机映射（Apple 禁止拦截 http/https）。
    /// 只读、带路径越界防护；找不到/越界一律回 404（不让页面拿到目录外内容）。
    /// </summary>
    private sealed class SchemeHandler : NSObject, IWKUrlSchemeHandler
    {
        private readonly ConcurrentDictionary<string, string> _hostFolders;
        // 已 Stop 的任务集合：WebKit 要求 stop 后不得再对该 task 回调，否则抛异常。
        private readonly System.Collections.Generic.HashSet<IWKUrlSchemeTask> _stopped = new();

        public SchemeHandler(ConcurrentDictionary<string, string> hostFolders) => _hostFolders = hostFolders;

        [Export("webView:startURLSchemeTask:")]
        public void StartUrlSchemeTask(WKWebView webView, IWKUrlSchemeTask urlSchemeTask)
        {
            try
            {
                var url = urlSchemeTask.Request.Url;
                string host = url?.Host ?? "";
                string path = url?.Path ?? "";
                if (!_hostFolders.TryGetValue(host, out string? folder) || string.IsNullOrEmpty(folder))
                {
                    Respond(urlSchemeTask, url, 404, null, null);
                    return;
                }

                string rel = Uri.UnescapeDataString(path).TrimStart('/');
                string fullPath = Path.GetFullPath(Path.Combine(folder, rel));
                string rootFull = Path.GetFullPath(folder);
                // 路径越界防护：拒绝跳出映射目录（../ 等）
                if (!fullPath.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.Ordinal)
                    || !File.Exists(fullPath))
                {
                    Respond(urlSchemeTask, url, 404, null, null);
                    return;
                }

                var data = NSData.FromFile(fullPath);
                Respond(urlSchemeTask, url, 200, MimeFor(fullPath), data);
            }
            catch (Exception ex)
            {
                try { urlSchemeTask.DidFailWithError(NSError.FromDomain(NSError.OsStatusErrorDomain, -1,
                    NSDictionary.FromObjectAndKey((NSString)ex.Message, (NSString)"NSLocalizedDescriptionKey"))); }
                catch { }
            }
        }

        [Export("webView:stopURLSchemeTask:")]
        public void StopUrlSchemeTask(WKWebView webView, IWKUrlSchemeTask urlSchemeTask)
        {
            lock (_stopped) _stopped.Add(urlSchemeTask);
        }

        private void Respond(IWKUrlSchemeTask task, NSUrl? url, int status, string? mime, NSData? body)
        {
            lock (_stopped) if (_stopped.Contains(task)) return;   // 已取消，禁止回调
            try
            {
                var headers = new NSMutableDictionary();
                if (mime != null) headers[(NSString)"Content-Type"] = (NSString)mime;
                var resp = new NSHttpUrlResponse(url ?? new NSUrl("sdlocal://localhost/"), (IntPtr)status, "HTTP/1.1", headers);
                task.DidReceiveResponse(resp);
                if (body != null) task.DidReceiveData(body);
                task.DidFinish();
            }
            catch { }
        }

        private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".html" or ".htm" => "text/html; charset=utf-8",
            ".js" or ".mjs" => "text/javascript; charset=utf-8",
            ".css" => "text/css; charset=utf-8",
            ".json" => "application/json; charset=utf-8",
            ".svg" => "image/svg+xml",
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".ico" => "image/x-icon",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2",
            ".ttf" => "font/ttf",
            ".txt" => "text/plain; charset=utf-8",
            ".wasm" => "application/wasm",
            _ => "application/octet-stream",
        };
    }

    /// <summary>
    /// 注入网页的兼容 shim：在 WKWebView 的 messageHandlers 之上重建 WebView2 的
    /// <c>window.chrome.webview</c>（postMessage / addEventListener / removeEventListener）。
    /// <c>__dispatch</c> 供原生 PostWebMessageAsJson 调用。幂等：重复注入直接返回。
    /// </summary>
    private const string Shim = @"
(function () {
  if (window.chrome && window.chrome.webview && window.chrome.webview.__sdShim) return;
  window.chrome = window.chrome || {};
  var listeners = [];
  var wk = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sidedesk;
  window.chrome.webview = {
    __sdShim: true,
    postMessage: function (obj) {
      if (!wk) return;
      try { wk.postMessage(obj === undefined ? 'null' : JSON.stringify(obj)); } catch (_) { }
    },
    addEventListener: function (type, cb) { if (type === 'message' && typeof cb === 'function') listeners.push(cb); },
    removeEventListener: function (type, cb) {
      if (type !== 'message') return;
      var i = listeners.indexOf(cb); if (i >= 0) listeners.splice(i, 1);
    },
    __dispatch: function (data) {
      var e = { data: data };
      for (var i = 0; i < listeners.length; i++) { try { listeners[i](e); } catch (_) { } }
    }
  };
})();";
}
