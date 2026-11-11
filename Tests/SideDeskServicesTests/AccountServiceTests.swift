import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 账号服务验收：登录核心持久化（幂等/云同步默认开关）、登出清场、Token 校验三分支
/// （有效 / 明确失效 / 传输失败离线）、云同步开关的 opt-out 标记。
final class AccountServiceTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-account-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        Settings.DirOverride = dir
        Seam.resetSettings()
        Seam.settings = Settings()
        Seam.uiPost = { $0() }
        Seam.reloadWindowConfigs = nil
    }

    override func tearDown() {
        Seam.resetSettings()
        Seam.uiPost = { _ in }
        Seam.reloadWindowConfigs = nil
        Settings.DirOverride = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    /// 按响应体造一个假 transport 的账号服务
    private func service(json: String? = nil, failTransport: Bool = false) -> AccountService {
        let api = BackendApiClient(logTag: "[Test]", timeout: 5) { _ in
            if failTransport { throw NSError(domain: "test", code: 1) }
            let data = Data((json ?? "{}").utf8)
            return (data, HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil))
        }
        return AccountService(api: api)
    }

    // MARK: - 登录核心持久化

    func testApplyLoginSuccessCoreDefaultsAndIdempotent() {
        let svc = service()
        XCTAssertTrue(svc.applyLoginSuccessCore(token: "tok"))
        let s = Seam.settings
        XCTAssertEqual(s.AccountToken, "tok")
        XCTAssertTrue(s.EnableCloudSync, "登录后默认开启云同步")
        XCTAssertTrue(s.HasLoggedInBefore)
        XCTAssertNotNil(s.AccountLoginTime)
        XCTAssertTrue(svc.Verified)
        XCTAssertFalse(svc.Offline)
        XCTAssertTrue(svc.readState().IsLoggedIn)
        XCTAssertFalse(svc.applyLoginSuccessCore(token: "tok"), "同 token 幂等，不重复处理")
        XCTAssertFalse(svc.applyLoginSuccessCore(token: ""))
    }

    func testApplyLoginSuccessRespectsUserOptOut() {
        Seam.settings.CloudSyncUserOptOut = true
        let svc = service()
        XCTAssertTrue(svc.applyLoginSuccessCore(token: "tok"))
        XCTAssertFalse(Seam.settings.EnableCloudSync, "用户主动关过云同步则登录不再自动开启")
    }

    func testLogoutClearsLoginFields() {
        let s = Seam.settings
        s.AccountToken = "tok"; s.AccountUserId = "u1"; s.AccountName = "N"
        s.AccountLoginTime = Date(); s.EnableCloudSync = true; s.SelectedCorpId = "c1"
        var stopped = false
        var wsToken: String??
        let svc = service()
        svc.cloudSyncStop = { stopped = true }
        svc.webSocketStart = { wsToken = .some($0) }
        svc.logout()
        XCTAssertNil(s.AccountToken)
        XCTAssertNil(s.AccountUserId)
        XCTAssertNil(s.AccountName)
        XCTAssertNil(s.AccountLoginTime)
        XCTAssertNil(s.SelectedCorpId)
        XCTAssertFalse(s.EnableCloudSync)
        XCTAssertTrue(stopped)
        XCTAssertEqual(wsToken, .some(nil), "登出后降级访客连接")
        XCTAssertFalse(svc.readState().IsLoggedIn)
    }

    // MARK: - Token 校验三分支

    func testValidateTokenValidRestoresLoginAndFetchesProfile() async {
        Seam.settings.AccountToken = "tok"
        var wsToken: String??
        var reloaded = false
        Seam.reloadWindowConfigs = { reloaded = true }
        let svc = service(json: #"{"code":200,"data":{"userId":"u1","nickName":"昵称"}}"#)
        svc.webSocketStart = { wsToken = .some($0) }
        await svc.validateToken()
        XCTAssertTrue(svc.Verified)
        XCTAssertFalse(svc.Offline)
        XCTAssertTrue(Seam.settings.HasLoggedInBefore)
        XCTAssertTrue(Seam.settings.EnableCloudSync)
        XCTAssertEqual(Seam.settings.AccountUserId, "u1")
        XCTAssertEqual(Seam.settings.AccountName, "昵称")
        XCTAssertEqual(wsToken, .some("tok"))
        XCTAssertTrue(reloaded, "作用域 空→u1 必须重载窗口数据")
    }

    func testValidateTokenExpiredClearsLoginState() async {
        let s = Seam.settings
        s.AccountToken = "tok"; s.AccountUserId = "u1"; s.EnableCloudSync = true
        var stopped = false
        var reloaded = false
        Seam.reloadWindowConfigs = { reloaded = true }
        let svc = service(json: #"{"code":401,"msg":"expired"}"#)
        svc.cloudSyncStop = { stopped = true }
        await svc.validateToken()
        XCTAssertNil(s.AccountToken)
        XCTAssertNil(s.AccountUserId)
        XCTAssertFalse(s.EnableCloudSync)
        XCTAssertNotNil(svc.TokenExpiredMessage)
        XCTAssertTrue(stopped)
        XCTAssertTrue(reloaded, "已绑定账号的作用域回退须重载")
        XCTAssertFalse(svc.Offline, "401 是服务器明确应答，不算离线")
    }

    func testValidateTokenTransportFailureMarksOfflineKeepsToken() async {
        Seam.settings.AccountToken = "tok"
        let svc = service(failTransport: true)
        await svc.validateToken()
        XCTAssertTrue(svc.Offline)
        XCTAssertFalse(svc.Verified)
        XCTAssertEqual(Seam.settings.AccountToken, "tok", "离线不清 Token，恢复后重新验证")
        XCTAssertFalse(svc.readState().IsLoggedIn)
    }

    func testValidateTokenOtherBizCodeMarksOffline() async {
        Seam.settings.AccountToken = "tok"
        let svc = service(json: #"{"code":500,"msg":"boom"}"#)
        await svc.validateToken()
        XCTAssertTrue(svc.Offline)
        XCTAssertEqual(Seam.settings.AccountToken, "tok")
    }

    func testValidateWithoutTokenStartsGuestWebSocket() async {
        var wsToken: String??
        let svc = service()
        svc.webSocketStart = { wsToken = .some($0) }
        await svc.validateToken()
        XCTAssertEqual(wsToken, .some(nil))
    }

    // MARK: - 云同步开关

    func testSetCloudSyncTracksOptOut() {
        let svc = service()
        var started = false, stopped = false
        svc.cloudSyncStart = { started = true }
        svc.cloudSyncStop = { stopped = true }
        svc.setCloudSync(false)
        XCTAssertFalse(Seam.settings.EnableCloudSync)
        XCTAssertTrue(Seam.settings.CloudSyncUserOptOut, "关闭=主动退出")
        XCTAssertTrue(stopped)
        svc.setCloudSync(true)
        XCTAssertTrue(Seam.settings.EnableCloudSync)
        XCTAssertFalse(Seam.settings.CloudSyncUserOptOut, "开启=取消退出")
        XCTAssertTrue(started)
    }
}