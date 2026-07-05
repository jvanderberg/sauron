import XCTest
@testable import DiskCore

final class CacheTests: XCTestCase {
    func testCanonicalAndVariants() {
        XCTAssertEqual(Paths.canonical("/Users/x/"), "/Users/x")
        XCTAssertEqual(Paths.canonical("/"), "/")

        // Deep paths alias across the firmlink graft, in both directions.
        XCTAssertEqual(Paths.variants("/System/Volumes/Data/Users/x"),
                       ["/System/Volumes/Data/Users/x", "/Users/x"])
        XCTAssertEqual(Paths.variants("/Users/x"),
                       ["/Users/x", "/System/Volumes/Data/Users/x"])
        // The two volume roots are distinct directories — no aliasing.
        XCTAssertEqual(Paths.variants("/"), ["/"])
        XCTAssertEqual(Paths.variants("/System/Volumes/Data"), ["/System/Volumes/Data"])
        XCTAssertEqual(Paths.variants("/System/Volumes/DataStore"),
                       ["/System/Volumes/DataStore", "/System/Volumes/Data/System/Volumes/DataStore"])
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
        XCTAssertNil(Paths.find("/Users/other", in: root))
        // A Data tree must never impersonate the "/" root (different dir).
        XCTAssertNil(Paths.find("/", in: root))
    }

    /// Regression: a "/" scan records the Data volume nested under
    /// /System/Volumes/Data (and may have recorded /Users only under that
    /// spelling thanks to alias dedup). Lookups must resolve to the nested
    /// nodes — never hand back the "/" root as if it were the Data volume.
    func testRootScanTreeServesDataAndHomeLookups() {
        let root = FileNode(name: "/", isDirectory: true, size: 500)
        let system = FileNode(name: "System", isDirectory: true, size: 480, parent: root)
        root.addChild(system)
        let volumes = FileNode(name: "Volumes", isDirectory: true, size: 470, parent: system)
        system.addChild(volumes)
        let data = FileNode(name: "Data", isDirectory: true, size: 460, parent: volumes)
        volumes.addChild(data)
        let users = FileNode(name: "Users", isDirectory: true, size: 400, parent: data)
        data.addChild(users)
        let josh = FileNode(name: "josh", isDirectory: true, size: 400, parent: users)
        users.addChild(josh)

        XCTAssertTrue(Paths.find("/System/Volumes/Data", in: root) === data)
        XCTAssertTrue(Paths.find("/Users/josh", in: root) === josh)

        let cache = ScanCache()
        cache.store(root: root, path: "/", complete: true)
        // Scan Disk after a "/" scan: served by the nested Data node.
        XCTAssertTrue(cache.lookup(path: "/System/Volumes/Data")?.node === data)
        // Scan Home: served through the Data spelling.
        XCTAssertTrue(cache.lookup(path: "/Users/josh")?.node === josh)
        // And "/" itself still gets the whole tree.
        XCTAssertTrue(cache.lookup(path: "/")?.node === root)
    }

    /// The inverse must NOT hold at the root level: a cached Data-volume
    /// tree cannot satisfy a request to scan "/".
    func testDataTreeDoesNotServeRootScan() {
        let cache = ScanCache()
        cache.store(root: makeTree(rootName: "/System/Volumes/Data"),
                    path: "/System/Volumes/Data", complete: true)
        XCTAssertNil(cache.lookup(path: "/"))
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
