import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sauron — Disk Usage")
                    .font(.title2.bold())
                Text("One treemap to find them all. Sauron shows where your disk space went, lets you explore every level, and frees space by moving things to the Trash.")
                    .foregroundStyle(.secondary)

                section("Scanning", """
                • House scans your home folder; the internal-drive button scans the \
                startup disk (the APFS Data volume — everything user-writable); the \
                folder button scans any folder you choose. You can also drop a \
                folder anywhere in the window. (Drag from a Finder window's main \
                pane — dragging items out of the sidebar's Favorites removes them \
                from Favorites; that's Finder behavior, not Sauron.)
                • The map appears immediately and updates live every 2 seconds while \
                the scan runs — big offenders dominate within seconds.
                • Starting a new scan cancels the current one and keeps its partial \
                work as cache: if earlier data covers the new target, it shows \
                instantly ("showing earlier results") while a fresh scan refreshes it.
                • ⟳ rescans just the folder you're viewing and splices in the fresh \
                numbers. ✕ cancels a running scan.
                • Hang-prone system locations (cloud storage placeholders, \
                automounts, sibling system volumes) are skipped by default; \
                scanning one directly always works, and Settings (⌘,) can \
                disable the skips or un-learn folders recorded after stalls.
                """)

                section("Reading the map", """
                • Sizes are physical (allocated) bytes: sparse files show their real \
                footprint, hard-linked data counts once, and APFS firmlinks are never \
                double-counted.
                • Color runs blue (small) → orange (large) within the current level. \
                Pure red with hatching means marked for the Trash. Directories are \
                saturated; files are muted.
                • The white ring is your selection; the bar below shows its path, \
                share of the current level, and size.
                """)

                section("Navigating", """
                • Click selects. Double-click opens a folder (zooms in). \
                Breadcrumbs and ↑ go back out.
                • Right-click any tile for Mark/Unmark, Open, Copy, Copy Full \
                Path, and Reveal in Finder.
                • ⌘C copies the selected item (paste it in Finder); ⌥⌘C copies \
                its full path as text. Space Quick Looks the selection.
                • Full keyboard control: Tab focuses the map (selecting the \
                largest tile), arrow keys move between tiles, Return opens a \
                folder (or Quick Looks a file), Esc goes up a level.
                """)

                section("Changes view", """
                • The third switcher position compares this scan against the \
                previous scan of the same location and lists what grew, shrank, \
                appeared, or vanished — blamed on the deepest responsible file \
                or folder. Red consumed space; green freed it.
                • The slider sets the minimum change size. Right-click a row \
                for Show in Map or Reveal in Finder.
                """)

                section("Largest Files view", """
                • The switcher in the toolbar flips between the map and a flat list \
                of the biggest files found anywhere in the scan.
                • The slider sets the minimum size; the list shows everything at or \
                above it, sorted. Mark files for the Trash right from the list, or \
                use Show in Map to jump to where a file lives.
                """)

                section("Trash", """
                • ⌫ (or the status-bar button, or right-click) marks the selection; \
                marked items collect in the right panel with the total space they \
                will free. Marking a folder absorbs marked items inside it.
                • Move to Trash moves everything marked into the macOS Trash — space \
                is not freed yet. Empty Trash… (with confirmation) asks Finder to \
                empty it.
                • Free space updates optimistically after emptying, shown in green \
                until the system confirms (macOS reclaims space asynchronously; \
                snapshots can delay it). The figure matches Finder's accounting, \
                which includes purgeable space and can exceed what `df` reports.
                • Delete Permanently… erases the marked items immediately — no \
                Trash, no undo, no recovery. Use it for things too big to stage \
                through the Trash, and read the confirmation before you click.
                """)

                section("Permissions", """
                • Grant Full Disk Access to Sauron (or the terminal that launches \
                it) to avoid "unreadable" directories.
                • The first Empty Trash triggers a one-time prompt to control Finder.
                """)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.system(size: 12)).lineSpacing(3)
        }
    }
}
