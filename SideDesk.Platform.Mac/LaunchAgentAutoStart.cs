using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Foundation;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IAutoStart"/> 的 macOS 实现：用户级 **LaunchAgent**（<c>~/Library/LaunchAgents/&lt;Label&gt;.plist</c>），
/// 取代 Windows 的注册表 <c>HKCU\...\Run</c> 值。无需管理员权限、随用户登录启动。
///
/// 行为对齐 Windows <c>AutoStartService</c>：
///  - <see cref="Apply"/>(true) **只写 plist**（RunAtLoad=true）——下次登录 launchd 自动加载并启动，
///    **不立即拉起**（避免用户正在用时双开）。这与「写注册表 Run 值」同口径：登记的是下次登录的行为。
///  - <see cref="Apply"/>(false) 先 best-effort <c>launchctl bootout</c> 卸载本会话可能已加载的项，再删 plist。
///  - <see cref="IsEnabled"/> = plist 存在且其程序路径指向当前 <see cref="ProgramArguments"/>（与 Windows 校验 exe 路径同理）。
///
/// 启动方式用 <c>/usr/bin/open &lt;bundle.app&gt;</c> 而非直接 exec 内部 Mach-O：GUI 应用经 LaunchServices
/// 激活更稳（Dock/焦点/单实例语义正确）；<c>open</c> 拉起后即退出，launchd 视该 job 已运行一次（无 KeepAlive，符合登录启动一次的预期）。
/// </summary>
public sealed class LaunchAgentAutoStart : IAutoStart
{
    /// <summary>LaunchAgent 标签（= plist 文件名与 launchd job 名）。默认取主 bundle 的标识符。</summary>
    public string Label { get; init; } = DefaultLabel();

    /// <summary>启动命令 argv。默认 <c>["/usr/bin/open", "&lt;主 bundle .app 路径&gt;"]</c>。</summary>
    public string[] ProgramArguments { get; init; } = DefaultProgramArguments();

    /// <summary>LaunchAgent 目录。默认 <c>~/Library/LaunchAgents</c>。</summary>
    public string PlistDirectory { get; init; } = DefaultPlistDirectory();

    /// <summary>plist 的 RunAtLoad（登录加载即启动）。默认 true。</summary>
    public bool RunAtLoad { get; init; } = true;

    /// <summary>
    /// launchctl 执行接缝（测试注入替身以捕获 argv、不触碰真实 launchd）。null = 真实执行
    /// <c>/bin/launchctl</c>，返回退出码。bootout 对未加载的 job 返回非零，属正常，调用方按 best-effort 忽略。
    /// </summary>
    internal Func<string[], int>? LaunchCtlRunner { get; set; }

    private string PlistPath => Path.Combine(PlistDirectory, Label + ".plist");

    public bool IsEnabled()
    {
        try
        {
            if (!File.Exists(PlistPath)) return false;
            string content = File.ReadAllText(PlistPath);
            // 指向当前程序才算启用（与 Windows 校验注册表值 == 当前 exe 路径同口径）。
            // 比对最后一个 argv（生产即 .app 路径）；用与写入一致的 XML 转义，避免特殊字符漏配。
            string needle = SecurityElement.Escape(ProgramArguments[^1]) ?? "";
            return content.Contains(needle, StringComparison.Ordinal);
        }
        catch { return false; }
    }

    public void Apply(bool enabled)
    {
        try
        {
            if (enabled)
            {
                Directory.CreateDirectory(PlistDirectory);
                File.WriteAllText(PlistPath, BuildPlist());
                // 不 bootstrap：登记下次登录启动，不立即拉起（对齐 Windows Run 值语义，避免双开）。
            }
            else
            {
                // 本会话若已加载则卸载（best-effort，未加载会非零返回，忽略），再删 plist。
                RunLaunchCtl(new[] { "bootout", $"gui/{GetUid()}/{Label}" });
                if (File.Exists(PlistPath)) File.Delete(PlistPath);
            }
        }
        catch (Exception ex)
        {
            SideDesk.Framework.RuntimeLog.Debug($"[AutoStart] failed to apply({enabled}): {ex.Message}");
        }
    }

    /// <summary>构造 LaunchAgent plist（XML 格式）。所有插值经 XML 转义。</summary>
    private string BuildPlist()
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
        sb.Append("<plist version=\"1.0\">\n<dict>\n");
        sb.Append("\t<key>Label</key>\n\t<string>").Append(SecurityElement.Escape(Label)).Append("</string>\n");
        sb.Append("\t<key>ProgramArguments</key>\n\t<array>\n");
        foreach (string arg in ProgramArguments)
            sb.Append("\t\t<string>").Append(SecurityElement.Escape(arg)).Append("</string>\n");
        sb.Append("\t</array>\n");
        sb.Append("\t<key>RunAtLoad</key>\n\t<").Append(RunAtLoad ? "true" : "false").Append("/>\n");
        sb.Append("\t<key>ProcessType</key>\n\t<string>Interactive</string>\n");
        sb.Append("</dict>\n</plist>\n");
        return sb.ToString();
    }

    private int RunLaunchCtl(string[] args)
    {
        var runner = LaunchCtlRunner;
        if (runner != null) return runner(args);

        try
        {
            var psi = new ProcessStartInfo("/bin/launchctl")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            foreach (string a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return -1;
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit(5000);
            return p.ExitCode;
        }
        catch
        {
            return -1;
        }
    }

    private static string DefaultLabel()
        => NSBundle.MainBundle.BundleIdentifier is { Length: > 0 } id ? id : "com.sidestmac.app";

    private static string[] DefaultProgramArguments()
    {
        string bundle = NSBundle.MainBundle.BundlePath ?? "";
        if (bundle.EndsWith(".app", StringComparison.Ordinal))
            return new[] { "/usr/bin/open", bundle };
        // 非 .app 宿主（如命令行/测试）回落当前可执行文件
        return new[] { Environment.ProcessPath ?? "" };
    }

    private static string DefaultPlistDirectory()
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "LaunchAgents");

    [DllImport("/usr/lib/libSystem.B.dylib")]
    private static extern uint getuid();

    private static uint GetUid() => getuid();
}
