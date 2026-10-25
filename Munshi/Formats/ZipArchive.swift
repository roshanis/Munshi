import Compression
import Foundation

/// A small read-only ZIP reader, enough for EPUB containers.
///
/// Supports stored and deflated entries. ZIP64 archives and encrypted entries are not supported,
/// which in practice never shows up in EPUB files.
struct ZipArchive {
    struct Entry: Hashable {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ZipError: Error, Equatable {
        case notAZip
        case corrupt
        case zip64Unsupported
        case unsupportedCompression(UInt16)
        case decompressionFailed(String)
        case missingEntry(String)
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readCentralDirectory(bytes)
    }

    func entry(named path: String) -> Entry? {
        entries.first { $0.path == path }
            ?? entries.first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    func contents(of path: String) throws -> Data {
        guard let entry = entry(named: path) else { throw ZipError.missingEntry(path) }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x0403_4B50 else {
            throw ZipError.corrupt
        }
        let nameLength = Int(Self.u16(bytes, header + 26))
        let extraLength = Int(Self.u16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupt }

        switch entry.method {
        case 0:
            return Data(bytes[start..<end])
        case 8:
            return try Self.inflate(bytes[start..<end], expectedSize: entry.uncompressedSize, path: entry.path)
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
    }

    /// Extracts every file into `directory`, refusing entries that would escape it.
    func extractAll(to directory: URL) throws {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in entries where !entry.isDirectory {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".."), !entry.path.hasPrefix("/") else { continue }
            let destination = components.reduce(root) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents(of: entry).write(to: destination, options: .atomic)
        }
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        let endRecordSize = 22
        guard bytes.count >= endRecordSize else { throw ZipError.notAZip }

        // The end-of-central-directory record sits at the end, optionally followed by a comment.
        let lowestStart = max(0, bytes.count - endRecordSize - 0xFFFF)
        var eocd: Int?
        var index = bytes.count - endRecordSize
        while index >= lowestStart {
            if u32(bytes, index) == 0x0605_4B50 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw ZipError.notAZip }

        let entryCount = Int(u16(bytes, eocd + 10))
        let directoryOffset = u32(bytes, eocd + 16)
        if directoryOffset == 0xFFFF_FFFF || entryCount == 0xFFFF { throw ZipError.zip64Unsupported }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var offset = Int(directoryOffset)
        for _ in 0..<entryCount {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(bytes, offset + 8)
            let method = u16(bytes, offset + 10)
            let compressedSize = u32(bytes, offset + 20)
            let uncompressedSize = u32(bytes, offset + 24)
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let localHeaderOffset = u32(bytes, offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            if compressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }

            let nameBytes = bytes[(offset + 46)..<(offset + 46 + nameLength)]
            let isUTF8 = flags & (1 << 11) != 0
            let name = (isUTF8 ? String(bytes: nameBytes, encoding: .utf8) : nil)
                ?? String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""

            entries.append(Entry(
                path: name,
                method: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ input: ArraySlice<UInt8>, expectedSize: Int, path: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is exactly what ZIP stores.
                compression_decode_buffer(
                    destination.baseAddress!, expectedSize,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.decompressionFailed(path) }
        return Data(output)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
