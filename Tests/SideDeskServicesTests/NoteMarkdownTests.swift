import XCTest
@testable import SideDeskServices

/// 便签 Markdown 编解码验收：块/行内解析、回写口径（与 C# FlowDocumentMarkdownWriter 子集一致）、往返稳定。
final class NoteMarkdownTests: XCTestCase {

    /// 规范化样本：write(parse(x)) 应逐字等于 x（存储口径的定点）。
    private let canonical = [
        "纯文本一行",
        "**粗体** 与 *斜体* 与 ~~删除~~ 与 `代码`",
        "# 一级标题",
        "### 三级标题",
        "> 引用一行",
        "---",
        "- 甲\n- 乙",
        "1. 甲\n2. 乙",
        "- [ ] 待办\n- [x] 已办",
        "```swift\nlet a = 1\n```",
        "[链接](https://example.com)",
        "![](/tmp/pic.png)",
        "<details>\n<summary>摘要</summary>\n\n正文一段\n\n</details>",
        "<details open>\n<summary>摘要</summary>\n\n- [ ] 内嵌待办\n\n</details>",
    ]

    func testCanonicalRoundTrip() {
        for sample in canonical {
            let written = NoteMarkdown.write(NoteMarkdown.parse(sample))
            XCTAssertEqual(written, sample, "样本应逐字往返: \(sample)")
        }
    }

    func testWriteParseIdempotent() {
        let messy = "第一行\n第二行\n\n\n- [x] 旧待办\n\n☐ 手打待办\n\n**未闭合粗体\n"
        let once = NoteMarkdown.write(NoteMarkdown.parse(messy))
        let twice = NoteMarkdown.write(NoteMarkdown.parse(once))
        XCTAssertEqual(once, twice, "往返一次后应稳定")
    }

    func testTodoNormalization() {
        let blocks = NoteMarkdown.parse("☐ 手打待办\n☑ 手打已办")
        guard case .list(_, let items) = blocks.first else { return XCTFail("应解析为列表") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].checked, false)
        XCTAssertEqual(items[1].checked, true)
        let written = NoteMarkdown.write(blocks)
        XCTAssertEqual(written, "- [ ] 手打待办\n- [x] 手打已办")
    }

    func testHeadingSuppressesEmphasis() {
        // 标题段落级已带粗体：回写不应叠 **（对应 C# suppressEmphasis）
        let blocks: [NoteBlock] = [.heading(level: 2, [.text("题", .bold)])]
        XCTAssertEqual(NoteMarkdown.write(blocks), "## 题")
    }

    func testInlineNestingAndUnclosed() {
        // 嵌套强调（** 里套 *）在扁平样式模型下会归一（与 C#「子集外有损」同取舍），断言归一后稳定且不丢结构
        let source = "a**b*c*d**e`f*g`h~~i~~j[k](u)![](p)**未闭合"
        let once = NoteMarkdown.writeInlines(NoteMarkdown.parseInlines(source))
        let twice = NoteMarkdown.writeInlines(NoteMarkdown.parseInlines(once))
        XCTAssertEqual(once, twice, "归一一次后应稳定")
        XCTAssertTrue(once.contains("![](p)"))
        XCTAssertTrue(once.contains("[k](u)"))
        XCTAssertTrue(once.contains("`f*g`"))
        XCTAssertTrue(once.contains("~~i~~"))
        XCTAssertTrue(once.hasSuffix("**未闭合"), "未闭合标记按字面保留")
    }

    func testUnknownStructureKeptVerbatim() {
        // 表格未建模：按原样段落往返，不丢内容
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let written = NoteMarkdown.write(NoteMarkdown.parse(table))
        XCTAssertEqual(written, table)
    }

    func testDetailsBodyBlocks() {
        let blocks = NoteMarkdown.parse("<details>\n<summary>摘</summary>\n\n## 内标题\n\n- 项\n\n</details>")
        guard case .details(let open, let summary, let body) = blocks.first else { return XCTFail("应解析为折叠块") }
        XCTAssertFalse(open)
        XCTAssertEqual(NoteMarkdown.writeInlines(summary), "摘")
        XCTAssertEqual(body.count, 2)
        guard case .heading(let level, _) = body[0] else { return XCTFail("体内应保留标题块") }
        XCTAssertEqual(level, 2)
    }
}
