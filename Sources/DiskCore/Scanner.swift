import Foundation
import Darwin

public struct ScanResult {
    public let root: FileNode
    public let entryCount: Int
    public let errorCount: Int
    public let cancelled: Bool
}

public enum ScanError: Error, CustomStringConvertible {
    case cannotOpen(String)

    public var description: String {
        switch self {
        case .cannotOpen(let p): return "cannot open \(p) for scanning"
        }
    }
}

/// Recursive physical-disk-usage scanner built on fts(3).
///
/// - Physical size = st_blocks * 512, so sparse files report actual allocated
///   space, not their logical length.
/// - Hard-linked files are counted once (subsequent links appear with size 0).
/// - Does not follow symlinks (FTS_PHYSICAL) and does not cross device
///   boundaries (FTS_XDEV), so mount points and the APFS firmlink maze are
///   not double-counted.
public enum Scanner {
    /// Progress callback: (entries scanned so far, current path).
    /// Return false to cancel the scan; the partial tree is still returned.
    public typealias Progress = (Int, String) -> Bool

    private static let progressInterval = 4096

    public static func scan(path rawPath: String, progress: Progress? = nil) throws -> ScanResult {
        let path = (rawPath as NSString).expandingTildeInPath
        var pathArgs: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(pathArgs[0]) }
        guard let stream = fts_open(&pathArgs, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw ScanError.cannotOpen(path)
        }
        defer { fts_close(stream) }

        var root: FileNode?
        var stack: [FileNode] = []
        var seenHardLinks = Set<HardLinkKey>()
        var entryCount = 0
        var errorCount = 0
        var cancelled = false

        while let ent = fts_read(stream) {
            let info = Int32(ent.pointee.fts_info)
            entryCount += 1
            if entryCount % progressInterval == 0, let progress {
                let current = String(cString: ent.pointee.fts_path)
                if !progress(entryCount, current) {
                    cancelled = true
                    break
                }
            }

            switch info {
            case FTS_D:
                let node = FileNode(
                    name: stack.isEmpty ? path : entName(ent),
                    isDirectory: true,
                    size: physicalSize(ent),
                    parent: stack.last
                )
                stack.last?.addChild(node)
                if root == nil { root = node }
                stack.append(node)

            case FTS_DP:
                let node = stack.removeLast()
                if let parent = stack.last { parent.size += node.size }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let parent = stack.last else { continue }
                var size = physicalSize(ent)
                if let st = ent.pointee.fts_statp, st.pointee.st_nlink > 1,
                   (st.pointee.st_mode & S_IFMT) == S_IFREG {
                    let key = HardLinkKey(dev: st.pointee.st_dev, ino: st.pointee.st_ino)
                    if !seenHardLinks.insert(key).inserted { size = 0 }
                }
                let node = FileNode(name: entName(ent), isDirectory: false, size: size, parent: parent)
                parent.addChild(node)
                parent.size += size

            case FTS_DNR, FTS_ERR, FTS_NS:
                errorCount += 1

            default:
                break
            }
        }

        // On cancellation the directory stack may be partially unwound; the
        // aggregated sizes of still-open directories are propagated here.
        while stack.count > 1 {
            let node = stack.removeLast()
            stack.last?.size += node.size
        }

        guard let rootNode = root ?? scanSingleFile(path: path) else {
            throw ScanError.cannotOpen(path)
        }
        rootNode.sortBySize()
        return ScanResult(root: rootNode, entryCount: entryCount, errorCount: errorCount, cancelled: cancelled)
    }

    /// fts on a plain file (not a directory) yields a single FTS_F at level 0
    /// with no enclosing FTS_D, so `root` stays nil. Stat it directly.
    private static func scanSingleFile(path: String) -> FileNode? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileNode(name: path, isDirectory: false, size: Int64(st.st_blocks) * 512)
    }

    private static func physicalSize(_ ent: UnsafeMutablePointer<FTSENT>) -> Int64 {
        guard let st = ent.pointee.fts_statp else { return 0 }
        return Int64(st.pointee.st_blocks) * 512
    }

    private static func entName(_ ent: UnsafeMutablePointer<FTSENT>) -> String {
        withUnsafePointer(to: &ent.pointee.fts_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.fts_namelen) + 1) {
                String(cString: $0)
            }
        }
    }

    private struct HardLinkKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }
}
