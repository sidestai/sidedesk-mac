import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 后端 WebSocket 客户端验收：地址派生、退避公式、Start 幂等/身份变更、
/// 心跳 ping、消息分发、断线重连、主动停止、重连上限放弃。
/// 全部经假连接驱动，不触网。
final class BackendWebSocketTests: XCTestCase {

    private var originalTimerFactory: ((TimeInterval, @escaping () -> Void) -> ServiceTimer)!

    override func setUp() {
        super.setUp()
        originalTimerFactory = Seam.timerFactory
        Seam.timerFactory = { _, _ in NoopTimer() }
    }

    override func tearDown() {
        Seam.timerFactory = originalTimerFactory
        super.tearDown()
    }

    private final class NoopTimer: ServiceTimer {
        func start() {}
        func stop() {}
    }

    private struct TestError: Error {}

    /// 假连接：ping 即握手成功；receive 先吐脚本消息，吐完挂起模拟长连接（cancel 唤醒）。
    private final class FakeSocket: BackendSocketConnection {
        let url: URL
        var resumed = false
        var cancelled = false
        var pingError: Error?
        var receiveError: Error?
        var messages: [String] = []
        var sent: [String] = []
        var onPing: (() -> Void)?
        var onSend: ((String) -> Void)?
        private var index = 0
        private var pendingReceive: CheckedContinuation<String?, Never>?

        init(url: URL) { self.url = url }

        func resume() { resumed = true }
        func ping() async throws {
            if let pingError { throw pingError }
            onPing?()
        }
        func send(text: String) async throws {
            sent.append(text)
            onSend?(text)
        }
        func receive() async throws -> String? {
            if let receiveError { throw receiveError }
            if index < messages.count {
                defer { index += 1 }
                return messages[index]
            }
            return await withCheckedContinuation { pendingReceive = $0 }
        }
        func cancel() {
            cancelled = true
            pendingReceive?.resume(returning: nil)
            pendingReceive = nil
        }
    }

    /// 起服务并挂假连接工厂。expectConnect 在每次 Start 前预创建握手期望
    /// （工厂按连接序号取用，避免「期望还没建好连接已成功」的竞态）。
    private func makeService() -> (BackendWebSocketService, () -> [FakeSocket], () -> XCTestExpectation) {
        let svc = BackendWebSocketService()
        var sockets: [FakeSocket] = []
        var exps: [XCTestExpectation] = []
        svc.connectFactory = { url in
            let s = FakeSocket(url: url)
            let idx = sockets.count
            s.onPing = { exps[idx].fulfill() }
            sockets.append(s)
            return s
        }
        let expectConnect = { () -> XCTestExpectation in
            let exp = self.expectation(description: "connect #\(exps.count + 1)")
            exps.append(exp)
            return exp
        }
        return (svc, { sockets }, expectConnect)
    }

    private func queryItems(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    // MARK: - 纯函数

    func testWsBaseUrlDerivation() {
        let f = BackendWebSocketService.wsBaseUrl(from:)
        XCTAssertEqual(f("https://api.sidedesk.bigjing.com/console"), "wss://api.sidedesk.bigjing.com/ws")
        XCTAssertEqual(f("https://example.com:8443/console"), "wss://example.com:8443/ws")
        XCTAssertEqual(f("http://example.com"), "ws://example.com/ws")
        XCTAssertEqual(f("http://localhost:8080/console"), "ws://127.0.0.1:19190", "loopback 回退直连本机后端")
        XCTAssertEqual(f("http://127.0.0.1:19190"), "ws://127.0.0.1:19190")
    }

    func testReconnectDelayBackoff() {
        let f = BackendWebSocketService.reconnectDelay(attempt:)
        XCTAssertEqual(f(1), 3)
        XCTAssertEqual(f(2), 6)
        XCTAssertEqual(f(3), 12)
        XCTAssertEqual(f(4), 24)
        XCTAssertEqual(f(5), 48)
        XCTAssertEqual(f(6), 60, "3×2^5=96 封顶 60")
        XCTAssertEqual(f(10), 60)
    }

    // MARK: - 连接 lifecycle

    func testStartConnectsAndDeliversMessages() async {
        let svc = BackendWebSocketService()
        let socket = FakeSocket(url: URL(string: "ws://fake")!)
        socket.messages = [#"{"event":"structure_changed"}"#]
        var capturedUrl: URL?
        svc.connectFactory = { url in
            capturedUrl = url
            return socket
        }
        let connected = expectation(description: "connected")
        socket.onPing = { connected.fulfill() }
        let received = expectation(description: "message")
        var texts: [String] = []
        svc.MessageReceived = { texts.append($0); received.fulfill() }

        svc.Start("tok")
        await fulfillment(of: [connected, received], timeout: 2)
        XCTAssertTrue(svc.IsConnected)
        XCTAssertTrue(svc.IsRunning)
        XCTAssertEqual(texts, [#"{"event":"structure_changed"}"#])
        XCTAssertEqual(queryItems(capturedUrl ?? socket.url)["token"], "tok")
        XCTAssertEqual(queryItems(capturedUrl ?? socket.url)["deviceId"], DeviceIdService.deviceId)

        svc.Stop()
        XCTAssertFalse(svc.IsRunning)
        XCTAssertFalse(svc.IsConnected)
        XCTAssertTrue(socket.cancelled)
    }

    func testStartIdempotentAndIdentityChange() async {
        let (svc, sockets, expectConnect) = makeService()

        let first = expectConnect()
        svc.Start("a")
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(sockets().count, 1)

        svc.Start("a")   // 身份未变 → 跳过
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sockets().count, 1, "重复 Start 不新建连接")

        let second = expectConnect()
        svc.Start("b")   // 身份变更 → 断旧连新
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(sockets().count, 2)
        XCTAssertTrue(sockets()[0].cancelled)
        XCTAssertEqual(queryItems(sockets()[1].url)["token"], "b")

        let third = expectConnect()
        svc.Start("")    // 空 token 规范化为访客
        await fulfillment(of: [third], timeout: 2)
        XCTAssertEqual(sockets().count, 3)
        let q = queryItems(sockets()[2].url)
        XCTAssertNil(q["token"], "访客连接不带 token")
        XCTAssertEqual(q["deviceId"], DeviceIdService.deviceId)
        svc.Stop()
    }

    func testHeartbeatSendsPing() async {
        var captured: (TimeInterval, () -> Void)?
        Seam.timerFactory = { interval, action in
            captured = (interval, action)
            return NoopTimer()
        }
        let socket = FakeSocket(url: URL(string: "ws://fake")!)
        let svc = BackendWebSocketService()
        svc.connectFactory = { _ in socket }
        let connected = expectation(description: "connected")
        socket.onPing = { connected.fulfill() }
        svc.Start("tok")
        await fulfillment(of: [connected], timeout: 2)
        // 握手期望先于 startHeartbeat 完成，轮询等计时器挂好
        let deadline = Date().addingTimeInterval(2)
        while captured == nil && Date() < deadline { await Task.yield() }

        XCTAssertEqual(captured?.0, 30, "心跳间隔 30 秒")
        let pinged = expectation(description: "ping sent")
        socket.onSend = { text in
            if text == #"{"event":"ping"}"# { pinged.fulfill() }
        }
        captured?.1()
        await fulfillment(of: [pinged], timeout: 2)
        XCTAssertTrue(socket.sent.contains(#"{"event":"ping"}"#))
        svc.Stop()
    }

    func testReconnectsAfterDisconnect() async {
        let svc = BackendWebSocketService()
        var sockets: [FakeSocket] = []
        let reconnected = expectation(description: "reconnected")
        svc.connectFactory = { url in
            let s = FakeSocket(url: url)
            if sockets.isEmpty {
                s.receiveError = TestError()
            } else {
                s.onPing = { reconnected.fulfill() }
            }
            sockets.append(s)
            return s
        }
        var delays: [TimeInterval] = []
        svc.delayProvider = { delays.append($0) }
        var disconnectedCount = 0
        svc.Disconnected = { disconnectedCount += 1 }

        svc.Start("tok")
        await fulfillment(of: [reconnected], timeout: 2)
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(delays, [3], "首次重连退避 3 秒")
        XCTAssertEqual(disconnectedCount, 1)
        XCTAssertTrue(svc.IsConnected)
        svc.Stop()
    }

    func testStopDuringReconnectDelayPreventsRetry() async {
        let svc = BackendWebSocketService()
        var count = 0
        svc.connectFactory = { url in
            count += 1
            let s = FakeSocket(url: url)
            s.receiveError = TestError()
            return s
        }
        let delayStarted = expectation(description: "delay")
        var gate: CheckedContinuation<Void, Never>?
        svc.delayProvider = { _ in
            await withCheckedContinuation { c in
                gate = c
                delayStarted.fulfill()
            }
        }
        svc.Start("tok")
        await fulfillment(of: [delayStarted], timeout: 2)
        svc.Stop()
        gate?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(count, 1, "主动停止后不再重连")
        XCTAssertFalse(svc.IsRunning)
    }

    func testGivesUpAfterMaxAttempts() async {
        let svc = BackendWebSocketService()
        var count = 0
        svc.connectFactory = { url in
            count += 1
            let s = FakeSocket(url: url)
            s.pingError = TestError()
            return s
        }
        var delays: [TimeInterval] = []
        svc.delayProvider = { delays.append($0) }
        svc.Start("tok")
        let deadline = Date().addingTimeInterval(3)
        while svc.IsRunning && Date() < deadline { await Task.yield() }
        XCTAssertFalse(svc.IsRunning, "超过最大重连次数后放弃")
        XCTAssertEqual(delays.count, 10, "10 次退避后第 11 次失败放弃")
        XCTAssertEqual(count, 11)
        XCTAssertEqual(delays, [3, 6, 12, 24, 48, 60, 60, 60, 60, 60])
    }
}