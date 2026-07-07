import SwiftUI
import DiskCore
import CryptoKit

/// On-disk persistence of scans, one archive per scan root (keyed by a hash
/// of the canonical path). Nonisolated on purpose: used from detached tasks;
/// locking stays inside synchronous functions.
enum ScanStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.joshv.sauron", isDirectory: true)
        let scans = base.appendingPathComponent("scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        // Clean up the short-lived single-archive scheme.
        try? FileManager.default.removeItem(at: base.appendingPathComponent("last-scan.sauronscan"))
        return scans
    }()

    private static func url(for path: String) -> URL {
        let canonical = Paths.canonical(path)
        let hex = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(hex).sauronscan")
    }

    static func exists(for path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    static func savedDate(for path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: path).path))?[.modificationDate] as? Date
    }

    private static func previousURL(for path: String) -> URL {
        url(for: path).appendingPathExtension("prev")
    }

    typealias Loaded = (root: FileNode, scannedPath: String, date: Date, errorCount: Int)

    static func load(for path: String) -> Loaded? {
        load(from: url(for: path), matching: path)
    }

    /// The generation before the current archive — the Changes baseline.
    static func loadPrevious(for path: String) -> Loaded? {
        load(from: previousURL(for: path), matching: path)
    }

    private static func load(from url: URL, matching path: String) -> Loaded? {
        guard let loaded = try? ScanArchive.load(from: url),
              Paths.canonical(loaded.scannedPath) == Paths.canonical(path)
        else { return nil }
        return loaded
    }

    /// rotate: a completed scan starts a new generation — the old current
    /// archive becomes the Changes baseline. Incremental updates (trash
    /// operations, rescans) overwrite current in place so the baseline
    /// stays anchored to the last full scan.
    static func save(root: FileNode, scannedPath: String, errorCount: Int,
                     lock: NSLock, rotate: Bool) {
        // Hold the lock only for a filtered copy (~10% of nodes); the slow
        // part — serialize + compress — runs on the private copy so UI
        // reads never block behind it.
        lock.lock()
        let snapshot = root.filteredCopy(minFileSize: 1_000_000)
        lock.unlock()
        let current = url(for: scannedPath)
        if rotate, FileManager.default.fileExists(atPath: current.path) {
            let previous = previousURL(for: scannedPath)
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: current, to: previous)
        }
        try? ScanArchive.save(root: snapshot, scannedPath: scannedPath, date: Date(),
                              errorCount: errorCount, to: current, minFileSize: 0)
    }
}

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
    enum ViewMode: String, CaseIterable {
        case map
        case files
        case changes
    }
    // Scan state. The tree is rendered *while* the scan runs: the scanner
    // mutates it under `treeLock`, and all UI reads go through the
    // snapshot/size accessors below, which take the same lock.
    @Published var root: FileNode?
    @Published var isScanning = false
    @Published var isRescanning = false
    @Published var scanErrors = 0
    @Published var scanIssues: [ScanIssue] = []
    @Published var scannedPath = ""

    let scanProgress = ScanProgress()

    // Navigation: breadcrumb stack, root first. Empty when nothing scanned.
    @Published var navigation: [FileNode] = []

    // Map (treemap) vs Files (largest files) vs Changes (scan diff).
    @Published var viewMode: ViewMode = .map
    // Minimum size for the largest-files list; persisted across switches.
    @Published var fileCutoff: Int64 = 100_000_000

    // Baseline for the Changes view: the archive of this location as it was
    // BEFORE the current scan overwrote it.
    @Published var baselineDate: Date?
    private var baselineRoot: FileNode?
    private var baselineErrorCount = 0

    /// True when the baseline scan couldn't read substantially more folders
    /// than the current one — e.g. it predates a Full Disk Access grant, so
    /// now-readable items would show as "new" though nothing was added. A
    /// diff across such a gap is meaningless, so the Changes view suppresses
    /// it. -1 baseline errorCount = unknown (old archive) → treat as changed.
    var baselineAccessChanged: Bool {
        baselineErrorCount < 0 || baselineErrorCount > scanErrors + 25
    }

    // Selection (single click). Marking for trash is a separate, explicit act.
    @Published var selected: FileNode?

    // Trash queue
    @Published var markedItems: [FileNode] = []
    @Published var lastError: String?
    @Published var isTrashing = false

    // Quick Look target (spacebar / context menu).
    @Published var quickLookURL: URL?

    struct UpdateNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let downloadURL: String?
    }

    @Published var updateNotice: UpdateNotice?

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
    // Cancellation and liveness for the current scan. Token identity also
    // distinguishes a live scan from an abandoned (stalled) one: results
    // arriving with a stale token are ignored.
    private var scanToken: CancelToken?
    private var rescanToken: CancelToken?
    private var scanHeartbeat: ScanHeartbeat?
    private var stallTimer: Timer?
    private var stallRestarts = 0
    /// Directories that wedged a scan, learned at runtime and persisted —
    /// future scans record them as empty leaves instead of hanging.
    /// Editable in Settings (⌘,).
    @Published var autoSkippedDirs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "autoSkippedDirectories") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(autoSkippedDirs), forKey: "autoSkippedDirectories")
        }
    }

    /// Built-in skip rules (CloudStorage, autofs, sibling system volumes);
    /// off = scan absolutely everything. Takes effect on the next scan.
    @Published var hazardSkipsEnabled: Bool =
        UserDefaults.standard.object(forKey: "hazardSkipsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hazardSkipsEnabled, forKey: "hazardSkipsEnabled")
        }
    }
    private static let stallThreshold: TimeInterval = 30
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
            guard let self else { return }
            Task { @MainActor in self.refreshFreeSpace() }
        }
        RunLoop.main.add(timer, forMode: .common)
        freeSpaceTimer = timer
        // Quiet launch check; only speaks up if something newer exists.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.checkForUpdates(interactive: false)
        }
    }

    // MARK: - Updates

    func checkForUpdates(interactive: Bool) {
        guard let current = UpdateChecker.currentVersion else {
            if interactive {
                updateNotice = UpdateNotice(title: "Development Build",
                                            message: "This build has no version stamp to compare.",
                                            downloadURL: nil)
            }
            return
        }
        Task { @MainActor [weak self] in
            do {
                let latest = try await UpdateChecker.fetchLatest()
                guard let self else { return }
                if UpdateChecker.isNewer(latest.version, than: current) {
                    self.updateNotice = UpdateNotice(
                        title: "Sauron \(latest.version) is available",
                        message: "You have \(current). The new version is signed, notarized, and a small download.",
                        downloadURL: latest.url)
                } else if interactive {
                    self.updateNotice = UpdateNotice(
                        title: "You're up to date",
                        message: "Sauron \(current) is the latest release.",
                        downloadURL: nil)
                }
            } catch {
                if interactive {
                    self?.updateNotice = UpdateNotice(
                        title: "Couldn't check for updates",
                        message: error.localizedDescription,
                        downloadURL: nil)
                }
            }
        }
    }

    // MARK: - Persisted scans (one archive per scan root)

    /// Snapshot the current tree to disk (serialized under the tree lock).
    /// Called after completed scans and after any operation that changes it.
    private func persistScan(rotate: Bool = false) {
        guard let root, !isScanning, !isRescanning else { return }
        let path = scannedPath
        let lock = treeLock
        let errors = scanErrors
        Task.detached(priority: .utility) { [weak self] in
            ScanStore.save(root: root, scannedPath: path, errorCount: errors,
                           lock: lock, rotate: rotate)
            if rotate {
                // The slots moved; the baseline is now the old current.
                await MainActor.run { [weak self] in
                    guard let self, self.scannedPath == path else { return }
                    self.loadBaseline(for: path)
                }
            }
        }
    }

    /// After the trash is emptied, the scanned ~/.Trash contents are gone:
    /// zero that node so the map (and the persisted archive) reflect it.
    private func zeroTrashInTree() {
        guard let root else { return }
        treeLock.lock()
        let trashPath = NSHomeDirectory() + "/.Trash"
        if let node = Paths.find(trashPath, in: root), node.isDirectory {
            node.replaceContents(with: FileNode(name: node.name, isDirectory: true, size: 0))
        }
        treeLock.unlock()
        objectWillChange.send()
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
            scanToken?.cancel()
            return
        }
        stallRestarts = 0
        startScan(path: path)
    }

    private func startScan(path: String) {
        isScanning = true
        scanProgress.count = 0
        scanProgress.currentPath = ""
        scanErrors = 0
        scanIssues = []
        scannedPath = path
        selected = nil
        stashedMarkedPaths = trashQueue.items.map(\.path)
        markedItems = []
        trashQueue.removeAll()
        lastError = nil
        baselineRoot = nil
        baselineDate = nil
        startScanRefreshTimer()

        // Earlier results covering this path display immediately while the
        // fresh scan refreshes them: first from the in-memory cache, then
        // from the per-root archive saved in a previous session. The archive
        // additionally becomes the BASELINE the Changes view diffs against.
        if let cached = scanCache.lookup(path: path) {
            root = cached.node
            navigation = [cached.node]
            showingCached = true
            loadBaseline(for: path)
            launchScanTask(path: path)
        } else if ScanStore.exists(for: path) {
            root = nil
            navigation = []
            showingCached = false
            Task.detached(priority: .userInitiated) { [weak self] in
                let loaded = ScanStore.load(for: path)
                await MainActor.run { [weak self] in
                    guard let self, self.isScanning, self.scannedPath == path else { return }
                    if let loaded, self.root == nil {
                        self.root = loaded.root
                        self.navigation = [loaded.root]
                        self.showingCached = true
                        self.scanCache.store(root: loaded.root, path: loaded.scannedPath,
                                             complete: true, date: loaded.date)
                    }
                    self.loadBaseline(for: path)
                    self.launchScanTask(path: path)
                }
            }
        } else {
            root = nil
            navigation = []
            showingCached = false
            loadBaseline(for: path)
            launchScanTask(path: path)
        }
    }

    private func loadBaseline(for path: String) {
        Task.detached(priority: .utility) { [weak self] in
            // The previous generation is the baseline; before a rotation
            // exists (second-ever scan in flight), fall back to current.
            guard let loaded = ScanStore.loadPrevious(for: path) ?? ScanStore.load(for: path)
            else { return }
            await MainActor.run { [weak self] in
                guard let self, self.scannedPath == path else { return }
                self.baselineRoot = loaded.root
                self.baselineDate = loaded.date
                self.baselineErrorCount = loaded.errorCount
            }
        }
    }

    /// Exact net change since the baseline, from the root aggregates —
    /// independent of the per-entry threshold and list cap.
    func netChange() -> Int64? {
        guard let baselineRoot, let root else { return nil }
        treeLock.lock()
        defer { treeLock.unlock() }
        return root.size - baselineRoot.size
    }

    /// What changed since the baseline archive of this location. Computed on
    /// demand; unchanged subtrees prune by aggregate size, so this is cheap.
    func changes(minDelta: Int64) -> [TreeChange] {
        guard let baselineRoot, let root else { return [] }
        treeLock.lock()
        defer { treeLock.unlock() }
        return TreeDiff.changes(from: baselineRoot, to: root, minDelta: minDelta)
    }

    private func launchScanTask(path: String) {
        let token = CancelToken()
        let heartbeat = ScanHeartbeat()
        scanToken = token
        scanHeartbeat = heartbeat
        startStallWatchdog()
        let skips = autoSkippedDirs
        let hazardSkips = hazardSkipsEnabled

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lastUpdate = Date.distantPast
            do {
                let result = try DiskCore.Scanner.scan(
                    path: path,
                    lock: self.treeLock,
                    sortAtEnd: false,
                    skipHazards: hazardSkips,
                    skipPaths: skips,
                    heartbeat: heartbeat,
                    cancelToken: token,
                    onRootReady: { newRoot in
                        Task { @MainActor [weak self] in
                            guard let self, self.isScanning, self.scanToken === token,
                                  self.scannedPath == path,
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
                                guard let self, self.scanToken === token else { return }
                                self.scanProgress.count = count
                                self.scanProgress.currentPath = current
                            }
                        }
                        return true // cancellation flows through the token
                    }
                )
                await MainActor.run { [weak self] in
                    self?.completeScan(result: result, path: path, token: token)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.scanToken === token else { return }
                    self.lastError = "Scan failed: \(error)"
                    self.finishScan()
                }
            }
        }
    }

    func cancelScan() {
        scanToken?.cancel()
        rescanToken?.cancel()
    }

    // MARK: - Stall watchdog

    private func startStallWatchdog() {
        stallTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkForStall() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    /// A scan thread wedged inside an unresponsive directory (dead cloud
    /// provider, stale mount) blocks in the kernel where it can't be
    /// cancelled. When the heartbeat goes quiet: orphan that scan (its
    /// stale token makes its results ignorable), remember the guilty
    /// directory so future scans skip it, and restart.
    private func checkForStall() {
        guard isScanning, let heartbeat = scanHeartbeat, let token = scanToken else { return }
        let snap = heartbeat.snapshot
        guard Date().timeIntervalSince(snap.lastBeat) > Self.stallThreshold else { return }

        token.cancel()   // takes effect if the syscall ever returns
        scanToken = nil  // orphan: completion with this token is ignored

        guard stallRestarts < 3, !snap.directory.isEmpty else {
            lastError = "Scan stalled repeatedly (last inside \(snap.directory)); giving up. See Help → Permissions."
            finishScan()
            return
        }
        stallRestarts += 1
        autoSkippedDirs.insert(snap.directory)
        lastError = "Skipped a folder that stopped responding and restarted the scan:\n\(snap.directory)"

        // Fresh tree — the wedged thread may still mutate the old one if it
        // ever unblocks (mutations are lock-guarded, but the data is tainted).
        root = nil
        navigation = []
        showingCached = false
        selected = nil
        scanProgress.count = 0
        scanProgress.currentPath = ""
        launchScanTask(path: scannedPath)
    }

    private func completeScan(result: ScanResult, path: String, token: CancelToken) {
        // Results from an orphaned (stalled-and-replaced) scan: discard.
        guard scanToken === token else { return }
        scanProgress.count = result.entryCount
        scanErrors = result.errorCount
        scanIssues = result.issues
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
        // Restore marks against whatever tree we ended up with. Union the
        // paths stashed at scan start with anything marked DURING the scan
        // (while cached results were shown) — otherwise mid-scan marks are
        // dropped on completion. Marks whose paths vanished fall away.
        var order: [String] = []
        var seen = Set<String>()
        for p in stashedMarkedPaths + trashQueue.items.map(\.path) where seen.insert(p).inserted {
            order.append(p)
        }
        rebuildQueue(fromPaths: order)
        stashedMarkedPaths = []
        finishScan()
        if !result.cancelled { persistScan(rotate: true) }
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
        scanToken = nil
        scanHeartbeat = nil
        stallTimer?.invalidate()
        stallTimer = nil
        scanRefreshTimer?.invalidate()
        scanRefreshTimer = nil
        objectWillChange.send()
        if let pending = pendingScanPath {
            pendingScanPath = nil
            stallRestarts = 0
            startScan(path: pending)
        }
    }

    /// While a scan runs, republish at 0.5 Hz so the treemap re-reads the
    /// (growing) tree; the view animates each update.
    private func startScanRefreshTimer() {
        scanRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.objectWillChange.send() }
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
        let token = CancelToken()
        rescanToken = token
        scanProgress.count = 0
        scanProgress.currentPath = ""
        lastError = nil
        let path = node.path
        let markedPaths = trashQueue.items.map(\.path)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lastUpdate = Date.distantPast
            do {
                let result = try DiskCore.Scanner.scan(
                    path: path, sortAtEnd: false, cancelToken: token,
                    progress: { count, current in
                        let now = Date()
                        if now.timeIntervalSince(lastUpdate) > 0.1 {
                            lastUpdate = now
                            Task { @MainActor [weak self] in
                                self?.scanProgress.count = count
                                self?.scanProgress.currentPath = current
                            }
                        }
                        return true
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
                    self.persistScan()
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

    /// Largest files anywhere under the scan root, with paths captured
    /// under the tree lock (safe during a live scan).
    func largestFiles(minSize: Int64, limit: Int = 500) -> [(node: FileNode, size: Int64, path: String)] {
        guard let root else { return [] }
        treeLock.lock()
        defer { treeLock.unlock() }
        return root.largestFiles(minSize: minSize, limit: limit)
            .map { (node: $0, size: $0.size, path: $0.path) }
    }

    func pathString(of node: FileNode) -> String {
        treeLock.lock()
        defer { treeLock.unlock() }
        return node.path
    }

    /// Copy a node to the general pasteboard: as a file URL (pasteable in
    /// Finder) or as its full path string.
    func copyToPasteboard(_ node: FileNode, pathOnly: Bool) {
        let path = pathString(of: node)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pathOnly {
            pasteboard.setString(path, forType: .string)
        } else {
            pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        }
    }

    /// Jump from the files list to a file's location in the map.
    func showInMap(_ node: FileNode) {
        guard let parent = node.parent else { return }
        navigation = parent.ancestry
        selected = node
        viewMode = .map
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

    func quickLook(_ node: FileNode?) {
        guard let node else { return }
        quickLookURL = URL(fileURLWithPath: pathString(of: node))
    }

    /// Selection-operating actions for keyboard shortcuts. These read
    /// `selected` at INVOCATION time — a shortcut's registered action
    /// closure can go stale in SwiftUI, so it must never capture the node.
    func toggleMarkSelection() {
        guard let selected else { return }
        toggleMark(selected)
    }

    func quickLookSelection() {
        quickLook(selected)
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
                if !finalSucceeded.isEmpty { self.persistScan() }
            }
        }
    }

    /// Delete everything marked immediately and irreversibly — no Trash.
    /// The UI gates this behind an explicit, scary confirmation.
    func deleteMarkedPermanently() {
        guard !trashQueue.isEmpty, !isTrashing, !isRescanning else { return }
        isTrashing = true
        lastError = nil
        let items = trashQueue.items.map { (node: $0, path: $0.path) }

        Task.detached(priority: .userInitiated) { [weak self] in
            var succeeded: [FileNode] = []
            var errors: [String] = []
            for item in items {
                do {
                    try Trasher.deletePermanently(path: item.path)
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
                self.refreshFreeSpace()
                if !finalErrors.isEmpty {
                    self.lastError = finalErrors.joined(separator: "\n")
                }
                if !finalSucceeded.isEmpty { self.persistScan() }
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
                    // The scanned trash contents no longer exist; reflect
                    // that in the map and the persisted archive.
                    self.zeroTrashInTree()
                    self.persistScan()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "\(error)"
                }
            }
        }
    }
}
