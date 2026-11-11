import XCTest
@testable import SideDeskServices
import SideDeskCore

/// 后端客户端骨架与两个只读接口的验收：信封分支、Bearer/超时、回落口径、变量集拉取合并。
final class BackendApiClientTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-api-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        Settings.DirOverride = dir
        Seam.resetSettings()
        let s = Settings()
        s.AccountToken = "tok"
        Seam.settings = s
    }

    override func tearDown() {
        Seam.resetSettings()
        Settings.DirOverride = nil
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - 信封解包（纯函数，逐分支钉死）

    private func parse(_ status: Int, _ body: String) throws -> BackendApiClient.Parsed {
        try BackendApiClient.parseEnvelope(status: status, json: Data(body.utf8))
    }

    func testParseEnvelopeBranches() throws {
        // 非 2xx：认证类置标记，其余不改写；body 不解析
        let un = try parse(401, "not even json")
        XCTAssertFalse(un.ok)
        XCTAssertEqual(un.authFlag, true)
        XCTAssertNil(un.data)
        XCTAssertNil(try parse(500, "").authFlag, "非认证类 HTTP 错误不改写标记")

        // HTTP 200 包业务 401/403：认证失败，data 丢弃
        let biz401 = try parse(200, #"{"code":401,"msg":"no","data":[{"id":"1"}]}"#)
        XCTAssertFalse(biz401.ok)
        XCTAssertEqual(biz401.msg, "no")
        XCTAssertNil(biz401.data)
        XCTAssertEqual(biz401.authFlag, true)
        XCTAssertEqual(try parse(200, #"{"code":403}"#).authFlag, true)

        // 业务非 200 且非认证：必须丢掉 data，否则「报错但捎带数据」会被渲染成真实数据
        let biz500 = try parse(200, #"{"code":500,"msg":"bad","data":[{"id":"1"}]}"#)
        XCTAssertFalse(biz500.ok)
        XCTAssertNil(biz500.data, "业务非 200 的 data 必须丢弃（C# 重写时丢过一次，由回归测试钉住）")
        XCTAssertEqual(biz500.authFlag, false)

        // 缺 code 视为非 200
        XCTAssertFalse(try parse(200, "{}").ok)

        let ok = try parse(200, #"{"code":200,"data":{"a":1}}"#)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.authFlag, false)
        if case .object(let obj)? = ok.data { XCTAssertNotNil(obj["a"]) } else { XCTFail("data 应保留") }

        XCTAssertThrowsError(try parse(200, "not json"), "响应体非法 JSON 由调用方按传输失败处理")
    }

    // MARK: - 列表/对象通道

    func testSendListMapsArrayAndFallsBack() async {
        let rec = Recorder()
        rec.json = #"{"code":200,"data":[{"varKey":"a.sum","op":"AVG","sourceKeys":["x"],"pattern":"p*","corpId":"c1"}]}"#
        let api = BackendApiClient(logTag: "[Test]", timeout: 5, transport: rec.transport)

        let got: [VariableSetInfo]? = await api.sendList("GET", "/sets")
        XCTAssertEqual(got?.count, 1)
        let first = got?.first
        XCTAssertEqual(first?.VarKey, "a.sum")
        XCTAssertEqual(first?.Op, "AVG")
        XCTAssertEqual(first?.SourceKeys, ["x"])
        XCTAssertEqual(first?.Pattern, "p*")
        XCTAssertEqual(first?.CorpId, "c1")

        // data 不是数组 → 回落 nil
        rec.json = #"{"code":200,"data":{"varKey":"a"}}"#
        let wrongShape: [VariableSetInfo]? = await api.sendList("GET", "/sets")
        XCTAssertNil(wrongShape)

        // 数组形状对但字段畸形 → 映射失败记日志后回落，不抛
        rec.json = #"{"code":200,"data":["just a string"]}"#
        let badMapping: [VariableSetInfo]? = await api.sendList("GET", "/sets")
        XCTAssertNil(badMapping)

        // 响应非法 JSON → 传输失败回落
        rec.json = "not json"
        let boom: [VariableSetInfo]? = await api.sendList("GET", "/sets")
        XCTAssertNil(boom)
    }

    func testSendObjectRequiresObjectShape() async {
        let rec = Recorder()
        rec.json = #"{"code":200,"data":{"id":"t1","name":"研发团队","isAdmin":true}}"#
        let api = BackendApiClient(logTag: "[Test]", timeout: 5, transport: rec.transport)
        let team: Team? = await api.sendObject("POST", "/team/create",
                                               body: .object(["name": .string("研发团队")]))
        XCTAssertEqual(team?.Id, "t1")
        XCTAssertEqual(team?.Name, "研发团队")
        XCTAssertTrue(team?.IsAdmin ?? false)

        rec.json = #"{"code":200,"data":[1,2]}"#
        let notObject: Team? = await api.sendObject("GET", "/team/create")
        XCTAssertNil(notObject)
    }

    // MARK: - 请求构造与认证记账

    func testRequestCarriesBearerAndTimeout() async {
        let rec = Recorder()
        let api = BackendApiClient(logTag: "[Test]", timeout: 7, transport: rec.transport)
        _ = await api.send("GET", "/api/team/list")

        let req = rec.requests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req?.url?.absoluteString, Constants.URLs.serverBaseUrl + "/api/team/list")
        XCTAssertEqual(req?.timeoutInterval, 7, "超时按各服务原有配置，不在骨架里统一")
    }

    func testPostBodyIsJson() async {
        let rec = Recorder()
        let api = BackendApiClient(logTag: "[Test]", timeout: 5, transport: rec.transport)
        _ = await api.send("POST", "/team/join", body: .object(["code": .string("abc")]))

        let req = rec.requests.first
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(String(data: req?.httpBody ?? Data(), encoding: .utf8), #"{"code":"abc"}"#)
    }

    func testLastAuthFailedAccounting() async {
        let rec = Recorder()
        let api = BackendApiClient(logTag: "[Test]", timeout: 5, transport: rec.transport)

        rec.status = 401
        _ = await api.send("GET", "/x")
        XCTAssertTrue(api.LastAuthFailed)

        rec.status = 500
        _ = await api.send("GET", "/x")
        XCTAssertTrue(api.LastAuthFailed, "其他 HTTP 错误码不改写标记")

        rec.status = 200
        rec.json = #"{"code":200,"data":[]}"#
        _ = await api.send("GET", "/x")
        XCTAssertFalse(api.LastAuthFailed, "HTTP 成功且业务非认证失败 → 复位")
    }

    // MARK: - DataVariableService

    func testListSetsSkipsRequestWhenLoggedOut() async {
        Seam.settings.AccountToken = nil
        let rec = Recorder()
        rec.json = #"{"code":200,"data":[{"varKey":"a"}]}"#
        let svc = DataVariableService(transport: rec.transport)

        let got = await svc.listSetsAsync(corpId: nil)
        XCTAssertNil(got)
        XCTAssertEqual(rec.requests.count, 0, "未登录只走本地，不发请求")
    }

    func testListSetsEscapesCorpIdAndDropsBusinessFailure() async {
        let rec = Recorder()
        rec.json = #"{"code":200,"data":[{"varKey":"a","corpId":"a b&c"}]}"#
        let svc = DataVariableService(transport: rec.transport)

        let got = await svc.listSetsAsync(corpId: "a b&c")
        XCTAssertEqual(rec.requests.first?.url?.query, "corpId=a%20b%26c",
                       "查询值按 RFC 3986 非保留字符转义（对应 C# Uri.EscapeDataString）")
        XCTAssertEqual(got?.first?.CorpId, "a b&c")

        rec.json = #"{"code":500,"msg":"bad","data":[{"varKey":"a"}]}"#
        let bizFail = await svc.listSetsAsync(corpId: nil)
        XCTAssertNil(bizFail, "业务失败一律回落 nil")

        rec.json = #"{"code":200,"data":[]}"#
        let empty = await svc.listSetsAsync(corpId: nil)
        XCTAssertEqual(empty?.count, 0, "空列表是成功，不是失败")
    }

    // MARK: - TeamService

    func testTeamServiceDecodesTeamsAndExposesAuthFlag() async {
        let rec = Recorder()
        rec.json = #"{"code":200,"data":[{"id":"t1","name":"研发","members":[{"id":"m1","name":"小明","avatar":null}],"isAdmin":true}]}"#
        let svc = TeamService(transport: rec.transport)

        let teams = await svc.listTeamsAsync()
        XCTAssertEqual(teams?.count, 1)
        XCTAssertEqual(teams?.first?.Id, "t1")
        XCTAssertEqual(teams?.first?.Members.first?.Name, "小明")
        XCTAssertNil(teams?.first?.InviteCode, "后端缺字段时回落 nil，不影响其余字段")
        XCTAssertFalse(svc.LastAuthFailed)

        rec.status = 403
        let forbidden = await svc.listTeamsAsync()
        XCTAssertNil(forbidden)
        XCTAssertTrue(svc.LastAuthFailed, "认证失败标记供 UI 刷新登录状态")
    }

    // MARK: - 替身

    /// 假传输：按序返回预设响应，并记录发出的请求
    private final class Recorder {
        var json = "{\"code\":200,\"data\":[]}"
        var status = 200
        var error: Error?
        private(set) var requests: [URLRequest] = []

        var transport: BackendApiClient.Transport {
            { [weak self] req in
                guard let self else { throw StubError(message: "recorder released") }
                self.requests.append(req)
                if let error = self.error { throw error }
                let url = req.url ?? URL(string: "https://example.invalid")!
                let resp = HTTPURLResponse(url: url, statusCode: self.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)
                return (Data(self.json.utf8), resp)
            }
        }
    }
}

private struct StubError: Error { let message: String }
