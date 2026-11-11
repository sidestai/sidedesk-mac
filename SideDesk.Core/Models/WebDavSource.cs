using System;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    /// <summary>WebDAV 存储源：用户配置的标准 WebDAV 服务器，可作为微屏主存储使用</summary>
    public class WebDavSource
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        /// <summary>显示名称</summary>
        public string Name { get; set; } = "";
        /// <summary>WebDAV 服务器地址（如 https://dav.example.com/user/）</summary>
        public string Url { get; set; } = "";
        /// <summary>用户名（匿名服务器可留空）</summary>
        public string Username { get; set; } = "";
        /// <summary>密码（DPAPI 加密后的 base64 密文）</summary>
        public string PasswordEncrypted { get; set; } = "";
        /// <summary>归属团队 ID（创建时当前选中的 corpId；空 = 个人）</summary>
        public string? CorpId { get; set; }
        /// <summary>归属团队名称（仅展示用，随创建时快照）</summary>
        public string? CorpName { get; set; }
        public DateTime CreatedAt { get; set; } = DateTime.Now;

        /// <summary>解密后的密码（解密失败返回空串）</summary>
        [JsonIgnore]
        public string Password => Composition.SecretProtector.Decrypt(PasswordEncrypted);

        /// <summary>规范化根地址：保证以 / 结尾</summary>
        [JsonIgnore]
        public string BaseUrl
        {
            get
            {
                string u = (Url ?? "").Trim();
                if (u.Length == 0) return "";
                return u.EndsWith('/') ? u : u + "/";
            }
        }
    }
}
