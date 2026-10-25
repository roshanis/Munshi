import Foundation
import Testing
@testable import Munshi

private final class BundleToken {}

private func sampleArchive() throws -> ZipArchive {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: "sample", withExtension: "epub"))
    return try ZipArchive(url: url)
}

struct ZipArchiveTests {
    @Test func listsEntries() throws {
        let archive = try sampleArchive()
        #expect(archive.entries.count == 9)
        #expect(archive.entry(named: "mimetype")?.method == 0)
        #expect(archive.entry(named: "OEBPS/Text/chapter 2.xhtml") != nil)
    }

    @Test func readsStoredAndDeflatedEntries() throws {
        let archive = try sampleArchive()
        let mimetype = try archive.contents(of: "mimetype")
        #expect(String(decoding: mimetype, as: UTF8.self) == "application/epub+zip")

        let chapter = String(decoding: try archive.contents(of: "OEBPS/Text/chapter1.xhtml"), as: UTF8.self)
        #expect(chapter.contains("bright cold day in April"))
        #expect(chapter.hasSuffix("</html>"))
    }

    @Test func extractsFiles() throws {
        let archive = try sampleArchive()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }

        try archive.extractAll(to: folder)
        let cover = folder.appendingPathComponent("OEBPS/Images/cover.png")
        #expect(FileManager.default.fileExists(atPath: cover.path))
    }

    @Test func rejectsNonZipData() {
        #expect(throws: ZipArchive.ZipError.notAZip) {
            try ZipArchive(data: Data("not a zip file at all, just some text".utf8))
        }
    }
}

struct EPUBParserTests {
    @Test func readsMetadataAndSpine() throws {
        let result = try EPUBParser.parse(try sampleArchive())
        let publication = result.publication
        #expect(publication.title == "The Sample Book")
        #expect(publication.author == "Ada Writer")
        // Non-linear items are left out of the reading order, and hrefs are percent-decoded.
        #expect(publication.spine == ["OEBPS/Text/chapter1.xhtml", "OEBPS/Text/chapter 2.xhtml"])
        #expect(publication.coverPath == "OEBPS/Images/cover.png")
        #expect(result.coverData != nil)
    }

    @Test func prefersNavDocumentForContents() throws {
        let toc = try EPUBParser.parse(try sampleArchive()).publication.toc
        #expect(toc.map(\.title) == ["Chapter One", "Part Two", "Chapter Two"])
        #expect(toc.map(\.level) == [0, 1, 0])
        #expect(toc[1].path == "OEBPS/Text/chapter1.xhtml")
        #expect(toc[1].fragment == "part2")
        #expect(toc[2].href == "OEBPS/Text/chapter 2.xhtml")
    }

    @Test func parsesNCX() throws {
        let data = try sampleArchive().contents(of: "OEBPS/toc.ncx")
        let toc = EPUBParser.parseNCX(data, documentPath: "OEBPS/toc.ncx")
        #expect(toc.map(\.title) == ["NCX One", "NCX One A", "NCX Two"])
        #expect(toc.map(\.level) == [0, 1, 0])
        #expect(toc[1].href == "OEBPS/Text/chapter1.xhtml#part2")
    }

    @Test func spineIndexIgnoresFragments() throws {
        let publication = try EPUBParser.parse(try sampleArchive()).publication
        #expect(publication.spineIndex(for: "OEBPS/Text/chapter1.xhtml#part2") == 0)
        #expect(publication.spineIndex(for: "OEBPS/Text/chapter 2.xhtml") == 1)
        #expect(publication.spineIndex(for: "OEBPS/Text/notes.xhtml") == nil)
    }
}

struct ContentPathTests {
    @Test(arguments: [
        ("chapter.xhtml", "OEBPS", "OEBPS/chapter.xhtml"),
        ("../Text/ch%201.xhtml#note", "OEBPS/Styles", "OEBPS/Text/ch 1.xhtml#note"),
        ("./a/./b.html", "", "a/b.html"),
        ("/root.html", "OEBPS", "root.html"),
    ])
    func resolves(href: String, base: String, expected: String) {
        #expect(ContentPath.resolve(href, relativeTo: base) == expected)
    }

    @Test func directory() {
        #expect(ContentPath.directory(of: "OEBPS/content.opf") == "OEBPS")
        #expect(ContentPath.directory(of: "content.opf") == "")
    }
}
