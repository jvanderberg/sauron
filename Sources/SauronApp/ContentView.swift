import SwiftUI
import DiskCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// "/System/Volumes/Data" is where all user-writable data on the startup
    /// disk actually lives; show a human name instead of the firmlink path.
    /// Only that literal path gets the label — a "/" scan is a different
    /// tree (the sealed system volume) and must not be mislabeled.
    private func friendlyName(_ path: String) -> String {
        Paths.canonical(path) == "/System/Volumes/Data" ? "Startup Disk (Data volume)" : path
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let current = model.currentNode {
                    if model.viewMode == .map {
                        breadcrumbs
                        Divider()
                    }
                    if model.isScanning || model.isRescanning {
                        ScanProgressStrip(progress: model.scanProgress, mode: stripMode)
                    }
                    if model.viewMode == .map {
                        TreemapView(node: current)
                    } else {
                        LargestFilesView()
                    }
                } else if model.isScanning {
                    ScanStartingView(progress: model.scanProgress)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 600, minHeight: 400)

            TrashPanel()
        }
        .onAppear {
            // Lets tests/scripts drive the UI: SAURON_SCAN=/path swift run SauronApp
            if let path = ProcessInfo.processInfo.environment["SAURON_SCAN"],
               model.root == nil, !model.isScanning {
                model.scan(path: path)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton("house", help: "Scan your home folder") {
                model.scan(path: NSHomeDirectory())
            }
            toolbarButton("internaldrive", help: "Scan the startup disk — the APFS Data volume, everything user-writable") {
                model.scan(path: "/System/Volumes/Data")
            }
            toolbarButton("folder", help: "Choose a folder to scan…") {
                chooseFolder()
            }
            Divider().frame(height: 16)
            Group {
                if model.isRescanning {
                    ProgressView().controlSize(.small)
                        .frame(width: 30, height: 24)
                } else {
                    toolbarButton("arrow.clockwise", help: "Rescan the folder currently shown (fast — only this subtree)") {
                        model.rescanCurrent()
                    }
                    .disabled(model.currentNode == nil || model.isScanning)
                }
            }
            if model.isScanning || model.isRescanning {
                toolbarButton("xmark.circle.fill", help: "Cancel the scan") {
                    model.cancelScan()
                }
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)
            Picker("", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(AppModel.ViewMode.map)
                    .help("Treemap")
                Image(systemName: "list.bullet").tag(AppModel.ViewMode.files)
                    .help("Largest files")
            }
            .pickerStyle(.segmented)
            .frame(width: 88)
            .disabled(model.currentNode == nil)
            .help("Switch between the treemap and the largest-files list")
            Spacer()
            if let root = model.root, !model.isScanning {
                Text("\(Format.bytes(model.size(of: root))) in \(friendlyName(model.scannedPath))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.scanErrors > 0 {
                    Text("\(model.scanErrors) unreadable")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help("Some directories could not be read — grant Full Disk Access for complete results")
                }
            }
            toolbarButton("questionmark.circle", help: "Sauron Help (⌘?)") {
                openWindow(id: "help")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func toolbarButton(_ symbol: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button {
                model.navigateUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(model.navigation.count <= 1)
            .help("Up one level")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.navigation.enumerated()), id: \.offset) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.navigate(to: node)
                        } label: {
                            Text(index == 0 ? friendlyName(node.path) : node.name)
                                .fontWeight(index == model.navigation.count - 1 ? .semibold : .regular)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.navigation.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if let current = model.currentNode {
                Text(Format.bytes(model.size(of: current)))
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var stripMode: ScanProgressStrip.Mode {
        if model.isRescanning { return .rescanning }
        return model.showingCached ? .refreshing : .scanning
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Scan a location to see where your disk space went.")
                .foregroundStyle(.secondary)
            Text("Sizes are physical (allocated) bytes — sparse files show their real footprint.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(path: url.path)
        }
    }
}

/// Shown above the (live, growing) treemap while a scan is in flight.
/// Observes ScanProgress directly so its ~10Hz counter updates don't
/// re-render the treemap (which refreshes on the model's 0.5Hz tick).
struct ScanProgressStrip: View {
    enum Mode { case scanning, refreshing, rescanning }

    @ObservedObject var progress: ScanProgress
    let mode: Mode

    private var title: String {
        switch mode {
        case .scanning: return "Scanning · \(progress.count.formatted()) items"
        case .refreshing: return "Refreshing · \(progress.count.formatted()) items"
        case .rescanning: return "Rescanning · \(progress.count.formatted()) items"
        }
    }

    private var trailing: String {
        switch mode {
        case .scanning: return "map updates live"
        case .refreshing: return "showing earlier results"
        case .rescanning: return "updates when finished"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // Monospaced digits in a fixed-width slot: the growing count
            // must not push the path around every 100ms.
            Text(title)
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)
            Text(progress.currentPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// Full-pane progress while a scan hasn't produced a root node yet.
private struct ScanStartingView: View {
    @ObservedObject var progress: ScanProgress

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Scanned \(progress.count.formatted()) items…")
                .font(.headline)
            Text(progress.currentPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 500)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
