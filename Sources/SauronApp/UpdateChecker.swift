import Foundation

/// Checks the GitHub releases feed for a newer version.
enum UpdateChecker {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/jvanderberg/sauron/releases/latest")!

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    /// nil when running unbundled (swift run) — no version to compare.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func fetchLatest() async throws -> (version: String, url: String) {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        return (version, release.html_url)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
