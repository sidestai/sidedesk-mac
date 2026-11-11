using System;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    /// <summary>S3 存储源：用户配置的 Amazon S3（或 S3 兼容协议）桶，可作为微屏主存储使用</summary>
    public class S3Source
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        /// <summary>显示名称</summary>
        public string Name { get; set; } = "";
        /// <summary>服务端点（空 = AWS 官方端点；MinIO/R2 等 S3 兼容服务填自定义地址）</summary>
        public string Endpoint { get; set; } = "";
        /// <summary>区域（AWS 默认 us-east-1）</summary>
        public string Region { get; set; } = "us-east-1";
        /// <summary>桶名</summary>
        public string Bucket { get; set; } = "";
        public string AccessKeyId { get; set; } = "";
        /// <summary>SecretAccessKey（DPAPI 加密后的 base64 密文）</summary>
        public string SecretKeyEncrypted { get; set; } = "";
        /// <summary>可选 STS 会话令牌（DPAPI 加密后的 base64 密文）</summary>
        public string? SessionTokenEncrypted { get; set; }
        /// <summary>路径风格寻址（部分自定义端点需要）</summary>
        public bool UsePathStyle { get; set; }
        /// <summary>存储根前缀（可选，相当于虚拟根目录，不以 / 开头、以 / 结尾）</summary>
        public string Prefix { get; set; } = "";
        /// <summary>归属团队 ID（创建时当前选中的 corpId；空 = 个人）</summary>
        public string? CorpId { get; set; }
        /// <summary>归属团队名称（仅展示用，随创建时快照）</summary>
        public string? CorpName { get; set; }
        public DateTime CreatedAt { get; set; } = DateTime.Now;

        /// <summary>解密后的 SecretAccessKey（解密失败返回空串）</summary>
        [JsonIgnore]
        public string SecretAccessKey => Composition.SecretProtector.Decrypt(SecretKeyEncrypted);

        /// <summary>解密后的会话令牌（无则 null）</summary>
        [JsonIgnore]
        public string? SessionToken
        {
            get
            {
                if (string.IsNullOrEmpty(SessionTokenEncrypted)) return null;
                string v = Composition.SecretProtector.Decrypt(SessionTokenEncrypted);
                return string.IsNullOrEmpty(v) ? null : v;
            }
        }

        /// <summary>规范化前缀：去首斜杠，非空时保证以 / 结尾</summary>
        [JsonIgnore]
        public string NormalizedPrefix
        {
            get
            {
                string p = (Prefix ?? "").Trim().TrimStart('/');
                if (p.Length == 0) return "";
                return p.EndsWith('/') ? p : p + "/";
            }
        }
    }
}
