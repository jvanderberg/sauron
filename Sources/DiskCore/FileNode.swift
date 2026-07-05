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
