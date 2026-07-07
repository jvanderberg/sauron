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

    @FocusState private var mapFocused: Bool
    @State private var hovered: FileNode?
    @State private var targets: [TreemapTile] = []
    @State private var origins: [ObjectIdentifier: CGRect] = [:]
    @State private var animStart = Date.distantPast
    @State private var lastSize = CGSize.zero
    @State private var duration: TimeInterval = 1.0
    @State private var easeOutMode = false

    /// The outgoing level during a navigation zoom, driven through the same
    /// transform so the map reads as one continuous surface: drilling down,
    /// the old level magnifies off-screen around the expanding target;
    /// going up, it shrinks back into its parent tile.
    private struct Ghost {
        let tile: TreemapTile
        let start: CGRect
        let end: CGRect
    }
    @State private var ghosts: [Ghost] = []
    @State private var ghostsAbove = false
    @State private var ghostsFade = false
    @State private var ghostMaxSize: Int64 = 1
    @State private var isAnimating = false
    @State private var lastNode: FileNode?
    @State private var lastClickTime = Date.distantPast
    @State private var lastClickLocation = CGPoint.zero

    private static let maxTiles = 600
    /// Slow breathe for in-scan reflows; quick zoom for navigation.
    private static let reflowDuration: TimeInterval = 1.0
    private static let zoomDuration: TimeInterval = 0.3

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // Display-link-synced frames (up to 120Hz on ProMotion),
                // running only while a transition is in flight. Safe even if
                // the pause wedges: the eased ramp clamps at t=1, so any
                // frame drawn at any later date shows the final layout.
                TimelineView(.animation(minimumInterval: nil, paused: !isAnimating)) { timeline in
                    canvas(frames: displayedFrames(at: timeline.date, size: geo.size),
                           ghosts: ghostFrames(at: timeline.date),
                           settled: !isAnimating
                               || timeline.date.timeIntervalSince(animStart) >= duration)
                }
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
                        mapFocused = true
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
                .focusable()
                .focusEffectDisabled()
                .focused($mapFocused)
                .overlay {
                    if mapFocused {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: mapFocused) { _, focused in
                    if focused, model.selected == nil {
                        selectLargest()
                    }
                }
                .onKeyPress { press in
                    handleKey(press.key)
                }
                .onAppear {
                    lastSize = geo.size
                    lastNode = node
                    relayout(size: geo.size, animated: false)
                }
                .onChange(of: geo.size) { _, newSize in
                    lastSize = newSize
                    relayout(size: newSize, animated: false)
                }
                .onChange(of: ObjectIdentifier(node)) { _, _ in
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

    // MARK: - Keyboard navigation

    private func selectLargest() {
        // Targets are sorted largest-first.
        if let largest = targets.first {
            model.select(largest.node)
        }
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .upArrow: return moveSelection(dx: 0, dy: -1)
        case .downArrow: return moveSelection(dx: 0, dy: 1)
        case .leftArrow: return moveSelection(dx: -1, dy: 0)
        case .rightArrow: return moveSelection(dx: 1, dy: 0)
        case .return:
            guard let selected = model.selected else { return .ignored }
            if selected.isDirectory, model.hasChildren(selected) {
                model.drillDown(into: selected)
                DispatchQueue.main.async { selectLargest() }
            } else {
                model.quickLook(selected)
            }
            return .handled
        case .escape:
            guard model.navigation.count > 1 else { return .ignored }
            let leaving = model.currentNode
            model.navigateUp()
            // Land on the tile we just climbed out of.
            DispatchQueue.main.async {
                if let leaving { model.select(leaving) } else { selectLargest() }
            }
            return .handled
        default:
            return .ignored
        }
    }

    /// Spatial move: nearest tile whose center lies in the pressed direction,
    /// preferring straight-ahead over lateral drift.
    private func moveSelection(dx: CGFloat, dy: CGFloat) -> KeyPress.Result {
        guard let selected = model.selected,
              let currentTile = targets.first(where: { $0.node === selected }) else {
            selectLargest()
            return .handled
        }
        let from = CGPoint(x: currentTile.rect.midX, y: currentTile.rect.midY)
        var best: (tile: TreemapTile, score: CGFloat)?
        for tile in targets where tile.node !== selected {
            let to = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
            let vx = to.x - from.x
            let vy = to.y - from.y
            let forward = vx * dx + vy * dy
            guard forward > 0.5 else { continue }
            let lateral = abs(vx * dy) + abs(vy * dx)
            let score = forward + 2.5 * lateral
            if best == nil || score < best!.score {
                best = (tile, score)
            }
        }
        if let best {
            model.select(best.tile.node)
        }
        return .handled
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
            // an update landing mid-animation continues smoothly. Ease-out:
            // reflows retarget every 2s during scans, and restarting an
            // ease-IN curve each time reads as a visible pulse.
            var current: [ObjectIdentifier: CGRect] = [:]
            for frame in interpolatedFrames(at: Date()) { current[frame.tile.id] = frame.rect }
            beginAnimation(to: newTargets, origins: current,
                           duration: Self.reflowDuration, easeOut: true)
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

        let outgoing = interpolatedFrames(at: Date())
        let outgoingMax = targets.first?.size ?? 1

        if current.isDescendant(of: previous),
           let container = outgoing
               .first(where: { current.isDescendant(of: $0.tile.node) })?.rect {
            // Down: new level starts squeezed inside the clicked tile; the
            // old level magnifies outward through the same transform and
            // slides off-screen beneath it.
            var starts: [ObjectIdentifier: CGRect] = [:]
            for tile in newTargets { starts[tile.id] = squeeze(tile.rect, into: container, viewport: size) }
            beginAnimation(to: newTargets, origins: starts,
                           duration: Self.zoomDuration, easeOut: false)
            ghosts = outgoing.map {
                Ghost(tile: $0.tile, start: $0.rect,
                      end: magnify($0.rect, from: container, viewport: size))
            }
            ghostsAbove = false
            ghostsFade = false
            ghostMaxSize = outgoingMax
        } else if previous.isDescendant(of: current),
                  let container = newTargets.first(where: { previous.isDescendant(of: $0.node) })?.rect {
            // Up: new level starts magnified so the tile we're leaving fills
            // the viewport; the old level shrinks back into that tile on top.
            var starts: [ObjectIdentifier: CGRect] = [:]
            for tile in newTargets { starts[tile.id] = magnify(tile.rect, from: container, viewport: size) }
            beginAnimation(to: newTargets, origins: starts,
                           duration: Self.zoomDuration, easeOut: false)
            ghosts = outgoing.map {
                Ghost(tile: $0.tile, start: $0.rect,
                      end: squeeze($0.rect, into: container, viewport: size))
            }
            ghostsAbove = true
            ghostsFade = true
            ghostMaxSize = outgoingMax
        } else {
            // Unrelated levels (new scan, cache swap): no zoom.
            setInstantly(newTargets)
        }
    }

    private func ghostFrames(at date: Date) -> [TileFrame] {
        guard !ghosts.isEmpty else { return [] }
        let raw = date.timeIntervalSince(animStart) / max(duration, 0.001)
        let t = max(0, min(1, raw))
        guard t < 1 else { return [] }
        let eased = t * t * (3 - 2 * t)
        let opacity = ghostsFade ? Double(1 - eased) : 1
        return ghosts.map {
            TileFrame(tile: $0.tile, rect: lerp($0.start, $0.end, eased), opacity: opacity)
        }
    }

    private func setInstantly(_ newTargets: [TreemapTile]) {
        origins = [:]
        ghosts = []
        animStart = .distantPast
        targets = newTargets
        isAnimating = false
    }

    private func beginAnimation(to newTargets: [TreemapTile],
                                origins newOrigins: [ObjectIdentifier: CGRect],
                                duration newDuration: TimeInterval,
                                easeOut: Bool) {
        // Callers that want ghosts (navigation zooms) assign them after.
        ghosts = []
        origins = newOrigins
        duration = newDuration
        easeOutMode = easeOut
        animStart = Date()
        targets = newTargets
        isAnimating = true
        // Unpause window ends shortly after the ramp completes. If a newer
        // animation restarted the clock meanwhile, its own deadline governs.
        DispatchQueue.main.asyncAfter(deadline: .now() + newDuration + 0.05) {
            if Date().timeIntervalSince(animStart) >= newDuration {
                isAnimating = false
            }
        }
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
        let eased = easeOutMode ? 1 - (1 - t) * (1 - t) : t * t * (3 - 2 * t)
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

    private func canvas(frames: [TileFrame], ghosts ghostFrames: [TileFrame],
                        settled: Bool) -> some View {
        let maxSize = frames.map(\.tile.size).max() ?? 1
        // Text resolution is the most expensive part of a frame; while tiles
        // are in motion, label only the big ones (small moving text is
        // unreadable anyway) so 120Hz stays cheap.
        let labelWidth: CGFloat = settled ? 60 : 110
        let labelHeight: CGFloat = settled ? 24 : 44
        return Canvas { context, _ in
            if !ghostsAbove {
                drawGhosts(ghostFrames, in: context, labelWidth: labelWidth, labelHeight: labelHeight)
            }
            for frame in frames {
                let inset = frame.rect.insetBy(dx: 0.5, dy: 0.5)
                guard inset.width > 0, inset.height > 0 else { continue }
                let tile = frame.tile
                let isMarked = model.isMarked(tile.node)
                let isSelected = model.selected === tile.node
                let isHovered = hovered === tile.node

                var (top, bottom) = isMarked
                    ? (Color(hue: 0, saturation: 0.78, brightness: 0.82),
                       Color(hue: 0, saturation: 0.90, brightness: 0.66))
                    : heatColors(size: tile.size, maxSize: maxSize, isDirectory: tile.node.isDirectory)
                if frame.opacity < 1 {
                    top = top.opacity(frame.opacity)
                    bottom = bottom.opacity(frame.opacity)
                }
                let shape = Path(roundedRect: inset, cornerRadius: 2)
                // Subtle top-lit gradient for texture instead of a flat fill.
                context.fill(shape, with: .linearGradient(
                    Gradient(colors: [top, bottom]),
                    startPoint: CGPoint(x: inset.midX, y: inset.minY),
                    endPoint: CGPoint(x: inset.midX, y: inset.maxY)))

                if isMarked {
                    // Diagonal hatching so marked tiles read as "condemned"
                    // even next to naturally hot (orange) tiles. A clipped
                    // copy of the context avoids a per-tile offscreen layer.
                    var clipped = context
                    clipped.clip(to: shape)
                    var hatch = Path()
                    var x = inset.minX - inset.height
                    while x < inset.maxX {
                        hatch.move(to: CGPoint(x: x, y: inset.maxY))
                        hatch.addLine(to: CGPoint(x: x + inset.height, y: inset.minY))
                        x += 10
                    }
                    clipped.stroke(hatch, with: .color(.white.opacity(0.35)), lineWidth: 2)
                    context.stroke(shape, with: .color(.red), lineWidth: 2)
                }
                if isSelected {
                    context.stroke(shape, with: .color(.white), lineWidth: 3)
                } else if isHovered {
                    context.stroke(shape, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }

                if inset.width > labelWidth, inset.height > labelHeight, frame.opacity == 1 {
                    let name = tile.node.isDirectory ? tile.node.name + "/" : tile.node.name
                    let text = Text("\(name)\n\(Format.bytes(tile.size))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    context.draw(context.resolve(text), in: inset.insetBy(dx: 4, dy: 3))
                }
            }
            if ghostsAbove {
                drawGhosts(ghostFrames, in: context, labelWidth: labelWidth, labelHeight: labelHeight)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// The outgoing level during a navigation zoom: fills and labels only —
    /// no selection, hover, or hatch decoration, and never hit-testable.
    private func drawGhosts(_ ghostFrames: [TileFrame], in context: GraphicsContext,
                            labelWidth: CGFloat, labelHeight: CGFloat) {
        for frame in ghostFrames {
            let inset = frame.rect.insetBy(dx: 0.5, dy: 0.5)
            guard inset.width > 0, inset.height > 0 else { continue }
            var (top, bottom) = heatColors(size: frame.tile.size, maxSize: ghostMaxSize,
                                           isDirectory: frame.tile.node.isDirectory)
            if frame.opacity < 1 {
                top = top.opacity(frame.opacity)
                bottom = bottom.opacity(frame.opacity)
            }
            let shape = Path(roundedRect: inset, cornerRadius: 2)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [top, bottom]),
                startPoint: CGPoint(x: inset.midX, y: inset.minY),
                endPoint: CGPoint(x: inset.midX, y: inset.maxY)))
            if inset.width > labelWidth, inset.height > labelHeight, frame.opacity > 0.5 {
                let name = frame.tile.node.isDirectory ? frame.tile.node.name + "/" : frame.tile.node.name
                let text = Text("\(name)\n\(Format.bytes(frame.tile.size))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(frame.opacity))
                context.draw(context.resolve(text), in: inset.insetBy(dx: 4, dy: 3))
            }
        }
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
            Button("Quick Look") { model.quickLook(target) }
            Divider()
            Button("Copy") { model.copyToPasteboard(target, pathOnly: false) }
            Button("Copy Full Path") { model.copyToPasteboard(target, pathOnly: true) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.pathString(of: target))])
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
                // Actions resolve the selection at keypress time via the
                // model — a captured node can be stale when the shortcut
                // fires (SwiftUI may keep the old registered action when
                // only the closure changed), which marked the WRONG tile.
                // .id() additionally forces re-registration per selection.
                Button {
                    model.quickLookSelection()
                } label: {
                    Image(systemName: "eye")
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.small)
                .help("Quick Look (Space)")
                .id("ql-\(ObjectIdentifier(selected))")
                Button(model.isMarked(selected)
                       ? "Unmark  ⌫"
                       : "Mark for Trash  ⌫") {
                    model.toggleMarkSelection()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .controlSize(.small)
                .help(model.isMarked(selected)
                      ? "Remove the selected item from the trash list (⌫)"
                      : "Add the selected item to the trash list (⌫)")
                .id("mark-\(ObjectIdentifier(selected))")
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
    /// marked for the trash. Returns a light/dark pair for the top-lit
    /// gradient fill.
    private func heatColors(size: Int64, maxSize: Int64, isDirectory: Bool) -> (Color, Color) {
        let fraction = maxSize > 0 ? Double(size) / Double(maxSize) : 0
        let t = fraction.squareRoot()
        let hue = 0.62 - 0.54 * t
        let saturation = isDirectory ? 0.65 : 0.45
        let brightness = isDirectory ? 0.80 : 0.70
        return (Color(hue: hue, saturation: max(0, saturation - 0.06),
                      brightness: min(1, brightness + 0.07)),
                Color(hue: hue, saturation: min(1, saturation + 0.05),
                      brightness: max(0, brightness - 0.06)))
    }
}
