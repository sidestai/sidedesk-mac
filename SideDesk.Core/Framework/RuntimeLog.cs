using System;
using System.IO;

namespace SideDesk.Framework
{
    /// <summary>
    /// 运行时日志（Release 可用）：应用主日志通道，取代裸 Debug.WriteLine。
    ///
    /// 设计（ADR-0002，克隆 HttpLog 的成熟骨架）：
    /// - 所有级别始终双写 System.Diagnostics.Debug.WriteLine，调试器可见性不降级；
    ///   文件写入按 <see cref="MinLevel"/> 门控——默认 Info，Debug 级不落盘（线上安静，
    ///   存量纯调试输出迁移后行为等价；需要时经 Settings.LogLevel 或环境变量 SIDESK_LOG_LEVEL 打开）。
    /// - 日志文件：%LocalAppData%\SideDesk\Logs\app.log，超过 8MB 滚动为 app.old.log（保留一份）。
    /// - 不使用 [Conditional("DEBUG")]——那正是旧日志在 Release 全部消失的根因。
    /// - 崩溃走 <see cref="Crash"/>：单独写 crash.log 并滚动保留最近 5 份（不会被启动清理删除）。
    ///
    /// 用法：RuntimeLog.Info("update", "new version found: 1.0.9")；单参重载省略分类。
    /// 行格式：[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [category] message（机器可解析）。
    /// </summary>
    public static class RuntimeLog
    {
        /// <summary>日志级别（数值越大越严重）</summary>
        public enum Level { Debug = 0, Info = 1, Warn = 2, Error = 3 }

        /// <summary>当前文件写入门槛；默认 Info。启动时由 Settings.LogLevel 赋值，环境变量 SIDESK_LOG_LEVEL 优先</summary>
        public static Level MinLevel = Level.Info;

        /// <summary>app.log 单文件最大字节数，超出滚动</summary>
        private const long MaxFileSize = 8 * 1024 * 1024;

        /// <summary>crash.log 单文件最大字节数，超出滚动</summary>
        private const long CrashMaxFileSize = 1 * 1024 * 1024;

        /// <summary>crash 滚动保留份数（crash.log + crash.1.log … crash.4.log）</summary>
        private const int CrashKeepCount = 5;

        private static readonly object _lock = new();

        /// <summary>测试缝隙：覆盖日志目录（集成测试隔离 LocalAppData 用；null=真实路径）</summary>
        internal static string? DirOverride;

        private static string _dir => DirOverride ?? Path.Combine(AppPaths.DataDir, "Logs");
        private static string _filePath => Path.Combine(_dir, "app.log");
        private static string _crashPath => Path.Combine(_dir, "crash.log");

        /// <summary>app.log 完整路径</summary>
        public static string FilePath => _filePath;

        /// <summary>按 Settings 字符串设置级别（非法值回落 Info）；优先级：SIDESK_LOG_LEVEL 环境变量 > 开发模式(Debug) > Settings</summary>
        public static void ApplyConfig(string? settingsLevel)
        {
            MinLevel = ParseLevel(settingsLevel);
            var env = Environment.GetEnvironmentVariable("SIDESK_LOG_LEVEL");
            if (!string.IsNullOrWhiteSpace(env))
                MinLevel = ParseLevel(env);
            else if (RuntimeMode.IsDev)
                MinLevel = Level.Debug; // 开发模式全量落盘（显式 SIDESK_LOG_LEVEL 仍优先）
        }

        internal static Level ParseLevel(string? s) => s?.Trim().ToLowerInvariant() switch
        {
            "debug" => Level.Debug,
            "warn" or "warning" => Level.Warn,
            "error" => Level.Error,
            _ => Level.Info,
        };

        public static void Debug(string message) => Write(Level.Debug, "", message);
        public static void Debug(string category, string message) => Write(Level.Debug, category, message);
        public static void Info(string message) => Write(Level.Info, "", message);
        public static void Info(string category, string message) => Write(Level.Info, category, message);
        public static void Warn(string message) => Write(Level.Warn, "", message);
        public static void Warn(string category, string message) => Write(Level.Warn, category, message);
        public static void Error(string message) => Write(Level.Error, "", message);
        public static void Error(string category, string message) => Write(Level.Error, category, message);

        /// <summary>异常日志：类型/消息/堆栈一并落盘</summary>
        public static void Error(string category, Exception ex) =>
            Write(Level.Error, category, $"{ex.GetType().FullName}: {ex.Message}\n堆栈: {ex.StackTrace}");

        /// <summary>崩溃记录：写 crash.log（独立滚动保留 5 份，启动清理豁免）。接管 App.LogCrash。</summary>
        public static void Crash(string source, Exception ex, string? extra = null)
        {
            string logLine = $"""
                [{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [CRASH] {source}
                类型: {ex.GetType().FullName}
                消息: {ex.Message}
                堆栈: {ex.StackTrace}
                {(extra != null ? $"内部异常:\n{extra}" : "")}
                """;
            System.Diagnostics.Debug.WriteLine(logLine);
            try
            {
                lock (_lock)
                {
                    Directory.CreateDirectory(_dir);
                    RollIfNeeded(_crashPath, ".log", CrashKeepCount, CrashMaxFileSize);
                    File.AppendAllText(_crashPath, logLine + Environment.NewLine);
                }
            }
            catch { /* 日志失败不能引发新异常 */ }
        }

        private static void Write(Level level, string category, string message)
        {
            string line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] [{level.ToString().ToUpperInvariant()}] " +
                          (string.IsNullOrEmpty(category) ? message : $"[{category}] {message}");
            System.Diagnostics.Debug.WriteLine(line);
            if (level < MinLevel) return;
            try
            {
                lock (_lock)
                {
                    Directory.CreateDirectory(_dir);
                    RollIfNeeded(_filePath, ".log", 1, MaxFileSize);
                    File.AppendAllText(_filePath, line + Environment.NewLine);
                }
            }
            catch { /* 日志失败不能引发新异常 */ }
        }

        /// <summary>
        /// 大小滚动：path 超 maxBytes 时把 path.ext → path.1.ext … path.{keep-1}.ext，最旧一份删除。
        /// keep=1 即 HttpLog 的老模式（xxx.log → xxx.old.log 之外的简化版：直接滚动一号）。
        /// </summary>
        internal static void RollIfNeeded(string path, string ext, int keep, long maxBytes)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= maxBytes) return;

            string baseNoExt = path[..^ext.Length];
            for (int i = keep - 1; i >= 1; i--)
            {
                string src = $"{baseNoExt}.{i}{ext}";
                if (i == keep - 1) { if (File.Exists(src)) File.Delete(src); continue; }
                string dst = $"{baseNoExt}.{i + 1}{ext}";
                if (File.Exists(src)) File.Move(src, dst);
            }
            File.Move(path, $"{baseNoExt}.1{ext}");
        }
    }
}
