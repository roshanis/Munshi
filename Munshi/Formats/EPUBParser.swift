import Foundation

/// Reads the package metadata, reading order, table of contents and cover out of an EPUB 2 or 3 file.
enum EPUBParser {
    enum EPUBError: LocalizedError {
        case missingContainer
        case missingPackage
        case emptySpine

        var errorDescription: String? {
            switch self {
            case .missingContainer: "This EPUB is missing META-INF/container.xml."
            case .missingPackage: "This EPUB's package file could not be read."
            case .emptySpine: "This EPUB has no readable chapters."
            }
        }
    }

    struct Result {
        var publication: Publication
        var coverData: Data?
    }

    static func parse(_ archive: ZipArchive) throws -> Result {
        guard let containerData = try? archive.contents(of: "META-INF/container.xml"),
              let container = try? MiniXMLElement.parse(containerData)
        else { throw EPUBError.missingContainer }

        guard let opfPath = container.firstDescendant("rootfile")?["full-path"],
              let opfData = try? archive.contents(of: opfPath),
              let package = try? MiniXMLElement.parse(opfData)
        else { throw EPUBError.missingPackage }

        let opfDirectory = ContentPath.directory(of: opfPath)

        // Metadata
        let metadata = package.child("metadata")
        let title = metadata?.child("title")?.allText.nilIfEmpty
        let author = metadata?.children("creator").map(\.allText).filter { !$0.isEmpty }
            .joined(separator: ", ").nilIfEmpty

        // Manifest
        struct Item {
            let id: String
            let path: String
            let mediaType: String
            let properties: Set<String>
        }
        var items: [String: Item] = [:]
        for element in package.child("manifest")?.children("item") ?? [] {
            guard let id = element["id"], let href = element["href"] else { continue }
            items[id] = Item(
                id: id,
                path: ContentPath.resolve(href, relativeTo: opfDirectory),
                mediaType: element["media-type"] ?? "",
                properties: Set((element["properties"] ?? "").split(separator: " ").map(String.init))
            )
        }

        // Spine
        let spineElement = package.child("spine")
        let spine = (spineElement?.children("itemref") ?? [])
            .filter { $0["linear"] != "no" }
            .compactMap { $0["idref"].flatMap { items[$0]?.path } }
        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        // Table of contents: prefer the EPUB 3 nav document, fall back to the EPUB 2 NCX.
        var toc: [TOCEntry] = []
        if let nav = items.values.first(where: { $0.properties.contains("nav") }),
           let data = try? archive.contents(of: nav.path) {
            toc = parseNav(data, documentPath: nav.path)
        }
        if toc.isEmpty {
            let ncx = spineElement?["toc"].flatMap { items[$0] }
                ?? items.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx, let data = try? archive.contents(of: ncx.path) {
                toc = parseNCX(data, documentPath: ncx.path)
            }
        }
        if toc.isEmpty {
            toc = spine.enumerated().map { index, path in
                TOCEntry(id: index, title: "Chapter \(index + 1)", href: path, level: 0)
            }
        }

        // Cover
        let coverID = metadata?.children("meta").first { $0["name"] == "cover" }?["content"]
        let coverItem = items.values.first { $0.properties.contains("cover-image") }
            ?? coverID.flatMap { items[$0] }
            ?? items.values.first { $0.mediaType.hasPrefix("image/") && $0.id.lowercased().contains("cover") }
        let coverData = coverItem.flatMap { try? archive.contents(of: $0.path) }

        return Result(
            publication: Publication(
                title: title,
                author: author,
                spine: spine,
                toc: toc,
                coverPath: coverItem?.path
            ),
            coverData: coverData
        )
    }

    /// Parses `<nav epub:type="toc">` from an EPUB 3 navigation document.
    static func parseNav(_ data: Data, documentPath: String) -> [TOCEntry] {
        guard let root = try? MiniXMLElement.parse(data) else { return [] }
        let navs = root.descendants("nav")
        guard let nav = navs.first(where: { ($0["type"] ?? "").split(separator: " ").contains("toc") }) ?? navs.first,
              let list = nav.firstDescendant("ol")
        else { return [] }

        let base = ContentPath.directory(of: documentPath)
        var entries: [TOCEntry] = []
        func walk(_ list: MiniXMLElement, level: Int) {
            for item in list.children("li") {
                if let link = item.child("a"), let href = link["href"] {
                    let title = link.allText
                    entries.append(TOCEntry(
                        id: entries.count,
                        title: title.isEmpty ? "Untitled" : title,
                        href: ContentPath.resolve(href, relativeTo: base),
                        level: level
                    ))
                }
                if let sublist = item.child("ol") {
                    walk(sublist, level: level + 1)
                }
            }
        }
        walk(list, level: 0)
        return entries
    }

    /// Parses the `navMap` of an EPUB 2 NCX file.
    static func parseNCX(_ data: Data, documentPath: String) -> [TOCEntry] {
        guard let root = try? MiniXMLElement.parse(data), let navMap = root.firstDescendant("navMap") else { return [] }
        let base = ContentPath.directory(of: documentPath)
        var entries: [TOCEntry] = []
        func walk(_ parent: MiniXMLElement, level: Int) {
            for point in parent.children("navPoint") {
                if let src = point.child("content")?["src"] {
                    let title = point.child("navLabel")?.allText ?? ""
                    entries.append(TOCEntry(
                        id: entries.count,
                        title: title.isEmpty ? "Untitled" : title,
                        href: ContentPath.resolve(src, relativeTo: base),
                        level: level
                    ))
                }
                walk(point, level: level + 1)
            }
        }
        walk(navMap, level: 0)
        return entries
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
