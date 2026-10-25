import Foundation

/// On-disk layout for imported books:
///
///     Application Support/Munshi/Books/<book id>/
///         original.<ext>      the file as imported
///         publication.json    reading order and contents (web formats only)
///         content/            extracted or generated HTML (web formats only)
enum BookStorage {
    static let publicationFileName = "publication.json"
    static let contentFolderName = "content"

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Munshi/Books", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func contentFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(contentFolderName, isDirectory: true)
    }

    static func savePublication(_ publication: Publication, for id: UUID) throws {
        let data = try JSONEncoder().encode(publication)
        try data.write(to: folder(for: id).appendingPathComponent(publicationFileName), options: .atomic)
    }

    static func loadPublication(for id: UUID) throws -> Publication {
        let data = try Data(contentsOf: folder(for: id).appendingPathComponent(publicationFileName))
        return try JSONDecoder().decode(Publication.self, from: data)
    }

    static func removeFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}
