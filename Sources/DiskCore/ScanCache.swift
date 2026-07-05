import Foundation

/// Path spelling helpers for cache lookups. On modern macOS the startup
/// disk's user data lives on the Data volume, and firmlinks graft it into
/// the / namespace: "/Users/x" and "/System/Volumes/Data/Users/x" are the
/// same directory. Crucially the two volume ROOTS are NOT equivalent — "/"
/// (the sealed system volume) and "/System/Volumes/Data" are different
/// directories with different direct contents — so deep paths get alias
/// spellings but the roots never alias each other.
public enum Paths {
    static let dataVolume = "/System/Volumes/Data"

    /// Trim trailing slashes; the canonical cache-key form.
    public static func canonical(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }

    /// All spellings of the same location through the Data-volume firmlink
    /// graft. The volume roots return only themselves.
    public static func variants(_ path: String) -> [String] {
        let p = canonical(path)
        if p.hasPrefix(dataVolume + "/") { return [p, String(p.dropFirst(dataVolume.count))] }
        if p != "/" && p != dataVolume && p.hasPrefix("/") { return [p, dataVolume + p] }
        return [p]
    }

    /// Find the node for an absolute path inside a tree, trying every alias
    /// spelling of the target. Asking a "/"-rooted tree for
    /// "/System/Volumes/Data" (or for "/Users/x" when the scan happened to
    /// record it under the Data spelling) resolves to the nested node.
    public static func find(_ target: String, in root: FileNode) -> FileNode? {
        let rootPath = canonical(root.path)
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        for spelling in variants(target) {
            if spelling == rootPath { return root }
            guard spelling.hasPrefix(prefix) else { continue }
            var node = root
            var found = true
            for component in spelling.dropFirst(prefix.count).split(separator: "/") {
                guard let next = node.children.first(where: { $0.name == component }) else {
                    found = false
                    break
                }
                node = next
            }
            if found { return node }
        }
        return nil
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
        let key = Paths.canonical(path)
        if let existing = entries[key], !complete {
            if existing.complete { return }
            if existing.root.size > root.size { return }
        }
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            entries.removeValue(forKey: insertionOrder.removeFirst())
        }
        entries[key] = Entry(root: root, complete: complete, date: date)
    }

    /// Best cached data covering `path`: an exact entry, or the node for
    /// `path` found inside another entry's tree (most recent first). A "/"
    /// scan serves a Data-volume request via its nested
    /// /System/Volumes/Data node — never by impersonating it with its root.
    public func lookup(path: String) -> (node: FileNode, complete: Bool, date: Date)? {
        let target = Paths.canonical(path)
        if let entry = entries[target] {
            return (entry.root, entry.complete, entry.date)
        }
        for key in insertionOrder.reversed() {
            guard let entry = entries[key] else { continue }
            if let node = Paths.find(target, in: entry.root) {
                return (node, entry.complete, entry.date)
            }
        }
        return nil
    }

    public func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}
