using System;
using System.Security.Cryptography;
using System.Text;
using Security;
using SideDesk.Composition;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="ISecretProtector"/> 的 macOS 实现：用 **Keychain 保管一把 AES-256 主密钥**，
/// 秘密本身经 AES-GCM 信封加密后仍以 base64 存回数据库（契约与 Windows 版一致：
/// Encrypt/Decrypt 都是 base64 进出，空输入/失败返回空串）。
///
/// 为什么是「主密钥 + 信封加密」而不是「每个秘密单独存 Keychain」：
///  - 保持既有 DB schema 与 base64 契约不变（<c>S3Source.SecretKeyEncrypted</c> 等字段照旧），
///    上层模型/服务零改动；
///  - 等价 DPAPI 的安全语义——密文可随 DB 走，但只有**本机 Keychain** 里的主密钥能解开；
///  - 主密钥首次使用时随机生成并写入登录钥匙串（<see cref="SecAccessible.WhenUnlocked"/>），
///    之后复用；不弹窗（generic password + 本进程为签名归属）。
///
/// 密文格式：base64( nonce[12] || tag[16] || ciphertext )。AES-GCM 自带完整性校验，
/// 篡改/错钥会在 Decrypt 抛异常 → 回落空串（与 DPAPI 版 Unprotect 失败同口径）。
/// </summary>
public sealed class KeychainSecretProtector : ISecretProtector
{
    // Keychain generic-password 归属标识（service/account 二元组唯一定位主密钥项）。
    private const string KeychainService = "com.sidestmac.app";
    private const string KeychainAccount = "master-secret-key";

    private const int KeySize = 32; // AES-256
    private const int NonceSize = 12; // AES-GCM 标准 nonce 长度
    private const int TagSize = 16;   // AES-GCM 认证标签长度

    // 主密钥惰性加载一次（Keychain 读/建），失败缓存 null → 之后 Encrypt/Decrypt 直接回落空串。
    private readonly Lazy<byte[]?> _key = new(LoadOrCreateKey);

    public string Encrypt(string? plain)
    {
        if (string.IsNullOrEmpty(plain)) return "";
        var key = _key.Value;
        if (key == null) return "";
        try
        {
            byte[] pt = Encoding.UTF8.GetBytes(plain);
            int n = NonceSize, t = TagSize;
            byte[] nonce = new byte[n];
            RandomNumberGenerator.Fill(nonce);
            byte[] ct = new byte[pt.Length];
            byte[] tag = new byte[t];
            using (var aes = new AesGcm(key, t))
                aes.Encrypt(nonce, pt, ct, tag);

            byte[] blob = new byte[n + t + ct.Length];
            Buffer.BlockCopy(nonce, 0, blob, 0, n);
            Buffer.BlockCopy(tag, 0, blob, n, t);
            Buffer.BlockCopy(ct, 0, blob, n + t, ct.Length);
            return Convert.ToBase64String(blob);
        }
        catch { return ""; }
    }

    public string Decrypt(string? cipher)
    {
        if (string.IsNullOrEmpty(cipher)) return "";
        var key = _key.Value;
        if (key == null) return "";
        try
        {
            byte[] blob = Convert.FromBase64String(cipher);
            int n = NonceSize, t = TagSize;
            if (blob.Length < n + t) return "";
            byte[] nonce = new byte[n], tag = new byte[t], ct = new byte[blob.Length - n - t];
            Buffer.BlockCopy(blob, 0, nonce, 0, n);
            Buffer.BlockCopy(blob, n, tag, 0, t);
            Buffer.BlockCopy(blob, n + t, ct, 0, ct.Length);

            byte[] pt = new byte[ct.Length];
            using (var aes = new AesGcm(key, t))
                aes.Decrypt(nonce, ct, tag, pt);
            return Encoding.UTF8.GetString(pt);
        }
        catch { return ""; }
    }

    // ===== Keychain 主密钥读写 =====

    private static byte[]? LoadOrCreateKey()
    {
        try
        {
            byte[]? existing = KeychainFind();
            if (existing is { Length: KeySize }) return existing;

            byte[] key = new byte[KeySize];
            RandomNumberGenerator.Fill(key);
            // 仅当成功写入 Keychain 才启用；写失败(钥匙串不可用)则 fail-closed 返回 null，
            // 使 Encrypt/Decrypt 回落空串——与 Windows DPAPI 版 catch→"" 同口径，
            // 避免"本进程能加密、重启后无法解密"的静默数据丢失。
            return SecKeyChain.AddGenericPassword(KeychainService, KeychainAccount, key)
                == SecStatusCode.Success ? key : null;
        }
        catch { return null; }
    }

    private static byte[]? KeychainFind()
    {
        var status = SecKeyChain.FindGenericPassword(KeychainService, KeychainAccount, out byte[]? password);
        return status == SecStatusCode.Success ? password : null;
    }
}
