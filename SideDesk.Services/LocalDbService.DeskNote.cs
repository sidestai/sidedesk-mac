using System;
using Microsoft.Data.Sqlite;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// 「记事」本地持久化（2026-10-05 自 LocalDbService.cs 拆出，ADR-0011）：独立表 local_desk_note。
/// 与便签的 local_sticky_note / local_global_note 同构，按 uid 存取。
/// #443：DeskNoteService 删除后，本文件只保留 SaveItemRows 用的 UpsertDeskNote——
/// 表真相源是 PanelItem.DeskNotes（经 ConfigManager.Save → SaveItemRows 写入），
/// 原 LoadDeskNotes / SaveDeskNotes（服务镜像清单的整表 DELETE+重插）随服务一并删除。
/// </summary>
public static partial class LocalDbService
{
    private static void UpsertDeskNote(SqliteConnection conn, DeskNote n, string scope)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"INSERT INTO local_desk_note (uid, user_id, content, created_at, updated_at)
VALUES ($uid, $scope, $content, $created, $updated)
ON CONFLICT(uid) DO UPDATE SET user_id=excluded.user_id, content=excluded.content, updated_at=excluded.updated_at;";
        cmd.Parameters.AddWithValue("$uid", n.Id);
        cmd.Parameters.AddWithValue("$scope", scope);
        cmd.Parameters.AddWithValue("$content", n.Content);
        cmd.Parameters.AddWithValue("$created", n.CreatedAt.ToString("o"));
        cmd.Parameters.AddWithValue("$updated", n.UpdatedAt.ToString("o"));
        cmd.ExecuteNonQuery();
    }
}
