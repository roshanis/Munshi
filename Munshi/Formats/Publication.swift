import Foundation

/// The reading order and table of contents for anything Munshi renders as HTML:
/// EPUB books, plain text files and HTML pages (and, later, saved web articles).
///
/// Paths are relative to the book's extracted `content` folder and use `/` separators.
struct Publication: Codable, Equatable {
    var title: String?
    var author: String?
    var spine: [String]
    var toc: [TOCEntry]
    var coverPath: String?

    /// Index of the spine item that `href` (optionally with a `#fragment`) points into.
    func spineIndex(for href: String) -> Int? {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        return spine.firstIndex(of: path)
    }
}

struct TOCEntry: Codable, Equatable, Hashable, Identifiable {
    var id: Int
    var title: String
    /// Content-relative path, possibly with a `#fragment`.
    var href: String
    var level: Int

    var path: String { href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href }
    var fragment: String? {
        let parts = href.split(separator: "#", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}

enum ContentPath {
    /// Resolves an href found in a file at `base` (a content-relative directory) to a
    /// normalized content-relative path, keeping any `#fragment`.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let fragment = parts.count == 2 ? String(parts[1]) : nil
        let decoded = rawPath.removingPercentEncoding ?? rawPath

        var components: [String] = []
        let joined = decoded.hasPrefix("/") || base.isEmpty ? decoded : base + "/" + decoded
        for component in joined.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        let path = components.joined(separator: "/")
        if let fragment, !fragment.isEmpty { return path + "#" + fragment }
        return path
    }

    /// The directory part of a content-relative path ("OEBPS/content.opf" -> "OEBPS").
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
