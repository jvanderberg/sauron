import XCTest
@testable import DiskCore

final class TrashQueueTests: XCTestCase {
    private func makeTree() -> (root: FileNode, dir: FileNode, fileA: FileNode, fileB: FileNode) {
        let root = FileNode(name: "/fake", isDirectory: true)
        let dir = FileNode(name: "dir", isDirectory: true, size: 300, parent: root)
        root.addChild(dir)
        let a = FileNode(name: "a.bin", isDirectory: false, size: 200, parent: dir)
        dir.addChild(a)
        let b = FileNode(name: "b.bin", isDirectory: false, size: 100, parent: dir)
        dir.addChild(b)
        root.size = 300
        return (root, dir, a, b)
    }

    func testAddRemoveAndTotal() {
        let (_, _, a, b) = makeTree()
        let queue = TrashQueue()
        queue.add(a)
        queue.add(b)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.totalSize, 300)
        queue.remove(a)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.totalSize, 100)
    }

    func testToggle() {
        let (_, _, a, _) = makeTree()
        let queue = TrashQueue()
        queue.toggle(a)
        XCTAssertTrue(queue.contains(a))
        queue.toggle(a)
        XCTAssertFalse(queue.contains(a))
    }

    func testMarkingAncestorAbsorbsDescendants() {
        let (_, dir, a, b) = makeTree()
        let queue = TrashQueue()
        queue.add(a)
        queue.add(b)
        XCTAssertEqual(queue.count, 2)
        // Marking the parent replaces both children — total is the dir, not 2x.
        queue.add(dir)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.totalSize, 300)
        XCTAssertTrue(queue.covers(a))
        XCTAssertFalse(queue.contains(a))
    }

    func testCannotMarkDescendantOfMarkedAncestor() {
        let (_, dir, a, _) = makeTree()
        let queue = TrashQueue()
        queue.add(dir)
        XCTAssertFalse(queue.add(a), "descendant of a marked dir must be rejected")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.totalSize, 300)
    }

    func testTrashRoundTripThroughRealTrash() throws {
        // End-to-end: create a real file, trash it, verify it left its origin,
        // then delete it from the trash so we don't litter.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-trash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim.bin")
        try Data(repeating: 1, count: 10_000).write(to: victim)

        let inTrash = try Trasher.moveToTrash(path: victim.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path))
        try FileManager.default.removeItem(at: inTrash)
    }

    func testDeletePermanentlyRemovesFilesAndDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-perm-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("nested/f.bin"))

        try Trasher.deletePermanently(path: dir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        XCTAssertThrowsError(try Trasher.deletePermanently(path: dir.path),
                             "deleting a missing path must throw")
    }

    func testMountedVolumesIncludesRoot() {
        let volumes = Volume.mountedVolumes()
        let root = volumes.first { $0.path == "/" }
        XCTAssertNotNil(root, "root volume must be listed")
        XCTAssertGreaterThan(root?.total ?? 0, 0)
        XCTAssertGreaterThanOrEqual(root?.usedFraction ?? -1, 0)
        XCTAssertLessThanOrEqual(root?.usedFraction ?? 2, 1)
    }

    func testFreeSpaceIsPositive() {
        let free = Volume.freeSpace()
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
    }
}
