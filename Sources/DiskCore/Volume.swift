import Foundation

public enum Volume {
    /// Available capacity (bytes) of the volume containing `path`.
    public static func freeSpace(at path: String = NSHomeDirectory()) -> Int64? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
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
