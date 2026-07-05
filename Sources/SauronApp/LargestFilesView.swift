import SwiftUI
import DiskCore

/// Flat list of the biggest files anywhere under the scan root, with a
/// log-scale cutoff slider. Marking integrates with the same trash queue
/// as the map.
struct LargestFilesView: View {
    @EnvironmentObject var model: AppModel

    /// Snap points for the cutoff slider.
    private static let detents: [Int64] = [
        10_000_000,          // 10 MB
        100_000_000,         // 100 MB
        1_000_000_000,       // 1 GB
        5_000_000_000,       // 5 GB
        20_000_000_000,      // 20 GB
        100_000_000_000,     // 100 GB
        500_000_000_000,     // 500 GB
    ]

    @State private var detentIndex: Double = 1

    private var cutoff: Int64 {
        Self.detents[max(0, min(Self.detents.count - 1, Int(detentIndex.rounded())))]
    }

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
            // Nearest detent to the persisted cutoff.
            let nearest = Self.detents.enumerated().min {
                abs($0.element - model.fileCutoff) < abs($1.element - model.fileCutoff)
            }
            detentIndex = Double(nearest?.offset ?? 1)
        }
        .onChange(of: detentIndex) { _ in
            model.fileCutoff = cutoff
        }
    }

    private func controls(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("Files ≥ \(Format.bytes(cutoff))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 130, alignment: .leading)
            // Quantize in the binding rather than using step: — stepped
            // NSSliders get the flat tick-marked track that looks disabled.
            Slider(
                value: Binding(
                    get: { detentIndex },
                    set: { detentIndex = $0.rounded() }
                ),
                in: 0...Double(Self.detents.count - 1)
            ) {
                EmptyView()
            } minimumValueLabel: {
                Text("10 MB").font(.system(size: 9)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("500 GB").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 340)
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
