import Foundation
import DiskCore

let usage = """
sauron-cli — drive the Sauron disk-usage core from the shell

USAGE:
  sauron-cli scan <path> [--depth N] [--top N]   Scan and print the size tree (physical bytes)
  sauron-cli du <path>                           Print total physical size of a path, bytes only
  sauron-cli layout <W> <H> <v1> [v2 ...]        Print squarified treemap rects for weights
  sauron-cli freespace [path]                    Print free space on the volume containing path
  sauron-cli trash <path> [path ...]             Move paths to the trash (prints trash locations)
  sauron-cli archive <path> <out>                Scan and save a compact scan archive (prints size)
  sauron-cli empty-trash --yes                   Empty the trash via Finder (requires --yes)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func intFlag(_ name: String, from args: inout [String], default def: Int) -> Int {
    guard let i = args.firstIndex(of: name) else { return def }
    guard i + 1 < args.count, let value = Int(args[i + 1]) else {
        fail("\(name) requires an integer argument")
    }
    args.removeSubrange(i...(i + 1))
    return value
}

func printTree(_ node: FileNode, depth: Int, maxDepth: Int, top: Int, indent: String) {
    print("\(Format.bytes(node.size).padding(toLength: 12, withPad: " ", startingAt: 0)) \(node.size) \(indent)\(node.isRoot ? node.name : node.name)\(node.isDirectory ? "/" : "")")
    guard node.isDirectory, depth < maxDepth else { return }
    let shown = node.children.prefix(top)
    for child in shown {
        printTree(child, depth: depth + 1, maxDepth: maxDepth, top: top, indent: indent + "  ")
    }
    let hidden = node.children.count - shown.count
    if hidden > 0 {
        let hiddenSize = node.children.dropFirst(top).reduce(Int64(0)) { $0 + $1.size }
        print("\(Format.bytes(hiddenSize).padding(toLength: 12, withPad: " ", startingAt: 0)) \(hiddenSize) \(indent)  … \(hidden) more")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

switch command {
case "scan":
    let depth = intFlag("--depth", from: &args, default: 2)
    let top = intFlag("--top", from: &args, default: 10)
    guard let path = args.first else { fail("scan: missing path") }
    do {
        let result = try Scanner.scan(path: path)
        printTree(result.root, depth: 0, maxDepth: depth, top: top, indent: "")
        print("entries: \(result.entryCount)  errors: \(result.errorCount)")
    } catch {
        fail("scan failed: \(error)")
    }

case "du":
    guard let path = args.first else { fail("du: missing path") }
    do {
        let result = try Scanner.scan(path: path)
        print(result.root.size)
    } catch {
        fail("du failed: \(error)")
    }

case "layout":
    guard args.count >= 3, let w = Double(args[0]), let h = Double(args[1]) else {
        fail("layout: need <W> <H> <v1> [v2 ...]")
    }
    let values = args.dropFirst(2).map { Double($0) ?? 0 }
    let rects = Treemap.layout(values: values, in: CGRect(x: 0, y: 0, width: w, height: h))
    for (i, r) in rects.enumerated() {
        print(String(format: "%d: x=%.2f y=%.2f w=%.2f h=%.2f area=%.2f",
                     i, r.minX, r.minY, r.width, r.height, r.width * r.height))
    }

case "freespace":
    let path = args.first ?? NSHomeDirectory()
    guard let free = Volume.freeSpace(at: path) else { fail("freespace: cannot stat volume") }
    print("\(free) (\(Format.bytes(free)))")

case "trash":
    guard !args.isEmpty else { fail("trash: missing path(s)") }
    var failed = false
    for path in args {
        do {
            let dest = try Trasher.moveToTrash(path: path)
            print("trashed \(path) -> \(dest.path)")
        } catch {
            failed = true
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }
    }
    exit(failed ? 1 : 0)

case "archive":
    guard args.count >= 2 else { fail("archive: need <path> <out>") }
    do {
        let result = try Scanner.scan(path: args[0])
        try ScanArchive.save(root: result.root, scannedPath: args[0], date: Date(),
                             to: URL(fileURLWithPath: args[1]))
        let attrs = try FileManager.default.attributesOfItem(atPath: args[1])
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        print("archived \(result.entryCount) entries -> \(Format.bytes(bytes)) (\(bytes) bytes)")
    } catch {
        fail("archive failed: \(error)")
    }

case "empty-trash":
    guard args.contains("--yes") else { fail("empty-trash: pass --yes to confirm") }
    do {
        try Trasher.emptyTrash()
        print("trash emptied")
    } catch {
        fail("\(error)")
    }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\(usage)")
}
