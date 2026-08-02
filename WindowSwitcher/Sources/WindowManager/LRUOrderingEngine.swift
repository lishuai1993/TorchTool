import AppKit

/// Tracks window ordering based on "recently-active-first" semantics.
/// Mirrors iOS 18 app-switcher behavior:
///   - A window receiving focus *without* user interaction keeps its position.
///   - A window receiving a "substantial interaction" (mouse click, key press,
///     scroll) moves to the front (index 0).
final class LRUOrderingEngine {
    /// Ordered window IDs, index 0 = most recently active.
    private(set) var orderedIDs: [CGWindowID] = []

    /// Timestamp of last substantial interaction per window.
    private var lastInteraction: [CGWindowID: Date] = [:]

    /// Window ID of the currently focused window.
    private var focusedWindowID: CGWindowID?

    /// Cursor pointing to the current position in the LRU list.
    /// Always reflects the most-recently-activated window (index 0 after activation).
    private var currentIndex: Int = 0

    /// Window name lookup, populated by WindowManager during sync.
    var windowNames: [CGWindowID: String] = [:]

    // MARK: - Diagnostics

    func dumpLRU() -> String {
        orderedIDs.enumerated().map { (i, id) in
            let name = windowNames[id] ?? "?"
            let marker = i == currentIndex ? " ← 游标" : ""
            return "  [\(i)] \(name)\(marker)"
        }.joined(separator: "\n")
    }

    // MARK: - Queries

    var count: Int { orderedIDs.count }

    func index(of id: CGWindowID) -> Int? {
        orderedIDs.firstIndex(of: id)
    }

    func id(at index: Int) -> CGWindowID? {
        guard index >= 0 && index < orderedIDs.count else { return nil }
        return orderedIDs[index]
    }

    // MARK: - Mutations

    /// Call when the window list changes (windows added / removed).
    /// New windows are inserted at the front. Removed windows are dropped.
    func sync(windowIDs: [CGWindowID]) {
        let oldSet = Set(orderedIDs)
        let newSet = Set(windowIDs)

        let added = newSet.subtracting(oldSet)
        let removed = oldSet.subtracting(newSet)

        if removed.isEmpty && added.isEmpty && orderedIDs == windowIDs {
            return
        }

        // Save the window ID at current cursor position before mutation
        let cursorWindowID: CGWindowID? = orderedIDs.indices.contains(currentIndex)
            ? orderedIDs[currentIndex] : nil

        // Remove closed windows
        if !removed.isEmpty {
            logDebug("LRU: sync - removed \(removed.count) windows")
        }
        orderedIDs.removeAll { removed.contains($0) }
        for id in removed {
            lastInteraction.removeValue(forKey: id)
        }

        // Prepend new windows in reverse CGWindowList order so the final
        // order matches the z-order snapshot.  Must iterate over `windowIDs`
        // (the ordered array) — NOT `added` (a Set with undefined iteration).
        if !added.isEmpty {
            logDebug("LRU: sync - added \(added.count) windows at front")
        }
        for id in windowIDs.reversed() where added.contains(id) {
            orderedIDs.insert(id, at: 0)
        }

        // Adjust cursor: try to stay on the same window, otherwise reset to 0
        if let cursorID = cursorWindowID, let newIdx = orderedIDs.firstIndex(of: cursorID) {
            currentIndex = newIdx
        } else if !orderedIDs.isEmpty {
            currentIndex = 0
        }
    }

    /// Call when a window receives focus (e.g. via Cmd+Tab or click).
    /// Does NOT reorder — only records the focus target.
    func windowDidFocus(_ id: CGWindowID) {
        focusedWindowID = id
    }

    /// Move a window to the front of the list in response to an external app
    /// activation event (Cmd+Tab, Dock click).  Unlike `windowDidInteract`,
    /// this does NOT record an interaction timestamp — it only reorders.
    func moveToFront(_ id: CGWindowID) {
        guard let idx = orderedIDs.firstIndex(of: id), idx > 0 else { return }
        orderedIDs.remove(at: idx)
        orderedIDs.insert(id, at: 0)
        currentIndex = 0
        logDebug("LRU: moveToFront [\(windowNames[id] ?? "?")] from [\(idx)] → [0]")
    }

    /// Call when a "substantial interaction" (click, key, scroll) occurs in a window.
    /// Moves the window to the front of the LRU list and resets cursor to 0.
    func windowDidInteract(_ id: CGWindowID) {
        lastInteraction[id] = Date()
        guard let idx = orderedIDs.firstIndex(of: id), idx > 0 else { return }
        orderedIDs.remove(at: idx)
        orderedIDs.insert(id, at: 0)
        currentIndex = 0
        logDebug("LRU: interact [\(windowNames[id] ?? "?")] → moved to [0], cursor reset")
    }

    /// Call when the user explicitly selects a window from the overlay.
    /// Does NOT reorder — only positions the cursor at the activated window.
    func userDidSelectWindow(_ id: CGWindowID) {
        if let idx = orderedIDs.firstIndex(of: id) {
            currentIndex = idx
        }
        logDebug("LRU: activated [\(windowNames[id] ?? "?")] → cursor at [\(currentIndex)]")
    }

    // MARK: - Relative navigation

    /// Returns the window ID that is "to the left" (more recent) relative to `id`.
    func moreRecent(than id: CGWindowID) -> CGWindowID? {
        guard let idx = orderedIDs.firstIndex(of: id), idx > 0 else { return nil }
        return orderedIDs[idx - 1]
    }

    /// Returns the window ID that is "to the right" (less recent) relative to `id`.
    func lessRecent(than id: CGWindowID) -> CGWindowID? {
        guard let idx = orderedIDs.firstIndex(of: id),
              idx + 1 < orderedIDs.count else { return nil }
        return orderedIDs[idx + 1]
    }

    /// Advances the cursor in the given direction and returns the target window.
    /// The cursor always reflects "where we are" in the LRU list.
    /// After a window is activated (userDidSelectWindow), cursor resets to 0.
    func advanceCursor(directionRight: Bool) -> CGWindowID? {
        guard !orderedIDs.isEmpty else { return nil }
        let oldIndex = currentIndex
        if directionRight {
            currentIndex = currentIndex + 1 >= orderedIDs.count ? 0 : currentIndex + 1
        } else {
            currentIndex = currentIndex - 1 < 0 ? orderedIDs.count - 1 : currentIndex - 1
        }
        let targetID = orderedIDs[currentIndex]
        logDebug("LRU: cursor [\(oldIndex)]→[\(currentIndex)] \(directionRight ? "→" : "←") \(windowNames[targetID] ?? "?")")
        return targetID
    }
}
