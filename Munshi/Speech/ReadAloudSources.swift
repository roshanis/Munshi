import Foundation
import PDFKit
import SwiftUI

extension WebReaderModel: ReadAloudSource {
    func speechSection(fromStart: Bool) async -> SpeechSection? {
        await page?.speechSection(fromStart: fromStart)
    }

    func advanceSpeechSection() -> Bool {
        guard canGoForward else { return false }
        nextChapter()
        // Remember that this move came from reading aloud, so the view doesn't treat it as the reader jumping.
        speechNavigationToken = request.token
        return true
    }

    func highlightSpeechBlock(_ index: Int?) {
        page?.highlightSpeechBlock(index)
    }
}

/// Reads a PDF page by page, turning the page as it goes.
@MainActor
final class PDFSpeechSource: ReadAloudSource {
    let document: PDFDocument
    /// The page on screen, kept up to date by the PDF reader.
    var visiblePage = 0
    var turnToPage: (Int) -> Void = { _ in }
    private var readingPage: Int?

    init(document: PDFDocument) {
        self.document = document
    }

    func speechSection(fromStart: Bool) async -> SpeechSection? {
        let index = fromStart ? (readingPage ?? visiblePage) : visiblePage
        readingPage = index
        let text = document.page(at: index)?.string ?? ""
        return SpeechSection(blocks: SpeechText.blocks(fromPageText: text), startIndex: 0)
    }

    func advanceSpeechSection() -> Bool {
        let next = (readingPage ?? visiblePage) + 1
        guard next < document.pageCount else { return false }
        readingPage = next
        turnToPage(next)
        return true
    }

    func highlightSpeechBlock(_ index: Int?) {}
}
