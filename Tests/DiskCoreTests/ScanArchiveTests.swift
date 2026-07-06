import XCTest
@testable import DiskCore

final class ScanArchiveTests: XCTestCase {
    var fixture: URL!
    var archive: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("sauron-archive-\(UUID().uuidString).sauronscan")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: archive)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = fixture.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func assertTreesEqual(_ a: FileNode, _ b: FileNode) {
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(a.size, b.size)
        XCTAssertEqual(a.isDirectory, b.isDirectory)
        XCTAssertEqual(a.children.count, b.children.count)
        for (ca, cb) in zip(a.children, b.children) {
            XCTAssertTrue(cb.parent === b)
            assertTreesEqual(ca, cb)
        }
    }

    func testRoundTripPreservesTree() throws {
        try write("a/one.bin", bytes: 2_000_000)
        try write("a/deep/two.bin", bytes: 3_000_000)
        try write("b/three.bin", bytes: 1_500_000)

        let scanned = try Scanner.scan(path: fixture.path).root
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try ScanArchive.save(root: scanned, scannedPath: fixture.path, date: stamp,
                             to: archive, minFileSize: 0)

        let loaded = try ScanArchive.load(from: archive)
        XCTAssertEqual(loaded.scannedPath, fixture.path)
        XCTAssertEqual(loaded.date.timeIntervalSince1970, 1_800_000_000, accuracy: 1)
        assertTreesEqual(scanned, loaded.root)
    }

    func testMinFileSizeDropsLeavesButKeepsTotals() throws {
        try write("dir/big.bin", bytes: 5_000_000)
        try write("dir/small.bin", bytes: 10_000)

        let scanned = try Scanner.scan(path: fixture.path).root
        try ScanArchive.save(root: scanned, scannedPath: fixture.path, date: Date(),
                             to: archive, minFileSize: 1_000_000)

        let loaded = try ScanArchive.load(from: archive).root
        // Aggregate sizes intact at every level...
        XCTAssertEqual(loaded.size, scanned.size)
        let dir = try XCTUnwrap(loaded.children.first { $0.name == "dir" })
        let originalDir = try XCTUnwrap(scanned.children.first { $0.name == "dir" })
        XCTAssertEqual(dir.size, originalDir.size)
        // ...but the sub-cutoff leaf is gone and the big one remains.
        XCTAssertNil(dir.children.first { $0.name == "small.bin" })
        XCTAssertNotNil(dir.children.first { $0.name == "big.bin" })
    }

    func testFilteredCopyPreservesTotalsAndDropsSmallFiles() throws {
        try write("dir/big.bin", bytes: 4_000_000)
        try write("dir/small.bin", bytes: 5_000)
        try write("top.bin", bytes: 2_000_000)

        let original = try Scanner.scan(path: fixture.path).root
        let copy = original.filteredCopy(minFileSize: 1_000_000)

        XCTAssertEqual(copy.size, original.size)
        XCTAssertFalse(copy === original)
        let dir = try XCTUnwrap(copy.children.first { $0.name == "dir" })
        let originalDir = try XCTUnwrap(original.children.first { $0.name == "dir" })
        XCTAssertEqual(dir.size, originalDir.size, "aggregates survive the filter")
        XCTAssertNil(dir.children.first { $0.name == "small.bin" })
        XCTAssertNotNil(dir.children.first { $0.name == "big.bin" })
        XCTAssertTrue(dir.parent === copy, "copied nodes are wired to copied parents")
        // The copy is fully detached from the original tree.
        XCTAssertFalse(dir === originalDir)
    }

    func testLoadRejectsGarbage() throws {
        try Data(repeating: 0xFF, count: 512).write(to: archive)
        XCTAssertThrowsError(try ScanArchive.load(from: archive))
    }
}
