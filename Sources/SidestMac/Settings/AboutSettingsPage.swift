import AppKit
import SwiftUI
import SideDeskCore

/// 设置 → 关于（对应 C# `AboutSettingsPage.xaml` + `AboutSettingsViewModel`）。
///
/// 已落地：产品图标、产品名、产品/文件版本号、应用简介、自动更新卡、支持外链（仅中文语言，对应 C# `ShowSupportLinks`）。
/// 未落地（不给死控件）：
/// - 「联系客服」在 C# 弹微信客服二维码，二维码资源未随包移植，故只保留「功能建议 & 微屏社区」外链。
///
/// 自动更新卡对应 C# `AboutSettingsPage.xaml:53-141` + `AboutSettingsViewModel`，数据源换成 `UpdateService`
/// （Sparkle，见 #63）。有意差异一处：C# 的进度区是「正在下载更新 + 数字百分比 + 6px 进度条」，
/// Sparkle 委托协议不回调字节数，故百分比去掉、进度条改不确定态。
struct AboutSettingsPage: View {

    @ObservedObject private var updates = UpdateService.shared

    /// 产品版本号（对应 C# `FileVersionInfo.ProductVersion`）：打包时由 Info.plist 提供，裸 `swift run` 回落 "dev"。
    private let productVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    /// 文件/构建版本号（对应 C# `FileVersionInfo.FileVersion`）：取 CFBundleVersion。
    private let fileVersion: String =
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"

    /// 支持外链仅中文语言显示（对应 C# `_queryShowSupportLinks`：Lang.Current 以 zh 开头）。
    private var showSupportLinks: Bool { Lang.current.hasPrefix("zh") }

    /// 功能建议 & 微屏社区外链（对应 C# `AboutSettingsViewModel.CommunityUrl`）。
    private static let communityURL = URL(string: "https://support.qq.com/products/801966")!

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(titleKey: "settings.about")
                .padding(.bottom, 24)

            // 产品图标（对应 C# 从 exe 内嵌图标提取；mac 侧取应用图标）
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .padding(.bottom, 12)

            Text(Lang.t("common.sideDeskScreen"))
                .font(.system(size: ThemeManager.fontSize(20), weight: .bold))   // C# FontSizeTitle
                .foregroundStyle(palette.textMain.color)
                .padding(.bottom, 8)

            Text(Lang.tf("settings.productVersionLabel", productVersion))
                .font(.system(size: ThemeManager.fontSize(13)))
                .foregroundStyle(palette.textSec.color)
                .padding(.bottom, 4)

            Text(Lang.tf("settings.fileVersionLabel", fileVersion))
                .font(.system(size: ThemeManager.fontSize(13)))
                .foregroundStyle(palette.textSec.color)
                .padding(.bottom, 16)

            Text(Lang.t("settings.appDescription"))
                .font(.system(size: ThemeManager.fontSize(13)))
                .foregroundStyle(palette.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            updateCard(palette: palette)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if showSupportLinks {
                Button {
                    NSWorkspace.shared.open(Self.communityURL)
                } label: {
                    Text(Lang.t("settings.feedbackCommunity"))
                        .font(.system(size: ThemeManager.fontSize(13)))
                        .foregroundStyle(palette.accent.color)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(palette.bg.color)
    }

    // MARK: - 自动更新卡

    /// 对应 C# 关于页 `Border` 里的四段：开关 → 1px 分隔线 → 检查行 → 下载区 → 就绪区。
    /// 后两段是条件渲染（C# 的 `DownloadProgressVisible` / `ApplyPanelVisible` DataTrigger）。
    @ViewBuilder
    private func updateCard(palette: ThemePalette) -> some View {
        SettingsCard(spacing: 12) {
            SettingsToggleRow(titleKey: "settings.automaticallyCheckAndDownload",
                              isOn: $updates.autoUpdateEnabled)

            Rectangle()
                .fill(palette.border.color)
                .frame(height: 1)

            HStack(spacing: 12) {
                Text(updates.statusText)
                    .font(.system(size: ThemeManager.fontSize(13)))
                    .foregroundStyle(palette.textSec.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Lang.t("common.checkForUpdates")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates || updates.isBusy)
            }

            if updates.isDownloading {
                Text(Lang.t("settings.downloadingUpdate"))
                    .font(.system(size: ThemeManager.fontSize(13)))
                    .foregroundStyle(palette.textMain.color)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(palette.accent.color)
            }

            if updates.isUpdateReady {
                HStack(spacing: 12) {
                    Text(Lang.t("settings.newVersionReadyRestart"))
                        .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                        .foregroundStyle(palette.accent.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(Lang.t("settings.restartNowAndApply")) { updates.applyAndRestart() }
                }
            }
        }
    }
}

#Preview {
    AboutSettingsPage()
        .frame(width: 500, height: 500)
}
