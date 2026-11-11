using System.IO;
using Newtonsoft.Json;

namespace SideDesk.Models;

/// <summary>
/// 数字员工
/// </summary>
public class DigitalEmployee
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "新员工";
    public string AvatarPath { get; set; } = "";   // 头像图片文件路径（为空则使用首字母/emoji 占位）
    public string Emoji { get; set; } = "";          // 无图片时可用 emoji 作为头像
    public string Role { get; set; } = "";           // 职位/角色
    public string Department { get; set; } = "";     // 部门
    public string Description { get; set; } = "";    // 简介/职责描述
    public string Skills { get; set; } = "";         // 擅长/技能
    public string Contact { get; set; } = "";        // 联系方式（邮箱/工号等）
    public string Status { get; set; } = "online";   // 状态：online 在线 / busy 忙碌 / offline 离线
    public DateTime CreatedAt { get; set; } = DateTime.Now;

    /// <summary>头像占位显示文字：优先 emoji，否则名字首字符</summary>
    [JsonIgnore]
    public string AvatarFallback =>
        !string.IsNullOrWhiteSpace(Emoji) ? Emoji
        : (string.IsNullOrWhiteSpace(Name) ? "?" : Name.Trim().Substring(0, 1));

    /// <summary>状态显示文本</summary>
    [JsonIgnore]
    public string StatusText => Status switch
    {
        "online" => Framework.Lang.T("common.online"),
        "busy" => Framework.Lang.T("digitalEmployee.busy"),
        "offline" => Framework.Lang.T("common.offline"),
        _ => Framework.Lang.T("common.online")
    };
}

// NOTE(port): DigitalEmployeeManager (Windows Models/DigitalEmployee.cs L40-131) is a
// persistence orchestrator over LocalDbService — a SERVICE-layer concern under the
// layered/seam architecture. Deferred to Phase 2 (re-port from the untouched Windows
// source, wired through Core seam interfaces). Kept out of SideDesk.Core for now.
