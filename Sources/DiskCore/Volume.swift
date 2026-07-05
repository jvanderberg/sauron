import Foundation

public enum Volume {
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
