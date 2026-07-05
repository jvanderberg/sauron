import XCTest
@testable import DiskCore

final class ScannerTests: XCTestCase {
    var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    private func writeFile(_ relative: String, bytes: Int) throws -> URL {
        let url = fixture.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
        return url
    }

    func testScanAggregatesPhysicalSizes() throws {
        try writeFile("a/one.bin", bytes: 1_000_000)
        try writeFile("a/two.bin", bytes: 2_000_000)
        try writeFile("b/three.bin", bytes: 500_000)

        let result = try Scanner.scan(path: fixture.path)
        let root = result.root

        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.children.count, 2)
        // Physical size is at least the logical size for non-sparse files.
        XCTAssertGreaterThanOrEqual(root.size, 3_500_000)
        // ...but not wildly more (allocation rounding + dir overhead only).
        XCTAssertLessThan(root.size, 3_500_000 * 2)

        // Children sorted largest-first; sizes aggregate up.
        let a = root.children[0]
        XCTAssertEqual(a.name, "a")
        XCTAssertGreaterThanOrEqual(a.size, 3_000_000)
        let childSum = root.children.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertGreaterThanOrEqual(root.size, childSum)
    }

    func testSparseFileReportsPhysicalNotLogicalSize() throws {
        let url = fixture.appendingPathComponent("sparse.bin")
        FileManager.default.createFile(atPath: url.path, contents: Data("hi".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 100_000_000) // 100 MB logical
        try handle.close()

        let logical = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        XCTAssertEqual(logical, 100_000_000)

        let result = try Scanner.scan(path: fixture.path)
        let sparse = result.root.children.first { $0.name == "sparse.bin" }
        let node = try XCTUnwrap(sparse)
        // Physical footprint of a 100MB hole is tiny.
        XCTAssertLessThan(node.size, 5_000_000,
            "sparse file should report allocated blocks, not logical length (got \(node.size))")
    }

    func testHardLinksCountedOnce() throws {
        let original = try writeFile("orig.bin", bytes: 1_000_000)
        let link = fixture.appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: original, to: link)

        let result = try Scanner.scan(path: fixture.path)
        // Both nodes appear, but the shared blocks are only counted once.
        XCTAssertEqual(result.root.children.count, 2)
        XCTAssertLessThan(result.root.size, 1_600_000,
            "hard-linked data should not be double-counted (got \(result.root.size))")
    }

    func testScanSingleFile() throws {
        let url = try writeFile("solo.bin", bytes: 250_000)
        let result = try Scanner.scan(path: url.path)
        XCTAssertFalse(result.root.isDirectory)
        XCTAssertGreaterThanOrEqual(result.root.size, 250_000)
    }

    func testScanMissingPathThrows() {
        XCTAssertThrowsError(try Scanner.scan(path: fixture.appendingPathComponent("nope").path))
    }

    func testRemoveFromParentUpdatesAncestorSizes() throws {
        try writeFile("a/big.bin", bytes: 2_000_000)
        try writeFile("a/small.bin", bytes: 100_000)

        let result = try Scanner.scan(path: fixture.path)
        let root = result.root
        let a = try XCTUnwrap(root.children.first { $0.name == "a" })
        let big = try XCTUnwrap(a.children.first { $0.name == "big.bin" })

        let rootBefore = root.size
        let aBefore = a.size
        let bigSize = big.size
        big.removeFromParent()

        XCTAssertEqual(a.size, aBefore - bigSize)
        XCTAssertEqual(root.size, rootBefore - bigSize)
        XCTAssertFalse(a.children.contains { $0 === big })
        XCTAssertNil(big.parent)
    }

    func testLiveAggregationGrowsMonotonically() throws {
        for i in 0..<20 {
            try writeFile("nest/level\(i % 4)/file\(i).bin", bytes: 100_000)
        }
        var observedRoot: FileNode?
        var observedSizes: [Int64] = []
        let result = try Scanner.scan(
            path: fixture.path,
            progressEvery: 1,
            onRootReady: { observedRoot = $0 },
            progress: { _, _ in
                // Called on the scanning thread mid-scan: the live tree must
                // already aggregate everything seen so far at the root.
                if let root = observedRoot { observedSizes.append(root.size) }
                return true
            }
        )
        XCTAssertTrue(observedRoot === result.root)
        XCTAssertGreaterThan(observedSizes.count, 10)
        XCTAssertEqual(observedSizes, observedSizes.sorted(),
            "root size must grow monotonically during the scan")
        XCTAssertGreaterThan(observedSizes[observedSizes.count / 2], 0,
            "root size must be non-zero mid-scan, not only at the end")
        XCTAssertEqual(observedSizes.last, result.root.size)
    }

    func testFindByPath() throws {
        try writeFile("a/b/target.bin", bytes: 1000)
        let root = try Scanner.scan(path: fixture.path).root
        let found = root.find(path: root.name + "/a/b/target.bin")
        XCTAssertEqual(found?.name, "target.bin")
        XCTAssertTrue(root.find(path: root.name) === root)
        XCTAssertNil(root.find(path: root.name + "/a/missing.bin"))
        XCTAssertNil(root.find(path: "/somewhere/else"))
    }

    func testReplaceContentsAfterSubtreeRescan() throws {
        try writeFile("sub/keep.bin", bytes: 1_000_000)
        let doomed = try writeFile("sub/doomed.bin", bytes: 2_000_000)
        try writeFile("other.bin", bytes: 500_000)

        let root = try Scanner.scan(path: fixture.path).root
        let sub = try XCTUnwrap(root.children.first { $0.name == "sub" })
        let rootBefore = root.size
        let subBefore = sub.size

        // Simulate an external deletion, then a subtree rescan spliced in.
        try FileManager.default.removeItem(at: doomed)
        let fresh = try Scanner.scan(path: sub.path).root
        sub.replaceContents(with: fresh)

        XCTAssertLessThan(sub.size, subBefore)
        XCTAssertEqual(root.size, rootBefore - (subBefore - sub.size))
        XCTAssertNil(sub.children.first { $0.name == "doomed.bin" })
        XCTAssertEqual(sub.children.first { $0.name == "keep.bin" }?.parent === sub, true)
        // The rescanned node keeps its identity and place in the tree.
        XCTAssertTrue(root.children.contains { $0 === sub })
        XCTAssertTrue(sub.children.allSatisfy { $0.path.hasPrefix(sub.path) })
    }

    func testPathReconstruction() throws {
        try writeFile("a/b/deep.bin", bytes: 1000)
        let result = try Scanner.scan(path: fixture.path)
        let a = try XCTUnwrap(result.root.children.first { $0.name == "a" })
        let b = try XCTUnwrap(a.children.first { $0.name == "b" })
        let deep = try XCTUnwrap(b.children.first { $0.name == "deep.bin" })
        // fixture.path may contain /private symlink differences; compare suffix.
        XCTAssertTrue(deep.path.hasSuffix("/a/b/deep.bin"))
        XCTAssertTrue(deep.path.hasPrefix(result.root.name))
    }
}
