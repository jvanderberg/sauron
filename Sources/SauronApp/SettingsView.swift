import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Skip system folders and cloud storage", isOn: $model.hazardSkipsEnabled)
                Text("Cloud placeholders take no real disk space, and reading them can hang the scan. Scanning one of these folders directly always works. Applies to the next scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Scanning")
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
    }
}
