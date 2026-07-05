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

    /// Owns the redraw timer so it dies with the view.
    private final class DisplayTimer {
        var timer: Timer?
        func stop() {
            timer?.invalidate()
            timer = nil
        }
        deinit { timer?.invalidate() }
    }

    @State private var hovered: FileNode?
    @State private var targets: [TreemapTile] = []
    @State private var origins: [ObjectIdentifier: CGRect] = [:]
    @State private var animStart = Date.distantPast
    @State private var lastSize = CGSize.zero
    @State private var duration: TimeInterval = 1.0
    @State private var lastNode: FileNode?
    @State private var animationTick = 0
    @State private var displayTimer = DisplayTimer()
    @State private var lastClickTime = Date.distantPast
    @State private var lastClickLocation = CGPoint.zero

    private static let maxTiles = 600
    /// Slow breathe for in-scan reflows; quick zoom for navigation.
    private static let reflowDuration: TimeInterval = 1.0
    private static let zoomDuration: TimeInterval = 0.3

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // Read the tick so timer-driven redraws invalidate this body.
                // Drawing always samples real time (Date()), and the ramp
                // clamps at its end — so even a missed redraw can never
                // freeze the map; the next one lands on the final layout.
                let _ = animationTick
                canvas(frames: displayedFrames(at: Date(), size: geo.size))
                .gesture(
                    // One handler for every click. An ExclusiveGesture(double,
                    // single) would delay the single tap ~300ms to rule out a
                    // double-click, during which ⌫ acts on the PREVIOUS
                    // selection. Here the first click selects instantly
                    // (Finder-style) and the second click drills. Double
                    // detection uses AppKit's clickCount with a manual
                    // time+distance fallback.
                    SpatialTapGesture(count: 1).onEnded { value in
                        let now = Date()
                        let sysClicks = NSApp.currentEvent?.clickCount ?? 1
                        let isDouble = sysClicks >= 2
                            || (now.timeIntervalSince(lastClickTime) < 0.45
                                && hypot(value.location.x - lastClickLocation.x,
                                         value.location.y - lastClickLocation.y) < 5)
                        lastClickTime = now
                        lastClickLocation = value.location
                        guard let frame = hitTest(at: value.location, size: geo.size) else {
                            if !isDouble { model.select(nil) }
                            return
                        }
                        if isDouble {
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
                    lastNode = node
                    relayout(size: geo.size, animated: false)
                }
                .onChange(of: geo.size) { newSize in
                    lastSize = newSize
                    relayout(size: newSize, animated: false)
                }
                .onChange(of: ObjectIdentifier(node)) { _ in
                    navigationRelayout(size: lastSize)
                }
                .onReceive(model.objectWillChange) { _ in
                    // objectWillChange fires before the mutation lands; read
                    // the new tree state on the next runloop turn.
                    DispatchQueue.main.async {
                        // Navigation transitions are handled (with zoom) by
                        // navigationRelayout; skip ticks that race it.
                        guard lastNode === model.currentNode else { return }
                        relayout(size: lastSize, animated: true)
                    }
                }
            }
            statusBar
        }
    }

    // MARK: - Layout & animation

    private func computeTargets(for node: FileNode, in size: CGSize) -> [TreemapTile] {
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
        // Handlers can run from closures captured by an earlier body
        // evaluation, where `node` is stale (one navigation behind). The
        // model is a class reference and always current — layout must key
        // off it, never the captured struct.
        let current = model.currentNode ?? node
        let newTargets = computeTargets(for: current, in: size)
        guard newTargets != targets else { return }
        if animated, !targets.isEmpty {
            // Current interpolated positions become the starting points, so
            // an update landing mid-animation continues smoothly.
            var current: [ObjectIdentifier: CGRect] = [:]
            for frame in interpolatedFrames(at: Date()) { current[frame.tile.id] = frame.rect }
            beginAnimation(to: newTargets, origins: current, duration: Self.reflowDuration)
        } else {
            setInstantly(newTargets)
        }
    }

    /// Zoom transition between navigation levels: drilling down expands the
    /// clicked tile's rect into the whole view; going up collapses the view
    /// back into the tile it lives in at the parent level.
    private func navigationRelayout(size: CGSize) {
        // Same staleness hazard as relayout(): resolve the level to display
        // from the model, not from the captured `node`.
        let current = model.currentNode ?? node
        let previous = lastNode
        lastNode = current
        hovered = nil
        let newTargets = computeTargets(for: current, in: size)
        guard let previous, previous !== current, !targets.isEmpty, !newTargets.isEmpty,
              size.width > 0, size.height > 0
        else {
            setInstantly(newTargets)
            return
        }

        if current.isDescendant(of: previous),
           let container = interpolatedFrames(at: Date())
               .first(where: { current.isDescendant(of: $0.tile.node) })?.rect {
            // Down: new level starts squeezed inside the clicked tile.
            var starts: [ObjectIdentifier: CGRect] = [:]
            for tile in newTargets { starts[tile.id] = squeeze(tile.rect, into: container, viewport: size) }
            beginAnimation(to: newTargets, origins: starts, duration: Self.zoomDuration)
        } else if previous.isDescendant(of: current),
                  let container = newTargets.first(where: { previous.isDescendant(of: $0.node) })?.rect {
            // Up: new level starts magnified so the tile we're leaving fills
            // the viewport, then settles to identity.
            var starts: [ObjectIdentifier: CGRect] = [:]
            for tile in newTargets { starts[tile.id] = magnify(tile.rect, from: container, viewport: size) }
            beginAnimation(to: newTargets, origins: starts, duration: Self.zoomDuration)
        } else {
            // Unrelated levels (new scan, cache swap): no zoom.
            setInstantly(newTargets)
        }
    }

    private func setInstantly(_ newTargets: [TreemapTile]) {
        displayTimer.stop()
        origins = [:]
        animStart = .distantPast
        targets = newTargets
        animationTick &+= 1
    }

    private func beginAnimation(to newTargets: [TreemapTile],
                                origins newOrigins: [ObjectIdentifier: CGRect],
                                duration newDuration: TimeInterval) {
        origins = newOrigins
        duration = newDuration
        animStart = Date()
        targets = newTargets
        // A plain repeating timer forces redraws for the transition window,
        // then invalidates itself. No pausable clock, no flag hand-off: the
        // draw path reads Date() directly, so state can't wedge.
        displayTimer.stop()
        let deadline = animStart.addingTimeInterval(newDuration + 0.1)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { timer in
            Task { @MainActor in animationTick &+= 1 }
            if Date() >= deadline { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer.timer = timer
    }

    /// Map a full-viewport rect down into `container` (drill-down start).
    private func squeeze(_ rect: CGRect, into container: CGRect, viewport: CGSize) -> CGRect {
        let sx = container.width / viewport.width
        let sy = container.height / viewport.height
        return CGRect(x: container.minX + rect.minX * sx,
                      y: container.minY + rect.minY * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }

    /// Scale the viewport up so `container` fills it (drill-up start).
    private func magnify(_ rect: CGRect, from container: CGRect, viewport: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0 else { return rect }
        let sx = viewport.width / container.width
        let sy = viewport.height / container.height
        return CGRect(x: (rect.minX - container.minX) * sx,
                      y: (rect.minY - container.minY) * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }

    private func interpolatedFrames(at date: Date) -> [TileFrame] {
        let raw = date.timeIntervalSince(animStart) / max(duration, 0.001)
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
            return computeTargets(for: model.currentNode ?? node, in: size)
                .map { TileFrame(tile: $0, rect: $0.rect, opacity: 1) }
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
