import Foundation

public enum ScanArchiveError: Error, CustomStringConvertible {
    case corrupt
    case unsupportedVersion

    public var description: String {
        switch self {
        case .corrupt: return "scan archive is corrupt"
        case .unsupportedVersion: return "scan archive was written by an incompatible version"
        }
    }
}

/// Compact on-disk snapshot of a scan tree, so the app can show the last
/// scan instantly at launch.
///
/// Format: "SAUR" + version + scanned path + date, then the tree depth-first
/// (flag byte, name, size as LEB128 varint, child count for directories),
/// LZFSE-compressed. Files below `minFileSize` are omitted — directory sizes
/// are aggregates, so every visible total stays exact while the node count
/// (and archive size) drops by ~10x.
public enum ScanArchive {
    private static let magic = Array("SAUR".utf8)
    private static let version: UInt64 = 1

    public static func save(root: FileNode, scannedPath: String, date: Date,
                            to url: URL, minFileSize: Int64 = 1_000_000) throws {
        var writer = Writer()
        writer.bytes(magic)
        writer.varint(version)
        writer.string(scannedPath)
        writer.varint(UInt64(max(0, date.timeIntervalSince1970)))
        encode(root, into: &writer, minFileSize: minFileSize)
        let compressed = try (writer.data as NSData).compressed(using: .lzfse)
        try (compressed as Data).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> (root: FileNode, scannedPath: String, date: Date) {
        let raw = try Data(contentsOf: url)
        let data = try (raw as NSData).decompressed(using: .lzfse) as Data
        var reader = Reader(data)
        guard try reader.bytes(magic.count) == Data(magic) else { throw ScanArchiveError.corrupt }
        guard try reader.varint() == version else { throw ScanArchiveError.unsupportedVersion }
        let path = try reader.string()
        let date = Date(timeIntervalSince1970: TimeInterval(try reader.varint()))
        let root = try decode(&reader, parent: nil)
        return (root, path, date)
    }

    private static func encode(_ node: FileNode, into writer: inout Writer, minFileSize: Int64) {
        writer.byte(node.isDirectory ? 1 : 0)
        writer.string(node.name)
        writer.varint(UInt64(max(0, node.size)))
        guard node.isDirectory else { return }
        let kept = node.children.filter { $0.isDirectory || $0.size >= minFileSize }
        writer.varint(UInt64(kept.count))
        for child in kept { encode(child, into: &writer, minFileSize: minFileSize) }
    }

    private static func decode(_ reader: inout Reader, parent: FileNode?) throws -> FileNode {
        let flag = try reader.byte()
        let name = try reader.string()
        let size = Int64(bitPattern: try reader.varint())
        let node = FileNode(name: name, isDirectory: flag == 1, size: size, parent: parent)
        if flag == 1 {
            let count = try reader.varint()
            guard count < 50_000_000 else { throw ScanArchiveError.corrupt }
            for _ in 0..<count {
                node.addChild(try decode(&reader, parent: node))
            }
        }
        return node
    }

    private struct Writer {
        var data = Data()

        mutating func byte(_ b: UInt8) { data.append(b) }
        mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }

        mutating func varint(_ value: UInt64) {
            var x = value
            repeat {
                var b = UInt8(x & 0x7F)
                x >>= 7
                if x != 0 { b |= 0x80 }
                data.append(b)
            } while x != 0
        }

        mutating func string(_ s: String) {
            let utf8 = Array(s.utf8)
            varint(UInt64(utf8.count))
            data.append(contentsOf: utf8)
        }
    }

    private struct Reader {
        private let data: Data
        private var index: Data.Index

        init(_ data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        mutating func byte() throws -> UInt8 {
            guard index < data.endIndex else { throw ScanArchiveError.corrupt }
            defer { index = data.index(after: index) }
            return data[index]
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard let end = data.index(index, offsetBy: count, limitedBy: data.endIndex) else {
                throw ScanArchiveError.corrupt
            }
            defer { index = end }
            return data[index..<end]
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let b = try byte()
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                guard shift < 64 else { throw ScanArchiveError.corrupt }
            }
        }

        mutating func string() throws -> String {
            let length = Int(try varint())
            guard length < 100_000 else { throw ScanArchiveError.corrupt }
            guard let s = String(data: try bytes(length), encoding: .utf8) else {
                throw ScanArchiveError.corrupt
            }
            return s
        }
    }
}
