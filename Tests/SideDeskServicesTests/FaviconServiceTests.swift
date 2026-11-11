import XCTest
@testable import SideDeskServices
import SideDeskCore

/// FaviconService 验收：纯函数（键归一 / 图标解析 / 格式判定）+ 本地缓存采用与自愈（无网络）。
final class FaviconServiceTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "sidest-fav-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        FaviconService.resetCacheForTests()
    }

    override func tearDown() {
        FaviconService.resetCacheForTests()
        AppPaths.setOverride(nil)
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    // MARK: - normalizeKey

    func testNormalizeKey() {
        XCTAssertEqual(FaviconService.normalizeKey("https://Example.COM/Path?Q=1#f"), "https://example.com")
        XCTAssertEqual(FaviconService.normalizeKey("http://a.com:8080/x"), "http://a.com:8080")
        XCTAssertNil(FaviconService.normalizeKey("ftp://a.com"))
        XCTAssertNil(FaviconService.normalizeKey("not a url"))
        XCTAssertNil(FaviconService.normalizeKey(""))
    }

    // MARK: - isPathIcon

    func testIsPathIcon() {
        XCTAssertTrue(FaviconService.isPathIcon("/tmp/x.png"))
        XCTAssertTrue(FaviconService.isPathIcon("C:\\icons\\a.ico"))
        XCTAssertFalse(FaviconService.isPathIcon("🔗"))
        XCTAssertFalse(FaviconService.isPathIcon(""))
        XCTAssertFalse(FaviconService.isPathIcon(nil))
    }

    // MARK: - parseFaviconLink

    func testParseFaviconLinkPicksLargestSizes() {
        let html = """
        <html><head>
        <link rel="icon" href="/small.png" sizes="16x16">
        <link rel="icon" href="/big.png" sizes="192x192">
        <link rel="apple-touch-icon" href="/apple.png" sizes="180x180">
        </head></html>
        """
        XCTAssertEqual(FaviconService.parseFaviconLink(html, baseUrl: "https://a.com/page"),
                       "https://a.com/big.png")
    }

    func testParseFaviconLinkResolvesRelativeAndProtocolRelative() {
        let rel = "<link rel='icon' href='/fav.ico'>"
        XCTAssertEqual(FaviconService.parseFaviconLink(rel, baseUrl: "https://a.com/x/y"),
                       "https://a.com/fav.ico")
        let proto = #"<link rel="shortcut icon" href="//cdn.a.com/i.png">"#
        XCTAssertEqual(FaviconService.parseFaviconLink(proto, baseUrl: "https://a.com/"),
                       "https://cdn.a.com/i.png")
    }

    func testParseFaviconLinkIgnoresNonIconAndDataUri() {
        XCTAssertNil(FaviconService.parseFaviconLink("<link rel='stylesheet' href='/a.css'>", baseUrl: "https://a.com"))
        XCTAssertNil(FaviconService.parseFaviconLink("<link rel='icon' href='data:image/png;base64,AAA'>", baseUrl: "https://a.com"))
        XCTAssertNil(FaviconService.parseFaviconLink("<html>no icons</html>", baseUrl: "https://a.com"))
    }

    // MARK: - guessExt

    func testGuessExtByMagicBytes() {
        XCTAssertEqual(FaviconService.guessExt("x", [0x89, 0x50, 0x4E, 0x47]), ".png")
        XCTAssertEqual(FaviconService.guessExt("x", [0xFF, 0xD8, 0xFF]), ".jpg")
        XCTAssertEqual(FaviconService.guessExt("x", [0x47, 0x49, 0x46, 0x38]), ".gif")
        XCTAssertEqual(FaviconService.guessExt("x", [0x00, 0x00, 0x01, 0x00]), ".ico")
    }

    func testGuessExtRejectsHtmlAndAcceptsSvg() {
        let html = Array("<html>error</html>".utf8)
        XCTAssertNil(FaviconService.guessExt("https://a.com/favicon.ico", html))
        let svg = Array("<svg xmlns='x'></svg>".utf8)
        XCTAssertEqual(FaviconService.guessExt("https://a.com/i.svg", svg), ".svg")
        // 顶着 .svg 后缀但内容非 svg → 不按 svg 收（防反爬页误判），且以 '<' 开头 → nil
        XCTAssertNil(FaviconService.guessExt("https://a.com/i.svg", html))
    }

    func testGuessExtFallsBackToUrlSuffix() {
        XCTAssertEqual(FaviconService.guessExt("https://a.com/i.PNG?q=1", [0x01, 0x02, 0x03, 0x04, 0x05]), ".png")
        XCTAssertNil(FaviconService.guessExt("https://a.com/i.bin", [0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    // MARK: - 缓存采用 + 自愈（无网络：手工落盘索引与图标文件）

    private func writeIndex(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dict)
        try data.write(to: URL(fileURLWithPath: dir + "/favicon-cache.json"))
    }

    func testCachedAdoptedWhenDecodable() throws {
        let favDir = dir + "/favicons"
        try FileManager.default.createDirectory(atPath: favDir, withIntermediateDirectories: true)
        let pngPath = favDir + "/a_com.png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).write(to: URL(fileURLWithPath: pngPath))
        try writeIndex(["https://a.com": pngPath])
        FaviconService.resetCacheForTests()   // 强制从磁盘重载索引

        XCTAssertEqual(FaviconService.validCachedOrPurge("https://a.com/deep/path"), pngPath)
        XCTAssertEqual(FaviconService.cachedPath(for: "https://a.com"), pngPath)
    }

    func testBadCachedFileIsPurged() throws {
        let favDir = dir + "/favicons"
        try FileManager.default.createDirectory(atPath: favDir, withIntermediateDirectories: true)
        let badPath = favDir + "/a_com.ico"
        try Data(Array("<html>not an icon</html>".utf8)).write(to: URL(fileURLWithPath: badPath))
        try writeIndex(["https://a.com": badPath])
        FaviconService.resetCacheForTests()

        XCTAssertNil(FaviconService.validCachedOrPurge("https://a.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: badPath), "坏图标文件应被删除")
        XCTAssertNil(FaviconService.cachedPath(for: "https://a.com"), "索引条目应被移除")
    }
}
