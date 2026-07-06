import Foundation

/// A node in the scanned file tree. `size` is the *physical* (allocated) size
/// in bytes — st_blocks * 512 — aggregated over children for directories.
public final class FileNode {
    public let name: String
    public let isDirectory: Bool
    public internal(set) var size: Int64
    public internal(set) var children: [FileNode]
    public internal(set) weak var parent: FileNode?

    public init(name: String, isDirectory: Bool, size: Int64 = 0, parent: FileNode? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.parent = parent
        self.children = []
    }

    /// Full filesystem path, reconstructed from the root (whose `name` is the
    /// absolute scan path).
    public var path: String {
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    public var isRoot: Bool { parent == nil }

    /// Ancestors from root down to (and including) self.
    public var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let n = node {
            chain.append(n)
            node = n.parent
        }
        return chain.reversed()
    }

    /// True if `other` is self or an ancestor of self.
    public func isDescendant(of other: FileNode) -> Bool {
        var node: FileNode? = self
        while let n = node {
            if n === other { return true }
            node = n.parent
        }
        return false
    }

    func addChild(_ child: FileNode) {
        children.append(child)
    }

    /// Sort children by size, largest first, recursively.
    public func sortBySize() {
        children.sort { $0.size > $1.size }
        for c in children { c.sortBySize() }
    }

    /// Find the node with the given absolute path in this subtree, matching
    /// by path components. Returns nil if it doesn't exist (anymore).
    public func find(path target: String) -> FileNode? {
        let own = path
        if target == own { return self }
        let prefix = own.hasSuffix("/") ? own : own + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var node = self
        for component in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Adopt the children and size of a freshly rescanned copy of this same
    /// directory, propagating the size delta to every ancestor. Used for
    /// subtree rescans: the node's identity (and the navigation stack
    /// pointing at it) survives; its contents are replaced.
    public func replaceContents(with other: FileNode) {
        let delta = other.size - size
        children = other.children
        for child in children { child.parent = self }
        size = other.size
        var node = parent
        while let n = node {
            n.size += delta
            node = n.parent
        }
    }

    /// Every file (not directory) in this subtree with size >= minSize,
    /// sorted largest first, capped at `limit`. Prunes aggressively: a
    /// directory smaller than minSize cannot contain a qualifying file, so
    /// huge trees stay cheap to query.
    public func largestFiles(minSize: Int64, limit: Int = 1000) -> [FileNode] {
        var result: [FileNode] = []
        if !isDirectory {
            if size >= minSize { result.append(self) }
            return result
        }
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            for child in node.children {
                if child.isDirectory {
                    if child.size >= minSize { stack.append(child) }
                } else if child.size >= minSize {
                    result.append(child)
                }
            }
        }
        result.sort { $0.size > $1.size }
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// Deep copy of this subtree, omitting files below `minFileSize`
    /// (directory aggregate sizes are preserved exactly). Used to snapshot a
    /// live tree quickly under a lock so slow work (serialization) can run
    /// on the copy without blocking readers.
    public func filteredCopy(minFileSize: Int64, parent: FileNode? = nil) -> FileNode {
        let copy = FileNode(name: name, isDirectory: isDirectory, size: size, parent: parent)
        if isDirectory {
            for child in children where child.isDirectory || child.size >= minFileSize {
                copy.addChild(child.filteredCopy(minFileSize: minFileSize, parent: copy))
            }
        }
        return copy
    }

    /// Detach this node from the tree, subtracting its size from every
    /// ancestor. Used after a successful move-to-trash.
    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var node: FileNode? = parent
        while let n = node {
            n.size -= size
            node = n.parent
        }
        self.parent = nil
    }
}
