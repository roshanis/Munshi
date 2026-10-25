import Foundation
import SwiftData
import UniformTypeIdentifiers

enum BookFormat: String, Codable, CaseIterable {
    case epub
    case pdf
    case text
    case html

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "txt", "text", "md", "markdown": self = .text
        case "html", "htm", "xhtml": self = .html
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .text: "Text"
        case .html: "HTML"
        }
    }

    /// Everything except PDF is rendered as HTML in a web view.
    var usesWebReader: Bool { self != .pdf }

    static var importableTypes: [UTType] {
        var types: [UTType] = [.epub, .pdf, .plainText, .html]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String?
    var formatRaw: String
    /// File name of the imported original inside the book's folder.
    var originalFileName: String
    var addedAt: Date
    var lastOpenedAt: Date?
    /// Reading progress from 0 to 1.
    var progress: Double
    /// Format-specific reading position: "chapter:fraction" for web formats, a page index for PDF.
    var location: String?
    @Attribute(.externalStorage) var coverData: Data?

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        format: BookFormat,
        originalFileName: String,
        coverData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.originalFileName = originalFileName
        self.addedAt = .now
        self.progress = 0
        self.coverData = coverData
    }

    var format: BookFormat { BookFormat(rawValue: formatRaw) ?? .text }

    var folderURL: URL { BookStorage.folder(for: id) }
    var originalFileURL: URL { folderURL.appendingPathComponent(originalFileName) }
}
