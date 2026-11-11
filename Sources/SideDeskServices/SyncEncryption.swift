import Foundation
import CryptoKit
import CommonCrypto
import Security
import SideDeskCore

/// 派生密钥的本地保护存储接缝。Windows 用 DPAPI（仅当前用户可解），macOS 用 Keychain；
/// 测试注入内存实现，避免触碰真实钥匙串。
public protocol SyncKeyStoring {
    func save(_ key: Data) -> Bool
    func load() -> Data?
}

/// Keychain 实现：通用密码项，服务名按 bundle id 隔离。
/// `AfterFirstUnlockThisDeviceOnly`：首次解锁后可读（后台同步可用），且不随 iCloud 钥匙串
/// 漫游到他机——派生密钥只属于本机，跨设备靠同一同步密码重新派生。
public final class KeychainSyncKeyStore: SyncKeyStoring {
    private let service = "com.sidestmac.app.sync-encryption"
    private let account = "sync-derived-key"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func save(_ key: Data) -> Bool {
        let attrs: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    public func load() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

/// 云同步加密：同步密码派生 AES-256 密钥，AES-GCM 加解密敏感设置项。
/// 对应 C# `SyncEncryption`。线格式与 C# 完全互通：
/// PBKDF2-SHA256（100k 迭代，salt = "sidedesk-sync:{userId}"，32 字节），
/// 密文 "ENC:v1:{base64(iv(12) + ciphertext + tag(16))}"。
/// 平台差异仅在密钥本地保护：DPAPI → Keychain（见 `SyncKeyStoring`）。
public enum SyncEncryption {
    private static let keySize = 32
    private static let cipherPrefix = "ENC:v1:"

    /// 密钥存储接缝（测试注入内存实现；生产走 Keychain）
    public static var keyStore: SyncKeyStoring = KeychainSyncKeyStore()

    /// 从同步密码 + userId 派生 AES-256 密钥。对应 C# `DeriveKey`。
    /// salt 只需确定性且每用户唯一，直接用 encrypt2 密文 userId（与 C# 同口径）。
    public static func deriveKey(password: String, userId: String) -> Data? {
        pbkdf2(password: password, salt: Array("sidedesk-sync:\(userId)".utf8), iterations: 100_000)
    }

    /// PBKDF2-HMAC-SHA256 原语（迭代数可注入，供已知向量验收）。
    static func pbkdf2(password: String, salt: [UInt8], iterations: UInt32) -> Data? {
        var out = [UInt8](repeating: 0, count: keySize)
        var status: Int32 = Int32(kCCParamError)
        password.withCString { pw in
            salt.withUnsafeBufferPointer { saltBuf in
                out.withUnsafeMutableBufferPointer { dest in
                    status = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw, password.utf8.count,
                        saltBuf.baseAddress, saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        dest.baseAddress, dest.count)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out)
    }

    /// AES-256-GCM 加密，返回 "ENC:v1:{base64(iv + ciphertext + tag)}"。对应 C# `Encrypt`。
    /// CryptoKit `sealed.combined` 布局即 nonce(12) || ciphertext || tag(16)，与 C# 组合一致。
    public static func encrypt(_ plaintext: String, key: Data) -> String? {
        guard key.count == keySize,
              let sealed = try? AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: key)),
              let combined = sealed.combined else { return nil }
        return cipherPrefix + combined.base64EncodedString()
    }

    /// AES-256-GCM 解密。非加密格式原样返回（C# 同语义）；密文损坏/密钥不符返回 nil
    /// （C# 抛 CryptographicException 由调用方 catch 跳过，等价）。对应 C# `Decrypt`。
    public static func decrypt(_ text: String, key: Data) -> String? {
        guard text.hasPrefix(cipherPrefix) else { return text }
        guard key.count == keySize,
              let combined = Data(base64Encoded: String(text.dropFirst(cipherPrefix.count))),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// 判断值是否为加密格式。对应 C# `IsEncrypted`。
    public static func isEncrypted(_ value: String?) -> Bool {
        value?.hasPrefix(cipherPrefix) == true
    }

    /// 保护派生密钥并返回可落盘的串。对应 C# `ProtectKeyForLocal`。
    /// 平台差异：C# 落盘的是 DPAPI 密文；macOS 密钥本体存 Keychain，
    /// 落盘串只是「已设置派生密钥」的标记（HasDerivedKey 按非空判定）。
    public static func protectKeyForLocal(_ key: Data) -> String? {
        keyStore.save(key) ? "keychain:v1" : nil
    }

    /// 取回本地保护的派生密钥。对应 C# `UnprotectKeyFromLocal`（失败回落 nil）。
    public static func unprotectKeyFromLocal(_ stored: String) -> Data? {
        guard !stored.isEmpty else { return nil }
        return keyStore.load()
    }
}