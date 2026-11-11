import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 内存密钥存储：测试不触碰真实钥匙串。
final class MemorySyncKeyStore: SyncKeyStoring {
    var key: Data?
    func save(_ key: Data) -> Bool { self.key = key; return true }
    func load() -> Data? { key }
}

/// 加密同步验收：PBKDF2-SHA256 已知向量、AES-GCM 线格式与往返、损坏/错钥拒绝、
/// Keychain 接缝（内存注入）、AccountService 首次开启加密同步编排。
final class SyncEncryptionTests: XCTestCase {

    private var dir: String!
    private var originalStore: SyncKeyStoring!
    private let store = MemorySyncKeyStore()

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-enc-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        Settings.DirOverride = dir
        Seam.resetSettings()
        Seam.settings = Settings()
        Seam.uiPost = { $0() }
        originalStore = SyncEncryption.keyStore
        SyncEncryption.keyStore = store
    }

    override func tearDown() {
        SyncEncryption.keyStore = originalStore
        Seam.resetSettings()
        Seam.uiPost = { _ in }
        Settings.DirOverride = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 密钥派生

    func testPbkdf2KnownVectors() {
        // PBKDF2-HMAC-SHA256 公开向量（password="password", salt="salt", dkLen=32）
        let salt = Array("salt".utf8)
        XCTAssertEqual(hex(SyncEncryption.pbkdf2(password: "password", salt: salt, iterations: 1)!),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(SyncEncryption.pbkdf2(password: "password", salt: salt, iterations: 2)!),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    func testDeriveKeyDeterministicAndUserScoped() {
        let a = SyncEncryption.deriveKey(password: "同步密码", userId: "u1")
        let b = SyncEncryption.deriveKey(password: "同步密码", userId: "u1")
        let c = SyncEncryption.deriveKey(password: "同步密码", userId: "u2")
        XCTAssertEqual(a, b, "同密码同用户派生一致（跨设备可复现）")
        XCTAssertNotEqual(a, c, "salt 含 userId，用户间隔离")
        XCTAssertEqual(a?.count, 32, "AES-256")
    }

    // MARK: - AES-GCM

    func testEncryptDecryptRoundTripAndWireFormat() {
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        let plain = "敏感 token-你好"
        let enc = SyncEncryption.encrypt(plain, key: key)!
        XCTAssertTrue(enc.hasPrefix("ENC:v1:"))
        let combined = Data(base64Encoded: String(enc.dropFirst("ENC:v1:".count)))!
        XCTAssertEqual(combined.count, 12 + plain.utf8.count + 16, "iv(12) + ciphertext + tag(16)，与 C# 布局互通")
        XCTAssertEqual(SyncEncryption.decrypt(enc, key: key), plain)
        XCTAssertNotEqual(enc, SyncEncryption.encrypt(plain, key: key), "随机 IV，两次密文不同")
    }

    func testDecryptWrongKeyOrTamperedReturnsNil() {
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        let other = SyncEncryption.deriveKey(password: "pw2", userId: "u1")!
        let enc = SyncEncryption.encrypt("secret", key: key)!
        XCTAssertNil(SyncEncryption.decrypt(enc, key: other), "错钥 GCM 校验失败")
        // 篡改密文主体一个字节
        var combined = Data(base64Encoded: String(enc.dropFirst("ENC:v1:".count)))!
        combined[12] ^= 0xFF
        let tampered = "ENC:v1:" + combined.base64EncodedString()
        XCTAssertNil(SyncEncryption.decrypt(tampered, key: key), "GCM 认证标签拒绝篡改")
        XCTAssertNil(SyncEncryption.decrypt("ENC:v1:!!!not-base64!!!", key: key))
        XCTAssertNil(SyncEncryption.encrypt("x", key: Data([1, 2, 3])), "非 32 字节密钥拒绝")
    }

    func testDecryptNonEncryptedPassthroughAndIsEncrypted() {
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        XCTAssertEqual(SyncEncryption.decrypt("plain-value", key: key), "plain-value", "非加密格式原样返回（C# 同语义）")
        XCTAssertTrue(SyncEncryption.isEncrypted("ENC:v1:abc"))
        XCTAssertFalse(SyncEncryption.isEncrypted("plain"))
        XCTAssertFalse(SyncEncryption.isEncrypted(nil))
    }

    // MARK: - 密钥本地保护

    func testProtectUnprotectKeyViaStore() {
        let key = SyncEncryption.deriveKey(password: "pw", userId: "u1")!
        XCTAssertNil(SyncEncryption.unprotectKeyFromLocal("keychain:v1"), "存储为空取不回")
        XCTAssertEqual(SyncEncryption.protectKeyForLocal(key), "keychain:v1", "落盘串是标记，密钥本体在存储接缝内")
        XCTAssertEqual(store.key, key)
        XCTAssertEqual(SyncEncryption.unprotectKeyFromLocal("keychain:v1"), key)
        XCTAssertNil(SyncEncryption.unprotectKeyFromLocal(""))
    }

    // MARK: - 账号服务编排

    func testEnableSyncEncryptionFlow() {
        let svc = AccountService()
        XCTAssertFalse(svc.enableSyncEncryption(password: "pw"), "userId 缺席拒绝")
        let s = Seam.settings
        s.AccountUserId = "u1"
        XCTAssertFalse(svc.enableSyncEncryption(password: ""), "空密码拒绝")
        XCTAssertTrue(svc.enableSyncEncryption(password: "pw"))
        XCTAssertTrue(s.SyncEncryptEnabled)
        XCTAssertTrue(svc.readState().HasDerivedKey)
        XCTAssertEqual(store.key, SyncEncryption.deriveKey(password: "pw", userId: "u1"))
        // 已有密钥：再次开启不重新派生（与 C# VM HasDerivedKey 分支一致）
        XCTAssertTrue(svc.enableSyncEncryption(password: "another"))
        XCTAssertEqual(store.key, SyncEncryption.deriveKey(password: "pw", userId: "u1"), "不覆盖既有派生密钥")
        svc.setSyncEncrypt(false)
        XCTAssertFalse(s.SyncEncryptEnabled)
        XCTAssertTrue(svc.readState().HasDerivedKey, "关开关不丢密钥")
    }
}