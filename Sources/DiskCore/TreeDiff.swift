import Foundation

/// One entry in a scan-to-scan comparison: the deepest node that explains a
/// size change between a baseline tree and a current tree.
public struct TreeChange: Identifiable {
    public enum Kind {
        case grew
        case shrank
        case added
        case removed
    }

    /// The node in the CURRENT tree (nil for removed items).
    public let node: FileNode?
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let oldSize: Int64
    public let newSize: Int64

    public var delta: Int64 { newSize - oldSize }
    public var id: String { path }

    public var kind: Kind {
        if oldSize == 0 { return .added }
        if newSize == 0 { return .removed }
        return delta > 0 ? .grew : .shrank
    }
}

/// Compares two scan trees (matched by name from a common root) and reports
/// what changed. Blame is attributed as deep as possible: a directory is
/// reported only when no single child crosses the threshold — otherwise the
/// changed children are reported instead. Unchanged subtrees are pruned by
/// their aggregate sizes, so the walk touches only changed regions.
public enum TreeDiff {
    public static func changes(from old: FileNode, to new: FileNode,
                               minDelta: Int64, limit: Int = 500) -> [TreeChange] {
        var results: [TreeChange] = []
        compare(old: old, new: new, into: &results, minDelta: max(1, minDelta))
        results.sort { abs($0.delta) > abs($1.delta) }
        if results.count > limit { results.removeLast(results.count - limit) }
        return results
    }

    private static func compare(old: FileNode, new: FileNode,
                                into results: inout [TreeChange], minDelta: Int64) {
        let delta = new.size - old.size
        guard abs(delta) >= minDelta else { return }
        guard old.isDirectory, new.isDirectory else {
            // A file changed (or a file was replaced by a directory or vice
            // versa) — report it here.
            results.append(TreeChange(node: new, path: new.path, name: new.name,
                                      isDirectory: new.isDirectory,
                                      oldSize: old.size, newSize: new.size))
            return
        }

        let oldByName = Dictionary(old.children.map { ($0.name, $0) },
                                   uniquingKeysWith: { a, _ in a })
        let newByName = Dictionary(new.children.map { ($0.name, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var blamedChild = false

        for (name, newChild) in newByName {
            if let oldChild = oldByName[name] {
                if abs(newChild.size - oldChild.size) >= minDelta {
                    compare(old: oldChild, new: newChild, into: &results, minDelta: minDelta)
                    blamedChild = true
                }
            } else if newChild.size >= minDelta {
                results.append(TreeChange(node: newChild, path: newChild.path,
                                          name: newChild.name,
                                          isDirectory: newChild.isDirectory,
                                          oldSize: 0, newSize: newChild.size))
                blamedChild = true
            }
        }
        for (name, oldChild) in oldByName where newByName[name] == nil {
            if oldChild.size >= minDelta {
                results.append(TreeChange(node: nil, path: new.path + "/" + name,
                                          name: name, isDirectory: oldChild.isDirectory,
                                          oldSize: oldChild.size, newSize: 0))
                blamedChild = true
            }
        }

        // The change is spread across entries too small to blame
        // individually: report the directory itself.
        if !blamedChild {
            results.append(TreeChange(node: new, path: new.path, name: new.name,
                                      isDirectory: true,
                                      oldSize: old.size, newSize: new.size))
        }
    }
}
