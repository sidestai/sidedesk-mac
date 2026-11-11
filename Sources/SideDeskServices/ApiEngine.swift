import Foundation
import SideDeskCore

/// API 直连取数引擎：`ApiMethod` 非空的数据项不经浏览器，直接 HTTP GET/POST 取数。
/// 对应 C# `DataPollingService.Api.cs` 的 `PollApiAsync` + `ExtractApiValue`。
public final class ApiEngine: ValueEngine {

    /// 发请求的接缝（测试注入替身；缺省走 URLSession，超时 20 秒与 C# HttpClient 一致）
    public typealias Perform = (URLRequest) async throws -> (Data, URLResponse?)

    private let perform: Perform

    public init(perform: Perform? = nil) {
        if let perform {
            self.perform = perform
        } else {
            let session = URLSession(configuration: .ephemeral)
            self.perform = { req in
                let (data, resp) = try await session.data(for: req)
                return (data, resp)
            }
        }
    }

    public func fetch(_ item: DataDashboardItem, forceLaunch: Bool) async -> String? {
        guard let url = URL(string: item.TargetUrl) else {
            RuntimeLog.debug("[DataPolling] ✗ API request error \"\(item.Label)\": invalid url \(item.TargetUrl)")
            return "--"
        }
        let isPost = (item.ApiMethod ?? "").lowercased() == "post"
        var req = URLRequest(url: url)
        req.httpMethod = isPost ? "POST" : "GET"
        req.timeoutInterval = 20
        if isPost {
            req.httpBody = (item.ApiBody ?? "").data(using: .utf8)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, resp) = try await perform(req)
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                // 与 C# 一致：非 2xx 只记日志，响应体仍按提取规则解析（很多接口会带错误详情）
                RuntimeLog.debug("[DataPolling] ✗ API request failed \"\(item.Label)\": HTTP \(status)")
            }
            var value = Self.extractApiValue(body, item.ResponseExtract, item.ApiExtractType)
            if value != "--" { value = DataDashboardItem.ApplyValueExtract(value, item.ExtractRegex, item.ExtractFormat) }
            RuntimeLog.debug("[DataPolling] ✓ API \"\(item.Label)\" = \"\(value)\"")
            return value
        } catch {
            RuntimeLog.debug("[DataPolling] ✗ API request error \"\(item.Label)\": \(error.localizedDescription)")
            return "--"
        }
    }

    /// 从 API 响应中提取值：`extractType=regex` 时按正则首匹配（有捕获组取首分组）；
    /// 否则按 JSON 路径（如 `data.list[0].count`）取值；路径留空返回整个响应；非 JSON 时回退返回原文。
    public static func extractApiValue(_ body: String, _ extract: String?, _ extractType: String?) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let extract, !extract.trimmingCharacters(in: .whitespaces).isEmpty else {
            return trimmedBody.isEmpty ? "--" : trimmedBody
        }

        if (extractType ?? "").lowercased() == "regex" {
            do {
                let re = try NSRegularExpression(pattern: extract)
                let ns = body as NSString
                guard let m = re.firstMatch(in: body, options: [], range: NSRange(location: 0, length: ns.length)) else {
                    return "--"
                }
                let text = m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
                return text.trimmingCharacters(in: .whitespaces).isEmpty ? "--" : text
            } catch {
                RuntimeLog.debug("[DataPolling] regex extraction failed (\(extract)): \(error.localizedDescription)")
                return "--"
            }
        }

        do {
            let root = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.allowFragments])
            guard let hit = Self.selectToken(root, extract) else { return "--" }
            let text = Self.tokenText(hit)
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? "--" : text
        } catch {
            RuntimeLog.debug("[DataPolling] response extraction failed (\(extract)): \(error.localizedDescription)")
            return trimmedBody.isEmpty ? "--" : trimmedBody
        }
    }

    // MARK: - JSON 路径（对应 Newtonsoft `JToken.SelectToken` 的点路径 + 下标子集）

    enum Token { case key(String), index(Int) }

    static func pathTokens(_ path: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(path)
        var i = 0
        // 去掉前导 "$" / "$."
        if i < chars.count, chars[i] == "$" {
            i += 1
            if i < chars.count, chars[i] == "." { i += 1 }
        }
        while i < chars.count {
            // 读 key 段
            var name = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                name.append(chars[i]); i += 1
            }
            if !name.isEmpty { tokens.append(.key(name)) }
            if i < chars.count, chars[i] == "." { i += 1; continue }
            // 读 [ ... ] 段：数字=下标，引号=键名
            if i < chars.count, chars[i] == "[" {
                i += 1
                var inner = ""
                while i < chars.count, chars[i] != "]" { inner.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }
                let quoteTrimmed = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let idx = Int(inner.trimmingCharacters(in: .whitespaces)), quoteTrimmed == inner.trimmingCharacters(in: .whitespaces) {
                    tokens.append(.index(idx))
                } else {
                    tokens.append(.key(quoteTrimmed))
                }
            }
        }
        return tokens
    }

    private static func selectToken(_ root: Any, _ path: String) -> Any? {
        var current: Any? = root
        for token in pathTokens(path) {
            switch token {
            case .key(let k):
                guard let dict = current as? [String: Any], let next = dict[k] else { return nil }
                current = next
            case .index(let n):
                guard let arr = current as? [Any], n >= 0, n < arr.count else { return nil }
                current = arr[n]
            }
        }
        return current
    }

    /// Token 文本化：对象/数组 → 紧凑 JSON，标量 → 文本（对应 C# `token.ToString()`）
    private static func tokenText(_ value: Any) -> String {
        if value is [String: Any] || value is [Any] {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let s = String(data: data, encoding: .utf8) else { return "" }
            return s
        }
        return JSONValue(any: value).stringValue ?? ""
    }
}
