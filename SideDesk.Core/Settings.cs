using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace SideDesk
{
    /// <summary>
    /// 单个显示器的停靠配置（停靠模式 + 每侧宽度/浮动独立）
    /// </summary>
    public class MonitorDockSettings
    {
        public LayoutMode Layout { get; set; } = LayoutMode.None;

        public int LeftPanelWidth { get; set; } = 105;
        public bool LeftHoverEnabled { get; set; } = true;
        public int LeftHoverWidth { get; set; } = 200;

        public int RightPanelWidth { get; set; } = 105;
        public bool RightHoverEnabled { get; set; } = false;
        public int RightHoverWidth { get; set; } = 200;

        /// <summary>深拷贝一份配置（供临时显示等场景使用，避免与持久化设置对象共享引用）</summary>
        public MonitorDockSettings Clone() => new MonitorDockSettings
        {
            Layout = Layout,
            LeftPanelWidth = LeftPanelWidth,
            LeftHoverEnabled = LeftHoverEnabled,
            LeftHoverWidth = LeftHoverWidth,
            RightPanelWidth = RightPanelWidth,
            RightHoverEnabled = RightHoverEnabled,
            RightHoverWidth = RightHoverWidth
        };
    }

    /// <summary>
    /// 单个虚拟桌面对应的全部显示器停靠配置
    /// </summary>
    public class DesktopDockProfile
    {
        public Guid DesktopId { get; set; }
        public string DesktopName { get; set; } = "";
        public List<MonitorDockSettings> Monitors { get; set; } = new();

        /// <summary>获取指定显示器的停靠配置，不存在时自动扩展列表并填充默认值。</summary>
        public MonitorDockSettings GetMonitor(int index)
        {
            if (index < 0) index = 0;
            while (Monitors.Count <= index)
                Monitors.Add(new MonitorDockSettings());
            return Monitors[index];
        }

        /// <summary>从另一个 profile 复制所有显示器配置</summary>
        public void CopyFrom(DesktopDockProfile source)
        {
            Monitors.Clear();
            foreach (var m in source.Monitors)
            {
                Monitors.Add(new MonitorDockSettings
                {
                    Layout = m.Layout,
                    LeftPanelWidth = m.LeftPanelWidth,
                    LeftHoverEnabled = m.LeftHoverEnabled,
                    LeftHoverWidth = m.LeftHoverWidth,
                    RightPanelWidth = m.RightPanelWidth,
                    RightHoverEnabled = m.RightHoverEnabled,
                    RightHoverWidth = m.RightHoverWidth
                });
            }
        }
    }

    public class Settings
    {
        public LayoutMode Layout { get; set; } = LayoutMode.Left;
        /// <summary>旧版单宽度配置（#441）：仅由 <see cref="Load"/> 一次性迁移回填 Left/RightPanelWidth，无其它读写；勿删（老配置文件兼容锚点）</summary>
        public int PanelWidth { get; set; } = 105;

        // 左侧停靠宽度与浮动配置
        public int LeftPanelWidth { get; set; } = 105;
        public bool LeftHoverEnabled { get; set; } = true;
        public int LeftHoverWidth { get; set; } = 200;

        // 右侧停靠宽度与浮动配置
        public int RightPanelWidth { get; set; } = 105;
        public bool RightHoverEnabled { get; set; } = false;
        public int RightHoverWidth { get; set; } = 200;

        public string ThemeMode { get; set; } = "Dark"; // 支持 "Dark", "Light", "System"
        /// <summary>界面语言偏好：auto（跟随系统）/ zh-CN / en</summary>
        public string Language { get; set; } = "auto";
        public double BackgroundOpacity { get; set; } = 50; // 背景透明度 0-100%

        /// <summary>是否显示通知条（窗口最右侧约 5px 宽的竖条，展示各种颜色的通知提醒）</summary>
        public bool ShowNotificationStrip { get; set; } = true;
        /// <summary>任务栏标题锁定总开关（启动自动恢复锁定 + 后台重扫自动捕捉重开的目标窗口）。
        /// 默认开启：配置了规则就应当执行，避免“规则保存了却永远不生效”的陷阱。</summary>
        public bool EnableTitleLock { get; set; } = true;

        /// <summary>用户是否主动关闭过标题锁定（true=主动关闭；启动时即使已配置规则也不再自动开启，尊重用户选择）</summary>
        public bool TitleLockUserOptOut { get; set; } = false;
        public bool EnableAutoUpdate { get; set; } = true;
        // 全局窗口切换热键（Ctrl+1~9），默认关闭以避免与浏览器等应用的 Ctrl+数字切标签冲突
        public bool EnableWindowSwitchHotkey { get; set; } = false;

        /// <summary>是否开启全局语音输入热键（默认开启：启动键开始语音识别，停止键结束并把识别文字粘贴到当前焦点位置）</summary>
        public bool EnableVoiceInputHotkey { get; set; } = true;

        /// <summary>启动语音识别的全局热键（格式如 "Ctrl+B"，可在 设置-快捷键 中修改）</summary>
        public string VoiceStartHotkey { get; set; } = "Ctrl+B";

        /// <summary>停止语音识别的全局热键（格式如 "Ctrl+B"，默认与启动键相同表示同一键切换开始/结束，可在 设置-快捷键 中修改）</summary>
        public string VoiceStopHotkey { get; set; } = "Ctrl+B";

        /// <summary>语音识别引擎（issue #44）：auto=模型随包就位优先本地 Whisper，否则回落系统 SAPI；whisper/sapi 为强制指定</summary>
        public string VoiceEngine { get; set; } = "auto";

        /// <summary>
        /// 语音出字位置（ADR-0014）："paste"=只在浮动窗实时显示、松手后粘贴（默认）；
        /// "inject"=边说边注入当前焦点应用的输入框（微信式，模拟按键）。
        /// 默认取 paste：注入会往任意前台应用打字，风险不对等，需用户显式开启。
        /// </summary>
        public string VoiceOutputMode { get; set; } = "paste";

        /// <summary>
        /// inject 档单次回改允许的最大退格数（ADR-0014）：说话中途改口会让已注入的文本需要回退重打，
        /// 超出此数即降级为松手粘贴——避免一次退格删掉用户自己的内容。
        /// </summary>
        public int VoiceInjectMaxRetract { get; set; } = 12;

        /// <summary>是否开启 MCP Server（HTTP/SSE，端口 19192）</summary>
        public bool EnableMcpServer { get; set; } = false;

        /// <summary>AI 对话模式："auto" = 已登录用网页版/未登录用本地化（默认），"web" = 网页版（未登录也可打开），"client" = 本地化（完全本机运行保护隐私）；其余取值由插件提供（IAiAssistantModeProvider，如 DSH 插件注册 "dsh"），未装该插件时按钮回落内置逻辑</summary>
        public string AIChatMode { get; set; } = "auto";

        /// <summary>Agent 模式默认引擎（#363）：gateway 引擎 id（claude 等）；空 = 未选择，对话框里首次选择后记住</summary>
        public string AgentEngine { get; set; } = "";

        /// <summary>是否开启内置 HTTP Server（默认开启，监听 127.0.0.1:HttpServerPort）</summary>
        public bool EnableHttpServer { get; set; } = true;

        /// <summary>内置 HTTP Server 监听端口（默认 19195）</summary>
        public int HttpServerPort { get; set; } = 19195;

        /// <summary>数据卡片连接方式："extension" = 浏览器插件（启动 WS 19191），"cdp" = 直连 CDP（需浏览器开启 --remote-debugging-port）</summary>
        public string DataConnectionMode { get; set; } = "extension";

        /// <summary>用户是否已明确选择过数据卡片连接方式（对话框确认或设置页切换）；未选择时首次添加数据看板卡片会弹选择对话框</summary>
        public bool DataConnectionModeChosen { get; set; } = false;

        /// <summary>CDP 模式连接的浏览器调试端口（浏览器需以 --remote-debugging-port=此端口 启动）</summary>
        public int CdpDebugPort { get; set; } = 9222;

        /// <summary>隐藏浏览器启动模式: "headless" = 无头模式, "hidden" = 隐藏窗口</summary>
        public string HiddenBrowserMode { get; set; } = "headless";

        /// <summary>是否启用自动启动隐藏浏览器（找不到匹配 tab 时）</summary>
        public bool EnableAutoLaunchHiddenBrowser { get; set; } = true;

        // ========== 账户 / 云同步 ==========

        /// <summary>登录后保存的账户 token（用于云同步鉴权；非空即视为已登录）</summary>
        public string? AccountToken { get; set; }

        /// <summary>登录后保存的用户 ID（encrypt2 密文，来自 /auth/userinfo；用作本地数据按账号隔离的作用域）</summary>
        public string? AccountUserId { get; set; }

        /// <summary>账户显示名称</summary>
        public string? AccountName { get; set; }

        /// <summary>账户头像（base64 编码的图片数据，空表示使用默认头像）</summary>
        public string? AccountAvatar { get; set; }

        /// <summary>最近一次登录时间</summary>
        public DateTime? AccountLoginTime { get; set; }

        /// <summary>用户是否曾经登录过（会员身份标记；一旦置 true 不再清除，用于掉线提示判断）</summary>
        public bool HasLoggedInBefore { get; set; } = false;

        /// <summary>是否开启云同步（开启后定时把本地全部配置备份到服务器）</summary>
        public bool EnableCloudSync { get; set; } = false;

        /// <summary>用户是否主动关闭过云同步（true=主动关闭；登录后不再自动开启，尊重用户选择）</summary>
        public bool CloudSyncUserOptOut { get; set; } = false;

        /// <summary>是否启用加密同步（敏感设置项加密后再上传）</summary>
        public bool SyncEncryptEnabled { get; set; } = false;

        /// <summary>是否记录网络请求日志（request/response 写入 %LocalAppData%\SideDesk\Logs\http.log，默认开启便于排查）</summary>
        public bool HttpLogEnabled { get; set; } = true;

        /// <summary>运行时日志级别（app.log 文件写入门槛：Debug/Info/Warn/Error，默认 Info——Debug 级仅调试器可见不落盘）。环境变量 SIDESK_LOG_LEVEL 优先于此设置</summary>
        public string LogLevel { get; set; } = "Info";

        /// <summary>是否写 keyboard.log 键盘事件日志（VK 键名，非输入内容；钩子本身按侧栏的鼠键记录器开关启用，此项是额外的隐私闸门，默认开）</summary>
        public bool KeyboardLogEnabled { get; set; } = true;

        /// <summary>强制软件渲染（禁用 WPF GPU 硬件加速）。显卡驱动与 DirectX 握手失败导致弹窗内容空白时可开启，重启应用后生效</summary>
        public bool ForceSoftwareRendering { get; set; } = false;

        /// <summary>DPAPI 加密后的派生密钥（base64，仅本机可解）</summary>
        public string? SyncDerivedKey { get; set; }

        /// <summary>最近一次设置同步成功的时间</summary>
        public DateTime? LastSettingsSyncTime { get; set; }

        // ========== 百度网盘 ==========

        /// <summary>百度网盘 OAuth access_token</summary>
        public string? BaiduPanAccessToken { get; set; }

        /// <summary>百度网盘 OAuth refresh_token（有效期10年，用于刷新 access_token）</summary>
        public string? BaiduPanRefreshToken { get; set; }

        /// <summary>百度网盘 access_token 过期时间</summary>
        public DateTime? BaiduPanTokenExpiry { get; set; }

        // ========== 团队（Corp）切换 ==========

        /// <summary>当前选中的团队 ID（null 或空表示"个人"，传给后台的 corpid）</summary>
        public string? SelectedCorpId { get; set; }

        /// <summary>当前选中的团队名称（用于 UI 显示）</summary>
        public string? SelectedCorpName { get; set; }

        /// <summary>最近一次云同步成功的时间</summary>
        public DateTime? LastCloudSyncTime { get; set; }

        /// <summary>云同步 localId -> serverId 映射表（本地 Id 不变，上传/同步时查此表）</summary>
        public Dictionary<string, string> CloudIdMap { get; set; } = new();

        /// <summary>用户手动禁用的插件 ID 集合（在设置-插件中关闭）</summary>
        public HashSet<string> DisabledPlugins { get; set; } = new();

        /// <summary>已关闭/已点击的通知记录（key=通知唯一标识，value=记录时间；用于控制某类通知在周期内不再出现）</summary>
        public Dictionary<string, DateTime> DismissedNotices { get; set; } = new();

        /// <summary>本地持久化的已读通知 ID 列表（插入序，代码内封顶 500）：重启后据此恢复已读状态，避免回传失败或本地通知的红点复现</summary>
        public List<string> ReadNotificationIds { get; set; } = new();

        /// <summary>判断指定 key 的通知是否应显示（从未记录过，或抑制周期已过期）</summary>
        public bool ShouldShowNotice(string key, TimeSpan? suppressPeriod = null)
        {
            if (!DismissedNotices.TryGetValue(key, out var time)) return true;
            if (suppressPeriod == null) return false; // 无周期 = 永久不再显示
            return DateTime.Now - time > suppressPeriod.Value;
        }

        /// <summary>记录通知已关闭/已点击（配合 ShouldShowNotice 实现免打扰）</summary>
        public void DismissNotice(string key)
        {
            DismissedNotices[key] = DateTime.Now;
        }

        /// <summary>每个物理显示器的停靠配置（下标 = 主显示器优先排序后的显示器序号）</summary>
        public List<MonitorDockSettings> Monitors { get; set; } = new();

        // ========== 虚拟桌面独立配置 ==========

        /// <summary>是否启用按虚拟桌面独立配置停靠布局</summary>
        public bool EnablePerVirtualDesktop { get; set; } = false;

        /// <summary>每个虚拟桌面的显示器停靠配置（仅在 EnablePerVirtualDesktop=true 时使用）</summary>
        public List<DesktopDockProfile> VirtualDesktops { get; set; } = new();

        /// <summary>获取指定显示器的停靠配置，不存在时自动扩展列表并填充默认值。</summary>
        public MonitorDockSettings GetMonitor(int index)
        {
            if (index < 0) index = 0;
            while (Monitors.Count <= index)
                Monitors.Add(new MonitorDockSettings());
            return Monitors[index];
        }

        /// <summary>获取指定虚拟桌面的配置 profile，不存在时自动创建并从全局 Monitors 复制。</summary>
        public DesktopDockProfile GetDesktopProfile(Guid desktopId, bool createIfMissing = true)
        {
            var profile = VirtualDesktops.Find(p => p.DesktopId == desktopId);
            if (profile != null) return profile;

            if (!createIfMissing)
                return new DesktopDockProfile { DesktopId = desktopId };

            // 新建 profile，从全局 Monitors 复制
            profile = new DesktopDockProfile { DesktopId = desktopId };
            foreach (var m in Monitors)
            {
                profile.Monitors.Add(new MonitorDockSettings
                {
                    Layout = m.Layout,
                    LeftPanelWidth = m.LeftPanelWidth,
                    LeftHoverEnabled = m.LeftHoverEnabled,
                    LeftHoverWidth = m.LeftHoverWidth,
                    RightPanelWidth = m.RightPanelWidth,
                    RightHoverEnabled = m.RightHoverEnabled,
                    RightHoverWidth = m.RightHoverWidth
                });
            }
            VirtualDesktops.Add(profile);
            return profile;
        }

        /// <summary>
        /// 获取当前虚拟桌面+指定显示器的停靠配置。
        /// 若未启用分桌面则退化为全局 GetMonitor()。
        /// </summary>
        public MonitorDockSettings GetCurrentMonitor(int monitorIndex, Guid? desktopId = null)
        {
            if (!EnablePerVirtualDesktop || desktopId == null || desktopId == Guid.Empty)
                return GetMonitor(monitorIndex);

            var profile = GetDesktopProfile(desktopId.Value);
            return profile.GetMonitor(monitorIndex);
        }

        /// <summary>
        /// 获取指定虚拟桌面 profile 中的显示器配置（用于设置 UI 绑定指定桌面）。
        /// </summary>
        public MonitorDockSettings GetMonitorForDesktop(Guid desktopId, int monitorIndex)
        {
            var profile = GetDesktopProfile(desktopId);
            return profile.GetMonitor(monitorIndex);
        }

        /// <summary>测试缝隙：覆盖配置目录（集成测试隔离 LocalAppData 用；null=真实路径）</summary>
        internal static string? DirOverride;

        /// <summary>配置目录：%LocalAppData%\SideDesk（与 sidedesk.db、日志同目录，稳定不随版本更新被清空）</summary>
        private static string SettingsDir => DirOverride ?? Framework.AppPaths.DataDir;

        /// <summary>主配置文件路径：%LocalAppData%\SideDesk\app-settings.json（文件名与云同步 key 一致，
        /// 且区别于 Framework.AppSettings 的 settings.json，避免同目录撞名）。
        /// 表达式属性：readonly 字段会在类型初始化时固化原始路径，导致 DirOverride 缝隙（ADR-0003）失效</summary>
        private static string SettingsPath => Path.Combine(SettingsDir, "app-settings.json");

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(SettingsDir);
                var json = JsonSerializer.Serialize(this, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                File.WriteAllText(SettingsPath, json);
            }
            catch (Exception ex)
            {
                Framework.RuntimeLog.Debug($"[Settings] save failed: {ex.Message}");
            }
        }

        public static Settings Load()
        {
            try
            {
                if (File.Exists(SettingsPath))
                {
                    var json = File.ReadAllText(SettingsPath);
                    // 判断是否为旧配置（旧版本仅有 PanelWidth，无 Left/RightPanelWidth 键）
                    bool hasPerSideWidth = json.Contains("LeftPanelWidth");
                    var settings = JsonSerializer.Deserialize<Settings>(json) ?? new Settings();
                    // 一次性迁移：旧配置将 PanelWidth 回填到左右两侧宽度，避免老用户自定义宽度丢失
                    if (!hasPerSideWidth)
                    {
                        settings.LeftPanelWidth = settings.RightPanelWidth = settings.PanelWidth;
                    }
                    // 一次性迁移：旧配置无 Monitors 列表，将全局停靠/宽度/浮动配置迁移到主显示器（下标 0）
                    if (settings.Monitors == null || settings.Monitors.Count == 0)
                    {
                        settings.Monitors = new List<MonitorDockSettings>
                        {
                            new MonitorDockSettings
                            {
                                Layout = settings.Layout,
                                LeftPanelWidth = settings.LeftPanelWidth,
                                LeftHoverEnabled = settings.LeftHoverEnabled,
                                LeftHoverWidth = settings.LeftHoverWidth,
                                RightPanelWidth = settings.RightPanelWidth,
                                RightHoverEnabled = settings.RightHoverEnabled,
                                RightHoverWidth = settings.RightHoverWidth
                            }
                        };
                    }
                    return settings;
                }
            }
            catch (Exception ex)
            {
                Framework.RuntimeLog.Debug($"[Settings] load failed: {ex.Message}");
            }
            return new Settings();
        }
    }
}
