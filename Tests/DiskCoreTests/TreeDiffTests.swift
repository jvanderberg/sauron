import XCTest
@testable import DiskCore

final class TreeDiffTests: XCTestCase {
    /// Build a tree from (name, size, children) tuples.
    private func dir(_ name: String, _ children: [FileNode], parent: FileNode? = nil) -> FileNode {
        let node = FileNode(name: name, isDirectory: true,
                            size: children.reduce(0) { $0 + $1.size }, parent: parent)
        for child in children {
            child.setParentForTest(node)
            node.addChild(child)
        }
        return node
    }

    private func file(_ name: String, _ size: Int64) -> FileNode {
        FileNode(name: name, isDirectory: false, size: size)
    }

    func testBlamesTheDeepestChangedFile() {
        let old = dir("/r", [dir("a", [file("big.bin", 100), file("same.bin", 50)]),
                             dir("b", [file("stable.bin", 500)])])
        let new = dir("/r", [dir("a", [file("big.bin", 400), file("same.bin", 50)]),
                             dir("b", [file("stable.bin", 500)])])

        let changes = TreeDiff.changes(from: old, to: new, minDelta: 100)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].name, "big.bin")
        XCTAssertEqual(changes[0].delta, 300)
        XCTAssertEqual(changes[0].kind, .grew)
        XCTAssertTrue(changes[0].path.hasSuffix("/r/a/big.bin"))
    }

    func testAddedAndRemovedSubtrees() {
        let old = dir("/r", [dir("gone", [file("x.bin", 900)]),
                             file("keep.bin", 100)])
        let new = dir("/r", [dir("fresh", [file("y.bin", 700)]),
                             file("keep.bin", 100)])

        let changes = TreeDiff.changes(from: old, to: new, minDelta: 100)
        XCTAssertEqual(changes.count, 2)
        let added = changes.first { $0.kind == .added }
        let removed = changes.first { $0.kind == .removed }
        XCTAssertEqual(added?.name, "fresh")
        XCTAssertEqual(added?.delta, 700)
        XCTAssertNotNil(added?.node)
        XCTAssertEqual(removed?.name, "gone")
        XCTAssertEqual(removed?.delta, -900)
        XCTAssertNil(removed?.node)
    }

    func testManySmallChangesBlameTheDirectory() {
        let old = dir("/r", [dir("cache", (0..<10).map { file("f\($0).bin", 10) })])
        let new = dir("/r", [dir("cache", (0..<10).map { file("f\($0).bin", 40) })])

        // Each file grew by 30 (< 100), but the dir grew by 300.
        let changes = TreeDiff.changes(from: old, to: new, minDelta: 100)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].name, "cache")
        XCTAssertTrue(changes[0].isDirectory)
        XCTAssertEqual(changes[0].delta, 300)
    }

    func testUnchangedTreesProduceNothingAndOrderingHolds() {
        let old = dir("/r", [file("a.bin", 100), file("b.bin", 1_000), file("c.bin", 10)])
        XCTAssertTrue(TreeDiff.changes(from: old, to: old, minDelta: 1).isEmpty)

        let new = dir("/r", [file("a.bin", 400), file("b.bin", 100), file("c.bin", 10)])
        let changes = TreeDiff.changes(from: old, to: new, minDelta: 100)
        XCTAssertEqual(changes.map(\.name), ["b.bin", "a.bin"], "sorted by |delta| descending")
        XCTAssertEqual(changes[0].kind, .shrank)
    }

    func testLimitCaps() {
        let old = dir("/r", (0..<20).map { file("f\($0).bin", 10) })
        let new = dir("/r", (0..<20).map { file("f\($0).bin", 500) })
        XCTAssertEqual(TreeDiff.changes(from: old, to: new, minDelta: 100, limit: 5).count, 5)
    }
}

private extension FileNode {
    func setParentForTest(_ parent: FileNode) {
        self.parent = parent
    }
}
