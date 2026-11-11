import XCTest
import ServiceManagement
@testable import SideDeskServices
import SideDeskCore

/// 开机自启验收（对应 C# `AutoStartService.Apply/IsEnabled`）。
/// 真机走 `SMAppService.mainApp`，测试一律注入假实现——不能碰用户真实登录项。
final class AutoStartServiceTests: XCTestCase {

    private var calls: [String] = []
    private var status: AutoStartService.Status = .notRegistered
    private var registerError: Error?

    override func setUp() {
        super.setUp()
        calls = []
        status = .notRegistered
        registerError = nil
        AutoStartService.registerImpl = { [weak self] in
            guard let self else { return }
            self.calls.append("register")
            if let error = self.registerError { throw error }
        }
        AutoStartService.unregisterImpl = { [weak self] in
            guard let self else { return }
            self.calls.append("unregister")
        }
        AutoStartService.statusImpl = { [weak self] in self?.status ?? .notRegistered }
    }

    override func tearDown() {
        AutoStartService.registerImpl = { try SMAppService.mainApp.register() }
        AutoStartService.unregisterImpl = { try SMAppService.mainApp.unregister() }
        AutoStartService.statusImpl = {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notFound
            default: return .notRegistered
            }
        }
        super.tearDown()
    }

    func testApplyEnabledRegisters() {
        status = .notRegistered
        AutoStartService.apply(true)
        XCTAssertEqual(calls, ["register"], "启用即登记（每次启动同步，等价 C# 每次重写 Run 值）")

        status = .enabled
        calls = []
        AutoStartService.apply(true)
        XCTAssertEqual(calls, ["register"], "已登记也照登记——register 幂等，不去猜状态")
    }

    func testApplyDisabledRemovesOnlyWhenRegistered() {
        status = .notRegistered
        AutoStartService.apply(false)
        XCTAssertEqual(calls, [], "本来就没登记：不碰 unregister（它会抛，等于每次启动刷日志）")

        status = .notFound
        AutoStartService.apply(false)
        XCTAssertEqual(calls, [], "bundle 查不到同样不动")

        status = .enabled
        AutoStartService.apply(false)
        XCTAssertEqual(calls, ["unregister"])

        status = .requiresApproval
        calls = []
        AutoStartService.apply(false)
        XCTAssertEqual(calls, ["unregister"], "待批准状态也属于「已写过登录项」，禁用时要清掉")
    }

    func testFailureIsSwallowed() {
        // 无权限/被策略拦下：记日志即可，启动不能被登录项写不成挡住（也不许误走注销分支）
        registerError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"])
        XCTAssertNoThrow(AutoStartService.apply(true))
        XCTAssertEqual(calls, ["register"], "失败只试一次，不重试、不连带 unregister")

        // unregister 抛同样吞掉
        registerError = nil
        AutoStartService.unregisterImpl = { throw NSError(domain: "test", code: 2) }
        status = .enabled
        XCTAssertNoThrow(AutoStartService.apply(false))
    }

    func testIsEnabledFollowsStatus() {
        status = .enabled
        XCTAssertTrue(AutoStartService.isEnabled())
        status = .requiresApproval
        XCTAssertFalse(AutoStartService.isEnabled(), "待批准不等于已生效")
        status = .notRegistered
        XCTAssertFalse(AutoStartService.isEnabled())
    }
}
