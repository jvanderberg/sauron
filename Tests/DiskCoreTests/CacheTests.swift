import XCTest
@testable import DiskCore

final class CacheTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Paths.normalize("/System/Volumes/Data"), "/")
        XCTAssertEqual(Paths.normalize("/System/Volumes/Data/Users/x"), "/Users/x")
        XCTAssertEqual(Paths.normalize("/Users/x/"), "/Users/x")
        XCTAssertEqual(Paths.normalize("/Users/x"), "/Users/x")
        XCTAssertEqual(Paths.normalize("/"), "/")
        XCTAssertEqual(Paths.normalize("/System/Volumes/DataStore"), "/System/Volumes/DataStore")
    }

    private func makeTree(rootName: String) -> FileNode {
        let root = FileNode(name: rootName, isDirectory: true, size: 300)
        let users = FileNode(name: "Users", isDirectory: true, size: 200, parent: root)
        root.addChild(users)
        let josh = FileNode(name: "josh", isDirectory: true, size: 200, parent: users)
        users.addChild(josh)
        let file = FileNode(name: "big.bin", isDirectory: false, size: 200, parent: josh)
        josh.addChild(file)
        return root
    }

    func testPathsFindAcrossFirmlinkAlias() {
        // Tree scanned as the Data volume; looked up by the / spelling.
        let root = makeTree(rootName: "/System/Volumes/Data")
        XCTAssertEqual(Paths.find("/Users/josh", in: root)?.name, "josh")
        XCTAssertEqual(Paths.find("/System/Volumes/Data/Users/josh", in: root)?.name, "josh")
        XCTAssertTrue(Paths.find("/", in: root) === root)
        XCTAssertNil(Paths.find("/Users/other", in: root))
    }

    func testCacheExactAndSubtreeLookup() {
        let cache = ScanCache()
        let root = makeTree(rootName: "/data")
        cache.store(root: root, path: "/data", complete: true)

        let exact = cache.lookup(path: "/data")
        XCTAssertTrue(exact?.node === root)
        XCTAssertEqual(exact?.complete, true)

        // A narrower scan target is served from inside the wider cached tree.
        let sub = cache.lookup(path: "/data/Users/josh")
        XCTAssertEqual(sub?.node.name, "josh")
        XCTAssertNil(cache.lookup(path: "/elsewhere"))
        XCTAssertNil(cache.lookup(path: "/datastore"))
    }

    func testDataVolumeCacheServesHomeScan() {
        let cache = ScanCache()
        let diskTree = makeTree(rootName: "/System/Volumes/Data")
        cache.store(root: diskTree, path: "/System/Volumes/Data", complete: false)
        // "Scan Disk" data covers a later "Scan Home" through the firmlink.
        let hit = cache.lookup(path: "/Users/josh")
        XCTAssertEqual(hit?.node.name, "josh")
        XCTAssertEqual(hit?.complete, false)
    }

    func testPartialNeverReplacesCompleteButCompleteAlwaysWins() {
        let cache = ScanCache()
        let complete = FileNode(name: "/p", isDirectory: true, size: 100)
        cache.store(root: complete, path: "/p", complete: true)

        // A bigger partial must not clobber complete data.
        let partial = FileNode(name: "/p", isDirectory: true, size: 500)
        cache.store(root: partial, path: "/p", complete: false)
        XCTAssertTrue(cache.lookup(path: "/p")?.node === complete)

        // A fresh complete scan replaces, even if smaller (files deleted).
        let fresher = FileNode(name: "/p", isDirectory: true, size: 80)
        cache.store(root: fresher, path: "/p", complete: true)
        XCTAssertTrue(cache.lookup(path: "/p")?.node === fresher)
    }

    func testBiggerPartialReplacesSmallerPartial() {
        let cache = ScanCache()
        let small = FileNode(name: "/p", isDirectory: true, size: 100)
        cache.store(root: small, path: "/p", complete: false)
        let big = FileNode(name: "/p", isDirectory: true, size: 500)
        cache.store(root: big, path: "/p", complete: false)
        XCTAssertTrue(cache.lookup(path: "/p")?.node === big)
        let smaller = FileNode(name: "/p", isDirectory: true, size: 50)
        cache.store(root: smaller, path: "/p", complete: false)
        XCTAssertTrue(cache.lookup(path: "/p")?.node === big)
    }

    func testCapacityEvictsOldest() {
        let cache = ScanCache(capacity: 2)
        cache.store(root: FileNode(name: "/a", isDirectory: true, size: 1), path: "/a", complete: true)
        cache.store(root: FileNode(name: "/b", isDirectory: true, size: 1), path: "/b", complete: true)
        cache.store(root: FileNode(name: "/c", isDirectory: true, size: 1), path: "/c", complete: true)
        XCTAssertNil(cache.lookup(path: "/a"))
        XCTAssertNotNil(cache.lookup(path: "/b"))
        XCTAssertNotNil(cache.lookup(path: "/c"))
    }
}
