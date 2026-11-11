import Foundation

/// 通用 JSON 值容器：用于需要保留任意结构（对象/数组/标量）的字段，
/// 例如通知动作的 payload。可 Codable 往返，替代 C# 的 Dictionary<string, object> + JToken。
public enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// 从 JSONSerialization 产出的 Any 构建（null → .null）。
    public init(any: Any?) {
        guard let any = any, !(any is NSNull) else { self = .null; return }
        if let b = any as? Bool { self = .bool(b); return }
        if let n = any as? NSNumber {
            // JSONSerialization 用 NSNumber 承载所有数字；区分整型/浮点
            if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.intValue) }
            return
        }
        if let s = any as? String { self = .string(s); return }
        if let dict = any as? [String: Any] {
            var o: [String: JSONValue] = [:]
            for (k, v) in dict { o[k] = JSONValue(any: v) }
            self = .object(o); return
        }
        if let arr = any as? [Any] {
            self = .array(arr.map { JSONValue(any: $0) }); return
        }
        self = .null
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return Bool(s)
        case .int(let i): return i != 0
        default: return nil
        }
    }
}
