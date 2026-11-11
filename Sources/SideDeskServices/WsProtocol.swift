import Foundation
import CryptoKit

/// RFC 6455 握手与分帧的纯函数。对应 C# `Services/WsProtocol.cs`。
///
/// 与 C# 同样自实现而不用系统 WebSocket API：服务端只服务本机浏览器扩展，
/// 需要的只是"回 101 + 收发文本帧"，纯函数便于单测（C# 注释里的 http.sys/Wine 缘由在 mac 不存在，
/// 但"不依赖系统升级 API"这一取舍保持下来：两侧行为一致、可测）。
enum WsParseStatus {
    case needMore
    case ok
    case error(String)
}

/// 一帧 WebSocket 数据（载荷已去掩码）。
struct WsFrame {
    let opcode: UInt8
    let fin: Bool
    let payload: [UInt8]

    /// 控制帧（opcode 高位为 1）：close / ping / pong，可穿插在分片消息中间。
    var isControl: Bool { (opcode & 0x8) != 0 }
}

enum WsProtocol {

    /// RFC 6455 规定的握手魔数 GUID。
    static let magicGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static let opContinuation: UInt8 = 0x0
    static let opText: UInt8 = 0x1
    static let opBinary: UInt8 = 0x2
    static let opClose: UInt8 = 0x8
    static let opPing: UInt8 = 0x9
    static let opPong: UInt8 = 0xA

    /// 单帧载荷上限：超出即视为协议错误（本地扩展桥没有大帧场景）。
    static let maxFrameBytes = 8 * 1024 * 1024
    /// 单条（重组后）消息上限。
    static let maxMessageBytes = 8 * 1024 * 1024

    /// 是否为 WebSocket 升级请求（Upgrade: websocket + Connection 含 Upgrade + 有 Key）。
    static func isUpgradeRequest(_ head: String) -> Bool {
        headerContainsToken(head, "Upgrade", "websocket")
            && headerContainsToken(head, "Connection", "Upgrade")
            && !(findHeader(head, "Sec-WebSocket-Key") ?? "").isEmpty
    }

    /// 由 `Sec-WebSocket-Key` 算出响应里的 `Sec-WebSocket-Accept`；缺 Key 返回 nil。
    static func computeAccept(_ head: String) -> String? {
        guard let key = findHeader(head, "Sec-WebSocket-Key"), !key.isEmpty else { return nil }
        let digest = Insecure.SHA1.hash(data: Data(ascii: key + magicGuid))
        return Data(digest).base64EncodedString()
    }

    /// 构造 101 切换协议响应（不含 `Sec-WebSocket-Extensions`，即拒绝 permessage-deflate 等扩展）。
    static func buildHandshakeResponse(_ accept: String) -> Data {
        Data(ascii: "HTTP/1.1 101 Switching Protocols\r\n"
             + "Upgrade: websocket\r\n"
             + "Connection: Upgrade\r\n"
             + "Sec-WebSocket-Accept: \(accept)\r\n\r\n")
    }

    /// 构造非升级请求的拒绝响应。
    static func buildBadRequestResponse() -> Data {
        Data(ascii: "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    }

    /// 编码一个服务端发出的帧（FIN=1、不掩码——掩码只用于客户端→服务端方向）。
    static func encodeFrame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let len = payload.count
        var buf: [UInt8] = []
        buf.reserveCapacity(len + 10)
        buf.append(0x80 | opcode)
        switch len {
        case 0..<126:
            buf.append(UInt8(len))
        case 126...Int(UInt16.max):
            buf.append(126)
            buf.append(UInt8(len >> 8 & 0xFF))
            buf.append(UInt8(len & 0xFF))
        default:
            buf.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                buf.append(UInt8(truncatingIfNeeded: Int64(len) >> shift))
            }
        }
        buf.append(contentsOf: payload)
        return buf
    }

    /// 从 `buf` 前 `len` 字节里解析一帧；`consumed` 是这一帧占用的字节数。
    /// 客户端帧必须带掩码（RFC 6455 §5.1）。
    static func tryParseFrame(_ buf: [UInt8], _ len: Int) -> (frame: WsFrame, consumed: Int, status: WsParseStatus, error: String?) {
        if len < 2 {
            return (WsFrame(opcode: 0, fin: false, payload: []), 0, .needMore, nil)
        }
        let b0 = buf[0], b1 = buf[1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        func fail(_ msg: String) -> (WsFrame, Int, WsParseStatus, String?) {
            (WsFrame(opcode: opcode, fin: fin, payload: []), 0, .error(msg), msg)
        }
        if (b0 & 0x70) != 0 { return fail("RSV 位非零（未协商任何扩展）") }
        if (b1 & 0x80) == 0 { return fail("客户端帧未掩码") }

        var payloadLen = Int(b1 & 0x7F)
        var offset = 2
        if payloadLen == 126 {
            if len < 4 { return (WsFrame(opcode: opcode, fin: fin, payload: []), 0, .needMore, nil) }
            payloadLen = Int(buf[2]) << 8 | Int(buf[3])
            offset = 4
        } else if payloadLen == 127 {
            if len < 10 { return (WsFrame(opcode: opcode, fin: fin, payload: []), 0, .needMore, nil) }
            var v = 0
            for i in 2..<10 { v = v << 8 | Int(buf[i]) }
            if v > maxFrameBytes { return fail("帧长度 \(v) 超出上限") }
            payloadLen = v
            offset = 10
        }

        let isControl = (opcode & 0x8) != 0
        if isControl && (!fin || payloadLen > 125) {
            return fail("控制帧不得分片且载荷不得超过 125 字节")
        }
        if !isControl && payloadLen > maxFrameBytes { return fail("帧长度 \(payloadLen) 超出上限") }

        if len < offset + 4 { return (WsFrame(opcode: opcode, fin: fin, payload: []), 0, .needMore, nil) }
        let maskOffset = offset
        offset += 4
        if len < offset + payloadLen { return (WsFrame(opcode: opcode, fin: fin, payload: []), 0, .needMore, nil) }

        var payload = [UInt8](repeating: 0, count: payloadLen)
        for i in 0..<payloadLen {
            payload[i] = buf[offset + i] ^ buf[maskOffset + (i & 3)]
        }
        return (WsFrame(opcode: opcode, fin: fin, payload: payload), offset + payloadLen, .ok, nil)
    }

    /// 在请求头里取指定头字段的值（大小写不敏感，取首个匹配）；没有则返回 nil。
    static func findHeader(_ head: String, _ name: String) -> String? {
        for line in head.components(separatedBy: "\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 头字段值里是否含指定 token（按逗号分隔，大小写不敏感）。
    static func headerContainsToken(_ head: String, _ name: String, _ token: String) -> Bool {
        guard let value = findHeader(head, name) else { return false }
        return value.components(separatedBy: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame }
    }
}

private extension Data {
    /// 按 ASCII 编码构造（握手字符串只含 ASCII；避免 UTF-8 歧义）。
    init(ascii: String) {
        self = ascii.data(using: .ascii) ?? Data()
    }
}
