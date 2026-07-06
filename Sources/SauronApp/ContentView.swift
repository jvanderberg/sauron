import SwiftUI
import DiskCore
import UniformTypeIdentifiers
import QuickLook

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

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
            .overlay {
                if isDropTargeted {
                    ZStack {
                        Color.accentColor.opacity(0.08)
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(6)
                        Label("Drop to scan", systemImage: "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .allowsHitTesting(false)
                }
            }
            // Drop a folder anywhere in the pane to scan it. The drop
            // modifier must be OUTSIDE the overlay: otherwise the highlight
            // that appears on dragEntered sits above the drop target and
            // swallows the drop itself.
            .onDrop(of: [UTType.fileURL],
                    delegate: ScanDropDelegate(model: model, isTargeted: $isDropTargeted))

            TrashPanel()
        }
        .quickLookPreview($model.quickLookURL)
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
        .focusable(false)
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
        VStack(spacing: 26) {
            Spacer()
            Text("Where did the space go?")
                .font(.title2.bold())
            HStack(spacing: 16) {
                scanChoice("house", "Scan Home",
                           "Your user folder — downloads, projects, caches, and everything else you own.") {
                    model.scan(path: NSHomeDirectory())
                }
                scanChoice("internaldrive", "Scan Disk",
                           "The whole startup disk (Data volume) — everything user-writable on this Mac.") {
                    model.scan(path: "/System/Volumes/Data")
                }
                scanChoice("folder", "Scan a Folder…",
                           "Pick any folder to analyze just that corner of the disk.") {
                    chooseFolder()
                }
            }
            Label("…or drop a folder anywhere in this window",
                  systemImage: "square.and.arrow.down")
                .font(.callout)
                .foregroundStyle(.secondary)
            volumeList
            Text("Sizes are physical (allocated) bytes — sparse files show their real footprint.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var volumeList: some View {
        let volumes = Volume.mountedVolumes()
        if !volumes.isEmpty {
            VStack(spacing: 6) {
                ForEach(volumes) { volume in
                    Button {
                        // "/" is the sealed system volume; the user's data
                        // lives on the Data volume.
                        model.scan(path: volume.path == "/" ? "/System/Volumes/Data" : volume.path)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(volume.name)
                                .frame(width: 140, alignment: .leading)
                                .lineLimit(1)
                            ProgressView(value: volume.usedFraction)
                                .tint(volume.usedFraction > 0.9 ? .red : .accentColor)
                                .frame(width: 180)
                            Text("\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 170, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Scan \(volume.name)")
                }
            }
        }
    }

    private func scanChoice(_ symbol: String, _ title: String, _ detail: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 190, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
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

/// Drop a folder (or file — its parent is used) to start scanning it.
/// A DropDelegate rather than the closure form so entered/exited/perform
/// all manage the highlight state explicitly — no stuck overlays.
struct ScanDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [UTType.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path,
                                                     isDirectory: &isDirectory) else { return }
                model.scan(path: isDirectory.boolValue
                           ? url.path
                           : url.deletingLastPathComponent().path)
            }
        }
        return true
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
