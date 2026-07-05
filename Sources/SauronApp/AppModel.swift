import SwiftUI
import DiskCore

@MainActor
final class AppModel: ObservableObject {
    // Scan state
    @Published var root: FileNode?
    @Published var isScanning = false
    @Published var scanCount = 0
    @Published var scanCurrentPath = ""
    @Published var scanErrors = 0
    @Published var scannedPath = ""

    // Navigation: breadcrumb stack, root first. Empty when nothing scanned.
    @Published var navigation: [FileNode] = []

    // Trash queue
    @Published var markedItems: [FileNode] = []
    @Published var lastError: String?
    @Published var isTrashing = false

    // Free space, with optimistic bump after emptying the trash (the OS can
    // take a while to report reclaimed space).
    @Published var actualFreeSpace: Int64 = 0
    @Published var optimisticFreeSpace: Int64?

    private let trashQueue = TrashQueue()
    private var cancelRequested = false
    private var freeSpaceTimer: Timer?

    var currentNode: FileNode? { navigation.last }

    var markedTotal: Int64 { trashQueue.totalSize }

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

    // MARK: - Scanning

    func scan(path: String) {
        guard !isScanning else { return }
        isScanning = true
        cancelRequested = false
        scanCount = 0
        scanErrors = 0
        scannedPath = path
        root = nil
        navigation = []
        markedItems = []
        trashQueue.removeAll()
        lastError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            var lastUpdate = Date.distantPast
            do {
                let result = try Scanner.scan(path: path) { count, current in
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > 0.1 {
                        lastUpdate = now
                        Task { @MainActor [weak self] in
                            self?.scanCount = count
                            self?.scanCurrentPath = current
                        }
                    }
                    var cancelled = false
                    DispatchQueue.main.sync { cancelled = self?.cancelRequested ?? true }
                    return !cancelled
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.root = result.root
                    self.navigation = [result.root]
                    self.scanCount = result.entryCount
                    self.scanErrors = result.errorCount
                    self.isScanning = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Scan failed: \(error)"
                    self?.isScanning = false
                }
            }
        }
    }

    func cancelScan() {
        cancelRequested = true
    }

    // MARK: - Navigation

    func drillDown(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        navigation.append(node)
    }

    func navigate(to node: FileNode) {
        navigation = node.ancestry
    }

    func navigateUp() {
        if navigation.count > 1 { navigation.removeLast() }
    }

    // MARK: - Trash queue

    func isMarked(_ node: FileNode) -> Bool { trashQueue.covers(node) }

    func toggleMark(_ node: FileNode) {
        guard !node.isRoot else { return }
        trashQueue.toggle(node)
        markedItems = trashQueue.items
    }

    func unmark(_ node: FileNode) {
        trashQueue.remove(node)
        markedItems = trashQueue.items
    }

    func moveMarkedToTrash() {
        guard !trashQueue.isEmpty, !isTrashing else { return }
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
                    self.trashQueue.remove(node)
                    node.removeFromParent()
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
        actualFreeSpace = free
        if let optimistic = optimisticFreeSpace, free >= optimistic {
            optimisticFreeSpace = nil
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
