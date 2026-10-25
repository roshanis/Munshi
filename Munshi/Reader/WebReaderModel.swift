import Foundation
import Observation

/// Reading state for books rendered as HTML (EPUB, text, HTML).
@MainActor
@Observable
final class WebReaderModel {
    /// Asks the web view to show a chapter. A new `token` forces a reload even for the same chapter.
    struct LoadRequest: Equatable {
        var chapter: Int
        var fraction: Double
        var fragment: String?
        var token = UUID()
    }

    let book: Book
    let publication: Publication
    let contentURL: URL

    private(set) var request: LoadRequest
    private(set) var chapter: Int
    private(set) var chapterFraction: Double

    /// The web view showing the current chapter, used to read it aloud.
    @ObservationIgnored weak var page: ChapterWebView.Coordinator?
    /// The last chapter change made by reading aloud (so it isn't mistaken for the reader jumping).
    @ObservationIgnored var speechNavigationToken: UUID?

    init(book: Book, publication: Publication) {
        self.book = book
        self.publication = publication
        self.contentURL = BookStorage.contentFolder(for: book.id)

        let saved = Self.parseLocation(book.location, chapterCount: publication.spine.count)
        chapter = saved.chapter
        chapterFraction = saved.fraction
        request = LoadRequest(chapter: saved.chapter, fraction: saved.fraction)
    }

    var chapterCount: Int { publication.spine.count }
    var canGoBack: Bool { chapter > 0 }
    var canGoForward: Bool { chapter < chapterCount - 1 }

    var overallProgress: Double {
        guard chapterCount > 0 else { return 0 }
        return min(1, (Double(chapter) + chapterFraction) / Double(chapterCount))
    }

    /// The table-of-contents entry for the current chapter, if any.
    var currentTOCEntry: TOCEntry? {
        let path = publication.spine[chapter]
        return publication.toc.last { $0.path == path }
            ?? publication.toc.last { (publication.spineIndex(for: $0.href) ?? .max) <= chapter }
    }

    func fileURL(forChapter index: Int) -> URL {
        publication.spine[index].split(separator: "/").reduce(contentURL) {
            $0.appendingPathComponent(String($1))
        }
    }

    func go(toChapter index: Int, fraction: Double = 0, fragment: String? = nil) {
        guard publication.spine.indices.contains(index) else { return }
        chapter = index
        chapterFraction = fraction
        request = LoadRequest(chapter: index, fraction: fraction, fragment: fragment)
        save()
    }

    func go(to entry: TOCEntry) {
        guard let index = publication.spineIndex(for: entry.href) else { return }
        go(toChapter: index, fragment: entry.fragment)
    }

    func nextChapter() { go(toChapter: chapter + 1) }

    /// Going back lands at the end of the previous chapter, like turning back a page.
    func previousChapter() { go(toChapter: chapter - 1, fraction: 1) }

    /// Called by the web view as the reader scrolls.
    func didScroll(to fraction: Double) {
        chapterFraction = max(0, min(1, fraction))
        save()
    }

    /// Called when a link inside the book points at another spine item.
    func didFollowLink(toPath path: String, fragment: String?) -> Bool {
        guard let index = publication.spine.firstIndex(of: path) else { return false }
        go(toChapter: index, fragment: fragment)
        return true
    }

    func relativePath(for url: URL) -> String? {
        let root = contentURL.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count + 1))
    }

    private func save() {
        book.location = "\(chapter):\(chapterFraction)"
        book.progress = overallProgress
        book.lastOpenedAt = .now
    }

    nonisolated static func parseLocation(_ location: String?, chapterCount: Int) -> (chapter: Int, fraction: Double) {
        guard let location else { return (0, 0) }
        let parts = location.split(separator: ":")
        guard parts.count == 2, let chapter = Int(parts[0]), let fraction = Double(parts[1]),
              (0..<chapterCount).contains(chapter)
        else { return (0, 0) }
        return (chapter, max(0, min(1, fraction)))
    }
}
