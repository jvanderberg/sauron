import SwiftUI
import DiskCore

/// Flat list of the biggest files anywhere under the scan root, with a
/// log-scale cutoff slider. Marking integrates with the same trash queue
/// as the map.
struct LargestFilesView: View {
    @EnvironmentObject var model: AppModel

    /// log10(bytes): 6 = 1 MB … 10.3 ≈ 20 GB.
    @State private var sliderLog: Double = 8

    private var cutoff: Int64 { Int64(pow(10, sliderLog)) }

    var body: some View {
        let rows = model.largestFiles(minSize: cutoff)
        VStack(spacing: 0) {
            controls(count: rows.count)
            Divider()
            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text(model.isScanning
                         ? "Nothing this big found yet — still scanning…"
                         : "No files at or above \(Format.bytes(cutoff)).")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(rows, id: \.path) { row in
                    fileRow(row)
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            sliderLog = log10(Double(max(model.fileCutoff, 1_000_000)))
        }
        .onChange(of: sliderLog) { _ in
            model.fileCutoff = cutoff
        }
    }

    private func controls(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("Files ≥ \(Format.bytes(cutoff))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 130, alignment: .leading)
            Slider(value: $sliderLog, in: 6...10.3)
                .frame(maxWidth: 320)
            Spacer()
            Text(count == 500 ? "500+ files" : "\(count) files")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func fileRow(_ row: (node: FileNode, size: Int64, path: String)) -> some View {
        let marked = model.isMarked(row.node)
        HStack(spacing: 8) {
            Image(systemName: marked ? "trash.fill" : "doc.fill")
                .foregroundStyle(marked ? Color.red : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.node.name)
                    .lineLimit(1)
                Text(row.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(Format.bytes(row.size))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(marked ? .red : .primary)
            Button {
                model.toggleMark(row.node)
            } label: {
                Image(systemName: marked ? "arrow.uturn.backward.circle" : "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(marked ? Color.orange : Color.secondary)
            .help(marked ? "Unmark" : "Mark for Trash")
        }
        .listRowBackground(marked ? Color.red.opacity(0.10) : nil)
        .contextMenu {
            Button(marked ? "Unmark \"\(row.node.name)\"" : "Mark \"\(row.node.name)\" for Trash") {
                model.toggleMark(row.node)
            }
            Button("Show in Map") { model.showInMap(row.node) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            }
        }
    }
}
