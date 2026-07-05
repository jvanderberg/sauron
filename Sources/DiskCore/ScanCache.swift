import Foundation

/// Path normalization for cache lookups. On modern macOS the startup disk's
/// user data lives on the Data volume, so "/System/Volumes/Data/Users/x" and
/// "/Users/x" are the same directory through a firmlink. Normalizing both
/// spellings lets a "Scan Disk" tree serve as cache for a "Scan Home".
public enum Paths {
    private static let dataVolume = "/System/Volumes/Data"

    public static func normalize(_ path: String) -> String {
        var p = path
        if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        if p == dataVolume { return "/" }
        if p.hasPrefix(dataVolume + "/") { return String(p.dropFirst(dataVolume.count)) }
        return p
    }

    /// Find the node for an absolute path inside a tree, tolerating
    /// firmlink-alias differences between the path and the tree's root.
    public static func find(_ target: String, in root: FileNode) -> FileNode? {
        let nt = normalize(target)
        let nr = normalize(root.path)
        if nt == nr { return root }
        let prefix = nr.hasSuffix("/") ? nr : nr + "/"
        guard nt.hasPrefix(prefix) else { return nil }
        var node = root
        for component in nt.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }
}

/// Remembers recent scan trees (complete or partial) keyed by their root
/// path, so switching scan targets can show earlier results instantly while
/// a fresh scan refreshes them. Not thread-safe; use from one actor.
public final class ScanCache {
    public struct Entry {
        public let root: FileNode
        public let complete: Bool
        public let date: Date
    }

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let capacity: Int

    public init(capacity: Int = 4) {
        self.capacity = capacity
    }

    /// Store a scan result. A partial (cancelled) tree never replaces a
    /// complete one, and a smaller partial never replaces a bigger partial —
    /// but a fresh *complete* scan always wins, even if smaller (files may
    /// genuinely have been deleted).
    public func store(root: FileNode, path: String, complete: Bool, date: Date = Date()) {
        let key = Paths.normalize(path)
        if let existing = entries[key], !complete {
            if existing.complete { return }
            if existing.root.size > root.size { return }
        }
        if entries[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > capacity {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        entries[key] = Entry(root: root, complete: complete, date: date)
    }

    /// Best cached data covering `path`: an exact entry, or the node found
    /// inside the most specific entry whose root is an ancestor of `path`.
    public func lookup(path: String) -> (node: FileNode, complete: Bool, date: Date)? {
        let target = Paths.normalize(path)
        if let entry = entries[target] {
            return (entry.root, entry.complete, entry.date)
        }
        var best: (key: String, entry: Entry)?
        for (key, entry) in entries {
            let prefix = key.hasSuffix("/") ? key : key + "/"
            guard target.hasPrefix(prefix) else { continue }
            if best == nil || key.count > best!.key.count { best = (key, entry) }
        }
        guard let best, let node = Paths.find(path, in: best.entry.root) else { return nil }
        return (node, best.entry.complete, best.entry.date)
    }

    public func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}
