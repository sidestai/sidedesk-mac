import Foundation
import SideDeskCore

/// 后端接口共用骨架：Bearer 注入 + 统一信封解包 + 认证失败记账 + 受保护的响应映射。
/// 对应 C# `Services.BackendApiClient`。
///
/// 信封约定（后端统一）：HTTP 2xx 携带 `{ code, msg, data }`。认证失败既可能是 HTTP 401/403，
/// 也可能是 HTTP 200 包着 `code: 401/403`——后端两种形态都出现过，两层都要认。
///
/// 失败必回落、异常不出边界：传输失败与响应非法 JSON 都归入 `Envelope.transportFailed`；
/// 响应映射失败由各通道记日志后回落默认值，绝不把后端的畸形字段变成调用方异常。
public final class BackendApiClient {

    /// 发请求的接缝（测试注入替身；缺省走 URLSession，超时按服务原有配置不统一）
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse?)

    /// 一次请求的信封结果。`transportFailed`=请求没送出去或响应不是合法 JSON
    /// （此时没有可用信封），`transportError` 为异常原文。
    public struct Envelope {
        public let ok: Bool
        public let msg: String
        /// data 节点；业务失败时已被丢弃（见 `parseEnvelope`）
        public let data: JSONValue?
        public let transportFailed: Bool
        public let transportError: String?
    }

    /// `parseEnvelope` 的纯函数结果。`authFlag`=是否改写 `LastAuthFailed`，nil 表示不改写。
    struct Parsed {
        let ok: Bool
        let msg: String
        let data: JSONValue?
        let authFlag: Bool?
    }

    /// 最近一次请求是否因认证失败（401/403）。口径：HTTP 401/403 或业务 code 401/403 → true；
    /// HTTP 成功且业务非认证失败 → 复位 false；其余（其他 HTTP 错误码）→ 不改写。
    public private(set) var LastAuthFailed = false

    private let logTag: String
    private let baseUrl: String
    private let timeout: TimeInterval
    private let transport: Transport

    /// - Parameters:
    ///   - logTag: 日志前缀，如 `[Team]`；沿用各服务原有标签，保住日志检索口径。
    ///   - timeout: 各服务原有超时（30s / 10s），不在此统一——统一超时是行为变更。
    ///   - transport: 仅测试注入；生产传 nil 走 URLSession。
    public init(logTag: String, timeout: TimeInterval, transport: Transport? = nil) {
        self.logTag = logTag
        self.timeout = timeout
        self.baseUrl = Constants.URLs.serverBaseUrl
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: config)
            self.transport = { req in
                let (data, resp) = try await session.data(for: req)
                return (data, resp as? HTTPURLResponse)
            }
        }
    }

    /// 发请求并解信封；GET 用 body=nil，POST 传 JSON 对象作为请求体。
    public func send(_ method: String, _ path: String, body: JSONValue? = nil) async -> Envelope {
        guard let url = URL(string: baseUrl + path) else {
            RuntimeLog.debug("\(logTag) \(method) \(path) 请求失败: invalid url")
            return Envelope(ok: false, msg: "", data: nil, transportFailed: true, transportError: "invalid url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer " + Self.token(), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONEncoder().encode(body)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, resp) = try await transport(req)
            let status = resp?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            RuntimeLog.debug("\(logTag) \(status) \(method) \(path): \(text)")
            let parsed = try Self.parseEnvelope(status: status, json: data)
            if let flag = parsed.authFlag { LastAuthFailed = flag }
            return Envelope(ok: parsed.ok, msg: parsed.msg, data: parsed.data,
                            transportFailed: false, transportError: nil)
        } catch {
            // 请求没送出去 / 响应不是合法 JSON —— 调用方据此回落（各接口回落值不同）
            RuntimeLog.debug("\(logTag) \(method) \(path) 请求失败: \(error.localizedDescription)")
            return Envelope(ok: false, msg: "", data: nil, transportFailed: true,
                            transportError: error.localizedDescription)
        }
    }

    /// 取数组：data 须为 JSON 数组并映射为 `[T]`；不是数组或映射失败回落 nil（不抛）。
    public func sendList<T: Decodable>(_ method: String, _ path: String, body: JSONValue? = nil) async -> [T]? {
        let r = await send(method, path, body: body)
        guard case .array? = r.data else { return nil }
        return map(r.data, as: [T].self, path: path, method: method)
    }

    /// 取对象：data 须为 JSON 对象并映射为 `T`；否则回落 nil（映射失败也不抛）。
    public func sendObject<T: Decodable>(_ method: String, _ path: String, body: JSONValue? = nil) async -> T? {
        let r = await send(method, path, body: body)
        guard case .object? = r.data else { return nil }
        return await map(r.data, as: T.self, path: path, method: method)
    }

    /// JSONValue → Decodable：映射失败记日志后回落 nil（对应 C# 的 ToObject try/catch）。
    private func map<T: Decodable>(_ value: JSONValue?, as type: T.Type, path: String, method: String) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        do {
            return try SideDeskJSON.decoder().decode(type, from: data)
        } catch {
            RuntimeLog.debug("\(logTag) \(method) \(path) 响应映射失败（已回落）: \(error.localizedDescription)")
            return nil
        }
    }

    /// 纯函数：HTTP 状态 + 响应体 → 信封语义。抽出来是为了能逐分支单测——网络路径在单测里
    /// 无法穷举，而全部分支判断都集中在这里。非法 JSON 抛出，由 `send` 按传输失败处理。
    static func parseEnvelope(status: Int, json: Data) throws -> Parsed {
        let httpAuth = status == 401 || status == 403
        guard (200..<300).contains(status) else {
            return Parsed(ok: false, msg: "", data: nil, authFlag: httpAuth ? true : nil)   // 非认证类 HTTP 错误不改写标记
        }

        struct RawEnvelope: Decodable { let code: Int?; let msg: String?; let data: JSONValue? }
        let root = try JSONDecoder().decode(RawEnvelope.self, from: json)
        let code = root.code ?? 0
        let msg = root.msg ?? ""

        if code == 401 || code == 403 {
            return Parsed(ok: false, msg: msg, data: nil, authFlag: true)
        }
        // 业务非 200 必须把 data 一并丢掉：调用方（列表/对象方法）只判 data 的存在性、
        // 不看成功标志，留着 data 会把「后端报错但捎带数据」渲染成真实数据。
        if code != 200 {
            return Parsed(ok: false, msg: msg, data: nil, authFlag: false)
        }
        // HTTP 成功且业务非认证失败 → 复位标记（这正是属性名承诺的语义）
        return Parsed(ok: true, msg: msg, data: root.data, authFlag: false)
    }

    /// 读当前账号 token。取不到（未登录）返回空串，不抛。
    static func token() -> String { Seam.settings.AccountToken ?? "" }

    /// 查询串取值转义（对应 C# `Uri.EscapeDataString`：只保留 RFC 3986 非保留字符）。
    static func queryValue(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
