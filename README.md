# Sauron

One treemap to find them all. A macOS disk-usage explorer: scan a folder (or the
whole Data volume), see where the space went as an explorable heat map, drill
into any level, mark things for the trash, and free the space — all without
Xcode. Pure SwiftPM.

![Treemap render](docs/screenshot.png)
*(headless render of the treemap — the hatched red tile is marked for the trash)*

## What it measures

**Physical (allocated) size** — `st_blocks * 512` — not logical length. Sparse
files show their real on-disk footprint. Hard-linked data is counted once.
Symlinks are not followed, and scans never cross volume boundaries, so APFS
firmlinks and mounted disks aren't double-counted.

## Using the app

```sh
make run        # run directly from the package
make app        # build Sauron.app, then: open Sauron.app
```

- **Scan Home / Scan Disk / Scan Folder…** — "Scan Disk" scans
  `/System/Volumes/Data`, which is everything user-writable on the startup
  disk. (Scanning `/` on modern macOS only shows the sealed system volume.)
  The map appears immediately and **updates live while the scan runs** — the
  big offenders dominate within seconds; explore without waiting.
- **Click** selects a tile. **⌫** (or the status-bar button, or right-click)
  marks the selection for the trash — marking is always an explicit act, never
  a stray click. **Double-click** a directory to drill in; breadcrumbs and the
  ↑ button navigate back out.
- **⟳ Rescan** re-scans just the folder you're looking at and splices the
  fresh numbers into the tree — cheap truth-up after deletions, no full rescan.
- **Switching scans never loses work.** Starting a new scan cancels the
  current one; every tree (partial or complete) is cached. If earlier data
  covers the new target — including through the `/System/Volumes/Data` ↔ `/`
  firmlink alias, so a partial "Scan Disk" seeds a "Scan Home" — it shows
  instantly while the fresh scan refreshes it in the background, then swaps
  in with navigation, marks, and selection carried across.
- The right panel lists everything marked, the total space it will free, and a
  **Move to Trash** button you can press at any time. Marking a folder absorbs
  any marked items inside it, so the total never double-counts.
- **Empty Trash…** (with confirmation) asks Finder to empty the trash, then
  optimistically bumps the displayed free space by the trash's size — macOS can
  take a while to report reclaimed space. The figure shows green until the
  system catches up (re-checked every 5 s).

Granting your terminal (or Sauron.app) **Full Disk Access** avoids "unreadable"
directories. The first Empty Trash triggers a one-time automation prompt to
control Finder.

## Architecture

- `Sources/DiskCore` — all logic, zero UI: fts(3)-based scanner, squarified
  treemap layout, trash queue/operations, volume free-space.
- `Sources/sauron-cli` — drives the core from the shell; used by the smoke tests.
- `Sources/SauronApp` — SwiftUI shell over DiskCore.

## Testing

```sh
make test       # unit tests (scanner incl. sparse/hardlink cases, treemap, trash queue)
make smoke      # end-to-end through the CLI: scan, du, layout, freespace, trash round-trip
make check      # both
```

The app itself can be driven headlessly:

```sh
# auto-start a scan at launch
SAURON_SCAN=~/Downloads swift run SauronApp

# screenshot built into the app: scan a path, render the treemap offscreen
# to a PNG (no window, no screen-recording permission), and exit
SAURON_RENDER=~/Downloads SAURON_RENDER_OUT=/tmp/map.png swift run SauronApp
```

The CLI is also handy on its own:

```sh
sauron-cli scan ~/Downloads --depth 3 --top 5
sauron-cli du ~/Library/Caches
sauron-cli freespace
sauron-cli trash ./junk.bin
sauron-cli empty-trash --yes
```
