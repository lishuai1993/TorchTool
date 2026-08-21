import AppKit

/// Tracks window ordering based on "recently-active-first" semantics.
/// Mirrors iOS 18 app-switcher behavior:
///   - A window receiving focus *without* user interaction keeps its position.
///   - A window receiving a "substantial interaction" (mouse click, key press,
///     scroll) moves to the front (index 0).
final class LRUOrderingEngine {
    /// Ordered window IDs, index 0 = most recently active.
    private(set) var orderedIDs: [CGWindowID] = []

    /// Cursor pointing to the current position in the LRU list.
    /// Always reflects the most-recently-activated window (index 0 after activation).
    private(set) var currentIndex: Int = 0

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

    /// 计算 id 在列表中的左右邻。cyclic=true 时边界绕回对侧（最左窗口的左邻=最右、
    /// 最右窗口的右邻=最左），与 advanceCursor 的 wrap 语义一致，保证滑动过渡的
    /// 画面滑入目标与提交激活目标始终指向同一窗口。cyclic=false 时边界返回 nil
    ///（wall-bump）。窗口瞬切与跟手滑动两个子模式由此遵守同一行为规范。
    func neighbors(of id: CGWindowID, cyclic: Bool) -> (left: CGWindowID?, right: CGWindowID?) {
        guard let idx = orderedIDs.firstIndex(of: id) else { return (nil, nil) }
        let left: CGWindowID? = idx > 0 ? orderedIDs[idx - 1]
            : (cyclic && count > 1 ? orderedIDs[count - 1] : nil)
        let right: CGWindowID? = idx + 1 < count ? orderedIDs[idx + 1]
            : (cyclic && count > 1 ? orderedIDs[0] : nil)
        return (left, right)
    }

    // MARK: - Mutations

    /// Call when the window list changes (windows added / removed).
    /// Genuinely new windows are inserted at the front. Removed windows are
    /// dropped. Windows that are a rebuild of a just-removed window (same app,
    /// `rebuildMap: addedID → removedID`) inherit the removed window's LRU
    /// position instead of jumping to the head — e.g. a terminal tab change
    /// recreates the CGWindowID and must not leap past apps the user is
    /// actually working in.
    func sync(windowIDs: [CGWindowID], rebuildMap: [CGWindowID: CGWindowID] = [:]) {
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

        // Capture each rebuild predecessor's index BEFORE any mutation.
        var rebuildPosition: [CGWindowID: Int] = [:]
        for (addedID, removedID) in rebuildMap {
            if let idx = orderedIDs.firstIndex(of: removedID) {
                rebuildPosition[addedID] = idx
            }
        }

        // Remove closed windows
        if !removed.isEmpty {
            logDebug("LRU: sync - removed \(removed.count) windows")
        }
        orderedIDs.removeAll { removed.contains($0) }

        // 1) Rebuild replacements inherit the predecessor's LRU position,
        //    inserted in ascending position order to keep the final ordering stable.
        let rebuildIDs = added.filter { rebuildMap[$0] != nil }
        if !rebuildIDs.isEmpty {
            logDebug("LRU: sync - inherited \(rebuildIDs.count) rebuilt windows in place")
        }
        for id in rebuildIDs.sorted(by: {
            (rebuildPosition[$0] ?? 0) < (rebuildPosition[$1] ?? 0)
        }) {
            let targetIndex = min(rebuildPosition[id] ?? 0, orderedIDs.count)
            orderedIDs.insert(id, at: targetIndex)
        }

        // 2) Genuinely new windows go to the front, in reverse CGWindowList
        //    order so the head matches the z-order snapshot. Iterate over
        //    `windowIDs` (the ordered array) — NOT `added` (a Set with
        //    undefined iteration).
        let trulyNew = windowIDs.reversed().filter { added.contains($0) && rebuildMap[$0] == nil }
        if !trulyNew.isEmpty {
            logDebug("LRU: sync - added \(trulyNew.count) genuinely-new windows at front")
        }
        for id in trulyNew {
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
    /// Does NOT reorder. Placeholder for future focus-tracking logic.
    func windowDidFocus(_ id: CGWindowID) {}

    /// Move a window to the front of the list in response to an external app
    /// activation event (Cmd+Tab, Dock click).  Unlike `windowDidInteract`,
    /// this does NOT record an interaction timestamp — it only reorders.
#if DEBUG
    func moveToFront(_ id: CGWindowID) {
        guard let idx = orderedIDs.firstIndex(of: id), idx > 0 else { return }
        orderedIDs.remove(at: idx)
        orderedIDs.insert(id, at: 0)
        currentIndex = 0
        logDebug("LRU: moveToFront [\(windowNames[id] ?? "?")] from [\(idx)] → [0]")
    }
#endif

    /// Call when a "substantial interaction" (click, key, scroll) occurs in a window.
    /// Moves the window to the front of the LRU list and resets cursor to 0.
    func windowDidInteract(_ id: CGWindowID) {
        guard let idx = orderedIDs.firstIndex(of: id) else {
            logDebug("LRU-INTERACT: id=\(id) name=\(windowNames[id] ?? "?") NOT FOUND in orderedIDs (count=\(orderedIDs.count))")
            return
        }
        let before = orderedIDs.prefix(5).compactMap { windowNames[$0] }.joined(separator: " → ")
        if idx > 0 {
            orderedIDs.remove(at: idx)
            orderedIDs.insert(id, at: 0)
            currentIndex = 0
            let after = orderedIDs.prefix(5).compactMap { windowNames[$0] }.joined(separator: " → ")
            logDebug("LRU-INTERACT: [\(windowNames[id] ?? "?")] idx=\(idx)→0, before=[\(before)], after=[\(after)]")
        } else {
            logDebug("LRU-INTERACT: [\(windowNames[id] ?? "?")] already at idx=0, no-op. order=[\(before)]")
        }
    }

    /// Call when the user explicitly selects a window from the overlay.
    /// Does NOT reorder — only positions the cursor at the activated window.
    func userDidSelectWindow(_ id: CGWindowID) {
        let before = orderedIDs.prefix(5).compactMap { windowNames[$0] }.joined(separator: " → ")
        if let idx = orderedIDs.firstIndex(of: id) {
            currentIndex = idx
        }
        let after = orderedIDs.prefix(5).compactMap { windowNames[$0] }.joined(separator: " → ")
        logDebug("LRU-SELECT: [\(windowNames[id] ?? "?")] cursor→\(currentIndex), order=[\(before)] (unchanged=\(before == after))")
    }

    /// 保持「currentIndex == index(of: frontmost)」不变量：外部切换（Cmd+Tab/Dock/
    /// 点击）只更新 frontmost、不重排 LRU（activation ≠ interaction），若游标停在上次
    /// 导航位置，下一次手势 commit 的 advanceCursor（游标 ±1）就会与画面目标
    ///（frontmost 的左右邻）脱节。调用方在外部激活更新 frontmost 后调用本方法。
    /// 只移动游标指针，不改变 orderedIDs 顺序。
    func syncCursor(toFrontmost id: CGWindowID) {
        guard let idx = orderedIDs.firstIndex(of: id) else {
            logDebug("LRU: syncCursor id=\(id) name=\(windowNames[id] ?? "?") NOT FOUND in orderedIDs")
            return
        }
        guard idx != currentIndex else { return }
        currentIndex = idx
        logDebug("LRU: cursor synced to frontmost [\(windowNames[id] ?? "?")] idx=\(idx)")
    }

    // MARK: - Relative navigation

    /// Read-only check: is the cursor at the boundary for the given direction?
    func isAtBoundary(directionRight: Bool) -> Bool {
        guard !orderedIDs.isEmpty else { return true }
        if directionRight {
            return currentIndex + 1 >= orderedIDs.count
        } else {
            return currentIndex - 1 < 0
        }
    }

    /// Returns the window ID that is "to the left" (more recent) relative to `id`.
#if DEBUG
    func moreRecent(than id: CGWindowID) -> CGWindowID? {
        guard let idx = orderedIDs.firstIndex(of: id), idx > 0 else { return nil }
        return orderedIDs[idx - 1]
    }
#endif

    /// Returns the window ID that is "to the right" (less recent) relative to `id`.
#if DEBUG
    func lessRecent(than id: CGWindowID) -> CGWindowID? {
        guard let idx = orderedIDs.firstIndex(of: id),
              idx + 1 < orderedIDs.count else { return nil }
        return orderedIDs[idx + 1]
    }
#endif

    /// Advances the cursor in the given direction and returns the target window.
    /// When `cyclic` is false and the cursor is at the boundary, returns nil
    /// (wall-bump) without moving the cursor.
    func advanceCursor(directionRight: Bool, cyclic: Bool = true) -> CGWindowID? {
        guard !orderedIDs.isEmpty else { return nil }
        let oldIndex = currentIndex
        if directionRight {
            if currentIndex + 1 >= orderedIDs.count {
                if cyclic { currentIndex = 0 } else { return nil }
            } else {
                currentIndex = currentIndex + 1
            }
        } else {
            if currentIndex - 1 < 0 {
                if cyclic { currentIndex = orderedIDs.count - 1 } else { return nil }
            } else {
                currentIndex = currentIndex - 1
            }
        }
        let targetID = orderedIDs[currentIndex]
        logDebug("LRU: cursor [\(oldIndex)]→[\(currentIndex)] \(directionRight ? "→" : "←") \(windowNames[targetID] ?? "?")")
        return targetID
    }
}
