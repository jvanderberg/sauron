import Foundation
import Darwin

public struct ScanResult {
    public let root: FileNode
    public let entryCount: Int
    public let errorCount: Int
    public let cancelled: Bool
}

/// Thread-safe cancellation flag. A scan blocked inside a syscall cannot be
/// interrupted, but once it returns, a cancelled token stops it at the next
/// checkpoint — and lets abandoned scans be identified by token identity.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Thread-safe liveness signal from a running scan. The scanner beats it on
/// every directory it enters (with the path) and periodically between files;
/// if the scanner wedges inside an unresponsive directory, the heartbeat
/// freezes holding that directory's path — exact blame for a watchdog.
public final class ScanHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = Date()
    private var currentDirectory = ""

    public init() {}

    public func beat(directory: String?) {
        lock.lock()
        lastBeat = Date()
        if let directory { currentDirectory = directory }
        lock.unlock()
    }

    public var snapshot: (lastBeat: Date, directory: String) {
        lock.lock()
        defer { lock.unlock() }
        return (lastBeat, currentDirectory)
    }
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
    /// - skipPaths: exact directory paths to record as empty leaves without
    ///   descending (the watchdog's learned list of unresponsive folders).
    /// - heartbeat: beaten with each directory entered; lets a watchdog
    ///   detect a wedged scan and identify the guilty directory.
    /// - cancelToken: checked at each progress interval alongside the
    ///   progress callback's return value.
    public static func scan(
        path rawPath: String,
        lock: NSLock? = nil,
        progressEvery: Int = 4096,
        sortAtEnd: Bool = true,
        skipPaths: Set<String> = [],
        heartbeat: ScanHeartbeat? = nil,
        cancelToken: CancelToken? = nil,
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
            if progressEvery > 0, entryCount % progressEvery == 0 {
                heartbeat?.beat(directory: nil)
                if cancelToken?.isCancelled == true {
                    cancelled = true
                    break
                }
                if let progress {
                    let current = String(cString: ent.pointee.fts_path)
                    if !progress(entryCount, current) {
                        cancelled = true
                        break
                    }
                }
            }

            switch info {
            case FTS_D:
                unwind(to: level)
                var dirPath: String?
                if heartbeat != nil || !skipPaths.isEmpty {
                    dirPath = String(cString: ent.pointee.fts_path)
                }
                if let dirPath { heartbeat?.beat(directory: dirPath) }
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
                // Hazard directories whose enumeration can block forever:
                // cloud-provider roots (~/Library/CloudStorage — the
                // provider daemon must answer, and hung providers wedge
                // readdir), the /Volumes mount stubs (a dead network mount
                // hangs lstat), and any path the caller learned to avoid.
                // Their contents are mostly not on disk, so record the
                // directory as an empty leaf and move on.
                let callerSkipped = dirPath.map { skipPaths.contains($0) } ?? false
                if !stack.isEmpty, callerSkipped || shouldSkipDescent(ent) {
                    lock?.lock()
                    let node = FileNode(name: entName(ent), isDirectory: true,
                                        size: physicalSize(ent), parent: stack.last)
                    stack.last?.addChild(node)
                    for ancestor in stack { ancestor.size += node.size }
                    lock?.unlock()
                    _ = fts_set(stream, ent, FTS_SKIP)
                    continue
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

    /// Directories we refuse to descend into because their enumeration can
    /// hang indefinitely (see call site). Matching is deliberately narrow.
    private static func shouldSkipDescent(_ ent: UnsafeMutablePointer<FTSENT>) -> Bool {
        let nameLen = Int(ent.pointee.fts_namelen)
        // Fast reject on name length before building any strings.
        guard nameLen == 12 /* CloudStorage */ || nameLen == 7 /* Volumes */ else { return false }
        let name = entName(ent)
        if name == "CloudStorage" {
            let path = String(cString: ent.pointee.fts_path)
            return path.hasSuffix("/Library/CloudStorage")
        }
        if name == "Volumes" {
            let path = String(cString: ent.pointee.fts_path)
            return path == "/Volumes" || path == "/System/Volumes/Data/Volumes"
        }
        return false
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
