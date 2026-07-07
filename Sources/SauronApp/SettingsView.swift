import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSkipInfo = false
    @State private var hasFullDiskAccess = SettingsView.checkFullDiskAccess()

    /// TCC-protected even for the owning user: readable only with FDA.
    static func checkFullDiskAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(
            atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.hazardSkipsEnabled) {
                    HStack(spacing: 5) {
                        Text("Skip system folders and cloud storage")
                        Button {
                            showSkipInfo = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("Show exactly which locations are skipped")
                        .popover(isPresented: $showSkipInfo, arrowEdge: .trailing) {
                            skipInfo
                        }
                    }
                }
                Text("Cloud placeholders take no real disk space, and reading them can hang the scan. Scanning one of these folders directly always works. Applies to the next scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Scanning")
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hasFullDiskAccess ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(hasFullDiskAccess
                         ? "Full Disk Access granted"
                         : "Full Disk Access not granted — some folders will show as unreadable")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Open System Settings…") {
                        Self.openFullDiskAccessSettings()
                    }
                    .controlSize(.small)
                }
                if !hasFullDiskAccess {
                    Text("In System Settings, add Sauron under Privacy & Security → Full Disk Access, then quit and reopen Sauron.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Permissions")
            }

            Section {
                if model.autoSkippedDirs.isEmpty {
                    Text("None. When a scan stalls inside an unresponsive folder, it is recorded here and skipped from then on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.autoSkippedDirs.sorted(), id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                model.autoSkippedDirs.remove(path)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Stop skipping this folder")
                        }
                    }
                    Button("Clear All") {
                        model.autoSkippedDirs.removeAll()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Folders skipped after stalls")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 300)
        .onAppear { hasFullDiskAccess = Self.checkFullDiskAccess() }
    }

    private var skipInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Locations skipped during scans")
                .font(.headline)
            skipRow("~/Library/CloudStorage",
                    "Dropbox, OneDrive, Google Drive and other cloud providers. Their placeholder files occupy no real disk space, and reading them requires the provider to respond — a hung provider freezes the scan.")
            skipRow("/Volumes",
                    "Mount points for external and network disks. Scan an external disk from its row on the welcome screen instead; a disconnected network mount here can hang the scan.")
            skipRow("/home and /net",
                    "Network automount triggers — merely reading them can start a network mount attempt.")
            skipRow("/System/Volumes (except Data)",
                    "Sealed system volumes: Recovery, Preboot, VM (swap), Update. System plumbing that isn't yours to clean up.")
            Divider()
            Text("Folders listed under “skipped after stalls” are also skipped. Scanning any skipped location directly (Scan Folder… or drag & drop) always works.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 440)
    }

    private func skipRow(_ path: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
