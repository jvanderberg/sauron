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

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let tiles = computeTiles(in: geo.size)
                canvas(tiles: tiles)
                    .gesture(
                        ExclusiveGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                if let tile = hitTest(tiles, value.location) {
                                    model.drillDown(into: tile.node)
                                }
                            },
                            SpatialTapGesture(count: 1).onEnded { value in
                                model.select(hitTest(tiles, value.location)?.node)
                            }
                        )
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = hitTest(tiles, location)?.node
                        case .ended:
                            hovered = nil
                        }
                    }
                    .contextMenu {
                        contextMenuItems()
                    }
            }
            statusBar
        }
    }

    private func computeTiles(in size: CGSize) -> [TreemapTile] {
        let snapshot = model.childrenSnapshot(of: node)
        guard !snapshot.isEmpty else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let rects = Treemap.layout(values: snapshot.map { Double($0.size) }, in: bounds)
        return zip(snapshot, rects).compactMap { entry, rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return TreemapTile(id: ObjectIdentifier(entry.node), node: entry.node,
                               size: entry.size, rect: rect)
        }
    }

    private func hitTest(_ tiles: [TreemapTile], _ point: CGPoint) -> TreemapTile? {
        tiles.first { $0.rect.contains(point) }
    }

    private func canvas(tiles: [TreemapTile]) -> some View {
        let maxSize = tiles.first?.size ?? 1
        return Canvas { context, _ in
            for tile in tiles {
                let inset = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                guard inset.width > 0, inset.height > 0 else { continue }
                let isMarked = model.isMarked(tile.node)
                let isSelected = model.selected === tile.node
                let isHovered = hovered === tile.node

                var color = heatColor(size: tile.size, maxSize: maxSize,
                                      isDirectory: tile.node.isDirectory)
                if isMarked { color = Color(hue: 0, saturation: 0.85, brightness: 0.75) }
                let shape = Path(roundedRect: inset, cornerRadius: 2)
                context.fill(shape, with: .color(color))

                if isMarked {
                    // Diagonal hatching so marked tiles read as "condemned"
                    // even next to naturally hot (orange) tiles.
                    context.drawLayer { layer in
                        layer.clip(to: shape)
                        var hatch = Path()
                        var x = inset.minX - inset.height
                        while x < inset.maxX {
                            hatch.move(to: CGPoint(x: x, y: inset.maxY))
                            hatch.addLine(to: CGPoint(x: x + inset.height, y: inset.minY))
                            x += 10
                        }
                        layer.stroke(hatch, with: .color(.white.opacity(0.35)), lineWidth: 2)
                    }
                    context.stroke(shape, with: .color(.red), lineWidth: 2)
                }
                if isHovered {
                    context.stroke(shape, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }
                if isSelected {
                    context.stroke(shape, with: .color(.white), lineWidth: 3)
                }

                if inset.width > 60 && inset.height > 24 {
                    let name = tile.node.isDirectory ? tile.node.name + "/" : tile.node.name
                    let text = Text("\(name)\n\(Format.bytes(tile.size))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    context.draw(
                        context.resolve(text),
                        in: inset.insetBy(dx: 4, dy: 3)
                    )
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func contextMenuItems() -> some View {
        if let target = hovered ?? model.selected {
            Button(model.isMarked(target) ? "Unmark \"\(target.name)\"" : "Mark \"\(target.name)\" for Trash") {
                model.toggleMark(target)
            }
            if target.isDirectory && model.hasChildren(target) {
                Button("Open \"\(target.name)\"") { model.drillDown(into: target) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
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
