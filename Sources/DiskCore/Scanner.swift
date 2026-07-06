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

    /// Scan a directory tree.
    ///
    /// Sizes propagate to every ancestor as each entry is visited, so the
    /// tree is *live*: readers see totals grow monotonically during the scan.
    /// - lock: taken around every tree mutation. Pass one (and take it when
    ///   reading) to render the tree while the scan is still running.
    /// - progressEvery: how many entries between progress callbacks.
    /// - sortAtEnd: recursively sort children by size when done. Sorting
    ///   millions of nodes holds the lock for seconds — callers that sort
    ///   per-level on read (like the app) should pass false.
    /// - onRootReady: called (on the scanning thread) as soon as the root
    ///   node exists, so callers can start displaying it.
    public static func scan(
        path rawPath: String,
        lock: NSLock? = nil,
        progressEvery: Int = 4096,
        sortAtEnd: Bool = true,
        onRootReady: ((FileNode) -> Void)? = nil,
        progress: Progress? = nil
    ) throws -> ScanResult {
        let path = (rawPath as NSString).expandingTildeInPath
        var pathArgs: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(pathArgs[0]) }
        guard let stream = fts_open(&pathArgs, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw ScanError.cannotOpen(path)
        }
        defer { fts_close(stream) }

        var root: FileNode?
        var stack: [FileNode] = []
        var seenHardLinks = Set<InodeKey>()
        var visitedDirs = Set<InodeKey>()
        var entryCount = 0
        var errorCount = 0
        var cancelled = false

        // The stack is kept in sync with fts_level rather than trusting a
        // strict FTS_D/FTS_DP pairing: fts can report a directory's
        // post-order visit as FTS_ERR (or skip it entirely for pruned
        // subtrees), and a single missed pop would silently re-parent the
        // whole rest of the traversal under the wrong directory.
        func unwind(to depth: Int) {
            while stack.count > depth { stack.removeLast() }
        }

        while let ent = fts_read(stream) {
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            entryCount += 1
            if progressEvery > 0, entryCount % progressEvery == 0, let progress {
                let current = String(cString: ent.pointee.fts_path)
                if !progress(entryCount, current) {
                    cancelled = true
                    break
                }
            }

            switch info {
            case FTS_D:
                unwind(to: level)
                // Firmlinks and mount points can expose the same directory
                // under several paths (e.g. /Users and
                // /System/Volumes/Data/Users). Traverse each physical
                // directory once; skip aliases.
                if let st = ent.pointee.fts_statp {
                    let key = InodeKey(dev: st.pointee.st_dev, ino: st.pointee.st_ino)
                    if !visitedDirs.insert(key).inserted {
                        _ = fts_set(stream, ent, FTS_SKIP)
                        continue
                    }
                }
                let own = physicalSize(ent)
                lock?.lock()
                let node = FileNode(
                    name: stack.isEmpty ? path : entName(ent),
                    isDirectory: true,
                    size: own,
                    parent: stack.last
                )
                stack.last?.addChild(node)
                for ancestor in stack { ancestor.size += own }
                lock?.unlock()
                if root == nil {
                    root = node
                    onRootReady?(node)
                }
                stack.append(node)

            case FTS_DP:
                unwind(to: level + 1)
                if stack.count == level + 1 { stack.removeLast() }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                unwind(to: level)
                guard let parent = stack.last else { continue }
                var size = physicalSize(ent)
                if let st = ent.pointee.fts_statp, st.pointee.st_nlink > 1,
                   (st.pointee.st_mode & S_IFMT) == S_IFREG {
                    let key = InodeKey(dev: st.pointee.st_dev, ino: st.pointee.st_ino)
                    if !seenHardLinks.insert(key).inserted { size = 0 }
                }
                lock?.lock()
                let node = FileNode(name: entName(ent), isDirectory: false, size: size, parent: parent)
                parent.addChild(node)
                for ancestor in stack { ancestor.size += size }
                lock?.unlock()

            case FTS_DNR, FTS_ERR, FTS_NS:
                errorCount += 1

            default:
                break
            }
        }

        guard let rootNode = root ?? scanSingleFile(path: path) else {
            throw ScanError.cannotOpen(path)
        }
        if sortAtEnd {
            lock?.lock()
            rootNode.sortBySize()
            lock?.unlock()
        }
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

    private struct InodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }
}
