using System;
using System.Diagnostics;
using System.IO;

namespace SideDesk.Framework
{
    /// <summary>
    /// 开发/生产运行模式（轻量双模式，不做多环境体系）：
    ///
    /// 判定（短路顺序，进程内只算一次）：
    ///   1. 环境变量 SIDESK_DEV=1 → Dev（显式覆盖，任何运行形态下可强制）
    ///   2. 调试器挂载（Debugger.IsAttached）→ Dev
    ///   3. exe 位于构建输出目录（...\bin\...）→ Dev（dotnet run/build 均落在 bin\
    ///      而已安装应用的 exe 在 %LocalAppData%\SideDesk\current\，不含 bin\）
    ///   4. 其余 → Prod
    ///
    /// 行为门控（详见 docs/observability.md）：
    ///   - RuntimeLog：Dev 且未显式设 SIDESK_LOG_LEVEL 时强制 Debug 级（全量落盘）
    ///   - HttpLog：Dev 强制开启
    ///   - Velopack 静默更新：Dev 跳过（避免调试期间被自动重启）
    ///
    /// 注意：本判定与 VelopackUpdateService 的 _updateManager.IsInstalled 相互独立——
    /// IsInstalled 对"可更新性"仍是权威（便携版未安装也算 Prod 但不可更新）。
    /// </summary>
    public static class RuntimeMode
    {
        /// <summary>是否开发模式（进程内首次访问时判定并缓存）</summary>
        public static bool IsDev => _isDev ??= Detect();

        /// <summary>测试模式（--test-mode 启动参数）：数据目录隔离到临时目录 + 跳过 GUI/钩子/自启/更新等副作用，供 E2E 进程测试（ADR-0004）</summary>
        public static bool IsTestMode { get; internal set; }

        private static bool? _isDev;

        /// <summary>重置模式缓存（测试缝隙：变更环境变量/判定输入后重新判定）</summary>
        internal static void ResetCache() => _isDev = null;

        private static bool Detect() =>
            DetectCore(Environment.GetEnvironmentVariable("SIDESK_DEV"), Debugger.IsAttached, AppContext.BaseDirectory);

        /// <summary>纯函数判定（internal 供单测直接验证优先级）：环境变量 &gt; 调试器 &gt; bin\ 启发式</summary>
        internal static bool DetectCore(string? env, bool debuggerAttached, string baseDir)
        {
            // 1. 显式环境变量覆盖（值大小写不敏感：TRUE/True 同 true，fixes #28）
            if (!string.IsNullOrWhiteSpace(env))
                return env.Trim().ToLowerInvariant() is "1" or "true" or "yes";

            // 2. 调试器挂载
            if (debuggerAttached)
                return true;

            // 3. 构建输出目录启发式（正反斜杠都认）
            if (baseDir.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}") ||
                baseDir.Contains("\\bin\\") || baseDir.Contains("/bin/"))
                return true;

            return false;
        }

        /// <summary>模式名（"test" / "dev" / "prod"），供日志首行等展示</summary>
        public static string Name => IsTestMode ? "test" : IsDev ? "dev" : "prod";
    }
}
