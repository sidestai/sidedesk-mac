import Foundation
import SideDeskCore

/// 账户页读取到的一份账号/云同步状态快照（只读值，供 UI 渲染）。对应 C# `AccountState` record。
public struct AccountState {
    public let Token: String?
    public let UserId: String?
    public let Name: String?
    public let Avatar: String?
    public let LoginTime: Date?
    public let Offline: Bool
    public let Verified: Bool
    public let TokenExpiredMessage: String?
    public let EnableCloudSync: Bool
    public let SyncEncryptEnabled: Bool
    public let HasDerivedKey: Bool
    public let LastSyncTime: Date?

    /// 已登录 = 持有 Token + 不离线 + 本次会话经接口确认（与 C# 判定一致）
    public var IsLoggedIn: Bool {
        !(Token ?? "").isEmpty && !Offline && Verified
    }
}

/// 账号服务：登录/登出/Token 校验/用户详情/作用域切换的编排中心。
/// 对应 C# `App.xaml.cs` 的账号段（ValidateAccountTokenAsync / ApplyLoginSuccessCore /
/// FetchAndSaveUserInfoAsync）+ `AccountSeam` 的宿主能力。
///
/// 与 C# 的平台差异：
/// - 登录唯一入口是系统浏览器 OAuth2（C# 的 WebView2 内嵌兜底在 macOS 不存在）；
/// - 掉线橙色通知（ShowLoggedOutNotification）依赖主窗口通知条，Mac 侧尚未移植该 UI，
///   此处只维护状态标志，账户页据此渲染；
/// - MCP 工具注册表同步未移植，缺席。
public final class AccountService {

    /// 状态变更广播（主线程发出）：账户页/登录菜单据此重读快照。
    public static let stateChangedNotification = Notification.Name("SideDeskAccountStateChanged")

    /// 运行时离线标记：auth 接口不可达、无法确认登录态（不清本地 Token，恢复后重新验证）
    public private(set) var Offline = false
    /// 本次会话登录态是否已经接口确认（启动校验 code=200 或登录成功）；
    /// 未确认前不得仅凭 Token 宣称已登录
    public private(set) var Verified = false
    /// 启动时 Token 验证失败的提示信息（非空表示登录已过期，账户页显示提示）
    public private(set) var TokenExpiredMessage: String?

    // MARK: - 宿主/兄弟服务接缝（ServicesBootstrap 接线；未接时静默缺席）

    /// 启动后端 WebSocket（token=nil 为访客连接）。对应 Resolve<BackendWebSocketService>().Start。
    public var webSocketStart: ((String?) -> Void)?
    /// 启动云同步（内部吞异常语义由调用闭包保证）
    public var cloudSyncStart: (() -> Void)?
    /// 停止云同步
    public var cloudSyncStop: (() -> Void)?
    /// 云同步对账（pushLocal=true 上传本地结构）
    public var cloudSyncReconcile: ((_ pushLocal: Bool) -> Void)?

    private let api: BackendApiClient

    /// - Parameter api: 仅测试注入（假 transport）；生产传 nil 走真实网络。
    public init(api: BackendApiClient? = nil) {
        self.api = api ?? BackendApiClient(logTag: "[Auth]", timeout: 10)
    }

    /// 读取当前账号与云同步状态快照
    public func readState() -> AccountState {
        let s = Seam.settings
        return AccountState(
            Token: s.AccountToken, UserId: s.AccountUserId, Name: s.AccountName,
            Avatar: s.AccountAvatar, LoginTime: s.AccountLoginTime,
            Offline: Offline, Verified: Verified, TokenExpiredMessage: TokenExpiredMessage,
            EnableCloudSync: s.EnableCloudSync, SyncEncryptEnabled: s.SyncEncryptEnabled,
            HasDerivedKey: !(s.SyncDerivedKey ?? "").isEmpty, LastSyncTime: s.LastCloudSyncTime)
    }

    // MARK: - Token 校验

    /// 启动时验证 Token：延迟 2 秒执行，避免与其他启动任务争抢网络。
    /// 对应 C# `ValidateTokenOnStartupAsync`。
    public func validateTokenOnStartup() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await validateToken()
    }

    /// 立即验证本地 Token（GET /auth/userinfo）：有效→恢复登录态；明确无效(401/403)→清本地登录态；
    /// 不可达→标记离线（不清 Token）。供账户页离线状态下点「登录」手动重连复用。
    /// 对应 C# `ValidateAccountTokenAsync`。
    public func validateToken() async {
        let s = Seam.settings
        guard let token = s.AccountToken, !token.isEmpty else {
            // 未登录 → 以访客（设备）身份建立后端 WebSocket，接收设备维度通知
            webSocketStart?(nil)
            return
        }

        let r = await api.send("GET", "/api/auth/userinfo")
        if r.transportFailed {
            // 网络不可达 / HTTP 层失败（502/504 等）→ 离线，不清 Token
            markOffline(true)
            return
        }
        if r.ok {
            // Token 有效：清过期提示、更新最后登录时间、默认开启云同步（除非用户主动关过）
            TokenExpiredMessage = nil
            Verified = true
            markOffline(false)
            s.AccountLoginTime = Date()
            s.HasLoggedInBefore = true
            var justEnabledCloudSync = false
            if !s.CloudSyncUserOptOut && !s.EnableCloudSync {
                s.EnableCloudSync = true
                justEnabledCloudSync = true
            }
            s.Save()
            notifyStateChanged()

            await fetchUserInfo(token: token)
            webSocketStart?(token)
            // 本次刚默认开启云同步 → 立即对账一次（已开启时不重复启动）
            if justEnabledCloudSync { cloudSyncStart?() }
            return
        }
        if api.LastAuthFailed {
            // code=401/403：Token 明确无效（过期/被踢）→ 清本地登录态
            RuntimeLog.debug("[Auth] token verification failed (auth), clearing local login state")
            TokenExpiredMessage = Lang.t("settings.loginExpired")
            let wasLoggedIn = !(s.AccountUserId ?? "").isEmpty
            clearLoginFields(s)
            s.Save()
            cloudSyncStop?()
            webSocketStart?(nil)
            if wasLoggedIn { reloadScope() }
            notifyStateChanged()
            // 401/403 是服务器的明确应答，网络可达 → 不算离线
            return
        }
        // 其他业务码（500 等）：服务器未确认登录态 → 离线（不清 Token，避免临时故障误清除）
        markOffline(true)
    }

    // MARK: - 登录 / 登出

    /// 统一登录入口：系统浏览器 OAuth2 → 核心持久化 → 拉用户详情。成功返回 true。
    /// 对应 C# `StartLoginAsync`（Mac 无内嵌登录窗兜底，OAuth 失败即失败）。
    @discardableResult
    public func startLogin() async -> Bool {
        guard let token = await OAuthLoginService.login() else { return false }
        if applyLoginSuccessCore(token: token) {
            await fetchUserInfo(token: token)
        }
        return true
    }

    /// 登录成功后的核心持久化（幂等）：存 token、默认开云同步（除非用户主动关过）、
    /// 启长连接与云同步。对应 C# `ApplyLoginSuccessCore`。
    @discardableResult
    public func applyLoginSuccessCore(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let s = Seam.settings
        if s.AccountToken == token { return false }   // 已应用过，不重复处理

        s.AccountToken = token
        s.AccountLoginTime = Date()
        s.HasLoggedInBefore = true
        // 团队选择为空则默认切到「个人」
        if (s.SelectedCorpId ?? "").isEmpty {
            s.SelectedCorpId = nil
            s.SelectedCorpName = nil
        }
        if !s.CloudSyncUserOptOut { s.EnableCloudSync = true }
        s.Save()

        TokenExpiredMessage = nil
        Verified = true      // 登录接口本身即接口确认
        markOffline(false)
        webSocketStart?(token)
        // 云同步已开启 → 立即对账一次（上传本地结构并回写 ServerId）
        if s.EnableCloudSync { cloudSyncStart?() }
        notifyStateChanged()
        return true
    }

    /// 退出登录：清账号字段、停云同步、降级访客长连接、必要时重载窗口作用域。
    /// 对应 C# `AccountSeam.Logout`。
    public func logout() {
        let s = Seam.settings
        // 作用域即将从 u:A 回退 local：记录是否已绑定账号（用于退出后切换窗口数据）
        let wasLoggedIn = !(s.AccountUserId ?? "").isEmpty
        clearLoginFields(s)
        s.Save()

        cloudSyncStop?()
        webSocketStart?(nil)   // 登出后降级访客连接，保持可接收设备维度通知
        Verified = false
        Offline = false
        TokenExpiredMessage = nil
        if wasLoggedIn { reloadScope() }
        notifyStateChanged()
    }

    /// 写云同步开关与「用户主动选择」标记：关=主动退出（后续登录不再自动开启），开=取消退出。
    /// 对应 C# `AccountSeam.SetCloudSync` + VM 的起停调用。
    public func setCloudSync(_ enabled: Bool) {
        let s = Seam.settings
        s.EnableCloudSync = enabled
        s.CloudSyncUserOptOut = !enabled
        s.Save()
        if enabled { cloudSyncStart?() } else { cloudSyncStop?() }
        notifyStateChanged()
    }

    // MARK: - 加密同步

    /// 写加密同步开关。对应 C# `AccountSeam.SetSyncEncrypt`（Mac 侧一并 Save/广播，
    /// 与 `setCloudSync` 同口径；C# VM 在调用后自行 Save）。
    public func setSyncEncrypt(_ enabled: Bool) {
        let s = Seam.settings
        s.SyncEncryptEnabled = enabled
        s.Save()
        notifyStateChanged()
    }

    /// 首次开启加密同步：同步密码 + userId 派生 AES 密钥，Keychain 保护后落盘并打开开关。
    /// userId 缺席 / 密码为空 / 派生或保护失败返回 false（UI 据此回退开关）。
    /// 已有派生密钥时不重新派生（与 C# VM 一致：HasDerivedKey 直接开开关，不再要密码）。
    /// 对应 C# `AccountSettingsViewModel.EncryptSyncOn` 的开启分支。
    @discardableResult
    public func enableSyncEncryption(password: String) -> Bool {
        let s = Seam.settings
        guard let userId = s.AccountUserId, !userId.isEmpty, !password.isEmpty else { return false }
        if (s.SyncDerivedKey ?? "").isEmpty {
            guard let key = SyncEncryption.deriveKey(password: password, userId: userId),
                  let stored = SyncEncryption.protectKeyForLocal(key) else { return false }
            s.SyncDerivedKey = stored
        }
        s.SyncEncryptEnabled = true
        s.Save()
        notifyStateChanged()
        return true
    }

    private func clearLoginFields(_ s: Settings) {
        s.AccountToken = nil
        s.AccountUserId = nil
        s.AccountName = nil
        s.AccountLoginTime = nil
        s.EnableCloudSync = false
        s.SelectedCorpId = nil
        s.SelectedCorpName = nil
    }

    // MARK: - 用户详情

    /// 拉取并保存用户详情（userId/昵称/头像），处理作用域变更与孤儿数据晋升。
    /// 对应 C# `FetchAndSaveUserInfoAsync`。调用前 token 须已落入 settings（两个调用点均满足）。
    public func fetchUserInfo(token: String) async {
        let s = Seam.settings
        let r = await api.send("GET", "/api/auth/userinfo")
        guard r.ok, case .object(let data) = r.data else { return }

        var changed = false
        // 用户 ID（encrypt2 密文）：数据隔离作用域 + 加密同步密钥派生 salt
        let userIdEnc = data["userId"]?.stringValue ?? ""
        // 作用域变更含「登出后重新登录」（旧值为空）这一档：内存配置属于加载时的作用域，
        // 一旦翻转就必须重载，否则随后一次保存会把该账号本地与服务端的全部窗口清空
        let scopeChanged = !userIdEnc.isEmpty && userIdEnc != s.AccountUserId
        if scopeChanged {
            s.AccountUserId = userIdEnc
            changed = true
        }
        let nickName = data["nickName"]?.stringValue ?? ""
        if !nickName.isEmpty && nickName != s.AccountName {
            s.AccountName = nickName
            changed = true
        }
        // 头像（URL → 下载转 base64；base64 → 直接使用）
        let avatar = data["avatar"]?.stringValue ?? ""
        if !avatar.isEmpty {
            if avatar.lowercased().hasPrefix("http") {
                if let url = URL(string: avatar),
                   let (bytes, _) = try? await URLSession.shared.data(from: url), !bytes.isEmpty {
                    s.AccountAvatar = bytes.base64EncodedString()
                    changed = true
                }
            } else {
                s.AccountAvatar = avatar
                changed = true
            }
        }
        if changed { s.Save() }

        // 登录/切换账号后：把未归属（local）数据晋升到当前用户（无残留时空查询，幂等）
        if !userIdEnc.isEmpty {
            AppContainer.shared.resolve(DataPollingService.self)?.adoptPendingLocalData()
        }
        // 作用域变更：等晋升落库后再重载窗口数据（否则新作用域加载会缺刚晋升的数据，
        // 随后一次保存就会把它们当「已删除」打墓碑上报）
        if scopeChanged { reloadScope() }
        notifyStateChanged()
    }

    // MARK: - 作用域重载

    /// 作用域变更后在进程内切换窗口数据（登录/登出/登录态失效均走此路径，不要求重启）。
    /// 对应 C# `App.ReloadWindowConfigsForNewScope`：宿主闭包负责重载内存树并重绑 UI；
    /// 重载后内存已属新作用域，补一次云同步对账才是与服务端对齐的正确时机。
    private func reloadScope() {
        Seam.uiPost { [weak self] in
            Seam.reloadWindowConfigs?()
            guard let self else { return }
            let s = Seam.settings
            if s.EnableCloudSync, let t = s.AccountToken, !t.isEmpty {
                self.cloudSyncReconcile?(true)
            }
        }
    }

    private func markOffline(_ offline: Bool) {
        if Offline == offline { return }
        Offline = offline
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        Seam.uiPost {
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        }
    }
}