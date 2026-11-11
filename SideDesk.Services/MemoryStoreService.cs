using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace SideDesk.Services;

/// <summary>
/// 记忆存储服务（#63 P1）：md + sqlite 双层——md 为人类可读物料层，sqlite 为检索层。
/// 轻量 v1 管线：CleanContent（清洗）→ ChunkMarkdown（## 标题分段 + 段落聚合）→ Ingest（幂等入库，
/// 可选双写 md）→ Recall（召回）→ BuildContext（上下文装配）。
/// 召回取舍：FTS5 unicode61 对中文分词不友好（连续 CJK 视作单 token），v1 用 SQL LIKE 候选 + 纯 C# 评分
/// （词命中数 + 标题命中加权）；FTS5/vec0 向量召回留 P2 接 embedding 后启用。
/// vec0.dll（sqlite-vec）随包分发，启动尝试加载并登记 VecAvailable（缺失优雅降级）。
/// 独立 memory.db，与 local.db 隔离；静态类 + 锁，v1 同步操作（本地毫秒级）。
/// </summary>
public static class MemoryStoreService
{
    /// <summary>召回命中：Chunk 所在文档与内容、得分（越高越相关）。</summary>
    public sealed record ChunkHit(long DocId, string DocTitle, string ChunkTitle, string Content, double Score);

    /// <summary>
    /// 嵌入向量维度（P3 接入 bge-small-zh-v1.5 时生效）。选型依据（2026-09 调研，见 issue #63）：
    /// 检索质量在 ~768 维后趋平，CPU 轻量甜点 384-768；中文场景取 512 = bge-small-zh-v1.5 原生维度
    /// （24M 参数/CPU 单句毫秒级）。备选：multilingual-e5-small 384（多语言）、Qwen3-Embedding-0.6B
    /// MRL 截断 512-768（质量最佳但 ~600MB 偏重）。
    /// </summary>
    public const int EmbeddingDims = 512;

    private static readonly object _gate = new();
    private static string _dbPath = Path.Combine(
        Framework.AppPaths.DataDir, "memory.db");
    private static bool _initialized;
    private static bool? _vecAvailable;

    /// <summary>注入数据库路径（单测用；须在首次操作前调用）。</summary>
    internal static void UseDatabase(string path)
    {
        lock (_gate) { _dbPath = path; _initialized = false; _vecAvailable = null; }
    }

    private static void EnsureInit()
    {
        if (_initialized) return;
        Directory.CreateDirectory(Path.GetDirectoryName(_dbPath)!);
        using var conn = Open();
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = """
                CREATE TABLE IF NOT EXISTS memory_doc(
                    id INTEGER PRIMARY KEY,
                    source TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    md_path TEXT,
                    content_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')));
                CREATE TABLE IF NOT EXISTS memory_chunk(
                    id INTEGER PRIMARY KEY,
                    doc_id INTEGER NOT NULL REFERENCES memory_doc(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL);
                """;
            cmd.ExecuteNonQuery();
        }
        _vecAvailable = TryLoadVec(conn);
        if (_vecAvailable == true)
        {
            // 向量位预留：vec0 虚表以 chunk_id 关联（P3 接 embedding 后写入）；建表本身即 vec0.dll 真实可用性验证
            try
            {
                using var cmd = conn.CreateCommand();
                cmd.CommandText = $"CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(chunk_id INTEGER PRIMARY KEY, embedding float[{EmbeddingDims}])";
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                _vecAvailable = false;
                Framework.RuntimeLog.Info("[MemoryStore] vec0 table create failed: " + ex.Message);
            }
        }
        _initialized = true;
        Framework.RuntimeLog.Info("[MemoryStore] init ok, vec=" + _vecAvailable);
    }

    private static SqliteConnection Open()
    {
        var conn = new SqliteConnection("Data Source=" + _dbPath);
        conn.Open();
        return conn;
    }

    /// <summary>
    /// 尝试加载 sqlite-vec（vec0.dll 随包在输出目录；亦探测 resources/sqlite-vec 子目录）。
    /// 成功与否登记 VecAvailable——P1 无 embedding 源不建向量表，仅确认能力位。
    /// </summary>
    private static bool TryLoadVec(SqliteConnection conn)
    {
        try
        {
            conn.EnableExtensions();
            var candidates = new[]
            {
                Path.Combine(AppContext.BaseDirectory, "vec0"),
                Path.Combine(AppContext.BaseDirectory, "resources", "sqlite-vec", "vec0"),
            };
            foreach (var ext in candidates)
            {
                if (!File.Exists(ext + ".dll")) continue;
                using var cmd = conn.CreateCommand();
                cmd.CommandText = "SELECT load_extension('" + ext.Replace("'", "''") + "')";
                cmd.ExecuteNonQuery();
                // 能力探测：vec_version() 是 sqlite-vec 注册的函数
                using var probe = conn.CreateCommand();
                probe.CommandText = "SELECT vec_version()";
                probe.ExecuteScalar();
                return true;
            }
            return false;
        }
        catch
        {
            return false; // 缺失/加载失败：优雅降级为纯 LIKE 召回
        }
    }

    /// <summary>sqlite-vec 是否可用（惰性触发首次初始化）。</summary>
    public static bool VecAvailable { get { EnsureInit(); return _vecAvailable == true; } }

    #region 纯函数：清洗与分段（可单测）

    /// <summary>
    /// 内容清洗：去 HTML 注释、行尾空白、折叠 3+ 空行为 2；代码围栏原样保留。
    /// </summary>
    internal static string CleanContent(string markdown)
    {
        if (string.IsNullOrEmpty(markdown)) return "";
        var text = Regex.Replace(markdown, @"<!--.*?-->", "", RegexOptions.Singleline);
        var lines = text.Replace("\r\n", "\n").Split('\n')
            .Select(l => l.TrimEnd());
        var sb = new StringBuilder();
        var blank = 0;
        foreach (var line in lines)
        {
            if (line.Length == 0) { blank++; if (blank > 2) continue; }
            else blank = 0;
            sb.AppendLine(line);
        }
        return sb.ToString().TrimEnd();
    }

    /// <summary>
    /// 分段：##（含更深层）标题为界切段；无标题段按空行聚合成 ~maxLen 块。返回 (段标题, 段内容)。
    /// 标题保留在内容内（供 LIKE 召回与上下文阅读）。
    /// </summary>
    internal static List<(string Title, string Content)> ChunkMarkdown(string markdown, int maxLen = 500)
    {
        var cleaned = CleanContent(markdown);
        var chunks = new List<(string, string)>();
        if (cleaned.Length == 0) return chunks;

        var currentTitle = "";
        var buffer = new List<string>();
        foreach (var line in cleaned.Replace("\r\n", "\n").Split('\n'))
        {
            var isHeading = Regex.IsMatch(line, @"^#{1,6}\s");
            if (isHeading)
            {
                Flush();
                currentTitle = line.TrimStart('#').Trim();
                buffer.Add(line);
                continue;
            }
            buffer.Add(line);
            if (string.Join("\n", buffer).Length >= maxLen) Flush(keepTitle: true);
        }
        Flush();

        void Flush(bool keepTitle = false)
        {
            var content = string.Join("\n", buffer).Trim();
            buffer.Clear();
            if (content.Length == 0) return;
            var title = string.IsNullOrEmpty(currentTitle)
                ? (content.Length <= 24 ? content : content[..24])
                : currentTitle;
            chunks.Add((title, content));
            if (!keepTitle) currentTitle = "";
        }
        return chunks;
    }

    /// <summary>查询分词：空白切分 + 去标点 + 2 字以上（中文词/英文词均适用 LIKE 命中）。</summary>
    internal static string[] TokenizeQuery(string query)
        => (query ?? "")
            .Split(new[] { ' ', '\t', '\r', '\n', '，', '。', '、', '；', '：', '？', '！', ',', '.', ';', ':', '?', '!' },
                StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(t => t.Trim())
            .Where(t => t.Length >= 1)
            .Distinct()
            .ToArray();

    /// <summary>召回评分（纯函数）：内容词命中数 + 标题词命中 ×3 加权；无命中返回 0。</summary>
    internal static double ScoreChunk(string content, string title, IReadOnlyList<string> tokens)
    {
        if (tokens.Count == 0) return 0;
        double score = 0;
        foreach (var tok in tokens)
        {
            if (content.Contains(tok, StringComparison.OrdinalIgnoreCase)) score += 1;
            if (title.Contains(tok, StringComparison.OrdinalIgnoreCase)) score += 3;
        }
        return score;
    }

    #endregion

    #region 入库 / 召回 / 装配

    /// <summary>
    /// 入库（幂等）：source+内容 hash 不变则跳过；变化则整文档重切重建 chunk。
    /// mdPath 非空时把原文双写为 md 文件（记忆物料的人类可读层）。返回入库 chunk 数（跳过返回 0）。
    /// </summary>
    public static int Ingest(string source, string title, string markdown, string? mdPath = null)
    {
        if (string.IsNullOrWhiteSpace(source)) throw new ArgumentException("source required", nameof(source));
        EnsureInit();
        var cleaned = CleanContent(markdown);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(cleaned)));
        var seq = 0;
        lock (_gate)
        {
            using var conn = Open();
            using var tx = conn.BeginTransaction();
            try
            {
                using (var find = conn.CreateCommand())
                {
                    find.Transaction = tx;
                    find.CommandText = "SELECT id, content_hash FROM memory_doc WHERE source = $s";
                    find.Parameters.AddWithValue("$s", source);
                    using var r = find.ExecuteReader();
                    if (r.Read())
                    {
                        if (r.GetString(1) == hash) { tx.Rollback(); return 0; } // 幂等：未变化
                        using (var del = conn.CreateCommand())
                        {
                            del.Transaction = tx;
                            del.CommandText = "DELETE FROM memory_chunk WHERE doc_id = $id; DELETE FROM memory_doc WHERE id = $id";
                            del.Parameters.AddWithValue("$id", r.GetInt64(0));
                            del.ExecuteNonQuery();
                        }
                    }
                }
                long docId;
                using (var ins = conn.CreateCommand())
                {
                    ins.Transaction = tx;
                    ins.CommandText = "INSERT INTO memory_doc(source, title, md_path, content_hash) VALUES($s,$t,$m,$h); SELECT last_insert_rowid();";
                    ins.Parameters.AddWithValue("$s", source);
                    ins.Parameters.AddWithValue("$t", title ?? source);
                    ins.Parameters.AddWithValue("$m", (object?)mdPath ?? DBNull.Value);
                    ins.Parameters.AddWithValue("$h", hash);
                    docId = (long)ins.ExecuteScalar()!;
                }
                seq = 0;
                foreach (var (chunkTitle, content) in ChunkMarkdown(cleaned))
                {
                    using var ins = conn.CreateCommand();
                    ins.Transaction = tx;
                    ins.CommandText = "INSERT INTO memory_chunk(doc_id, seq, title, content) VALUES($d,$q,$t,$c)";
                    ins.Parameters.AddWithValue("$d", docId);
                    ins.Parameters.AddWithValue("$q", seq++);
                    ins.Parameters.AddWithValue("$t", chunkTitle);
                    ins.Parameters.AddWithValue("$c", content);
                    ins.ExecuteNonQuery();
                }
                tx.Commit();
            }
            catch
            {
                tx.Rollback();
                throw;
            }
        }
        if (!string.IsNullOrEmpty(mdPath))
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(mdPath))!);
                File.WriteAllText(mdPath, cleaned, new UTF8Encoding(false));
            }
            catch (Exception ex) { Framework.RuntimeLog.Info("[MemoryStore] md write failed: " + ex.Message); }
        }
        Framework.RuntimeLog.Info("[MemoryStore] ingest ok source=" + source + " chunks=" + seq);
        return seq;
    }

    /// <summary>
    /// 召回：SQL LIKE 取候选（任一词命中 content 或 title，OR 连接），C# 评分排序取前 k。
    /// LIKE 对中文天然友好（无分词依赖）；候选集上限 500 防长库全扫评分。
    /// </summary>
    public static List<ChunkHit> Recall(string query, int k = 5)
    {
        EnsureInit();
        var tokens = TokenizeQuery(query);
        if (tokens.Length == 0) return new List<ChunkHit>();
        lock (_gate)
        {
            using var conn = Open();
            using var cmd = conn.CreateCommand();
            // ESCAPE '\'：LIKE 通配符转义生效前提（EscapeLike 以 \ 转义 % _ \）
            var where = string.Join(" OR ", tokens.Select((t, i) =>
                $"c.content LIKE $p{i} ESCAPE '\\' OR c.title LIKE $p{i} ESCAPE '\\'"));
            cmd.CommandText = $"SELECT c.doc_id, d.title, c.title, c.content FROM memory_chunk c " +
                              $"JOIN memory_doc d ON d.id = c.doc_id WHERE {where} LIMIT 500";
            for (var i = 0; i < tokens.Length; i++)
                cmd.Parameters.AddWithValue("$p" + i, "%" + EscapeLike(tokens[i]) + "%");
            var hits = new List<ChunkHit>();
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    var content = r.GetString(3);
                    var chunkTitle = r.GetString(2);
                    var score = ScoreChunk(content, chunkTitle, tokens);
                    if (score > 0) hits.Add(new ChunkHit(r.GetInt64(0), r.GetString(1), chunkTitle, content, score));
                }
            }
            return hits.OrderByDescending(h => h.Score).Take(k).ToList();
        }
    }

    /// <summary>装配上下文：召回片段整理为带来源标注的单一文本块（供 AI 提示词拼接）。</summary>
    public static string BuildContext(IEnumerable<ChunkHit> hits)
    {
        var sb = new StringBuilder();
        foreach (var h in hits)
        {
            if (sb.Length > 0) sb.AppendLine();
            sb.AppendLine($"[{h.DocTitle} / {h.ChunkTitle}]");
            sb.AppendLine(h.Content);
        }
        return sb.ToString();
    }

    private static string EscapeLike(string s) => s.Replace(@"\", @"\\").Replace("%", @"\%").Replace("_", @"\_");

    /// <summary>记忆库存量统计（#430 管理 UI）：文档数 / 分块数。</summary>
    public static (int Docs, int Chunks) Stats()
    {
        EnsureInit();
        lock (_gate)
        {
            using var conn = Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT (SELECT COUNT(*) FROM memory_doc), (SELECT COUNT(*) FROM memory_chunk)";
            using var r = cmd.ExecuteReader();
            if (!r.Read()) return (0, 0);
            return (Convert.ToInt32(r.GetValue(0)), Convert.ToInt32(r.GetValue(1)));
        }
    }

    /// <summary>清空全部记忆（#430 管理 UI）：删分块与文档，返回删除的文档数。不可撤销。</summary>
    public static int ClearAll()
    {
        EnsureInit();
        lock (_gate)
        {
            using var conn = Open();
            using (var count = conn.CreateCommand())
            {
                count.CommandText = "SELECT COUNT(*) FROM memory_doc";
                var docs = Convert.ToInt32(count.ExecuteScalar() ?? 0);
                using (var del = conn.CreateCommand())
                {
                    del.CommandText = "DELETE FROM memory_chunk; DELETE FROM memory_doc;";
                    del.ExecuteNonQuery();
                }
                Framework.RuntimeLog.Info("[MemoryStore] clear all docs=" + docs);
                return docs;
            }
        }
    }

    #endregion
}
