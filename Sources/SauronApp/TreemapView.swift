import SwiftUI
import DiskCore

struct TreemapTile: Identifiable {
    let id: ObjectIdentifier
    let node: FileNode
    let size: Int64
    let rect: CGRect
}

struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    @State private var hovered: FileNode?

    /// More tiles than this are invisible slivers anyway; keeping the view
    /// count bounded keeps animated updates cheap.
    private static let maxTiles = 600
    private let tileAnimation = Animation.easeInOut(duration: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let tiles = computeTiles(in: geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { tile in
                        tileView(tile, maxSize: tiles.first?.size ?? 1)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(Color(nsColor: .underPageBackgroundColor))
                // Drives insert/remove transitions when the set of tiles
                // changes between scan refreshes.
                .animation(tileAnimation, value: tiles.map(\.id))
            }
            .clipped()
            statusBar
        }
    }

    private func computeTiles(in size: CGSize) -> [TreemapTile] {
        let snapshot = model.childrenSnapshot(of: node)
        guard !snapshot.isEmpty else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let rects = Treemap.layout(values: snapshot.map { Double($0.size) }, in: bounds)
        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(min(snapshot.count, Self.maxTiles))
        for (entry, rect) in zip(snapshot, rects) {
            guard rect.width >= 1.5, rect.height >= 1.5 else { continue }
            tiles.append(TreemapTile(id: ObjectIdentifier(entry.node), node: entry.node,
                                     size: entry.size, rect: rect))
            if tiles.count >= Self.maxTiles { break }
        }
        return tiles
    }

    @ViewBuilder
    private func tileView(_ tile: TreemapTile, maxSize: Int64) -> some View {
        let inset = tile.rect.insetBy(dx: 0.5, dy: 0.5)
        let isMarked = model.isMarked(tile.node)
        TileBody(
            name: tile.node.isDirectory ? tile.node.name + "/" : tile.node.name,
            sizeText: Format.bytes(tile.size),
            color: isMarked
                ? Color(hue: 0, saturation: 0.85, brightness: 0.75)
                : heatColor(size: tile.size, maxSize: maxSize, isDirectory: tile.node.isDirectory),
            isMarked: isMarked,
            isSelected: model.selected === tile.node,
            isHovered: hovered === tile.node,
            showLabel: inset.width > 60 && inset.height > 24
        )
        .frame(width: max(inset.width, 1), height: max(inset.height, 1))
        .position(x: inset.midX, y: inset.midY)
        .animation(tileAnimation, value: tile.rect)
        .transition(.opacity)
        .onHover { inside in
            if inside {
                hovered = tile.node
            } else if hovered === tile.node {
                hovered = nil
            }
        }
        .gesture(
            ExclusiveGesture(
                TapGesture(count: 2).onEnded { model.drillDown(into: tile.node) },
                TapGesture(count: 1).onEnded { model.select(tile.node) }
            )
        )
        .contextMenu {
            Button(isMarked ? "Unmark \"\(tile.node.name)\"" : "Mark \"\(tile.node.name)\" for Trash") {
                model.toggleMark(tile.node)
            }
            if tile.node.isDirectory && model.hasChildren(tile.node) {
                Button("Open \"\(tile.node.name)\"") { model.drillDown(into: tile.node) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tile.node.path)])
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let subject = hovered ?? model.selected {
                Text(subject.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let parentSize = model.size(of: node)
                if parentSize > 0 {
                    Text(String(format: "%.1f%%", Double(model.size(of: subject)) / Double(parentSize) * 100))
                        .foregroundStyle(.secondary)
                }
                Text(Format.bytes(model.size(of: subject)))
                    .fontWeight(.semibold)
            } else {
                Text("Click to select · double-click to open · right-click for more")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let selected = model.selected {
                Button(model.isMarked(selected)
                       ? "Unmark  ⌫"
                       : "Mark for Trash  ⌫") {
                    model.toggleMark(selected)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(.bar)
    }

    /// Blue (small) → orange (large) heat scale on a sqrt ramp so mid-sized
    /// items are still distinguishable. Pure red is reserved for tiles
    /// marked for the trash.
    private func heatColor(size: Int64, maxSize: Int64, isDirectory: Bool) -> Color {
        let fraction = maxSize > 0 ? Double(size) / Double(maxSize) : 0
        let t = fraction.squareRoot()
        let hue = 0.62 - 0.54 * t
        return Color(hue: hue, saturation: isDirectory ? 0.65 : 0.45,
                     brightness: isDirectory ? 0.80 : 0.70)
    }
}

/// A single treemap tile. Kept dumb (all state passed in) so SwiftUI can
/// animate frame/position/color changes cheaply.
private struct TileBody: View {
    let name: String
    let sizeText: String
    let color: Color
    let isMarked: Bool
    let isSelected: Bool
    let isHovered: Bool
    let showLabel: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(color)

            if isMarked {
                // Diagonal hatching so marked tiles read as "condemned"
                // even next to naturally hot (orange) tiles.
                Canvas { context, size in
                    var hatch = Path()
                    var x = -size.height
                    while x < size.width {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 10
                    }
                    context.stroke(hatch, with: .color(.white.opacity(0.35)), lineWidth: 2)
                }
                .allowsHitTesting(false)
            }

            if showLabel {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).lineLimit(1)
                    Text(sizeText)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay {
            if isMarked {
                RoundedRectangle(cornerRadius: 2).stroke(Color.red, lineWidth: 2)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 3)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.7), lineWidth: 1.5)
            }
        }
    }
}
