import SwiftUI
import DiskCore

/// Flat list of what changed since the previous scan of this location —
/// blame attributed to the deepest responsible file or folder.
struct ChangesView: View {
    @EnvironmentObject var model: AppModel

    private static let detents: [Int64] = [
        10_000_000, 100_000_000, 1_000_000_000, 5_000_000_000, 20_000_000_000,
    ]

    @State private var detentIndex: Double = 0

    private var cutoff: Int64 {
        Self.detents[max(0, min(Self.detents.count - 1, Int(detentIndex.rounded())))]
    }

    var body: some View {
        if model.baselineDate == nil {
            VStack {
                Spacer()
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("First scan of this location.")
                    .foregroundStyle(.secondary)
                Text("Scan it again later and this view will show what grew, shrank, appeared, or vanished.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            let rows = model.changes(minDelta: cutoff)
            VStack(spacing: 0) {
                controls(count: rows.count)
                Divider()
                if rows.isEmpty {
                    VStack {
                        Spacer()
                        Text(model.isScanning
                             ? "Comparing as the scan runs…"
                             : "No changes of \(Format.bytes(cutoff)) or more since then.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(rows) { change in
                        changeRow(change)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func controls(count: Int) -> some View {
        HStack(spacing: 10) {
            if let date = model.baselineDate {
                Text("Since \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12, weight: .semibold))
            }
            if let net = model.netChange() {
                Text((net >= 0 ? "+" : "−") + Format.bytes(abs(net)) + " net")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(net > 0 ? Color.red : net < 0 ? Color.green : Color.secondary)
            }
            Text("≥ \(Format.bytes(cutoff))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(
                value: Binding(
                    get: { detentIndex },
                    set: { detentIndex = $0.rounded() }
                ),
                in: 0...Double(Self.detents.count - 1)
            )
            .focusable(false)
            .frame(maxWidth: 240)
            Spacer()
            Text(count == 500 ? "500+ changes" : "\(count) changes")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func changeRow(_ change: TreeChange) -> some View {
        let grewOrAdded = change.delta > 0
        HStack(spacing: 8) {
            Image(systemName: symbol(for: change.kind))
                .foregroundStyle(grewOrAdded ? Color.red : Color.green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.isDirectory ? change.name + "/" : change.name)
                    .lineLimit(1)
                Text(change.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text((grewOrAdded ? "+" : "−") + Format.bytes(abs(change.delta)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(grewOrAdded ? Color.red : Color.green)
                Text(detail(for: change))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            if let node = change.node {
                Button("Show in Map") { model.showInMap(node) }
                Button("Quick Look") { model.quickLook(node) }
                Divider()
            }
            Button("Copy Full Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            if change.kind != .removed {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: change.path)])
                }
            }
        }
    }

    private func symbol(for kind: TreeChange.Kind) -> String {
        switch kind {
        case .grew: return "arrow.up.circle.fill"
        case .shrank: return "arrow.down.circle.fill"
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        }
    }

    private func detail(for change: TreeChange) -> String {
        switch change.kind {
        case .added: return "new"
        case .removed: return "removed"
        case .grew, .shrank:
            return "was \(Format.bytes(change.oldSize)) · now \(Format.bytes(change.newSize))"
        }
    }
}
