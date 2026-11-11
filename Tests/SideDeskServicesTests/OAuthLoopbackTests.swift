import XCTest
@testable import SideDeskServices
import SideDeskCore

/// OAuth 回环监听验收：真实 loopback HTTP 往返（NWListener 管道）、state 防 CSRF、
/// 非回调路径 404 后继续等、超时收口、finish 幂等。
final class OAuthLoopbackTests: XCTestCase {

    private func get(_ port: UInt16, _ pathAndQuery: String) async throws -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)" + pathAndQuery)!
        let (_, resp) = try await URLSession.shared.data(from: url)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testCallbackSuccessReturnsCode() async throws {
        let server = LoopbackCallbackServer(expectedState: "st-123")
        let started = await server.start()
        let port = try XCTUnwrap(started)
        async let code = server.waitForCallback(timeout: 5)
        let status = try await get(port, "/callback?code=abc&state=st-123")
        XCTAssertEqual(status, 200)
        let got = await code
        XCTAssertEqual(got, "abc")
        server.stop()
    }

    func testStateMismatchRejects() async throws {
        let server = LoopbackCallbackServer(expectedState: "st-123")
        let started = await server.start()
        let port = try XCTUnwrap(started)
        async let code = server.waitForCallback(timeout: 5)
        let status = try await get(port, "/callback?code=abc&state=wrong")
        XCTAssertEqual(status, 400)
        let got = await code
        XCTAssertNil(got, "state 不匹配必须拒绝（防 CSRF）")
        server.stop()
    }

    func testMissingCodeRejects() async throws {
        let server = LoopbackCallbackServer(expectedState: "st")
        let started = await server.start()
        let port = try XCTUnwrap(started)
        async let code = server.waitForCallback(timeout: 5)
        _ = try await get(port, "/callback?state=st")
        let got = await code
        XCTAssertNil(got)
        server.stop()
    }

    func testNonCallbackPathKeepsWaiting() async throws {
        let server = LoopbackCallbackServer(expectedState: "st")
        let started = await server.start()
        let port = try XCTUnwrap(started)
        async let code = server.waitForCallback(timeout: 5)
        let notFound = try await get(port, "/favicon.ico")
        XCTAssertEqual(notFound, 404)
        let ok = try await get(port, "/callback?code=xyz&state=st")
        XCTAssertEqual(ok, 200)
        let got = await code
        XCTAssertEqual(got, "xyz", "非回调路径不应终止等待")
        server.stop()
    }

    func testTimeoutReturnsNil() async throws {
        let server = LoopbackCallbackServer(expectedState: "st")
        let started = await server.start()
        _ = try XCTUnwrap(started)
        let start = Date()
        let got = await server.waitForCallback(timeout: 0.3)
        XCTAssertNil(got)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "超时应及时收口")
        server.stop()   // 幂等：超时已 finish，再 stop 不重复 resume
    }

    func testStopUnblocksWaiter() async throws {
        let server = LoopbackCallbackServer(expectedState: "st")
        let started = await server.start()
        _ = try XCTUnwrap(started)
        async let code = server.waitForCallback(timeout: 10)
        try await Task.sleep(nanoseconds: 100_000_000)
        server.stop()
        let got = await code
        XCTAssertNil(got, "取消/退出须立即解除等待")
    }
}