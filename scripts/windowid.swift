// Print the CGWindow ID of the first on-screen window owned by the named app.
// Usage: swift scripts/windowid.swift SauronApp
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sauron"
guard let list = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else { exit(1) }

for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner.contains(target),
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          (bounds["Height"] as? Double ?? 0) > 100
    else { continue }
    print(number)
    exit(0)
}
exit(1)
