import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SideDeskCore
import SideDeskServices

/// 设置 → 账户（对应 C# `AccountSettingsPage.xaml` + `AccountSettingsViewModel`）：
/// 个人资料卡（头像/昵称/进入个人后台）+ 登录状态、云同步卡（开关/立即同步/加密同步/从云端恢复）、
/// 本地备份卡（备份/恢复下拉/导出）。
///
/// 与 C# 的平台差异：
/// - 登录唯一入口是系统浏览器 OAuth2（`AccountService.startLogin` 内部已完成核心持久化与拉详情，
///   本页只需重读状态，无需 C# 的 OnLoginSuccess 回调段）；
/// - 确认/提示框走 NSAlert（C# ThemedMessageBox）；三个文件对话框走 NSOpenPanel/NSSavePanel；
/// - 团队切换下拉（RefreshCorpSelector）未移植，缺席。
struct AccountSettingsPage: View {

    @StateObject private var model = AccountSettingsModel()
    /// 昵称展示行悬停（对应 C# `IsMouseOver` 触发器：高亮 + 浮现编辑提示）
    @State private var nicknameHovered = false

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(titleKey: "common.account")
                .padding(.bottom, 8)   // C# 标题 Margin="0,0,0,24"（spacing 16 + 8）
            profileCard(palette)
            cloudSyncCard(palette)
            backupCard(palette)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.color)
        .onAppear { model.refresh() }
    }

    // MARK: - 个人资料卡（含登录状态）

    /// 对应 C# 第一张 Border：登录后显示个人资料区（标题行/头像昵称/分隔线），底部恒显登录状态行。
    private func profileCard(_ palette: ThemePalette) -> some View {
        SettingsCard(spacing: 12) {
            if model.isLoggedIn {
                HStack {
                    Text(Lang.t("settings.profile"))
                        .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                        .foregroundStyle(palette.textMain.color)
                    Spacer()
                    Button(Lang.t("settings.enterUserConsole")) { model.openUserConsole() }
                }
                divider(palette)
                HStack(alignment: .center, spacing: 16) {
                    avatarView(palette)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Lang.t("common.nickname"))
                            .font(.system(size: ThemeManager.fontSize(11)))
                            .foregroundStyle(palette.textMuted.color)
                        if model.isEditingNickname {
                            nicknameEditRow
                        } else {
                            nicknameDisplayRow(palette)
                        }
                    }
                    Spacer(minLength: 0)
                }
                divider(palette)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText)
                        .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                        .foregroundStyle(palette.textMain.color)
                    Text(model.subText)
                        .font(.system(size: ThemeManager.fontSize(12)))
                        .foregroundStyle(palette.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(model.actionButtonText) { model.accountAction() }
                    .disabled(!model.actionEnabled)
            }
        }
    }

    /// 头像（点击更换）：有图显示圆裁图，无图显示昵称首字兜底（对应 C# AvatarFallbackText/AvatarHasImage）。
    private func avatarView(_ palette: ThemePalette) -> some View {
        ZStack {
            Circle().fill(palette.accent.color)
            if let image = model.avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else {
                Text(model.avatarFallbackText)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .onTapGesture { model.pickAvatar() }
        .help(Lang.t("settings.clickToChangeAvatar"))
    }

    /// 昵称展示态：悬停浮现高亮与「✎ 编辑」，点击进入编辑态。
    private func nicknameDisplayRow(_ palette: ThemePalette) -> some View {
        HStack(spacing: 8) {
            Text(model.nicknameDisplay)
                .font(.system(size: ThemeManager.fontSize(13)))
                .foregroundStyle(model.nicknameIsSet ? palette.textMain.color : palette.textMuted.color)
            if nicknameHovered {
                Text(Lang.t("common.editEmoji"))
                    .font(.system(size: ThemeManager.fontSize(11)))
                    .foregroundStyle(palette.textMuted.color)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: ThemeManager.radius(6))
            .fill(nicknameHovered ? palette.listItemMouseOver.color : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: ThemeManager.radius(6))
            .stroke(nicknameHovered ? palette.border.color : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { nicknameHovered = $0 }
        .onTapGesture { model.beginEditNickname() }
        .help(Lang.t("settings.clickToChangeNickname"))
    }

    /// 昵称编辑态：输入框 + 保存/取消（Enter 保存、Esc 取消，对应 C# KeyBinding）。
    private var nicknameEditRow: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.nicknameBoxText)
                .dialogFieldStyle()
                .onSubmit { model.saveNickname() }
                .onExitCommand { model.cancelNickname() }
            Button(Lang.t("common.save")) { model.saveNickname() }
            Button(Lang.t("common.cancel")) { model.cancelNickname() }
        }
    }

    // MARK: - 云同步卡

    /// 对应 C# 第二张 Border：云同步开关 → 状态行+立即同步 → 加密同步开关 → 恢复设置行。
    private func cloudSyncCard(_ palette: ThemePalette) -> some View {
        SettingsCard(spacing: 12) {
            SettingsRow(titleKey: "common.cloudSync", hintKey: "settings.autoBackupHint") {
                Toggle("", isOn: Binding(
                    get: { model.cloudSyncOn },
                    set: { model.setCloudSync($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(palette.accent.color)
                .disabled(!model.cloudSyncSwitchEnabled)
            }
            divider(palette)
            HStack(spacing: 12) {
                Text(model.cloudSyncStatusText)
                    .font(.system(size: ThemeManager.fontSize(13)))
                    .foregroundStyle(palette.textSec.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Lang.t("settings.syncNow")) { model.syncNow() }
                    .disabled(!model.syncNowEnabled)
            }
            divider(palette)
            SettingsRow(titleKey: "common.encryptedSync", hintKey: "settings.encryptedSyncHint") {
                Toggle("", isOn: Binding(
                    get: { model.encryptSyncOn },
                    set: { model.setEncryptSync($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(palette.accent.color)
                .disabled(!model.encryptSyncEnabled)
            }
            divider(palette)
            SettingsRow(titleKey: "settings.restoreSettings", hintKey: "settings.pullSettingsHint") {
                Button(Lang.t("settings.restoreFromCloud")) { model.restoreSettingsFromCloud() }
                    .disabled(!model.restoreSettingsEnabled)
            }
        }
    }

    // MARK: - 本地备份卡

    /// 对应 C# 第三张 Border：标题+说明 → 状态行 + 备份/恢复下拉/导出。
    private func backupCard(_ palette: ThemePalette) -> some View {
        SettingsCard(spacing: 12) {
            SettingsSectionTitle(titleKey: "settings.backupExport", hintKey: "settings.localBackupHint")
            divider(palette)
            HStack(spacing: 8) {
                Text(model.backupStatusText)
                    .font(.system(size: ThemeManager.fontSize(13)))
                    .foregroundStyle(palette.textSec.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(Lang.t("common.backup")) { model.backup() }
                // 「恢复」下拉（对应 C# restoreBtn.ContextMenu：直接恢复最近备份 / 选择文件恢复）
                Menu {
                    Button(Lang.t("settings.restoreLastBackup")) { model.restoreLastBackup() }
                        .disabled(!model.restoreLastBackupEnabled)
                    Button(Lang.t("settings.restoreFromFile")) { model.restoreFromFile() }
                } label: {
                    HStack(spacing: 6) {
                        Text(Lang.t("common.restore"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                }
                .menuIndicator(.hidden)
                Button(Lang.t("settings.exportConfiguration")) { model.exportConfig() }
            }
        }
    }

    private func divider(_ palette: ThemePalette) -> some View {
        Rectangle()
            .fill(palette.border.color)
            .frame(height: 1)
    }
}

/// 账户页模型（对应 C# `AccountSettingsViewModel`）：状态判定与命令流程；
/// 确认/提示框、文件面板、密码对话框经 NSAlert/NSOpenPanel/`SyncPasswordDialog` 就地实现
/// （C# 把这些作为属性注入由 code-behind 接线，Swift 侧无需中间层）。
@MainActor
final class AccountSettingsModel: ObservableObject {

    // MARK: 登录状态

    @Published private(set) var isLoggedIn = false
    @Published private(set) var statusText = ""
    @Published private(set) var subText = ""
    @Published private(set) var actionButtonText = ""
    /// 主按钮可用（重新校验 Token 期间禁用，防重复点击）
    @Published private(set) var actionEnabled = true

    // MARK: 个人资料

    @Published private(set) var nicknameDisplay = "-"
    @Published private(set) var nicknameIsSet = false
    @Published private(set) var avatarFallbackText = "?"
    @Published private(set) var avatarImage: NSImage?
    @Published var isEditingNickname = false
    @Published var nicknameBoxText = ""

    // MARK: 云同步

    @Published private(set) var cloudSyncOn = false
    @Published private(set) var cloudSyncSwitchEnabled = false
    @Published private(set) var syncNowEnabled = false
    @Published private(set) var encryptSyncOn = false
    @Published private(set) var encryptSyncEnabled = false
    @Published private(set) var restoreSettingsEnabled = false
    @Published var cloudSyncStatusText = ""

    // MARK: 本地备份

    @Published private(set) var backupStatusText = ""
    @Published private(set) var restoreLastBackupEnabled = false

    private let account: AccountService?
    private let cloudSync: CloudSyncService?
    private let profile: ProfileService?
    private var accountObserver: NSObjectProtocol?

    init() {
        account = AppContainer.shared.resolve(AccountService.self)
        cloudSync = AppContainer.shared.resolve(CloudSyncService.self)
        profile = AppContainer.shared.resolve(ProfileService.self)
        refresh()
        // 账号状态广播（登录/登出/校验/作用域切换）→ 整页重读
        accountObserver = NotificationCenter.default.addObserver(
            forName: AccountService.stateChangedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        // 云同步状态回调可能来自后台任务 → 投递主线程（对应 C# OnCloudSyncStatus + InvokeOnUi）
        cloudSync?.statusChanged = { [weak self] _, message in
            Seam.uiPost { MainActor.assumeIsolated { self?.cloudSyncStatusText = message } }
        }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        cloudSync?.statusChanged = nil
    }

    // MARK: - 加载与刷新

    /// 读取账号与云同步状态并刷新整页（对应 C# Refresh + RefreshProfile + RefreshBackup）。
    func refresh() {
        refreshBackup()
        guard let account else {
            // 容器未登记（Preview 等）：未登录态呈现，动作全部禁用
            isLoggedIn = false
            statusText = Lang.t("common.notLoggedIn")
            subText = Lang.t("settings.logInToEnable")
            actionButtonText = Lang.t("common.logIn")
            actionEnabled = false
            cloudSyncOn = false
            encryptSyncOn = false
            cloudSyncSwitchEnabled = false
            syncNowEnabled = false
            encryptSyncEnabled = false
            restoreSettingsEnabled = false
            cloudSyncStatusText = Lang.t("settings.logInToSync")
            nicknameDisplay = Lang.t("common.notSet")
            nicknameIsSet = false
            avatarFallbackText = "?"
            avatarImage = nil
            return
        }
        let s = account.readState()

        isLoggedIn = s.IsLoggedIn
        if s.IsLoggedIn {
            let name = s.Name ?? ""
            // 全角冒号沿用 C# 拼接（标点，非待译文案）
            statusText = Lang.t("common.loggedIn") + (name.isEmpty ? "" : "：" + name)
            subText = s.LoginTime.map { dateText("settings.loggedInTime", $0) } ?? Lang.t("common.loggedIn")
            actionButtonText = Lang.t("common.logOut")
        } else {
            statusText = Lang.t("common.notLoggedIn")
            // 启动后接口校验尚未完成→校验中；离线→离线提示；Token 过期→过期提示；否则默认引导
            if let token = s.Token, !token.isEmpty, !s.Offline {
                subText = Lang.t("settings.verifyingLoginStatus")
            } else if s.Offline {
                subText = Lang.t("settings.offlineServerUnreachable")
            } else if let expired = s.TokenExpiredMessage, !expired.isEmpty {
                subText = expired
            } else {
                subText = Lang.t("settings.logInToEnable")
            }
            actionButtonText = Lang.t("common.logIn")
        }

        cloudSyncOn = s.EnableCloudSync && s.IsLoggedIn
        encryptSyncOn = s.SyncEncryptEnabled && s.IsLoggedIn
        cloudSyncSwitchEnabled = s.IsLoggedIn
        syncNowEnabled = s.IsLoggedIn
        encryptSyncEnabled = s.IsLoggedIn && s.EnableCloudSync
        restoreSettingsEnabled = s.IsLoggedIn
        if let t = s.LastSyncTime {
            cloudSyncStatusText = dateText("settings.lastSync", t)
        } else {
            cloudSyncStatusText = s.IsLoggedIn ? Lang.t("common.notSyncedYet") : Lang.t("settings.logInToSync")
        }

        // 个人资料区（昵称 + 头像预览）
        let trimmed = (s.Name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        nicknameIsSet = !trimmed.isEmpty
        nicknameDisplay = trimmed.isEmpty ? Lang.t("common.notSet") : (s.Name ?? "")
        avatarFallbackText = trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
        avatarImage = (s.Avatar ?? "").isEmpty ? nil : decodeAvatar(s.Avatar ?? "")
    }

    /// 刷新本地备份状态（对应 C# RefreshBackup）。
    func refreshBackup() {
        if let t = LocalBackupService.getLocalBackupTime() {
            backupStatusText = dateText("settings.latestBackup", t)
            restoreLastBackupEnabled = true
        } else {
            backupStatusText = Lang.t("settings.noLocalBackupYet")
            restoreLastBackupEnabled = false
        }
    }

    // MARK: - 登录 / 退出

    /// 登录 / 退出登录 / 重新校验 Token（对应 C# AccountActionAsync）。
    func accountAction() {
        guard let account else { return }
        let s = account.readState()

        if s.IsLoggedIn {
            guard confirm(Lang.t("settings.logoutConfirm"), title: Lang.t("common.logOut")) else { return }
            account.logout()
            refresh()
            return
        }

        if let token = s.Token, !token.isEmpty {
            // 离线或启动校验未完成但本地 Token 仍在：点「登录」= 重新验证现有 Token
            actionEnabled = false
            Task { [weak self] in
                await account.validateToken()
                guard let self else { return }
                let after = account.readState()
                if after.Offline, let t = after.Token, !t.isEmpty {
                    self.alert(Lang.t("settings.serverStillUnreachable"), title: Lang.t("common.logIn"))
                }
                self.actionEnabled = true
                self.refresh()
            }
            return
        }

        // 系统浏览器 OAuth2：服务内部已完成持久化/启长连接/云同步对账/拉详情，这里只重读
        Task { [weak self] in
            _ = await account.startLogin()
            self?.refresh()
        }
    }

    // MARK: - 昵称 / 头像

    func beginEditNickname() {
        nicknameBoxText = account?.readState().Name ?? ""
        isEditingNickname = true
    }

    func cancelNickname() {
        isEditingNickname = false
    }

    /// 保存昵称（空 = 清除），并同步到后端（失败不阻断本地保存，对应 C# SaveNickname）。
    func saveNickname() {
        let name = nicknameBoxText.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = Seam.settings
        s.AccountName = name.isEmpty ? nil : name
        s.Save()
        isEditingNickname = false
        refresh()
        if !(s.AccountToken ?? "").isEmpty, let n = s.AccountName, let profile {
            Task {
                let (ok, msg) = await profile.updateMyProfile(nickName: n, avatar: nil)
                if !ok { RuntimeLog.debug("[Settings] profile sync to backend failed: \(msg)") }
            }
        }
    }

    /// 更换头像：选图 → 压缩 base64 落盘 → 直传 OSS 并同步后端（对应 C# PickAvatar + UploadAvatarAsync）。
    func pickAvatar() {
        let panel = NSOpenPanel()
        panel.title = Lang.t("settings.chooseAvatarImage")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let base64 = ProfileService.prepareAvatarBase64(filePath: url.path) else {
            alert(Lang.t("settings.failedToLoadAvatar") + url.lastPathComponent, title: Lang.t("common.avatar"))
            return
        }
        let s = Seam.settings
        s.AccountAvatar = base64
        s.Save()
        refresh()
        guard let profile else { return }
        Task {
            guard !(Seam.settings.AccountToken ?? "").isEmpty else { return }
            guard let bytes = Data(base64Encoded: base64),
                  let avatarUrl = await profile.uploadAvatarToCache(bytes) else {
                RuntimeLog.debug("[Settings] avatar OSS cache upload failed, skipping backend sync this time")
                return
            }
            let (ok, msg) = await profile.updateMyProfile(nickName: nil, avatar: avatarUrl)
            if !ok { RuntimeLog.debug("[Settings] profile sync to backend failed: \(msg)") }
        }
    }

    /// 进入个人后台（系统浏览器打开控制台「我的」页，已登录时交接码免登）。
    func openUserConsole() {
        Task { await OAuthLoginService.openConsolePage("/system/user-center") }
    }

    // MARK: - 云同步

    /// 云同步开关（对应 C# CloudSyncOn setter）：无 Token 开启会被拦回；
    /// 关闭 = 主动退出（服务写 CloudSyncUserOptOut），起停与落盘都在服务内完成。
    func setCloudSync(_ value: Bool) {
        guard let account else { return }
        if value && (account.readState().Token ?? "").isEmpty {
            alert(Lang.t("settings.loginRequiredCloudSync"), title: Lang.t("common.notice"))
            refresh()   // 开关弹回
            return
        }
        account.setCloudSync(value)
        refresh()
    }

    /// 加密同步开关（对应 C# EncryptSyncOn setter）：首次开启需设置同步密码；
    /// 已有派生密钥直接开；取消/派生失败弹回开关。
    func setEncryptSync(_ value: Bool) {
        guard let account else { return }
        if value {
            let s = account.readState()
            if !s.HasDerivedKey {
                if (s.UserId ?? "").isEmpty {
                    alert(Lang.t("settings.userIdUnavailable"), title: Lang.t("common.notice"))
                    refresh()
                    return
                }
                guard let password = SyncPasswordDialog.requestPassword() else {
                    refresh()
                    return
                }
                guard account.enableSyncEncryption(password: password) else {
                    refresh()   // 派生/Keychain 保护失败：与取消同样弹回（C# 无独立失败分支）
                    return
                }
            } else {
                account.setSyncEncrypt(true)
            }
        } else {
            account.setSyncEncrypt(false)
        }
        refresh()
    }

    /// 立即同步一次（对应 C# SyncNowAsync）。
    func syncNow() {
        guard let cloudSync else { return }
        syncNowEnabled = false
        Task { [weak self] in
            _ = await cloudSync.syncNow()
            guard let self else { return }
            self.syncNowEnabled = !(self.account?.readState().Token ?? "").isEmpty
            self.refresh()
        }
    }

    /// 从云端恢复设置（对应 C# RestoreSettingsAsync）：确认后拉取覆盖本地，按结果提示。
    func restoreSettingsFromCloud() {
        guard confirm(Lang.t("settings.pullSettingsConfirm"), title: Lang.t("settings.restoreSettings")) else { return }
        restoreSettingsEnabled = false
        Task { [weak self] in
            let count = await self?.cloudSync?.restoreSettings() ?? -1
            guard let self else { return }
            self.restoreSettingsEnabled = true
            if count > 0 {
                self.alert(Lang.tf("settings.restoredSettings", count), title: Lang.t("common.done"))
            } else if count == 0 {
                self.alert(Lang.t("settings.noSyncedSettingsFound"), title: Lang.t("common.notice"))
            } else {
                self.alert(Lang.t("settings.restoreFailedPleaseCheck"), title: Lang.t("common.failed"))
            }
            self.refresh()
        }
    }

    // MARK: - 本地备份 / 导出

    /// 创建本地备份（覆盖最后一个，对应 C# Backup）。
    func backup() {
        let ok = LocalBackupService.createLocalBackup()
        alert(ok ? Lang.t("settings.localBackupCreated") : Lang.t("settings.backupFailedPleaseRetry"),
              title: Lang.t("common.backup"))
        refreshBackup()
    }

    /// 从最近一次本地备份恢复（对应 C# RestoreLastBackup）。
    func restoreLastBackup() {
        guard LocalBackupService.hasLocalBackup() else {
            alert(Lang.t("settings.noLocalBackupsAvailable"), title: Lang.t("common.restore"))
            return
        }
        guard confirm(Lang.t("settings.restoreBackupConfirm"), title: Lang.t("settings.restoreBackup")) else { return }
        showRestoreResult(LocalBackupService.restoreLocalBackup())
    }

    /// 选择备份文件恢复（默认定位本地备份目录，对应 C# RestoreFromFile + PickBackupFile）。
    func restoreFromFile() {
        let panel = NSOpenPanel()
        panel.title = Lang.t("settings.restoreBackup")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.zip, UTType.json]
        let backupDir = LocalBackupService.localBackupDir
        if FileManager.default.fileExists(atPath: backupDir) {
            panel.directoryURL = URL(fileURLWithPath: backupDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard confirm(Lang.t("settings.restoreFromFileConfirm"), title: Lang.t("settings.restoreBackup")) else { return }
        showRestoreResult(LocalBackupService.restoreFromBackupFile(url.path))
    }

    /// 导出全部配置与数据为 zip（对应 C# ExportConfig + PickExportPath）。
    func exportConfig() {
        let panel = NSSavePanel()
        panel.title = Lang.t("settings.exportConfiguration")
        panel.allowedContentTypes = [UTType.zip]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SideDesk-backup-\(f.string(from: Date())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LocalBackupService.exportBackupZip(to: url.path)
            alert(Lang.t("settings.configurationExported"), title: Lang.t("common.export"))
        } catch {
            alert(Lang.t("settings.exportFailed") + error.localizedDescription, title: Lang.t("common.export"))
        }
    }

    /// 统一提示恢复结果（n>=0 为成功恢复的文件数，-1 失败，对应 C# ShowRestoreResult）。
    private func showRestoreResult(_ n: Int) {
        if n >= 0 {
            alert(Lang.tf("settings.restoreConfigFilesDone", n), title: Lang.t("common.restore"))
        } else {
            alert(Lang.t("settings.restoreFailedPleaseRetry"), title: Lang.t("common.restore"))
        }
    }

    // MARK: - 宿主小工具

    /// 确认框（对应 C# ThemedMessageBox.Confirm）。
    private func confirm(_ message: String, title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: Lang.t("common.confirm"))
        alert.addButton(withTitle: Lang.t("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 提示框（对应 C# ThemedMessageBox.Show）。
    private func alert(_ message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: Lang.t("common.ok"))
        alert.runModal()
    }

    /// 头像 base64 → NSImage（失败返回 nil，回退昵称首字，对应 C# DecodeAvatar）。
    private func decodeAvatar(_ base64: String) -> NSImage? {
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    /// 日期占位文案（C# Lang.TF 的 {0:yyyy-MM-dd HH:mm}；Swift Lang.tf 只替换 {i}，
    /// 手动替换格式占位符，与 `CloudSyncService.syncedText` 同法）。
    private func dateText(_ key: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        let text = f.string(from: date)
        var s = Lang.t(key)
        s = s.replacingOccurrences(of: "{0:yyyy-MM-dd HH:mm}", with: text)
        s = s.replacingOccurrences(of: "{0}", with: text)
        return s
    }
}