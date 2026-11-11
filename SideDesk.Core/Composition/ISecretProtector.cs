using System;

namespace SideDesk.Composition
{
    /// <summary>
    /// 秘密保护接缝（分层解耦）：领域模型（S3Source / WebDavSource 等）需要把持久化的
    /// 密文还原为明文，但**具体加密实现是平台专有的**——Windows 用 DPAPI，macOS 用 Keychain。
    /// 模型只依赖本抽象，具体实现由各平台在服务层注册进 <see cref="AppContainer"/>。
    /// </summary>
    public interface ISecretProtector
    {
        /// <summary>解密 base64 密文；失败/空输入返回空串（不抛，与 Windows *SourceService.Decrypt 口径一致）。</summary>
        string Decrypt(string? cipher);

        /// <summary>加密明文为可持久化的 base64 密文；失败返回空串。</summary>
        string Encrypt(string? plain);
    }

    /// <summary>
    /// <see cref="ISecretProtector"/> 的静态门面：从组合根解析当前平台实现。
    /// 未注册时回落空串而非抛异常——领域模型的解密计算属性（如 S3Source.SecretAccessKey）
    /// 不应因宿主尚未装配而炸；这与 Windows 版 Decrypt「失败返回空串」的容错一致。
    /// </summary>
    public static class SecretProtector
    {
        public static string Decrypt(string? cipher)
            => AppContainer.TryResolve<ISecretProtector>(out var p) && p != null ? p.Decrypt(cipher) : "";

        public static string Encrypt(string? plain)
            => AppContainer.TryResolve<ISecretProtector>(out var p) && p != null ? p.Encrypt(plain) : "";
    }
}
