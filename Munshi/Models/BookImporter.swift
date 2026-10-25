import Foundation
import PDFKit
import SwiftData

/// Copies a file into the library and prepares it for reading.
enum BookImporter {
    enum ImportError: LocalizedError {
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name): "Munshi can't open \"\(name)\" yet. Try an EPUB, PDF, text or HTML file."
            }
        }
    }

    struct Prepared: Sendable {
        var id: UUID
        var title: String
        var author: String?
        var format: BookFormat
        var originalFileName: String
        var coverData: Data?
    }

    /// Imports `url` and inserts the new book into `context`.
    @MainActor
    @discardableResult
    static func importBook(from url: URL, into context: ModelContext) async throws -> Book {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepare(url)
        }.value
        let book = Book(
            id: prepared.id,
            title: prepared.title,
            author: prepared.author,
            format: prepared.format,
            originalFileName: prepared.originalFileName,
            coverData: prepared.coverData
        )
        context.insert(book)
        try? context.save()
        return book
    }

    static func prepare(_ url: URL) throws -> Prepared {
        let fileName = url.lastPathComponent
        guard let format = BookFormat(fileExtension: url.pathExtension) else {
            throw ImportError.unsupportedFormat(fileName)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let folder = BookStorage.folder(for: id)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let originalName = "original." + url.pathExtension.lowercased()
            let original = folder.appendingPathComponent(originalName)
            try fileManager.copyItem(at: url, to: original)

            let fallbackTitle = url.deletingPathExtension().lastPathComponent
            var prepared = Prepared(
                id: id, title: fallbackTitle, author: nil, format: format,
                originalFileName: originalName, coverData: nil
            )

            switch format {
            case .epub:
                let archive = try ZipArchive(url: original)
                let result = try EPUBParser.parse(archive)
                try archive.extractAll(to: BookStorage.contentFolder(for: id))
                try BookStorage.savePublication(result.publication, for: id)
                prepared.title = result.publication.title ?? fallbackTitle
                prepared.author = result.publication.author
                prepared.coverData = result.coverData.flatMap(CoverImage.thumbnail(from:))

            case .pdf:
                if let document = PDFDocument(url: original) {
                    let attributes = document.documentAttributes ?? [:]
                    if let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfEmpty {
                        prepared.title = title
                    }
                    prepared.author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfEmpty
                    prepared.coverData = CoverImage.thumbnail(of: document)
                }

            case .text:
                let text = TextDocument.decode(try Data(contentsOf: original))
                let result = TextDocument.html(fromText: text, title: fallbackTitle)
                try writeSingleFile(result.html, toc: result.toc, title: fallbackTitle, id: id)

            case .html:
                let html = TextDocument.decode(try Data(contentsOf: original))
                let title = TextDocument.htmlTitle(in: html) ?? fallbackTitle
                prepared.title = title
                let toc = [TOCEntry(id: 0, title: title, href: TextDocument.fileName, level: 0)]
                try writeSingleFile(html, toc: toc, title: title, id: id)
            }
            return prepared
        } catch {
            BookStorage.removeFiles(for: id)
            throw error
        }
    }

    private static func writeSingleFile(_ html: String, toc: [TOCEntry], title: String, id: UUID) throws {
        let content = BookStorage.contentFolder(for: id)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: content.appendingPathComponent(TextDocument.fileName), options: .atomic)
        let publication = Publication(title: title, author: nil, spine: [TextDocument.fileName], toc: toc, coverPath: nil)
        try BookStorage.savePublication(publication, for: id)
    }
}
