import SwiftUI
import DiskCore

@main
struct SauronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    init() {
        Self.headlessRenderIfRequested()
    }

    var body: some Scene {
        WindowGroup("Sauron — Disk Usage") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 500)
        }
    }
}

extension SauronApp {
    /// Headless UI smoke test: SAURON_RENDER=<path> [SAURON_RENDER_OUT=<png>]
    /// scans the path, renders the treemap offscreen, writes a PNG, and exits.
    /// Lets scripts verify the actual UI drawing without screen-capture
    /// permissions or a visible window.
    @MainActor
    static func headlessRenderIfRequested() {
        guard let scanPath = ProcessInfo.processInfo.environment["SAURON_RENDER"] else { return }
        let out = ProcessInfo.processInfo.environment["SAURON_RENDER_OUT"] ?? "/tmp/sauron-render.png"
        do {
            let result = try DiskCore.Scanner.scan(path: scanPath)
            let model = AppModel()
            model.root = result.root
            model.navigation = [result.root]
            // Mark the second-largest child so the render exercises the
            // marked-for-trash styling too.
            if result.root.children.count > 1 {
                model.toggleMark(result.root.children[1])
            }
            let view = TreemapView(node: result.root)
                .environmentObject(model)
                .frame(width: 900, height: 600)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("render: could not produce image\n".utf8))
                exit(2)
            }
            try png.write(to: URL(fileURLWithPath: out))
            print("rendered \(out)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// When launched from `swift run` (no app bundle) the process starts as a
/// background/accessory app; promote it so the window shows and gets focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
