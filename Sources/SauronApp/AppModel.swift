import SwiftUI
import DiskCore

/// High-frequency scan telemetry, deliberately separated from AppModel:
/// only the progress strip observes it, so its ~10Hz updates don't force
/// treemap re-renders. The map itself refreshes on AppModel's 0.5Hz tick.
@MainActor
final class ScanProgress: ObservableObject {
    @Published var count = 0
    @Published var currentPath = ""
}

@MainActor
final class AppModel: ObservableObject {
    // Scan state. The tree is rendered *while* the scan runs: the scanner
    // mutates it under `treeLock`, and all UI reads go through the
    // snapshot/size accessors below, which take the same lock.
    @Published var root: FileNode?
    @Published var isScanning = false
    @Published var isRescanning = false
    @Published var scanErrors = 0
    @Published var scannedPath = ""

    let scanProgress = ScanProgress()

    // Navigation: breadcrumb stack, root first. Empty when nothing scanned.
    @Published var navigation: [FileNode] = []

    // Selection (single click). Marking for trash is a separate, explicit act.
    @Published var selected: FileNode?

    // Trash queue
    @Published var markedItems: [FileNode] = []
    @Published var lastError: String?
    @Published var isTrashing = false

    // Free space, with optimistic bump after emptying the trash (the OS can
    // take a while to report reclaimed space).
    @Published var actualFreeSpace: Int64 = 0
    @Published var optimisticFreeSpace: Int64?
    // The optimistic figure only bridges the OS's reporting lag. It can
    // legitimately overshoot reality (APFS snapshots keep referencing
    // deleted blocks), so it expires instead of waiting forever for the
    // real number to catch up.
    private var optimisticExpiry: Date?

    // True while the map shows earlier (cached/partial) results and a fresh
    // scan is refreshing them in the background.
    @Published var showingCached = false

    let treeLock = NSLock()
    private let trashQueue = TrashQueue()
    private let scanCache = ScanCache()
    private var cancelRequested = false
    private var pendingScanPath: String?
    // Marked paths captured at scan start, re-resolved against the finished
    // tree so a same-path refresh doesn't wipe the trash list.
    private var stashedMarkedPaths: [String] = []
    private var freeSpaceTimer: Timer?
    private var scanRefreshTimer: Timer?

    var currentNode: FileNode? { navigation.last }

    var displayedFreeSpace: Int64 {
        max(actualFreeSpace, optimisticFreeSpace ?? 0)
    }

    init() {
        refreshFreeSpace()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFreeSpace() }
        }
        RunLoop.main.add(timer, forMode: .common)
        freeSpaceTimer = timer
    }

    // MARK: - Locked tree accessors (safe during a live scan)

    /// Children of a node with their sizes captured atomically, sorted
    /// largest-first. The single source the treemap renders from.
    func childrenSnapshot(of node: FileNode) -> [(node: FileNode, size: Int64)] {
        treeLock.lock()
        let pairs = node.children.map { (node: $0, size: $0.size) }
        treeLock.unlock()
        return pairs.sorted { $0.size > $1.size }
    }

    func size(of node: FileNode) -> Int64 {
        treeLock.lock()
        defer { treeLock.unlock() }
        return node.size
    }

    func hasChildren(_ node: FileNode) -> Bool {
        treeLock.lock()
        defer { treeLock.unlock() }
        return !node.children.isEmpty
    }

    var markedTotal: Int64 {
        treeLock.lock()
        defer { treeLock.unlock() }
        return trashQueue.totalSize
    }

    // MARK: - Scanning

    /// Start (or switch to) a scan. If one is already running it is
    /// cancelled, its partial tree is cached, and the new scan starts as
    /// soon as the cancellation lands.
    func scan(path: String) {
        if isScanning {
            pendingScanPath = path
            cancelRequested = true
            return
        }
        startScan(path: path)
    }

    private func startScan(path: String) {
        isScanning = true
        cancelRequested = false
        scanProgress.count = 0
        scanProgress.currentPath = ""
        scanErrors = 0
        scannedPath = path
        selected = nil
        stashedMarkedPaths = trashQueue.items.map(\.path)
        markedItems = []
        trashQueue.removeAll()
        lastError = nil

        // Earlier results covering this path (including the partial tree of
        // a scan the user just abandoned) display immediately; the fresh
        // scan refreshes them in the background.
        if let cached = scanCache.lookup(path: path) {
            root = cached.node
            navigation = [cached.node]
            showingCached = true
        } else {
            root = nil
            navigation = []
            showingCached = false
        }
        startScanRefreshTimer()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lastUpdate = Date.distantPast
            do {
                let result = try DiskCore.Scanner.scan(
                    path: path,
                    lock: self.treeLock,
                    onRootReady: { newRoot in
                        Task { @MainActor [weak self] in
                            guard let self, self.isScanning, self.scannedPath == path,
                                  !self.showingCached, self.root == nil else { return }
                            self.root = newRoot
                            self.navigation = [newRoot]
                        }
                    },
                    progress: { count, current in
                        let now = Date()
                        if now.timeIntervalSince(lastUpdate) > 0.1 {
                            lastUpdate = now
                            Task { @MainActor [weak self] in
                                self?.scanProgress.count = count
                                self?.scanProgress.currentPath = current
                            }
                        }
                        var cancelled = false
                        DispatchQueue.main.sync { cancelled = self.cancelRequested }
                        return !cancelled
                    }
                )
                await MainActor.run { [weak self] in
                    self?.completeScan(result: result, path: path)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Scan failed: \(error)"
                    self?.finishScan()
                }
            }
        }
    }

    func cancelScan() {
        cancelRequested = true
    }

    private func completeScan(result: ScanResult, path: String) {
        scanProgress.count = result.entryCount
        scanErrors = result.errorCount
        scanCache.store(root: result.root, path: path, complete: !result.cancelled)

        if showingCached {
            if result.cancelled {
                // The refresh was abandoned; keep showing the cached tree.
                showingCached = false
            } else {
                swapToFreshTree(result.root)
            }
        } else if root == nil {
            // onRootReady may not have landed for tiny scans.
            root = result.root
            navigation = [result.root]
        }
        // Restore marks (stashed at scan start) against whatever tree we
        // ended up with; marks whose paths vanished are dropped.
        rebuildQueue(fromPaths: stashedMarkedPaths)
        stashedMarkedPaths = []
        finishScan()
    }

    /// Replace the displayed (cached) tree with the freshly scanned one,
    /// carrying navigation and selection across by path.
    private func swapToFreshTree(_ freshRoot: FileNode) {
        let deepestNavPath = navigation.last?.path
        let selectedPath = selected?.path

        root = freshRoot
        navigation = [freshRoot]
        if let navPath = deepestNavPath, let node = Paths.find(navPath, in: freshRoot),
           node.isDirectory {
            navigation = node.ancestry
        }
        selected = selectedPath.flatMap { Paths.find($0, in: freshRoot) }
        showingCached = false
    }

    private func finishScan() {
        isScanning = false
        scanRefreshTimer?.invalidate()
        scanRefreshTimer = nil
        objectWillChange.send()
        if let pending = pendingScanPath {
            pendingScanPath = nil
            startScan(path: pending)
        }
    }

    /// While a scan runs, republish at 0.5 Hz so the treemap re-reads the
    /// (growing) tree; the view animates each update.
    private func startScanRefreshTimer() {
        scanRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scanRefreshTimer = timer
    }

    // MARK: - Subtree rescan

    /// Re-scan just the folder currently being viewed and splice the fresh
    /// result into the tree — cheap way to true-up numbers after deletions
    /// or external changes, without redoing the whole root.
    func rescanCurrent() {
        guard let node = currentNode, node.isDirectory, !isScanning, !isRescanning else { return }
        // Rescanning the scan root IS a full scan — route it through the
        // real thing so it gets the live map, progress strip, cancellation,
        // and cached display instead of a mute spinner for minutes.
        if node === root {
            scan(path: scannedPath)
            return
        }
        isRescanning = true
        cancelRequested = false
        scanProgress.count = 0
        scanProgress.currentPath = ""
        lastError = nil
        let path = node.path
        let markedPaths = trashQueue.items.map(\.path)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lastUpdate = Date.distantPast
            do {
                let result = try DiskCore.Scanner.scan(path: path, progress: { count, current in
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > 0.1 {
                        lastUpdate = now
                        Task { @MainActor [weak self] in
                            self?.scanProgress.count = count
                            self?.scanProgress.currentPath = current
                        }
                    }
                    var cancelled = false
                    DispatchQueue.main.sync { cancelled = self.cancelRequested }
                    return !cancelled
                })
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    defer { self.isRescanning = false }
                    // A cancelled rescan is discarded: splicing a partial
                    // tree in would understate sizes.
                    guard !result.cancelled else { return }
                    self.treeLock.lock()
                    node.replaceContents(with: result.root)
                    self.treeLock.unlock()
                    self.rebuildQueue(fromPaths: markedPaths)
                    self.selected = nil
                    self.objectWillChange.send()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Rescan failed: \(error)"
                    self?.isRescanning = false
                }
            }
        }
    }

    /// Marked nodes inside a rescanned subtree are stale objects; re-resolve
    /// every marked path against the current tree and drop the ones that no
    /// longer exist.
    private func rebuildQueue(fromPaths paths: [String]) {
        trashQueue.removeAll()
        if let root {
            treeLock.lock()
            let resolved = paths.compactMap { Paths.find($0, in: root) }
            treeLock.unlock()
            for node in resolved { trashQueue.add(node) }
        }
        markedItems = trashQueue.items
    }

    // MARK: - Navigation

    func drillDown(into node: FileNode) {
        // Only ever drill into a direct child of the current view — rejects
        // any stale node a UI layer might hand us.
        guard node.isDirectory, hasChildren(node), node.parent === navigation.last else { return }
        selected = nil
        navigation.append(node)
    }

    func navigate(to node: FileNode) {
        selected = nil
        navigation = node.ancestry
    }

    func navigateUp() {
        if navigation.count > 1 {
            selected = nil
            navigation.removeLast()
        }
    }

    // MARK: - Selection & trash queue

    func select(_ node: FileNode?) {
        selected = node
    }

    func isMarked(_ node: FileNode) -> Bool { trashQueue.covers(node) }

    func toggleMark(_ node: FileNode) {
        // Never the tree root, and never the top of the current view (which
        // can be a mid-tree node when displaying a cached subtree).
        guard !node.isRoot, node !== navigation.first else { return }
        trashQueue.toggle(node)
        markedItems = trashQueue.items
    }

    func unmark(_ node: FileNode) {
        trashQueue.remove(node)
        markedItems = trashQueue.items
    }

    func moveMarkedToTrash() {
        // Not during a rescan: the splice would resurrect just-trashed nodes.
        guard !trashQueue.isEmpty, !isTrashing, !isRescanning else { return }
        isTrashing = true
        lastError = nil
        let items = trashQueue.items.map { (node: $0, path: $0.path) }

        Task.detached(priority: .userInitiated) { [weak self] in
            var succeeded: [FileNode] = []
            var errors: [String] = []
            for item in items {
                do {
                    try Trasher.moveToTrash(path: item.path)
                    succeeded.append(item.node)
                } catch {
                    errors.append("\(error)")
                }
            }
            let finalSucceeded = succeeded
            let finalErrors = errors
            await MainActor.run { [weak self] in
                guard let self else { return }
                for node in finalSucceeded {
                    // If we're currently viewing inside a trashed directory,
                    // climb out before detaching it from the tree.
                    while let current = self.navigation.last, current.isDescendant(of: node) {
                        self.navigation.removeLast()
                    }
                    if let sel = self.selected, sel.isDescendant(of: node) {
                        self.selected = nil
                    }
                    self.trashQueue.remove(node)
                    self.treeLock.lock()
                    node.removeFromParent()
                    self.treeLock.unlock()
                }
                self.markedItems = self.trashQueue.items
                self.isTrashing = false
                if !finalErrors.isEmpty {
                    self.lastError = finalErrors.joined(separator: "\n")
                }
            }
        }
    }

    // MARK: - Free space / empty trash

    func refreshFreeSpace() {
        let free = Volume.freeSpace() ?? 0
        // Assign only on change: every @Published write re-renders all
        // observers, and this runs on a 5s timer.
        if actualFreeSpace != free { actualFreeSpace = free }
        if let optimistic = optimisticFreeSpace {
            let expired = optimisticExpiry.map { Date() > $0 } ?? true
            if free >= optimistic || expired {
                optimisticFreeSpace = nil
                optimisticExpiry = nil
            }
        }
    }

    func emptyTrash() {
        lastError = nil
        let baseline = actualFreeSpace
        Task.detached(priority: .userInitiated) { [weak self] in
            let trashSize = Trasher.trashSize()
            do {
                try Trasher.emptyTrash()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.optimisticFreeSpace = baseline + trashSize
                    self.optimisticExpiry = Date().addingTimeInterval(30)
                    self.refreshFreeSpace()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "\(error)"
                }
            }
        }
    }
}
