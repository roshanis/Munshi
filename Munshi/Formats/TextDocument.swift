import Foundation

/// Turns plain text and Markdown into a single HTML page so it can share the web reader with EPUB.
enum TextDocument {
    struct Result {
        var html: String
        var toc: [TOCEntry]
    }

    static let fileName = "index.html"

    static func decode(_ data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .windowsCP1252) { return string }
        return String(decoding: data, as: UTF8.self)
    }

    /// Paragraphs are separated by blank lines; hard-wrapped lines inside a paragraph are joined.
    /// Lines starting with `#` become headings and are listed in the table of contents.
    static func html(fromText text: String, title: String) -> Result {
        var body: [String] = []
        var toc: [TOCEntry] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            body.append("<p>\(escape(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if let heading = heading(in: line) {
                flushParagraph()
                let anchor = "h\(toc.count)"
                toc.append(TOCEntry(id: toc.count, title: heading.text, href: "\(fileName)#\(anchor)", level: heading.level - 1))
                body.append("<h\(heading.level) id=\"\(anchor)\">\(escape(heading.text))</h\(heading.level)>")
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()

        if toc.isEmpty {
            toc = [TOCEntry(id: 0, title: title, href: fileName, level: 0)]
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title></head>
        <body>
        \(body.joined(separator: "\n"))
        </body></html>
        """
        return Result(html: html, toc: toc)
    }

    /// Pulls the `<title>` out of an HTML page, if it has one.
    static func htmlTitle(in html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        return String(html[open.upperBound..<close.lowerBound]).nilIfEmpty
    }

    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard (1...6).contains(hashes), !text.isEmpty, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, text)
    }
}
