import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 模块设置 → 数据看板卡片段（对应 C# `ModulesSettingsPage` 的「数据卡片连接方式」区）。
/// CDP 相关控件：连接方式、测试连接、调试端口、隐藏浏览器模式、自动拉起隐藏浏览器；
/// 状态直接读写 `Seam.settings` 并落盘，文案一律走 Lang。
@MainActor
final class DataDashboardSettingsModel: ObservableObject {

    /// 是否 CDP 连接模式（决定端口/自动拉起两行的显隐，与 C# `CdpSectionVisible` 同语义）
    @Published private(set) var isCdpMode: Bool

    /// 调试端口输入文本（回车或失焦提交）
    @Published var cdpPortText: String

    /// 自动拉起隐藏浏览器（找不到匹配 tab 时）
    @Published private(set) var autoLaunchHiddenBrowser: Bool

    /// 隐藏浏览器启动模式："headless" 无头 / "hidden" 隐藏窗口（对应 C# `HiddenBrowserIndex` 0/1）
    @Published private(set) var hiddenBrowserMode: String

    /// 测试连接进行中：按钮禁用，避免同一端口重复建连
    @Published private(set) var isTestingConnection = false

    init() {
        let settings = Seam.settings
        isCdpMode = settings.DataConnectionMode == "cdp"
        cdpPortText = String(settings.CdpDebugPort)
        autoLaunchHiddenBrowser = settings.EnableAutoLaunchHiddenBrowser
        hiddenBrowserMode = settings.HiddenBrowserMode == "hidden" ? "hidden" : "headless"
    }

    func selectMode(cdp: Bool) {
        let mode = cdp ? "cdp" : "extension"
        guard mode != Seam.settings.DataConnectionMode else {
            isCdpMode = cdp
            return
        }
        Seam.settings.DataConnectionMode = mode
        // 在设置页切换过即视为明确选择（与 C# 选模式后置位一致）
        Seam.settings.DataConnectionModeChosen = true
        Seam.settings.Save()
        isCdpMode = cdp
    }

    /// 提交端口：合法则落盘，非法回退到当前值（对应 C# `ApplyCdpPort`）
    func applyPort() {
        let trimmed = cdpPortText.trimmingCharacters(in: .whitespaces)
        if let port = Int(trimmed), port > 0, port <= 65535 {
            if Seam.settings.CdpDebugPort != port {
                Seam.settings.CdpDebugPort = port
                Seam.settings.Save()
            }
            cdpPortText = String(port)
        } else {
            cdpPortText = String(Seam.settings.CdpDebugPort)
        }
    }

    func setAutoLaunchHiddenBrowser(_ value: Bool) {
        guard value != Seam.settings.EnableAutoLaunchHiddenBrowser else {
            autoLaunchHiddenBrowser = value
            return
        }
        Seam.settings.EnableAutoLaunchHiddenBrowser = value
        Seam.settings.Save()
        autoLaunchHiddenBrowser = value
    }

    /// 隐藏浏览器启动模式（对应 C# `HiddenBrowserIndex`：0 无头 / 1 隐藏窗口）
    func setHiddenBrowserMode(_ value: String) {
        guard value != Seam.settings.HiddenBrowserMode else {
            hiddenBrowserMode = value
            return
        }
        Seam.settings.HiddenBrowserMode = value
        Seam.settings.Save()
        hiddenBrowserMode = value
    }

    /// 测试 CDP 连接，结果交给自检窗（对应 C# `TestCdpConnectionAsync` + `ShowCdpResult`）。
    /// 端口优先取输入框的值（与 C# 一样只要求 >0），非法则回落已保存端口。
    func testConnection() {
        guard !isTestingConnection else { return }
        let typed = Int(cdpPortText.trimmingCharacters(in: .whitespaces))
        let port = (typed != nil && typed! > 0) ? typed! : Seam.settings.CdpDebugPort
        isTestingConnection = true
        Task { @MainActor in
            let text = await CdpConnectionTest.run(port: port)
            isTestingConnection = false
            CdpTestResult.show(title: Lang.t("settings.cdpConnectionTest"), text: text)
        }
    }
}

struct DataDashboardSettingsView: View {
    @StateObject private var model = DataDashboardSettingsModel()
    @FocusState private var portFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(titleKey: "common.dataDashboard", hintKey: "settings.moduleConfigHint")

            connectionCard

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(ThemeManager.palette.bg.color)
        .onChange(of: portFocused) { focused in
            if !focused { model.applyPort() }
        }
    }

    // MARK: - 数据卡片连接方式

    private var connectionCard: some View {
        SettingsCard(spacing: 10) {
            HStack(spacing: 6) {
                Text(Lang.t("settings.webDataSourceMode"))
                    .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                    .foregroundStyle(ThemeManager.palette.textMain.color)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: ThemeManager.fontSize(11)))
                    .foregroundStyle(ThemeManager.palette.textMuted.color)
                    .help(Lang.t("settings.webFetchModeHint"))
            }

            Picker(selection: Binding(
                get: { model.isCdpMode },
                set: { model.selectMode(cdp: $0) }
            ), label: EmptyView()) {
                Text(Lang.t("settings.browserExtensionMode")).tag(false)
                Text(Lang.t("settings.cdpConnectionMode")).tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if model.isCdpMode {
                testConnectionRow
                debugPortRow
                hiddenBrowserRow
            }
        }
    }

    private var debugPortRow: some View {
        HStack(spacing: 6) {
            Text(Lang.t("settings.debugPort"))
                .foregroundStyle(ThemeManager.palette.textMuted.color)
            TextField("", text: $model.cdpPortText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                .focused($portFocused)
                .onSubmit { model.applyPort() }
            Text(Lang.t("settings.remoteDebuggingPortNote"))
                .font(.system(size: ThemeManager.fontSize(11)))
                .foregroundStyle(ThemeManager.palette.textMuted.color)
        }
        .padding(.leading, 20)
    }

    private var hiddenBrowserRow: some View {
        HStack(spacing: 8) {
            Text(Lang.t("settings.hiddenBrowser"))
                .foregroundStyle(ThemeManager.palette.textMuted.color)
            Picker(selection: Binding(
                get: { model.hiddenBrowserMode },
                set: { model.setHiddenBrowserMode($0) }
            ), label: EmptyView()) {
                Text(Lang.t("settings.headlessMode")).tag("headless")
                Text(Lang.t("common.hiddenWindow")).tag("hidden")
            }
            .labelsHidden()
            .fixedSize()

            Text(Lang.t("settings.autoLaunchHiddenBrowser"))
                .foregroundStyle(ThemeManager.palette.textMuted.color)
                .padding(.leading, 8)
            Toggle(isOn: Binding(
                get: { model.autoLaunchHiddenBrowser },
                set: { model.setAutoLaunchHiddenBrowser($0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(ThemeManager.palette.accent.color)
        }
        .padding(.leading, 20)
    }

    /// 测试连接：连一次调试端口并列出页面标签，结果进自检窗
    private var testConnectionRow: some View {
        HStack(spacing: 8) {
            Button(action: { model.testConnection() }) {
                Text(Lang.t("settings.testConnection"))
            }
            .controlSize(.small)
            .disabled(model.isTestingConnection)
            if model.isTestingConnection {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.leading, 20)
    }
}

#Preview {
    DataDashboardSettingsView()
        .frame(width: 700, height: 360)
}
