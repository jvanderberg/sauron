import SwiftUI
import DiskCore

struct TreemapTile: Equatable {
    let id: ObjectIdentifier
    let node: FileNode
    let size: Int64
    let rect: CGRect

    static func == (lhs: TreemapTile, rhs: TreemapTile) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.rect == rhs.rect
    }
}

/// A tile with its on-screen rect at one instant (possibly mid-animation).
struct TileFrame {
    let tile: TreemapTile
    let rect: CGRect
    let opacity: Double
}

/// Animated treemap drawn as a single Canvas.
///
/// The layout animation is interpolated manually (origins → targets with an
/// eased ramp) and BOTH drawing and hit-testing read the same interpolated
/// frames. This is deliberate: with per-tile SwiftUI views, gesture targets
/// live in the view hierarchy where interrupted transitions can strand
/// invisible-but-clickable ghosts, and hit-testing tracks model geometry
/// while pixels lag behind — either way, what you click isn't what you see.
/// Here a click resolves against the rects that were just drawn, always.
struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    @State private var hovered: FileNode?
    @State private var targets: [TreemapTile] = []
    @State private var origins: [ObjectIdentifier: CGRect] = [:]
    @State private var animStart = Date.distantPast
    @State private var isAnimating = false
    @State private var lastSize = CGSize.zero

    private static let maxTiles = 600
    private static let animDuration: TimeInterval = 1.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { timeline in
                    canvas(frames: displayedFrames(at: timeline.date, size: geo.size))
                }
                .gesture(
                    // One handler for every click, disambiguated by AppKit's
                    // click count. An ExclusiveGesture(double, single) would
                    // delay the single tap ~300ms to rule out a double-click,
                    // during which ⌫ acts on the PREVIOUS selection. Here the
                    // first click selects instantly (Finder-style) and the
                    // second click of a double-click drills.
                    SpatialTapGesture(count: 1).onEnded { value in
                        let clicks = NSApp.currentEvent?.clickCount ?? 1
                        guard let frame = hitTest(at: value.location, size: geo.size) else {
                            if clicks == 1 { model.select(nil) }
                            return
                        }
                        if clicks >= 2 {
                            model.drillDown(into: frame.tile.node)
                        } else {
                            model.select(frame.tile.node)
                        }
                    }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hovered = hitTest(at: location, size: geo.size)?.tile.node
                    case .ended:
                        hovered = nil
                    }
                }
                .contextMenu { contextMenuItems() }
                .onAppear {
                    lastSize = geo.size
                    relayout(size: geo.size, animated: false)
                }
                .onChange(of: geo.size) { newSize in
                    lastSize = newSize
                    relayout(size: newSize, animated: false)
                }
                .onReceive(model.objectWillChange) { _ in
                    // objectWillChange fires before the mutation lands; read
                    // the new tree state on the next runloop turn.
                    DispatchQueue.main.async { relayout(size: lastSize, animated: true) }
                }
            }
            statusBar
        }
    }

    // MARK: - Layout & animation

    private func computeTargets(in size: CGSize) -> [TreemapTile] {
        guard size.width > 0, size.height > 0 else { return [] }
        let snapshot = model.childrenSnapshot(of: node)
        guard !snapshot.isEmpty else { return [] }
        let rects = Treemap.layout(values: snapshot.map { Double($0.size) },
                                   in: CGRect(origin: .zero, size: size))
        var tiles: [TreemapTile] = []
        for (entry, rect) in zip(snapshot, rects) {
            guard rect.width >= 1.5, rect.height >= 1.5 else { continue }
            tiles.append(TreemapTile(id: ObjectIdentifier(entry.node), node: entry.node,
                                     size: entry.size, rect: rect))
            if tiles.count >= Self.maxTiles { break }
        }
        return tiles
    }

    private func relayout(size: CGSize, animated: Bool) {
        let newTargets = computeTargets(in: size)
        guard newTargets != targets else { return }
        if animated, !targets.isEmpty {
            let now = Date()
            // Current interpolated positions become the starting points, so
            // an update landing mid-animation continues smoothly.
            var current: [ObjectIdentifier: CGRect] = [:]
            for frame in interpolatedFrames(at: now) { current[frame.tile.id] = frame.rect }
            origins = current
            animStart = now
            targets = newTargets
            isAnimating = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animDuration + 0.05) {
                if Date().timeIntervalSince(animStart) >= Self.animDuration {
                    isAnimating = false
                }
            }
        } else {
            origins = [:]
            animStart = .distantPast
            targets = newTargets
            isAnimating = false
        }
    }

    private func interpolatedFrames(at date: Date) -> [TileFrame] {
        let raw = date.timeIntervalSince(animStart) / Self.animDuration
        let t = max(0, min(1, raw))
        let eased = t * t * (3 - 2 * t)
        return targets.map { tile in
            if let origin = origins[tile.id] {
                return TileFrame(tile: tile, rect: lerp(origin, tile.rect, eased), opacity: 1)
            }
            // Tile newly crossed the visibility threshold: fade in, in place.
            return TileFrame(tile: tile, rect: tile.rect, opacity: origins.isEmpty ? 1 : eased)
        }
    }

    /// Frames to draw right now. Falls back to a direct layout when state is
    /// empty (first frame, or offscreen rendering where onAppear never ran).
    private func displayedFrames(at date: Date, size: CGSize) -> [TileFrame] {
        if targets.isEmpty {
            return computeTargets(in: size).map { TileFrame(tile: $0, rect: $0.rect, opacity: 1) }
        }
        return interpolatedFrames(at: date)
    }

    /// Resolve a point against the frames as displayed at this instant —
    /// the same source the canvas draws from. Later frames draw on top,
    /// so search from the end.
    private func hitTest(at point: CGPoint, size: CGSize) -> TileFrame? {
        displayedFrames(at: Date(), size: size).last { $0.rect.contains(point) }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    // MARK: - Drawing

    private func canvas(frames: [TileFrame]) -> some View {
        let maxSize = frames.map(\.tile.size).max() ?? 1
        return Canvas { context, _ in
            for frame in frames {
                let inset = frame.rect.insetBy(dx: 0.5, dy: 0.5)
                guard inset.width > 0, inset.height > 0 else { continue }
                let tile = frame.tile
                let isMarked = model.isMarked(tile.node)
                let isSelected = model.selected === tile.node
                let isHovered = hovered === tile.node

                var color = isMarked
                    ? Color(hue: 0, saturation: 0.85, brightness: 0.75)
                    : heatColor(size: tile.size, maxSize: maxSize, isDirectory: tile.node.isDirectory)
                if frame.opacity < 1 { color = color.opacity(frame.opacity) }
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
                if isSelected {
                    context.stroke(shape, with: .color(.white), lineWidth: 3)
                } else if isHovered {
                    context.stroke(shape, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }

                if inset.width > 60, inset.height > 24, frame.opacity == 1 {
                    let name = tile.node.isDirectory ? tile.node.name + "/" : tile.node.name
                    let text = Text("\(name)\n\(Format.bytes(tile.size))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    context.draw(context.resolve(text), in: inset.insetBy(dx: 4, dy: 3))
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Menus & status

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
