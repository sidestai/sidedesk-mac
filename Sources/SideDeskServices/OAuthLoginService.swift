import CryptoKit
import Foundation
import Network
import SideDeskCore

/// 桌面客户端「系统浏览器登录」：OAuth2 授权码 + PKCE(S256) + Loopback 回环（RFC 8252）。
/// 对应 C# `Services.OAuthLoginService`（macOS 无 WebView2 兜底通道，浏览器登录即唯一入口）。
/// 流程：
///   1) 生成 code_verifier / code_challenge(S256) / state；
///   2) 起临时回环监听 http://127.0.0.1:{随机端口}/callback；
///   3) 系统默认浏览器打开后端授权入口 {ServerBaseUrl}/api/oauth/authorize?...；
///   4) 前端回跳 loopback /callback?code&state → 校验 state → 返回「可关闭此页」HTML；
///   5) POST /api/oauth/token（授权码 + code_verifier）换取 access_token。
/// 任一环节失败/超时/取消均返回 nil。
public enum OAuthLoginService {

    /// 整个浏览器登录流程的等待上限（用户需在浏览器完成登录 + 授权，留足时间）
    private static let loginTimeout: TimeInterval = 180
    /// 令牌交换请求超时（换取 access_token 是快速接口）
    private static let tokenHttpTimeout: TimeInterval = 30

    /// 发起系统浏览器 OAuth2 登录。成功返回 access_token；失败 / 超时 / 取消返回 nil。
    public static func login() async -> String? {
        let codeVerifier = base64Url(randomBytes(32))
        let codeChallenge = base64Url(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let state = base64Url(randomBytes(16))

        let server = LoopbackCallbackServer(expectedState: state)
        guard let port = await server.start() else {
            RuntimeLog.debug("[OAuth] no loopback port available, abort browser login")
            return nil
        }
        let redirectUri = "http://127.0.0.1:\(port)/callback"
        RuntimeLog.debug("[OAuth] loopback listener started on \(redirectUri)")

        guard let authorizeUrl = URL(string: buildAuthorizeUrl(redirectUri: redirectUri,
                                                               codeChallenge: codeChallenge, state: state)),
              Seam.openUrl(authorizeUrl) else {
            RuntimeLog.debug("[OAuth] failed to launch system browser")
            server.stop()
            return nil
        }

        let code = await server.waitForCallback(timeout: loginTimeout)
        server.stop()
        guard let code, !code.isEmpty else {
            RuntimeLog.debug("[OAuth] login timed out, cancelled or rejected")
            return nil
        }
        return await exchangeCodeForToken(code: code, codeVerifier: codeVerifier, redirectUri: redirectUri)
    }

    /// 用系统默认浏览器打开 web 控制台页面（path 形如 /system/user-center）。
    /// 已登录时先换一次性交接码走 /#/handoff?code=…&redirect=… 免登直达
    /// （长期 token 不进 URL/浏览器历史）；未登录或换取失败则直接打开目标页。
    /// 对应 C# `OpenConsolePageAsync`。
    public static func openConsolePage(_ path: String) async {
        var target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { target = "/" }
        if !target.hasPrefix("/") { target = "/" + target }

        var handoff: String?
        if let token = Seam.settings.AccountToken, !token.isEmpty {
            let api = BackendApiClient(logTag: "[OAuth]", timeout: tokenHttpTimeout)
            let r = await api.send("POST", "/api/oauth/handoff/code", body: .object([:]))
            if r.ok, case .object(let data) = r.data, let c = data["code"]?.stringValue, !c.isEmpty {
                handoff = c
            }
        }
        let esc = BackendApiClient.queryValue
        let urlText: String
        if let handoff {
            urlText = Constants.URLs.frontendBaseUrl + "/#/handoff?code=" + esc(handoff)
                + "&redirect=" + esc(target)
        } else {
            urlText = Constants.URLs.frontendBaseUrl + "/#" + target
        }
        if let url = URL(string: urlText) { _ = Seam.openUrl(url) }
    }

    // MARK: - PKCE / state / URL

    /// code_verifier：base64url(随机 32 字节)，长度 43，符合 RFC 7636 的 [43,128] 约束
    private static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// base64url 编码（去掉填充 '='，'+'→'-'，'/'→'_'），与后端 PKCE 校验一致
    private static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// 拼接后端授权入口 URL（走 /api 前缀，由 nginx 反代到后端 /oauth/authorize）
    private static func buildAuthorizeUrl(redirectUri: String, codeChallenge: String, state: String) -> String {
        let esc = BackendApiClient.queryValue
        let q = "response_type=code"
            + "&client_id=" + esc(Constants.URLs.oauthClientId)
            + "&redirect_uri=" + esc(redirectUri)
            + "&code_challenge=" + esc(codeChallenge)
            + "&code_challenge_method=S256"
            + "&state=" + esc(state)
        return Constants.URLs.serverBaseUrl + "/api/oauth/authorize?" + q
    }

    // MARK: - 令牌交换

    /// POST /api/oauth/token：授权码 + code_verifier 换 access_token；失败返回 nil。
    /// 字段名须与后端 OAuthTokenDto 完全一致（全局 whitelist 会剔除未知字段）。
    private static func exchangeCodeForToken(code: String, codeVerifier: String, redirectUri: String) async -> String? {
        guard let url = URL(string: Constants.URLs.serverBaseUrl + "/api/oauth/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = tokenHttpTimeout
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // 后端用 user-agent 构造 clientInfo，显式带上避免解析空值
        req.setValue("SideDesk-Desktop/1.0 (OAuth2 PKCE loopback)", forHTTPHeaderField: "User-Agent")
        let body: JSONValue = .object([
            "grant_type": .string("authorization_code"),
            "code": .string(code),
            "code_verifier": .string(codeVerifier),
            "redirect_uri": .string(redirectUri),
            "client_id": .string(Constants.URLs.oauthClientId),
        ])
        req.httpBody = try? JSONEncoder().encode(body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = tokenHttpTimeout
        let session = URLSession(configuration: config)
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(status) else {
                RuntimeLog.debug("[OAuth] token exchange failed \(status): \(text)")
                return nil
            }
            // 兼容标准 OAuth2（顶层 access_token）与 ResultData 包裹（data.access_token）两种形态
            let root = JSONValue(any: try JSONSerialization.jsonObject(with: data))
            if case .object(let obj) = root {
                if let t = obj["access_token"]?.stringValue, !t.isEmpty { return t }
                if case .object(let d) = obj["data"], let t = d["access_token"]?.stringValue, !t.isEmpty { return t }
            }
            RuntimeLog.debug("[OAuth] token response has no access_token: \(text)")
            return nil
        } catch {
            RuntimeLog.debug("[OAuth] token exchange error: \(error.localizedDescription)")
            return nil
        }
    }
}

/// 回环回调监听：NWListener 绑定 127.0.0.1 随机端口，只认 /callback 路径。
/// 对应 C# `LoopbackHttpListener` + `WaitForCallbackAsync`（state 防 CSRF、非回调路径 404 继续等、
/// 超时/取消由 finish(nil) 统一收口，continuation 保证只 resume 一次）。
final class LoopbackCallbackServer {

    private let expectedState: String
    private let queue = DispatchQueue(label: "sidedesk.oauth.loopback")
    private let lock = SyncLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String?, Never>?
    private var readyContinuation: CheckedContinuation<UInt16?, Never>?
    private var finished = false
    private var result: String?
    private var timeoutWork: DispatchWorkItem?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    /// 启动监听并返回系统分配的端口；绑定失败返回 nil。
    func start() async -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return await withCheckedContinuation { cont in
            lock.withLock { readyContinuation = cont }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = l.port?.rawValue ?? 0
                    self.finishReady(port > 0 ? port : nil)
                case .failed(let err):
                    RuntimeLog.debug("[OAuth] loopback listener failed: \(err)")
                    self.finishReady(nil)
                case .cancelled:
                    self.finishReady(nil)
                default:
                    break
                }
            }
            l.start(queue: queue)
        }
    }

    private func finishReady(_ port: UInt16?) {
        let cont = lock.withLock { () -> CheckedContinuation<UInt16?, Never>? in
            let c = readyContinuation
            readyContinuation = nil
            return c
        }
        cont?.resume(returning: port)
    }

    /// 等待浏览器回跳（带整体超时）；超时/拒绝/错误返回 nil。
    func waitForCallback(timeout: TimeInterval) async -> String? {
        let work = DispatchWorkItem { [weak self] in
            RuntimeLog.debug("[OAuth] callback wait timed out")
            self?.finish(nil)
        }
        lock.withLock { timeoutWork = work }
        queue.asyncAfter(deadline: .now() + timeout, execute: work)

        return await withCheckedContinuation { cont in
            let early: (done: Bool, value: String?) = lock.withLock {
                if finished { return (true, result) }
                continuation = cont
                return (false, nil)
            }
            if early.done { cont.resume(returning: early.value) }
        }
    }

    func stop() {
        finish(nil)
    }

    /// 唯一收口：幂等，continuation 只 resume 一次。
    private func finish(_ code: String?) {
        struct Drain {
            var cont: CheckedContinuation<String?, Never>?
            var work: DispatchWorkItem?
            var listener: NWListener?
            var already = false
        }
        let d = lock.withLock { () -> Drain in
            if finished { return Drain(already: true) }
            finished = true
            result = code
            let d = Drain(cont: continuation, work: timeoutWork, listener: listener)
            continuation = nil
            timeoutWork = nil
            listener = nil
            return d
        }
        guard !d.already else { return }
        d.work?.cancel()
        d.listener?.cancel()
        d.cont?.resume(returning: code)
    }

    // MARK: - HTTP 处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// 攒够请求头（\r\n\r\n）即路由；GET 回调无请求体，不需要读更多。
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buf[..<end.lowerBound], encoding: .utf8) ?? ""
                self.route(conn, header: header)
            } else if isComplete || error != nil || buf.count > 256 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(_ conn: NWConnection, header: String) {
        let firstLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        guard let comps = URLComponents(string: "http://127.0.0.1" + target) else {
            sendHtml(conn, status: 400, html: callbackHtml(success: false, message: "无效的请求。"))
            return
        }
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path == "callback" else {
            // 非回调路径（如 /favicon.ico）404 后继续等待其它连接
            sendHtml(conn, status: 404, html: callbackHtml(success: false, message: "无效的回调路径。"))
            return
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }

        if let err = query["error"], !err.isEmpty {
            sendHtml(conn, status: 400, html: callbackHtml(success: false, message: "授权被拒绝：\(err)"))
            finish(nil)
            return
        }
        let code = query["code"] ?? ""
        let recvState = query["state"] ?? ""
        if code.isEmpty || recvState != expectedState {
            RuntimeLog.debug("[OAuth] callback rejected: state mismatch or missing code")
            sendHtml(conn, status: 400,
                     html: callbackHtml(success: false,
                                        message: "登录状态校验失败（state 不匹配或缺少授权码），请返回客户端重试。"))
            finish(nil)
            return
        }
        sendHtml(conn, status: 200, html: callbackHtml(success: true, message: nil))
        finish(code)
    }

    private func sendHtml(_ conn: NWConnection, status: Int, html: String) {
        let body = Data(html.utf8)
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 回环回调页（成功/失败双语提示；C# 同样硬编码双语，浏览器页不走应用内 Lang）
    private func callbackHtml(success: Bool, message: String?) -> String {
        let icon = success
            ? "<svg viewBox=\"0 0 24 24\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"12\" cy=\"12\" r=\"11\" fill=\"#22c55e\"/><path d=\"M7 12.5l3.2 3.2L17 9\" stroke=\"#fff\" stroke-width=\"2.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>"
            : "<svg viewBox=\"0 0 24 24\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"12\" cy=\"12\" r=\"11\" fill=\"#ef4444\"/><path d=\"M8.5 8.5l7 7M15.5 8.5l-7 7\" stroke=\"#fff\" stroke-width=\"2.2\" stroke-linecap=\"round\"/></svg>"
        let title = success ? "登录成功 · Signed in" : "登录失败 · Sign-in failed"
        let color = success ? "#16a34a" : "#dc2626"
        let desc = success
            ? "你已登录 SideDesk，可以关闭此页面并返回桌面客户端。<br>You are signed in to SideDesk. You can close this page and return to the app."
            : escapeHtml(message ?? "") + "<br><br>请返回 SideDesk 重试。<br>Please return to SideDesk and try again."
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>SideDesk</title>
        <style>
          html, body { height: 100%; margin: 0; }
          body { display: flex; align-items: center; justify-content: center;
                 font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Microsoft YaHei', sans-serif;
                 background: #f5f6f8; color: #1f2329; }
          .card { text-align: center; padding: 48px 36px; max-width: 460px; }
          .icon { width: 68px; height: 68px; margin: 0 auto 22px; }
          h1 { font-size: 20px; font-weight: 600; margin: 0 0 12px; }
          p { font-size: 14px; line-height: 1.7; color: #646a73; margin: 0; }
        </style>
        </head>
        <body>
          <div class="card">
            <div class="icon">\(icon)</div>
            <h1 style="color:\(color)">\(title)</h1>
            <p>\(desc)</p>
          </div>
        </body>
        </html>
        """
    }

    private func escapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}