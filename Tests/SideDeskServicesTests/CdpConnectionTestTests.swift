import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 假 CDP 客户端：只回应 `Target.getTargets`，记录命令与关闭动作。
private final class FakeCdpClient: CdpClientProtocol {
    var targetInfos: [JSONValue] = []
    var error: Error?
    private(set) var methods: [String] = []
    private(set) var didClose = false

    var isConnected: Bool { true }

    func sendCommand(_ method: String, _ params: [String: JSONValue]?,
                     _ sessionId: String?, timeout: TimeInterval) async throws -> JSONValue {
        methods.append(method)
        if let error { throw error }
        return .object(["targetInfos": .array(targetInfos)])
    }

    func close() { didClose = true }
}

private func page(_ id: String, url: String, title: String, type: String = "page") -> JSONValue {
    .object([
        "targetId": .string(id),
        "type": .string(type),
        "url": .string(url),
        "title": .string(title),
    ])
}

/// 设置页「测试连接」的取数与文案拼装（对应 C# `ModulesSeam.TestCdpConnectionAsync`）。
/// 期望值一律用 Lang 现算，避免绑定具体语言。
final class CdpConnectionTestTests: XCTestCase {

    private var originalFactory: ((Int) async -> CdpClientProtocol?)!
    private let port = 9333

    override func setUp() {
        super.setUp()
        originalFactory = CdpConnectionTest.connectFactory
    }

    override func tearDown() {
        CdpConnectionTest.connectFactory = originalFactory
        super.tearDown()
    }

    private func stub(_ client: FakeCdpClient?) {
        CdpConnectionTest.connectFactory = { _ in client }
    }

    func testNoEndpointUsesConnectFailedDetail() async {
        stub(nil)
        let text = await CdpConnectionTest.run(port: port)
        XCTAssertEqual(text, Lang.tf("settings.cdpConnectFailedDetail", port, port))
    }

    func testConnectedWithoutPages() async {
        let client = FakeCdpClient()
        client.targetInfos = [page("W1", url: "https://sw", title: "sw", type: "service_worker")]
        stub(client)
        let text = await CdpConnectionTest.run(port: port)
        XCTAssertEqual(text, Lang.tf("settings.cdpConnectedNoTabs", port))
        XCTAssertTrue(client.didClose, "测试用的连接必须用完即关")
    }

    func testListsPagesAndFallsBackToUntitled() async {
        let client = FakeCdpClient()
        client.targetInfos = [
            page("T1", url: "https://a.example", title: "Page A"),
            page("W1", url: "https://sw", title: "sw", type: "service_worker"),
            page("T2", url: "https://b.example", title: ""),
        ]
        stub(client)

        let lines = await CdpConnectionTest.run(port: port).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, Lang.tf("settings.cdpConnectedTabSummary", port, 2))
        XCTAssertEqual(lines[1], String(repeating: "─", count: 40))
        XCTAssertEqual(lines[2], "1. Page A")
        XCTAssertEqual(lines[3], "   https://a.example")
        XCTAssertEqual(lines[4], "2. " + Lang.t("settings.untitled"))
        XCTAssertEqual(lines[5], "   https://b.example")
        XCTAssertEqual(lines.count, 6, "非 page 目标不该进列表")
        XCTAssertEqual(client.methods, ["Target.getTargets"])
        XCTAssertTrue(client.didClose)
    }

    func testCommandFailureUsesConnectFailedTemplate() async {
        let client = FakeCdpClient()
        let error = CdpError.failed("boom")
        client.error = error
        stub(client)
        let text = await CdpConnectionTest.run(port: port)
        XCTAssertEqual(text, Lang.tf("settings.cdpConnectFailed", error.localizedDescription, port))
        XCTAssertTrue(client.didClose)
    }
}
