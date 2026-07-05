import SwiftUI
import DiskCore

struct TreemapTile: Identifiable {
    let id: ObjectIdentifier
    let node: FileNode
    let rect: CGRect
}

struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    @State private var hovered: FileNode?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let tiles = computeTiles(in: geo.size)
                canvas(tiles: tiles, size: geo.size)
                    .gesture(
                        ExclusiveGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                if let tile = hitTest(tiles, value.location) {
                                    model.drillDown(into: tile.node)
                                }
                            },
                            SpatialTapGesture(count: 1).onEnded { value in
                                if let tile = hitTest(tiles, value.location) {
                                    model.toggleMark(tile.node)
                                }
                            }
                        )
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverLocation = location
                            hovered = hitTest(tiles, location)?.node
                        case .ended:
                            hovered = nil
                        }
                    }
                    .contextMenu {
                        contextMenuItems(tiles: tiles)
                    }
            }
            statusBar
        }
    }

    private func computeTiles(in size: CGSize) -> [TreemapTile] {
        let children = node.children
        guard !children.isEmpty else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let rects = Treemap.layout(values: children.map { Double($0.size) }, in: bounds)
        return zip(children, rects).compactMap { child, rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return TreemapTile(id: ObjectIdentifier(child), node: child, rect: rect)
        }
    }

    private func hitTest(_ tiles: [TreemapTile], _ point: CGPoint) -> TreemapTile? {
        tiles.first { $0.rect.contains(point) }
    }

    private func canvas(tiles: [TreemapTile], size: CGSize) -> some View {
        let maxSize = node.children.first?.size ?? 1
        return Canvas { context, _ in
            for tile in tiles {
                let inset = tile.rect.insetBy(dx: 0.5, dy: 0.5)
                guard inset.width > 0, inset.height > 0 else { continue }
                let isMarked = model.isMarked(tile.node)
                let isHovered = hovered === tile.node

                var color = heatColor(size: tile.node.size, maxSize: maxSize,
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
                    context.stroke(shape, with: .color(.white), lineWidth: 2)
                }

                if inset.width > 60 && inset.height > 24 {
                    let name = tile.node.isDirectory ? tile.node.name + "/" : tile.node.name
                    var text = Text("\(name)\n\(Format.bytes(tile.node.size))")
                        .font(.system(size: 10, weight: .medium))
                    text = text.foregroundColor(.white)
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
    private func contextMenuItems(tiles: [TreemapTile]) -> some View {
        if let target = hovered {
            Button(model.isMarked(target) ? "Unmark \"\(target.name)\"" : "Mark \"\(target.name)\" for Trash") {
                model.toggleMark(target)
            }
            if target.isDirectory && !target.children.isEmpty {
                Button("Open \"\(target.name)\"") { model.drillDown(into: target) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let hovered {
                Text(hovered.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if node.size > 0 {
                    Text(String(format: "%.1f%%", Double(hovered.size) / Double(node.size) * 100))
                        .foregroundStyle(.secondary)
                }
                Text(Format.bytes(hovered.size))
                    .fontWeight(.semibold)
            } else {
                Text("Click to mark for trash · double-click to drill in · right-click for more")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
