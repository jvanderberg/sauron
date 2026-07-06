import Foundation

public struct VolumeInfo: Identifiable {
    public let name: String
    public let path: String
    public let total: Int64
    public let free: Int64
    public let isInternal: Bool

    public var id: String { path }
    public var used: Int64 { max(0, total - free) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public enum Volume {
    /// All user-visible mounted volumes, root volume first.
    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }
        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }
            let free = freeSpace(at: url.path) ?? Int64(values.volumeAvailableCapacity ?? 0)
            volumes.append(VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Int64(total),
                free: free,
                isInternal: values.volumeIsInternal ?? false))
        }
        return volumes.sorted { $0.path.count < $1.path.count }
    }
}

extension Volume {
    /// Available capacity (bytes) of the volume containing `path`.
    /// Prefers the "important usage" figure — the one Finder shows — which
    /// includes purgeable space and responds promptly to emptying the trash;
    /// falls back to the plain figure if it's unavailable.
    public static func freeSpace(at path: String = NSHomeDirectory()) -> Int64? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity
        else { return nil }
        return Int64(capacity)
    }

    /// Total capacity (bytes) of the volume containing `path`.
    public static func totalSpace(at path: String = NSHomeDirectory()) -> Int64? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let capacity = values.volumeTotalCapacity
        else { return nil }
        return Int64(capacity)
    }
}

public enum Format {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    public static func bytes(_ n: Int64) -> String {
        formatter.string(fromByteCount: n)
    }
}
