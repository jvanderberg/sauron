import SwiftUI
import DiskCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if model.isScanning {
                    scanningView
                } else if let current = model.currentNode {
                    breadcrumbs
                    Divider()
                    TreemapView(node: current)
                        .id(ObjectIdentifier(current))
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
        HStack(spacing: 10) {
            Button("Scan Home") { model.scan(path: NSHomeDirectory()) }
            Button("Scan Disk") { model.scan(path: "/System/Volumes/Data") }
                .help("Scans the APFS Data volume — everything user-writable on the startup disk")
            Button("Scan Folder…") { chooseFolder() }
            if model.isScanning {
                Button("Cancel") { model.cancelScan() }
            }
            Spacer()
            if let root = model.root, !model.isScanning {
                Text("\(Format.bytes(root.size)) in \(model.scannedPath)")
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
        }
        .padding(10)
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
                            Text(index == 0 ? node.name : node.name)
                                .fontWeight(index == model.navigation.count - 1 ? .semibold : .regular)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.navigation.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if let current = model.currentNode {
                Text(Format.bytes(current.size))
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Scanned \(model.scanCount.formatted()) items…")
                .font(.headline)
            Text(model.scanCurrentPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 500)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
