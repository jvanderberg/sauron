import Foundation

/// The set of nodes the user has marked to move to the trash, with the total
/// space that trashing them would free. Marking a node whose ancestor is
/// already marked is rejected (the ancestor covers it); marking an ancestor
/// of already-marked nodes absorbs them.
public final class TrashQueue {
    public private(set) var items: [FileNode] = []

    public init() {}

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func contains(_ node: FileNode) -> Bool {
        items.contains { $0 === node }
    }

    /// True if the node itself or any of its ancestors is marked.
    public func covers(_ node: FileNode) -> Bool {
        items.contains { node.isDescendant(of: $0) }
    }

    @discardableResult
    public func add(_ node: FileNode) -> Bool {
        guard !covers(node) else { return false }
        items.removeAll { $0.isDescendant(of: node) }
        items.append(node)
        return true
    }

    public func remove(_ node: FileNode) {
        items.removeAll { $0 === node }
    }

    public func removeAll() {
        items.removeAll()
    }

    public func toggle(_ node: FileNode) {
        if contains(node) { remove(node) } else { add(node) }
    }
}

public enum TrashError: Error, CustomStringConvertible {
    case moveFailed(path: String, underlying: Error)
    case emptyFailed(String)

    public var description: String {
        switch self {
        case .moveFailed(let path, let err):
            return "could not trash \(path): \(err.localizedDescription)"
        case .emptyFailed(let msg):
            return "empty trash failed: \(msg)"
        }
    }
}

public enum Trasher {
    /// Move a file or directory to the trash. Returns the URL of the item in
    /// the trash (useful for tests that want to clean up after themselves).
    @discardableResult
    public static func moveToTrash(path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var resultURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
        } catch {
            throw TrashError.moveFailed(path: path, underlying: error)
        }
        return (resultURL as URL?) ?? url
    }

    /// Physical size of everything currently in the user's trash.
    public static func trashSize() -> Int64 {
        guard let trashURL = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return 0 }
        guard let result = try? Scanner.scan(path: trashURL.path) else { return 0 }
        return result.root.size
    }

    /// Empty the trash via Finder (the sanctioned route; triggers a one-time
    /// automation permission prompt). No-op if the trash is already empty.
    public static func emptyTrash() throws {
        if let trashURL = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: trashURL.path),
           contents.filter({ $0 != ".DS_Store" }).isEmpty {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw TrashError.emptyFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "osascript exited \(process.terminationStatus)"
            throw TrashError.emptyFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
