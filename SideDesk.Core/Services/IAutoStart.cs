namespace SideDesk.Services;

/// <summary>
/// 开机自启接缝。平台实现：Windows=注册表 <c>HKCU\...\Run</c> 值；macOS=用户 LaunchAgent
/// （<c>~/Library/LaunchAgents/&lt;label&gt;.plist</c>）。
///
/// <para>语义对齐 Windows <c>AutoStartService</c>：<see cref="Apply"/>(true) 只做**持久登记**
/// （下次登录由系统加载启动），**不立即拉起**应用——避免用户正在用时又开一个实例；
/// <see cref="Apply"/>(false) 撤销登记（并尽力卸载本会话已加载的项）。<see cref="IsEnabled"/>
/// 反映「是否已登记且指向当前程序」，与是否正在运行无关。</para>
/// </summary>
public interface IAutoStart
{
    /// <summary>当前是否已登记开机自启（且指向当前程序路径）。</summary>
    bool IsEnabled();

    /// <summary>按开关同步登记状态：启用则写入（含路径修正），禁用则撤销。</summary>
    void Apply(bool enabled);
}
