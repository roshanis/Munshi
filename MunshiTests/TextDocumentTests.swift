import Foundation
import Testing
@testable import Munshi

struct TextDocumentTests {
    @Test func joinsWrappedLinesIntoParagraphs() {
        let text = "It was the best of times,\nit was the worst of times.\n\nSecond paragraph."
        let result = TextDocument.html(fromText: text, title: "Tale")
        #expect(result.html.contains("<p>It was the best of times, it was the worst of times.</p>"))
        #expect(result.html.contains("<p>Second paragraph.</p>"))
        #expect(result.toc.map(\.title) == ["Tale"])
    }

    @Test func turnsMarkdownHeadingsIntoContents() {
        let text = "# Part One\n\nIntro.\n\n## Chapter 1\r\nBody.\n\n#hashtag is not a heading"
        let result = TextDocument.html(fromText: text, title: "Notes")
        #expect(result.toc.map(\.title) == ["Part One", "Chapter 1"])
        #expect(result.toc.map(\.level) == [0, 1])
        #expect(result.toc[1].href == "index.html#h1")
        #expect(result.html.contains("<h2 id=\"h1\">Chapter 1</h2>"))
        #expect(result.html.contains("<p>#hashtag is not a heading</p>"))
    }

    @Test func escapesMarkup() {
        let result = TextDocument.html(fromText: "a < b & \"c\"", title: "x")
        #expect(result.html.contains("<p>a &lt; b &amp; &quot;c&quot;</p>"))
    }

    @Test func findsHTMLTitle() {
        #expect(TextDocument.htmlTitle(in: "<html><head><TITLE lang=en> Hello </TITLE></head></html>") == "Hello")
        #expect(TextDocument.htmlTitle(in: "<p>No title</p>") == nil)
    }

    @Test func parsesSavedLocations() {
        let saved = WebReaderModel.parseLocation("2:0.5", chapterCount: 5)
        #expect(saved.chapter == 2)
        #expect(saved.fraction == 0.5)
        #expect(WebReaderModel.parseLocation("9:0.5", chapterCount: 5).chapter == 0)
        #expect(WebReaderModel.parseLocation(nil, chapterCount: 5).chapter == 0)
    }
}
