import AppKit
import Compression
import Foundation
import SQLite3

/// One copy read from another clipboard app. Images are PNG.
struct ImportedClip: Equatable {
    var text: String?
    var image: Data?
    var date: Date?
}

enum ClipImportError: LocalizedError, Equatable {
    case unreadable
    case notRecognized
    case encrypted
    case unsupportedValue

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file couldn't be read."
        case .notRecognized: return "This isn't a Ditto database or a CopyQ file."
        case .encrypted: return "This CopyQ file is encrypted. Export again from CopyQ without a password, or choose CopyQ's data folder."
        case .unsupportedValue: return "Part of this CopyQ export couldn't be read. Export again with only tabs, without configuration or commands."
        }
    }
}

/// Reads history from Ditto (Windows, `Ditto.db`) and CopyQ (`.cpq` exports and its `copyq_tab_*.dat` files).
/// Only reads the files, and never changes them.
enum ClipboardImport {
    static func read(_ url: URL) throws -> [ImportedClip] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw ClipImportError.unreadable }
        if isFolder.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let tabs = names.filter { $0.hasPrefix("copyq_tab_") && $0.hasSuffix(".dat") }.sorted()
            guard !tabs.isEmpty else { throw ClipImportError.notRecognized }
            return try tabs.flatMap { try CopyQReader.tabFile(Data(contentsOf: url.appendingPathComponent($0)), folder: url) }
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ClipImportError.unreadable }
        if data.starts(with: Array("SQLite format 3".utf8)) { return try DittoReader.read(url) }
        if let clips = try CopyQReader.export(data, folder: url.deletingLastPathComponent()) { return clips }
        return try CopyQReader.tabFile(data, folder: url.deletingLastPathComponent())
    }
}

// MARK: Ditto

enum DittoReader {
    static func read(_ url: URL) throws -> [ImportedClip] {
        var db: OpaquePointer?
        // immutable=1 keeps SQLite from writing journal files next to the database.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "file"
        components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components?.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            throw ClipImportError.unreadable
        }
        defer { sqlite3_close(db) }
        let query = """
            SELECT m.lID, m.lDate, m.mText, d.strClipBoardFormat, d.ooData
            FROM Main m LEFT JOIN Data d ON d.lParentID = m.lID
            WHERE IFNULL(m.bIsGroup, 0) = 0
            ORDER BY m.lDate DESC, m.lID DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ClipImportError.notRecognized
        }
        defer { sqlite3_finalize(statement) }

        var order: [Int64] = []
        var rows: [Int64: (date: Date?, fallback: String?, formats: [String: Data])] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            if rows[id] == nil {
                order.append(id)
                let seconds = sqlite3_column_int64(statement, 1)
                let text = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                rows[id] = (seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil, text, [:])
            }
            if let format = sqlite3_column_text(statement, 3).map({ String(cString: $0) }),
               let bytes = sqlite3_column_blob(statement, 4) {
                rows[id]?.formats[format] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 4)))
            }
        }
        return order.compactMap { id in
            guard let row = rows[id] else { return nil }
            if let text = clipText(row.formats) { return ImportedClip(text: text, date: row.date) }
            // For images, Ditto's description column only says what kind of picture it is.
            if let png = clipImage(row.formats) { return ImportedClip(image: png, date: row.date) }
            if let text = row.fallback, !text.isEmpty, row.formats.isEmpty { return ImportedClip(text: text, date: row.date) }
            return nil
        }
    }

    /// Windows text formats end with a zero.
    static func clipText(_ formats: [String: Data]) -> String? {
        if let utf16 = formats["CF_UNICODETEXT"], let text = String(data: utf16, encoding: .utf16LittleEndian) {
            return text.trimmingTrailingZeros
        }
        if let ansi = formats["CF_TEXT"], let text = String(data: ansi, encoding: .windowsCP1252) {
            return text.trimmingTrailingZeros
        }
        return nil
    }

    static func clipImage(_ formats: [String: Data]) -> Data? {
        if let png = formats["PNG"], NSBitmapImageRep(data: png) != nil { return png }
        guard let dib = formats["CF_DIB"] ?? formats["CF_DIBV5"], let bmp = bitmapFile(fromDIB: dib),
              let image = NSBitmapImageRep(data: bmp) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    /// A DIB is a BMP file without its 14-byte header, so the header is added back.
    static func bitmapFile(fromDIB dib: Data) -> Data? {
        guard dib.count > 40 else { return nil }
        func u32(_ offset: Int) -> UInt32 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
        func u16(_ offset: Int) -> UInt16 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian } }
        let headerSize = Int(u32(0)), bitCount = Int(u16(14)), compression = u32(16), used = Int(u32(32))
        guard headerSize >= 40, headerSize < dib.count else { return nil }
        let colors = used > 0 ? used : (bitCount <= 8 ? 1 << bitCount : 0)
        let masks = compression == 3 && headerSize == 40 ? 12 : 0
        let offset = 14 + headerSize + masks + colors * 4
        // "BM", file size, two reserved 16-bit fields, then the pixel offset.
        var file = Data("BM".utf8)
        withUnsafeBytes(of: UInt32(14 + dib.count).littleEndian) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0)) { file.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(offset).littleEndian) { file.append(contentsOf: $0) }
        file.append(dib)
        return file
    }
}

private extension String {
    var trimmingTrailingZeros: String {
        var text = self
        while text.last == "\0" { text.removeLast() }
        return text
    }
}

// MARK: CopyQ

/// CopyQ saves with Qt's QDataStream: big-endian numbers, UTF-16 strings, and length-prefixed byte arrays.
struct QtStream {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    var atEnd: Bool { offset >= data.count }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw ClipImportError.notRecognized }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    mutating func uint32() throws -> UInt32 {
        let raw = try bytes(4)
        return raw.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint64() throws -> UInt64 {
        let raw = try bytes(8)
        return raw.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bool() throws -> Bool { try bytes(1).first != 0 }

    mutating func byteArray() throws -> Data {
        let length = try uint32()
        if length == 0xFFFF_FFFF { return Data() }
        return try bytes(Int(length))
    }

    mutating func string() throws -> String {
        let length = try uint32()
        if length == 0xFFFF_FFFF { return "" }
        guard length % 2 == 0 else { throw ClipImportError.notRecognized }
        return String(data: try bytes(Int(length)), encoding: .utf16BigEndian) ?? ""
    }

    indirect enum Value {
        case bool(Bool), number(Double), string(String), strings([String]), bytes(Data), list([Value]), map([String: Value])

        var bytesValue: Data? { if case .bytes(let data) = self { return data }; return nil }
        var stringValue: String? { if case .string(let text) = self { return text }; return nil }
        var listValue: [Value]? { if case .list(let list) = self { return list }; return nil }
        var mapValue: [String: Value]? { if case .map(let map) = self { return map }; return nil }
    }

    /// A QVariant in the Qt 4.7 stream format: type, null flag, then the value.
    mutating func variant(depth: Int = 0) throws -> Value {
        guard depth < 32 else { throw ClipImportError.unsupportedValue }
        let type = try uint32()
        _ = try bytes(1)
        switch type {
        case 1: return .bool(try bool())
        case 2: return .number(Double(try int32()))
        case 3: return .number(Double(try uint32()))
        case 4: return .number(Double(Int64(bitPattern: try uint64())))
        case 5: return .number(Double(try uint64()))
        case 6: return .number(Double(bitPattern: try uint64()))
        case 8: return .map(try map(depth: depth + 1))
        case 9:
            let count = try uint32()
            return .list(try (0..<count).map { _ in try variant(depth: depth + 1) })
        case 10: return .string(try string())
        case 11:
            let count = try uint32()
            return .strings(try (0..<count).map { _ in try string() })
        case 12: return .bytes(try byteArray())
        default: throw ClipImportError.unsupportedValue
        }
    }

    mutating func map(depth: Int = 0) throws -> [String: Value] {
        let count = try uint32()
        guard count < 1_000_000 else { throw ClipImportError.notRecognized }
        var result: [String: Value] = [:]
        for _ in 0..<count {
            let key = try string()
            result[key] = try variant(depth: depth)
        }
        return result
    }
}

enum CopyQReader {
    /// A `.cpq` export. Returns nil when the file doesn't start with a CopyQ header.
    static func export(_ data: Data, folder: URL) throws -> [ImportedClip]? {
        var stream = QtStream(data)
        guard let header = try? stream.byteArray(), header.starts(with: Array("CopyQ v".utf8)),
              let version = String(data: header, encoding: .ascii) else { return nil }
        if version.hasPrefix("CopyQ v5") { throw ClipImportError.encrypted }
        if version.hasPrefix("CopyQ v4") {
            _ = try stream.map()
            var clips: [ImportedClip] = []
            while !stream.atEnd {
                let tab = try stream.map()
                if let bytes = tab["data"]?.bytesValue { clips += try tabFile(bytes, folder: folder) }
            }
            return clips
        }
        if version.hasPrefix("CopyQ v3") {
            let settings = try stream.map()
            return try (settings["tabs"]?.listValue ?? []).flatMap { tab -> [ImportedClip] in
                guard let bytes = tab.mapValue?["data"]?.bytesValue else { return [] }
                return try tabFile(bytes, folder: folder)
            }
        }
        if version.hasPrefix("CopyQ v2") || version.hasPrefix("CopyQ v1") {
            _ = try stream.string()
            return try items(&stream, folder: folder)
        }
        throw ClipImportError.notRecognized
    }

    /// The item list CopyQ keeps for each tab, newest first.
    static func tabFile(_ data: Data, folder: URL) throws -> [ImportedClip] {
        var stream = QtStream(data)
        return try items(&stream, folder: folder)
    }

    private static func items(_ stream: inout QtStream, folder: URL) throws -> [ImportedClip] {
        let count = try stream.int32()
        guard count >= 0, count < 10_000_000 else { throw ClipImportError.notRecognized }
        var clips: [ImportedClip] = []
        var sawEncrypted = false
        for _ in 0..<count {
            let formats: [String: Data]
            do {
                formats = try item(&stream, folder: folder)
            } catch ClipImportError.encrypted {
                // The rest of the stream can't be found without the key.
                sawEncrypted = true
                break
            }
            if let text = (formats["text/plain;charset=utf-8"] ?? formats["text/plain"]).flatMap({ String(data: $0, encoding: .utf8) }),
               !text.isEmpty {
                clips.append(ImportedClip(text: text))
            } else if let png = formats["image/png"], NSBitmapImageRep(data: png) != nil {
                clips.append(ImportedClip(image: png))
            }
        }
        if clips.isEmpty, sawEncrypted { throw ClipImportError.encrypted }
        return clips
    }

    private static func item(_ stream: inout QtStream, folder: URL) throws -> [String: Data] {
        let version = try stream.int32()
        var formats: [String: Data] = [:]
        if version == -3 { throw ClipImportError.encrypted }
        if version == -2 {
            let size = try stream.int32()
            guard size >= 0 else { throw ClipImportError.notRecognized }
            for _ in 0..<size {
                var mime = try mimeType(&stream)
                let compressed = try stream.bool()
                var bytes = try stream.byteArray()
                if mime.hasPrefix("FILE:") {
                    // Large items live in their own file, and the stream holds the path.
                    mime.removeFirst(5)
                    let path = String(decoding: bytes, as: UTF8.self)
                    let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
                    guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 20_000_000,
                          let contents = try? Data(contentsOf: file) else { continue }
                    bytes = contents
                } else if compressed {
                    guard let inflated = qUncompress(bytes) else { continue }
                    bytes = inflated
                }
                formats[mime] = bytes
            }
            return formats
        }
        guard version >= 0 else { throw ClipImportError.notRecognized }
        for _ in 0..<version {
            let mime = try stream.string()
            let bytes = try stream.byteArray()
            formats[mime] = bytes.isEmpty ? bytes : (qUncompress(bytes) ?? Data())
        }
        return formats
    }

    /// CopyQ shortens MIME types to a hex digit for a common prefix and the rest.
    private static let prefixes: [Int: String] = [
        1: "application/x-copyq-owner-window-title", 2: "application/x-copyq-item-notes", 3: "application/x-copyq-",
        4: "text/plain", 5: "text/html", 6: "text/uri-list", 7: "image/", 8: "text/", 9: "application/",
        10: "audio/", 11: "video/",
    ]

    private static func mimeType(_ stream: inout QtStream) throws -> String {
        let raw = try stream.string()
        guard let first = raw.first, let id = Int(String(first), radix: 16) else { throw ClipImportError.notRecognized }
        let rest = String(raw.dropFirst())
        if id == 0 { return rest }
        guard let prefix = prefixes[id] else { throw ClipImportError.notRecognized }
        return prefix + rest
    }

    /// Qt's qCompress: a 4-byte big-endian length, then a zlib stream.
    static func qUncompress(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let bytes = [UInt8](data)
        let expected = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard expected > 0, expected <= 50_000_000 else { return expected == 0 ? Data() : nil }
        // Apple's ZLIB decoder reads raw deflate, so the two-byte zlib header is skipped.
        let source = Array(bytes[6...])
        var output = [UInt8](repeating: 0, count: expected)
        let written = compression_decode_buffer(&output, expected, source, source.count, nil, COMPRESSION_ZLIB)
        return written == expected ? Data(output) : nil
    }
}
