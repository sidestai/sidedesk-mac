using System;

namespace SideDesk.Models
{
    /// <summary>云空间条目：用户配置的网盘/云存储快捷入口</summary>
    public class CloudSpace
    {
        /// <summary>内置「微屏云盘」的固定 Id（#790）：内置空间必须跨安装/迁移保持同一个 Id，
        /// 否则文件区里导入的云文件（按 CloudSpaceId 回查空间）会在重建后失配，点击静默无反应。</summary>
        public const string BuiltinSideDeskId = "builtin-sidedesk-cloud";

        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        /// <summary>显示名称</summary>
        public string Name { get; set; } = "";
        /// <summary>访问地址</summary>
        public string Url { get; set; } = "";
        /// <summary>图标（emoji 或图标路径）</summary>
        public string Icon { get; set; } = "☁️";
        /// <summary>备注说明</summary>
        public string? Note { get; set; }
        /// <summary>关联的存储源 ID（如 S3Source.Id）；非空时该项为可直连存储源，打开方式由源类型决定</summary>
        public string? RefId { get; set; }
        /// <summary>关联存储源类型（"s3" / "webdav"）；RefId 非空且本字段为空时按 s3 兼容旧数据</summary>
        public string? RefType { get; set; }
        /// <summary>是否为系统内置预设</summary>
        public bool IsBuiltin { get; set; }
        public DateTime CreatedAt { get; set; } = DateTime.Now;
    }
}
