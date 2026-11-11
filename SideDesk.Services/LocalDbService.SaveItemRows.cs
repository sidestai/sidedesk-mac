using System.Collections.Generic;
using Microsoft.Data.Sqlite;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// 面板行数据落库（2026-10-05 自 LocalDbService.cs 拆出，ADR-0011）：写 local_item_row + 各独立数据表。
/// 与 <c>SaveItemTree</c> 是一对（树结构 / 行列表），散在同一个巨型文件里没有理由。
/// </summary>
public static partial class LocalDbService
{
    /// <summary>将面板的行列表数据写入 local_item_row + 独立数据表（镜像服务端结构；打当前作用域）。</summary>
    private static void SaveItemRows(SqliteConnection conn, PanelItem p, string now,
        Dictionary<string, (string? RowServerId, string? DataServerId)> serverIdMap, string scope)
    {
        void Insert(string rowUid, string rowType, string content, int order)
        {
            serverIdMap.TryGetValue(rowUid, out var sids);
            InsertRow(conn, p.Id, rowUid, rowType, content, order, now, sids.RowServerId, sids.DataServerId, scope);
        }

        if (p.StickyNotes != null)
        {
            int o = 0;
            foreach (var n in p.StickyNotes)
            {
                Insert(n.Id, "sticky_note", JsonConvert.SerializeObject(n), o++);
                UpsertStickyNote(conn, n, scope);
            }
        }
        if (p.DeskNotes != null)
        {
            int o = 0;
            foreach (var n in p.DeskNotes)
            {
                Insert(n.Id, "desk_note", JsonConvert.SerializeObject(n), o++);
                UpsertDeskNote(conn, n, scope);
            }
        }
        if (p.TodoItems != null)
        {
            int o = 0;
            foreach (var t in p.TodoItems)
            {
                Insert(t.Id, "todo", JsonConvert.SerializeObject(t), o++);
                UpsertTodoItem(conn, t, scope);
            }
        }
        if (p.ClipboardItems != null)
        {
            int o = 0;
            foreach (var c in p.ClipboardItems)
            {
                Insert(c.Id, "clipboard", JsonConvert.SerializeObject(c), o++);
                UpsertClipboardItem(conn, c, scope);
            }
        }
        if (p.TimerItems != null)
        {
            int o = 0;
            foreach (var t in p.TimerItems)
                Insert(t.Id, "timer", JsonConvert.SerializeObject(t), o++);
        }
        if (p.CountdownItems != null)
        {
            int o = 0;
            foreach (var c in p.CountdownItems)
                Insert(c.Id, "countdown", JsonConvert.SerializeObject(c), o++);
        }
        if (p.SignalLights != null)
        {
            int o = 0;
            foreach (var s in p.SignalLights)
                Insert(s.Id, "signal_light", JsonConvert.SerializeObject(s), o++);
        }
        if (p.FileItems != null)
        {
            int o = 0;
            foreach (var f in p.FileItems)
                Insert(f.Id, "file_area", JsonConvert.SerializeObject(f), o++);
        }
        // 番茄钟：单行记录（设置+运行状态），与其他行同步面板统一走行级存储
        if (p.Pomodoro != null)
            Insert(p.Pomodoro.Id, "pomodoro", JsonConvert.SerializeObject(p.Pomodoro), 0);
        if (p.DashboardItems != null)
        {
            int o = 0;
            foreach (var d in p.DashboardItems)
                Insert(d.Id, "dashboard", JsonConvert.SerializeObject(d), o++);
        }
        // 数字员工/好友：引用 Id 列表包装为行对象（Id = 引用 Id）
        if (p.DigitalEmployeeIds != null)
        {
            int o = 0;
            foreach (var id in p.DigitalEmployeeIds)
            {
                if (string.IsNullOrEmpty(id)) continue;
                Insert(id, "digital_employee",
                    JsonConvert.SerializeObject(new DigitalEmployeeRow { Id = id, EmployeeId = id }), o++);
            }
        }
        if (p.FriendUserIds != null)
        {
            int o = 0;
            foreach (var id in p.FriendUserIds)
                Insert(id.ToString(), "friend_user",
                    JsonConvert.SerializeObject(new FriendUserRow { Id = id.ToString(), UserId = id.ToString() }), o++);
        }
        // 快捷方式：每个快捷项一行（原 quickgroups.json 数据已迁入面板）
        if (p.QuickItems != null)
        {
            int o = 0;
            foreach (var q in p.QuickItems)
                Insert(q.Id, "shortcut", JsonConvert.SerializeObject(q), o++);
        }
        // 打卡：每个打卡项一行（含当日计数，跨天由客户端 EnsureTodayCount 清零）
        if (p.CheckInItems != null)
        {
            int o = 0;
            foreach (var c in p.CheckInItems)
                Insert(c.Id, "check_in", JsonConvert.SerializeObject(c), o++);
        }
    }
}
