import AppKit

// MARK: - Minimal Test Harness

private var passed = 0
private var failed = 0
private var testName = ""

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("  ✘ [\(testName)] expected \(expected), got \(actual) — \(file):\(line)")
    }
}

private func assertTrue(_ value: Bool, file: String = #file, line: Int = #line) {
    assertEqual(value, true)
}

private func assertFalse(_ value: Bool, file: String = #file, line: Int = #line) {
    assertEqual(value, false)
}

private func assertNil<T>(_ value: T?, file: String = #file, line: Int = #line) {
    if value == nil {
        passed += 1
    } else {
        failed += 1
        print("  ✘ [\(testName)] expected nil, got \(value!) — \(file):\(line)")
    }
}

private func assertNotNil<T>(_ value: T?, file: String = #file, line: Int = #line) {
    if value != nil {
        passed += 1
    } else {
        failed += 1
        print("  ✘ [\(testName)] expected non-nil — \(file):\(line)")
    }
}

private func assertNear(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.001,
                        file: String = #file, line: Int = #line) {
    if abs(actual - expected) <= tolerance {
        passed += 1
    } else {
        failed += 1
        print("  ✘ [\(testName)] expected ≈\(expected), got \(actual) — \(file):\(line)")
    }
}

private func runSuite(_ name: String, _ block: () -> Void) {
    testName = name
    print("  \(name)...")
    block()
}

// MARK: - LRUOrderingEngine Tests

private func testLRUOrderingEngine() {
    let engine = LRUOrderingEngine()

    runSuite("initial count is 0") {
        assertEqual(engine.count, 0)
    }

    runSuite("sync adds windows in order") {
        let engine = LRUOrderingEngine()
        let ids: [CGWindowID] = [1, 2, 3]
        engine.sync(windowIDs: ids)
        assertEqual(engine.count, 3)
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 2)
        assertEqual(engine.id(at: 2), 3)
    }

    runSuite("sync removes closed windows") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.sync(windowIDs: [1, 3])
        assertEqual(engine.count, 2)
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 3)
    }

    runSuite("sync adds new windows at front preserving z-order") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2])
        engine.sync(windowIDs: [3, 4, 1, 2])
        assertEqual(engine.id(at: 0), 3)
        assertEqual(engine.id(at: 1), 4)
        assertEqual(engine.id(at: 2), 1)
        assertEqual(engine.id(at: 3), 2)
    }

    runSuite("sync preserves cursor on same window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.sync(windowIDs: [1, 2])
        assertEqual(engine.id(at: 0), 1)
    }

    runSuite("index(of:) finds window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        assertEqual(engine.index(of: 2), 1)
    }

    runSuite("index(of:) returns nil for unknown window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2])
        assertNil(engine.index(of: 99))
    }

    runSuite("neighbors middle window non-cyclic") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        let (l, r) = engine.neighbors(of: 2, cyclic: false)
        assertEqual(l, 1)
        assertEqual(r, 3)
    }

    runSuite("neighbors middle window cyclic same as non-cyclic") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        let (l, r) = engine.neighbors(of: 2, cyclic: true)
        assertEqual(l, 1)
        assertEqual(r, 3)
    }

    runSuite("neighbors left boundary wraps to last with cyclic") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        let (l, r) = engine.neighbors(of: 1, cyclic: true)
        assertEqual(l, 4)   // 最左窗口的左邻绕回最右
        assertEqual(r, 2)
    }

    runSuite("neighbors right boundary wraps to first with cyclic") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        let (l, r) = engine.neighbors(of: 4, cyclic: true)
        assertEqual(l, 3)
        assertEqual(r, 1)   // 最右窗口的右邻绕回最左
    }

    runSuite("neighbors boundaries non-cyclic return nil") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        let (l1, r1) = engine.neighbors(of: 1, cyclic: false)
        assertNil(l1)
        assertEqual(r1, 2)
        let (l2, r2) = engine.neighbors(of: 4, cyclic: false)
        assertEqual(l2, 3)
        assertNil(r2)
    }

    runSuite("neighbors single window never wraps to itself") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [5])
        let (l, r) = engine.neighbors(of: 5, cyclic: true)
        assertNil(l)
        assertNil(r)
    }

    runSuite("neighbors unknown id returns nil pair") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        let (l, r) = engine.neighbors(of: 99, cyclic: true)
        assertNil(l)
        assertNil(r)
    }

    runSuite("neighbors(cyclic) boundary matches advanceCursor(cyclic) wrap") {
        // 画面（neighbors）与激活（advanceCursor）在边界 + 循环时必须指向同一窗口。
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4])
        engine.userDidSelectWindow(4)   // currentIndex → 3（最右窗口）
        // 最右窗口右滑：neighbors 右邻 = 1；advanceCursor(right, cyclic) wrap → 1
        let (_, rNeighbor) = engine.neighbors(of: 4, cyclic: true)
        assertEqual(rNeighbor, 1)
        let wrapRight = engine.advanceCursor(directionRight: true, cyclic: true)  // 3→0 wrap
        assertEqual(wrapRight, 1)
        // 此时游标在最左窗口（idx=0）。最左窗口左滑：neighbors 左邻 = 4；
        // advanceCursor(left, cyclic) wrap → 4
        let (lNeighbor, _) = engine.neighbors(of: 1, cyclic: true)
        assertEqual(lNeighbor, 4)
        let wrapLeft = engine.advanceCursor(directionRight: false, cyclic: true)  // 0→3 wrap
        assertEqual(wrapLeft, 4)
    }

    runSuite("moveToFront moves window to index 0") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(3)
        assertEqual(engine.id(at: 0), 3)
        assertEqual(engine.id(at: 1), 1)
        assertEqual(engine.id(at: 2), 2)
    }

    runSuite("moveToFront no-op when already at 0") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(1) // already at 0
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 2)
        assertEqual(engine.id(at: 2), 3)
    }

    runSuite("moveToFront no-op for unknown window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(99) // unknown
        assertEqual(engine.count, 3)
        assertEqual(engine.id(at: 0), 1)
    }

    runSuite("windowDidInteract moves window to 0 and resets cursor") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.windowDidInteract(3)
        assertEqual(engine.id(at: 0), 3)
        assertEqual(engine.id(at: 1), 1)
        assertEqual(engine.id(at: 2), 2)
    }

    runSuite("windowDidInteract no-op when already at 0") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.windowDidInteract(1) // already at 0
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 2)
        assertEqual(engine.id(at: 2), 3)
    }

    runSuite("userDidSelectWindow positions cursor without reordering") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.userDidSelectWindow(2)
        // Order unchanged
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 2)
        assertEqual(engine.id(at: 2), 3)
    }

    runSuite("syncCursor moves cursor to frontmost index without reordering") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.userDidSelectWindow(3)   // cursor 0 → 2
        engine.syncCursor(toFrontmost: 2)  // external Cmd+Tab to window 2 (idx 1)
        // Order unchanged — activation does NOT reorder
        assertEqual(engine.id(at: 0), 1)
        assertEqual(engine.id(at: 1), 2)
        assertEqual(engine.id(at: 2), 3)
        // Cursor now points at window 2
        assertEqual(engine.id(at: 3), nil)
        let left = engine.advanceCursor(directionRight: false)  // idx 1 → 0
        assertEqual(left, 1)   // window 1 is window 2's more-recent neighbor
        let right = engine.advanceCursor(directionRight: true)  // idx 0 → 1
        assertEqual(right, 2)
    }

    runSuite("syncCursor no-op when already aligned") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.syncCursor(toFrontmost: 1)  // cursor already 0
        assertEqual(engine.currentIndex, 0)
        assertEqual(engine.id(at: 0), 1)
    }

    runSuite("syncCursor no-op for unknown window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.userDidSelectWindow(2)
        engine.syncCursor(toFrontmost: 99)  // not in orderedIDs
        assertEqual(engine.currentIndex, 1)
        assertEqual(engine.count, 3)
    }

    runSuite("syncCursor then advanceCursor navigates from frontmost neighbors") {
        // Regression for the slide divergence: user externally switches to 迅雷@idx=11,
        // cursor was stale at Chrome@idx=4. After syncCursor, a swipe must navigate
        // from 迅雷's LRU neighbors, and a round-trip must return to 迅雷.
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4, 5])   // 1..5 LRU order
        engine.userDidSelectWindow(2)             // last navigation left cursor at 2 (idx 1)
        engine.syncCursor(toFrontmost: 5)         // user externally switched to 5 (idx 4)
        // right swipe → window 5's less-recent neighbor (nil here = boundary wall-bump)
        let right = engine.advanceCursor(directionRight: true, cyclic: false)
        assertNil(right)                          // 5 is at the right boundary, non-cyclic
        // left swipe → window 5's more-recent neighbor = 4 (round-trip returns toward 迅雷)
        let left = engine.advanceCursor(directionRight: false, cyclic: false)
        assertEqual(left, 4)
        // another left swipe → 3, continues toward the more-recent end
        let left2 = engine.advanceCursor(directionRight: false, cyclic: false)
        assertEqual(left2, 3)
    }

    runSuite("advanceCursor right wraps around") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        let result = engine.advanceCursor(directionRight: true) // 0 → 1
        assertEqual(result, 2)
        let result2 = engine.advanceCursor(directionRight: true) // 1 → 2
        assertEqual(result2, 3)
        let result3 = engine.advanceCursor(directionRight: true) // 2 → 0 (wrap)
        assertEqual(result3, 1)
    }

    runSuite("advanceCursor left wraps around") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        let result = engine.advanceCursor(directionRight: false) // 0 → 2 (wrap)
        assertEqual(result, 3)
        let result2 = engine.advanceCursor(directionRight: false) // 2 → 1
        assertEqual(result2, 2)
        let result3 = engine.advanceCursor(directionRight: false) // 1 → 0
        assertEqual(result3, 1)
    }

    runSuite("advanceCursor returns nil for empty list") {
        let engine = LRUOrderingEngine()
        assertNil(engine.advanceCursor(directionRight: true))
    }

    runSuite("moreRecent returns previous window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        assertEqual(engine.moreRecent(than: 2), 1)
        assertNil(engine.moreRecent(than: 1)) // first window has no more-recent
        assertNil(engine.moreRecent(than: 99)) // unknown
    }

    runSuite("lessRecent returns next window") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        assertEqual(engine.lessRecent(than: 2), 3)
        assertNil(engine.lessRecent(than: 3)) // last window has no less-recent
    }

    runSuite("id(at:) bounds checking") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2])
        assertNil(engine.id(at: -1))
        assertNil(engine.id(at: 2))
        assertNotNil(engine.id(at: 0))
    }
}

// MARK: - ActivationHistory Tests

private func testActivationHistory() {
    runSuite("can create ActivationHistory") {
        let ah = ActivationHistory()
        assertNotNil(ah)
    }

    runSuite("onAppActivated callback is initially nil") {
        let ah = ActivationHistory()
        assertNil(ah.onAppActivated)
    }

    runSuite("start and stop do not crash") {
        let ah = ActivationHistory()
        ah.start()
        ah.stop()
        passed += 1 // if we reach here, no crash
    }

    runSuite("multiple stops are safe") {
        let ah = ActivationHistory()
        ah.start()
        ah.stop()
        ah.stop() // should not crash
        passed += 1
    }

    runSuite("callback fires when invoked directly") {
        let ah = ActivationHistory()
        var invoked = false
        var invokedPid: pid_t = -1
        ah.onAppActivated = { pid in
            invoked = true
            invokedPid = pid
        }
        ah.onAppActivated?(42)
        assertTrue(invoked)
        assertEqual(invokedPid, 42)
    }
}

// MARK: - ActivationSuppressor Tests

private func testActivationSuppressor() {
    runSuite("records and suppresses matching pid within window") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        assertTrue(sup.shouldSuppress(pid: 42, at: t0.addingTimeInterval(0.1)))
    }

    runSuite("does not suppress a different pid") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        assertFalse(sup.shouldSuppress(pid: 43, at: t0.addingTimeInterval(0.1)))
    }

    runSuite("does not suppress when nothing recorded") {
        let sup = ActivationSuppressor()
        assertFalse(sup.shouldSuppress(pid: 42, at: Date()))
    }

    runSuite("clears after suppress match (second call no-op)") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        assertTrue(sup.shouldSuppress(pid: 42, at: t0.addingTimeInterval(0.1)))
        assertFalse(sup.shouldSuppress(pid: 42, at: t0.addingTimeInterval(0.2)))
    }

    runSuite("clears after non-match too") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        assertFalse(sup.shouldSuppress(pid: 43, at: t0.addingTimeInterval(0.1)))
        assertFalse(sup.shouldSuppress(pid: 42, at: t0.addingTimeInterval(0.2)))
    }

    runSuite("does not suppress beyond time window") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        assertFalse(sup.shouldSuppress(pid: 42, at: t0.addingTimeInterval(2.0)))
    }

    runSuite("new activation overwrites previous pending") {
        let sup = ActivationSuppressor()
        let t0 = Date()
        sup.recordActivation(pid: 42, at: t0)
        sup.recordActivation(pid: 43, at: t0.addingTimeInterval(0.05))
        // Only the latest record (43) is pending
        assertTrue(sup.shouldSuppress(pid: 43, at: t0.addingTimeInterval(0.1)))
    }
}

// MARK: - GesturePhase Tests

private func testGesturePhase() {
    runSuite("idle does not intercept scroll") {
        assertFalse(GesturePhase.idle.interceptsScroll)
    }

    runSuite("overlayVisible does not intercept scroll") {
        assertFalse(GesturePhase.overlayVisible.interceptsScroll)
    }

    runSuite("quickSwitching intercepts scroll") {
        assertTrue(GesturePhase.quickSwitching.interceptsScroll)
    }

    runSuite("elasticDragging intercepts scroll") {
        assertTrue(GesturePhase.elasticDragging.interceptsScroll)
    }
}

// MARK: - AXWindowMatcher Tests

private func testAXWindowMatcher() {
    let matcher = AXWindowMatcher.shared

    runSuite("frameMatches exact same frame") {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        assertTrue(AXWindowMatcher.frameMatches(a, a))
    }

    runSuite("frameMatches within tolerance") {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 5, y: 3, width: 100, height: 50)
        assertTrue(AXWindowMatcher.frameMatches(a, b, tolerance: 10))
    }

    runSuite("frameMatches rejects origin beyond tolerance") {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 20, y: 0, width: 100, height: 50)
        assertFalse(AXWindowMatcher.frameMatches(a, b, tolerance: 10))
    }

    runSuite("frameMatches rejects size difference") {
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 0, y: 0, width: 120, height: 50)
        assertFalse(AXWindowMatcher.frameMatches(a, b, tolerance: 10))
    }

    // -- matchAXToCGWindowID --
    let win1 = WindowInfo(id: 101, ownerPid: 10, ownerName: "AppA", ownerBundleID: nil,
                          windowTitle: "Alpha", frame: CGRect(x: 0, y: 0, width: 200, height: 100), thumbnail: nil)
    let win2 = WindowInfo(id: 102, ownerPid: 10, ownerName: "AppA", ownerBundleID: nil,
                          windowTitle: "Beta", frame: CGRect(x: 300, y: 0, width: 200, height: 100), thumbnail: nil)
    let win3 = WindowInfo(id: 103, ownerPid: 20, ownerName: "AppB", ownerBundleID: nil,
                          windowTitle: "Gamma", frame: CGRect(x: 0, y: 200, width: 200, height: 100), thumbnail: nil)
    let windows: [CGWindowID: WindowInfo] = [101: win1, 102: win2, 103: win3]

    runSuite("matchAX single frame match") {
        let m = matcher.matchAXToCGWindowID(pid: 10, title: "Alpha", frame: win1.frame,
                                            windows: windows, appZOrder: [:])
        assertEqual(m, 101)
    }

    runSuite("matchAX title-only fallback when no frame match") {
        let m = matcher.matchAXToCGWindowID(pid: 20, title: "Gamma",
                                            frame: CGRect(x: 999, y: 999, width: 10, height: 10),
                                            windows: windows, appZOrder: [:])
        assertEqual(m, 103)
    }

    runSuite("matchAX returns nil when nothing matches") {
        let m = matcher.matchAXToCGWindowID(pid: 99, title: "Unknown", frame: .zero,
                                            windows: windows, appZOrder: [:])
        assertNil(m)
    }

    runSuite("matchAX multiple same-frame candidates resolved by title") {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let wA = WindowInfo(id: 201, ownerPid: 30, ownerName: "AppC", ownerBundleID: nil,
                            windowTitle: "One", frame: frame, thumbnail: nil)
        let wB = WindowInfo(id: 202, ownerPid: 30, ownerName: "AppC", ownerBundleID: nil,
                            windowTitle: "Two", frame: frame, thumbnail: nil)
        let ws: [CGWindowID: WindowInfo] = [201: wA, 202: wB]
        let m = matcher.matchAXToCGWindowID(pid: 30, title: "Two", frame: frame,
                                            windows: ws, appZOrder: [30: [(201, frame), (202, frame)]])
        assertEqual(m, 202)
    }

    runSuite("matchAX fallback to first candidate when no title match") {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let wA = WindowInfo(id: 201, ownerPid: 30, ownerName: "AppC", ownerBundleID: nil,
                            windowTitle: "One", frame: frame, thumbnail: nil)
        let wB = WindowInfo(id: 202, ownerPid: 30, ownerName: "AppC", ownerBundleID: nil,
                            windowTitle: "Two", frame: frame, thumbnail: nil)
        let ws: [CGWindowID: WindowInfo] = [201: wA, 202: wB]
        let m = matcher.matchAXToCGWindowID(pid: 30, title: "Mismatch", frame: frame,
                                            windows: ws, appZOrder: [:])
        assertEqual(m, 201) // candidates.first
    }

    // -- selectAXWindow --
    runSuite("selectAX single frame match") {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let ax = [(index: 0, title: "A", frame: frame)]
        let r = matcher.selectAXWindow(for: 501, pid: 40, frame: frame, title: "A",
                                       axWindows: ax, appZOrder: [40: [(501, frame)]])
        assertEqual(r?.index, 0)
        assertEqual(r?.title, "A")
    }

    runSuite("selectAX multiple same-frame uses z-order rank") {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let ax = [(index: 0, title: "A", frame: frame), (index: 1, title: "B", frame: frame)]
        let r = matcher.selectAXWindow(for: 502, pid: 50, frame: frame, title: "",
                                       axWindows: ax, appZOrder: [50: [(501, frame), (502, frame)]])
        assertEqual(r?.index, 1) // rank of 502 within sameFrameCG is 1
    }

    runSuite("selectAX title fallback when no frame match") {
        let ax = [(index: 0, title: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 50)),
                  (index: 1, title: "B", frame: CGRect(x: 200, y: 0, width: 100, height: 50))]
        let r = matcher.selectAXWindow(for: 601, pid: 60, frame: .zero, title: "B",
                                       axWindows: ax, appZOrder: [:])
        assertEqual(r?.index, 1)
    }
}

// MARK: - LRU Boundary Tests

private func testLRUBoundary() {
    runSuite("isAtBoundary right true at last index") {
        let e = LRUOrderingEngine()
        e.sync(windowIDs: [1, 2, 3])
        _ = e.advanceCursor(directionRight: true) // cursor 0 → 1
        _ = e.advanceCursor(directionRight: true) // cursor 1 → 2
        assertTrue(e.isAtBoundary(directionRight: true))
        assertFalse(e.isAtBoundary(directionRight: false))
    }

    runSuite("isAtBoundary left true at index 0") {
        let e = LRUOrderingEngine()
        e.sync(windowIDs: [1, 2, 3])
        assertTrue(e.isAtBoundary(directionRight: false))
        assertFalse(e.isAtBoundary(directionRight: true))
    }

    runSuite("isAtBoundary false in the middle") {
        let e = LRUOrderingEngine()
        e.sync(windowIDs: [1, 2, 3])
        _ = e.advanceCursor(directionRight: true) // cursor → 1
        assertFalse(e.isAtBoundary(directionRight: true))
        assertFalse(e.isAtBoundary(directionRight: false))
    }

    runSuite("isAtBoundary true for empty list") {
        let e = LRUOrderingEngine()
        assertTrue(e.isAtBoundary(directionRight: true))
        assertTrue(e.isAtBoundary(directionRight: false))
    }

    runSuite("advanceCursor non-cyclic returns nil at right wall, cursor stays") {
        let e = LRUOrderingEngine()
        e.sync(windowIDs: [1, 2, 3])
        _ = e.advanceCursor(directionRight: true, cyclic: false) // 0 → 1 (window 2)
        _ = e.advanceCursor(directionRight: true, cyclic: false) // 1 → 2 (window 3)
        assertNil(e.advanceCursor(directionRight: true, cyclic: false))
        assertEqual(e.currentIndex, 2) // cursor did not move
    }

    runSuite("advanceCursor non-cyclic returns nil at left wall, cursor stays") {
        let e = LRUOrderingEngine()
        e.sync(windowIDs: [1, 2, 3])
        assertNil(e.advanceCursor(directionRight: false, cyclic: false))
        assertEqual(e.currentIndex, 0)
    }
}

// MARK: - Integration Tests

private func testIntegration() {
    runSuite("moveToFront preserves other window order") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3, 4, 5])
        engine.windowNames = [
            1: "A1", 2: "B1", 3: "B2", 4: "A2", 5: "C1",
        ]
        engine.moveToFront(4) // Move A2 to front
        // A2 should now be at [0], A1 at [1], rest unchanged
        assertEqual(engine.id(at: 0), 4)
        assertEqual(engine.id(at: 1), 1)
        assertEqual(engine.id(at: 2), 2)
        assertEqual(engine.id(at: 3), 3)
        assertEqual(engine.id(at: 4), 5)
    }

    runSuite("repeated moveToFront is idempotent") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(3)
        engine.moveToFront(3) // already at 0, no-op
        assertEqual(engine.count, 3)
        assertEqual(engine.id(at: 0), 3)
        assertEqual(engine.id(at: 1), 1)
        assertEqual(engine.id(at: 2), 2)
    }

    runSuite("sync after moveToFront preserves order") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(3)
        // sync with same set should preserve the new order
        engine.sync(windowIDs: [1, 2, 3])
        assertEqual(engine.id(at: 0), 3)
    }

    runSuite("sync removes window that was moved to front") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        engine.moveToFront(3)
        engine.sync(windowIDs: [1, 2]) // 3 removed
        assertEqual(engine.count, 2)
        assertEqual(engine.id(at: 0), 1)
    }

    runSuite("moveToFront resets cursor to 0") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [1, 2, 3])
        _ = engine.advanceCursor(directionRight: true) // cursor 0 → 1
        _ = engine.advanceCursor(directionRight: true) // cursor 1 → 2
        engine.moveToFront(3) // 3: [2]→[0], list becomes [3,1,2]
        assertEqual(engine.id(at: 0), 3)
        // Cursor should now be at 0, so next advance goes to index 1 → window 1
        let next = engine.advanceCursor(directionRight: true)
        assertEqual(next, 1)
    }
}

// MARK: - SlideOffset（滑动过渡映射）Tests
// 核心规范（见知识库文档 2.5）：滑动全程 offset 必须是 progress 的连续函数，
// 禁止任何瞬移/跳变。以下用与实机一致的参数（屏宽 1470、ratio 1.5、disp 0.08）
// 验证映射：无瞬移、连续性、clamp、对称、提交阈值。

private func testSlideOffset() {
    let W: CGFloat = 1470
    let ppp: CGFloat = 1.5 * 0.08 * W          // pointsPerProgress = 176.4
    let threshold: CGFloat = 0.45 * W          // 提交阈值 = 661.5

    runSuite("progress 0 → offset 0") {
        assertEqual(SlideOffset.eased(progress: 0, pointsPerProgress: ppp, screenWidth: W), 0)
    }

    runSuite("软起步：微小 progress 处位移趋 0（无首帧弹射）") {
        let d = SlideOffset.eased(progress: 0.01, pointsPerProgress: ppp, screenWidth: W)
        assertTrue(d >= 0 && d < 1.0)          // ~0.04px，绝非瞬移到阈值
    }

    runSuite("离散事件点(progress=1.0) offset 远低于提交阈值 → 无瞬移") {
        let off1 = SlideOffset.eased(progress: 1.0, pointsPerProgress: ppp, screenWidth: W)
        assertTrue(off1 > 0)
        assertTrue(off1 < threshold)           // ~126px ≪ 661px：手指只甩过 8% 触控板时窗口只到 ~8.6% 屏
    }

    runSuite("全程扫描 0.01→5.0 offset 增量有界（连续无跳变）") {
        var prev = SlideOffset.eased(progress: 0.01, pointsPerProgress: ppp, screenWidth: W)
        var maxDelta: CGFloat = 0
        var i: CGFloat = 0.02
        while i <= 5.0 {
            let cur = SlideOffset.eased(progress: i, pointsPerProgress: ppp, screenWidth: W)
            maxDelta = max(maxDelta, abs(cur - prev))
            prev = cur
            i += 0.01
        }
        // 步长 0.01 progress 对应最大增量 ≤2px（eased 导数上限 ~0.92×ppp×0.01≈1.6）
        assertTrue(maxDelta <= 2.0)
    }

    runSuite("boost 回归：progress 单调递增 offset 单调不减（不再 115→661 跳变）") {
        let off1 = SlideOffset.eased(progress: 1.0, pointsPerProgress: ppp, screenWidth: W)
        let off2 = SlideOffset.eased(progress: 1.1, pointsPerProgress: ppp, screenWidth: W)
        assertTrue(off2 >= off1)
        assertTrue(off2 - off1 < 30)           // 相邻帧增量 ~16px，绝非 546px 瞬移
    }

    runSuite("反向对称：eased(-p) = -eased(p)") {
        let pos = SlideOffset.eased(progress: 0.7, pointsPerProgress: ppp, screenWidth: W)
        let neg = SlideOffset.eased(progress: -0.7, pointsPerProgress: ppp, screenWidth: W)
        assertEqual(neg, -pos)
    }

    runSuite("大 progress clamp 到 ±屏宽") {
        assertEqual(SlideOffset.eased(progress: 10, pointsPerProgress: ppp, screenWidth: W), W)
        assertEqual(SlideOffset.eased(progress: -10, pointsPerProgress: ppp, screenWidth: W), -W)
    }

    runSuite("提交阈值需 ~4.1 progress（33% 触控板）才达到") {
        assertTrue(SlideOffset.eased(progress: 4.0, pointsPerProgress: ppp, screenWidth: W) < threshold)
        assertTrue(SlideOffset.eased(progress: 4.5, pointsPerProgress: ppp, screenWidth: W) >= threshold)
    }
}

// MARK: - SlideChain（链式会话：连甩连贯）Tests
// 覆盖三态派发决策、位置继承（carry）、以及链式游标推进序列。

private func testSlideChain() {
    let W: CGFloat = 1470
    let ppp: CGFloat = 1.5 * 0.08 * W          // pointsPerProgress = 176.4

    runSuite("decision 全表：未激活/跟手/收尾同向/收尾反向/fade期") {
        // 未激活：一律 freshBegin（不论 settling 与方向）
        assertEqual(SlideChain.decision(isActive: false, isSettling: false, settleComplete: false, newSign: 1, lastSettleSign: 1), .freshBegin)
        assertEqual(SlideChain.decision(isActive: false, isSettling: true, settleComplete: false, newSign: -1, lastSettleSign: 1), .freshBegin)
        // 激活且跟手：update（newSign 不参与——非收尾态不看方向）
        assertEqual(SlideChain.decision(isActive: true, isSettling: false, settleComplete: false, newSign: 1, lastSettleSign: -1), .update)
        assertEqual(SlideChain.decision(isActive: true, isSettling: false, settleComplete: false, newSign: -1, lastSettleSign: -1), .update)
        // 激活且收尾 + 同向：chain
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: false, newSign: 1, lastSettleSign: 1), .chain)
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: false, newSign: -1, lastSettleSign: -1), .chain)
        // 激活且收尾 + 反向：cancelAndFresh（取消旧会话、全新 begin）
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: false, newSign: 1, lastSettleSign: -1), .cancelAndFresh)
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: false, newSign: -1, lastSettleSign: 1), .cancelAndFresh)
        // 方案C：fade 期（settleComplete=true）无论方向一律 cancelAndFresh（不再链式静默跳过）
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: true, newSign: 1, lastSettleSign: 1), .cancelAndFresh)
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: true, newSign: -1, lastSettleSign: 1), .cancelAndFresh)
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: true, newSign: 1, lastSettleSign: -1), .cancelAndFresh)
        assertEqual(SlideChain.decision(isActive: true, isSettling: true, settleComplete: true, newSign: -1, lastSettleSign: -1), .cancelAndFresh)
        // 未激活时 settleComplete 不影响（仍 freshBegin）
        assertEqual(SlideChain.decision(isActive: false, isSettling: true, settleComplete: true, newSign: 1, lastSettleSign: -1), .freshBegin)
    }

    runSuite("sign(ofProgress:)：progress≥0 → 1，否则 -1") {
        assertEqual(SlideChain.sign(ofProgress: 0), 1)
        assertEqual(SlideChain.sign(ofProgress: 0.5), 1)
        assertEqual(SlideChain.sign(ofProgress: -0.0001), -1)
        assertEqual(SlideChain.sign(ofProgress: -1.5), -1)
    }

    runSuite("chained carry=0 退化为普通 eased（与既有映射一致）") {
        for p in stride(from: -2.0, through: 2.0, by: 0.05) {
            let direct = SlideOffset.eased(progress: p, pointsPerProgress: ppp, screenWidth: W)
            let chained = SlideChain.chainedOffset(progress: p, carry: 0, pointsPerProgress: ppp, screenWidth: W)
            assertEqual(chained, direct)
        }
    }

    runSuite("chained 位置继承：progress=0 时即从 carry 起算（运动位置不回跳）") {
        let carry: CGFloat = -0.6 * W
        let at0 = SlideChain.chainedOffset(progress: 0, carry: carry, pointsPerProgress: ppp, screenWidth: W)
        assertEqual(at0, carry)                    // 新会话起点 = 被打断位置
        let at1 = SlideChain.chainedOffset(progress: 1.0, carry: carry, pointsPerProgress: ppp, screenWidth: W)
        assertTrue(at1 > carry)                    // 同向继续前移（朝提交方向推进）
    }

    runSuite("chained 连续性：carry+progress 全程无跳变（步长 0.01 增量有界）") {
        let carry: CGFloat = -0.45 * W
        var prev = SlideChain.chainedOffset(progress: 0.01, carry: carry, pointsPerProgress: ppp, screenWidth: W)
        var maxDelta: CGFloat = 0
        var i: CGFloat = 0.02
        while i <= 5.0 {
            let cur = SlideChain.chainedOffset(progress: i, carry: carry, pointsPerProgress: ppp, screenWidth: W)
            maxDelta = max(maxDelta, abs(cur - prev))
            prev = cur
            i += 0.01
        }
        assertTrue(maxDelta <= 2.0)
    }

    runSuite("chained 反向对称：chained(-p, carry=+c) = -chained(p, carry=-c)") {
        let pos = SlideChain.chainedOffset(progress: 0.7, carry: -0.3 * W, pointsPerProgress: ppp, screenWidth: W)
        let neg = SlideChain.chainedOffset(progress: -0.7, carry: 0.3 * W, pointsPerProgress: ppp, screenWidth: W)
        assertEqual(neg, -pos)
    }

    runSuite("链式游标序列：同向连续快甩逐窗口推进、最后一下落定、全程不重排") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [400, 300, 200, 100])   // 400=A(最近) 300=B 200=C 100=D(最旧)
        engine.windowNames[400] = "A"; engine.windowNames[300] = "B"
        engine.windowNames[200] = "C"; engine.windowNames[100] = "D"
        engine.syncCursor(toFrontmost: 400)            // 游标停在 A

        // 快甩1（左滑=方向右→较旧窗口）：提交 A→B
        guard let t1 = engine.advanceCursor(directionRight: true, cyclic: true) else {
            assertTrue(false); return
        }
        assertEqual(t1, 300)
        assertEqual(engine.id(at: engine.currentIndex), 300)

        // 快甩2 链式：源 = 游标窗口(B)，目标 = 其右邻(C)——同方向推进
        let src2 = engine.id(at: engine.currentIndex)!
        let n2 = engine.neighbors(of: src2, cyclic: true)
        assertEqual(src2, 300)
        assertEqual(n2.right, 200)

        // 快甩2 提交：B→C
        guard let t2 = engine.advanceCursor(directionRight: true, cyclic: true) else {
            assertTrue(false); return
        }
        assertEqual(t2, 200)

        // 快甩3 链式：源 = C，目标 = D；最后一下提交落定 C→D
        let src3 = engine.id(at: engine.currentIndex)!
        assertEqual(src3, 200)
        assertEqual(engine.neighbors(of: src3, cyclic: true).right, 100)
        guard let t3 = engine.advanceCursor(directionRight: true, cyclic: true) else {
            assertTrue(false); return
        }
        assertEqual(t3, 100)

        // 链式期间从未重排：LRU 顺序保持原样（仅游标推进）
        assertEqual(engine.orderedIDs, [400, 300, 200, 100])
        assertEqual(engine.currentIndex, 3)
    }

    runSuite("链式边界：循环滚动开启时最旧窗口继续同向推进绕回最近窗口") {
        let engine = LRUOrderingEngine()
        engine.sync(windowIDs: [400, 300, 200, 100])
        engine.syncCursor(toFrontmost: 100)            // 游标停在最旧 D（index 3）
        let n = engine.neighbors(of: 100, cyclic: true)
        assertEqual(n.right, 400)                       // 右邻绕回 A（循环）
        guard let t = engine.advanceCursor(directionRight: true, cyclic: true) else {
            assertTrue(false); return
        }
        assertEqual(t, 400)
    }
}

// MARK: - MenuBarImageCache（菜单横条真实像素缓存）Tests
// 纯内存缓存 + 顶部裁剪，无外部依赖、无 SCK 权限要求。

private func testMenuBarImageCache() {
    runSuite("record → strip 返回缓存；未记录返回 nil") {
        let cache = MenuBarImageCache()
        assertTrue(cache.strip(pid: 123) == nil)
        guard let img = makeSolidImage(width: 200, height: 40) else {
            print("  (failed to create test image)")
            return
        }
        cache.record(pid: 123, strip: img)
        assertTrue(cache.contains(pid: 123))
        assertTrue(cache.strip(pid: 123) != nil)
        assertTrue(cache.strip(pid: 999) == nil)
    }

    runSuite("覆盖更新：再次 record 替换旧缓存") {
        let cache = MenuBarImageCache()
        guard let img1 = makeSolidImage(width: 100, height: 40),
              let img2 = makeSolidImage(width: 300, height: 40) else { return }
        cache.record(pid: 7, strip: img1)
        cache.record(pid: 7, strip: img2)
        assertTrue(cache.strip(pid: 7)?.width == 300)
    }

    runSuite("cropTopStrip 尺寸正确且越界 clamp") {
        guard let full = makeSolidImage(width: 1512, height: 982) else { return }
        let strip = MenuBarImageCache.cropTopStrip(from: full, coverWidthPx: 857, menuBarPx: 74)
        assertTrue(strip != nil)
        assertTrue(strip?.width == 857)
        assertTrue(strip?.height == 74)
        // 越界 clamp 到图像尺寸
        let clamped = MenuBarImageCache.cropTopStrip(from: full, coverWidthPx: 9999, menuBarPx: 5)
        assertTrue(clamped?.width == 1512)
        assertTrue(clamped?.height == 5)
        // 非法参数返回 nil
        assertTrue(MenuBarImageCache.cropTopStrip(from: full, coverWidthPx: 0, menuBarPx: 74) == nil)
        assertTrue(MenuBarImageCache.cropTopStrip(from: full, coverWidthPx: 857, menuBarPx: 0) == nil)
    }
}

// MARK: - BackdropPreCapturer 排除判定 Tests
// Fix A：预捕 SCK 截屏必须排除本进程自己的窗口（全屏面板 + 菜单覆盖条）。
// 回归点：预捕异步执行可能晚于 begin() 建面板，若不排除本进程窗口，
// 会把「面板黑占位罩在真实桌面 + 面板内源/目标图像」自拍进背景图 → 暗层屏闪。

private func testBackdropExclusion() {
    let ourPid: pid_t = 1111

    runSuite("排除调用方显式指定的 windowIDs") {
        let r = BackdropPreCapturer.WindowRef(windowID: 5, ownerPid: 99)
        assertTrue(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [5], panelWindowNumber: nil, ourPid: ourPid))
    }

    runSuite("排除 panelWindowNumber 对应窗口") {
        let r = BackdropPreCapturer.WindowRef(windowID: 500, ownerPid: 99)
        assertTrue(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [], panelWindowNumber: 500, ourPid: ourPid))
    }

    runSuite("预捕路径(nil)排除本进程全屏面板 —— Fix A 核心回归") {
        let r = BackdropPreCapturer.WindowRef(windowID: 700, ownerPid: ourPid)
        assertTrue(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [], panelWindowNumber: nil, ourPid: ourPid))
    }

    runSuite("本进程菜单覆盖条（非全屏）同样排除") {
        let r = BackdropPreCapturer.WindowRef(windowID: 701, ownerPid: ourPid)
        assertTrue(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [], panelWindowNumber: nil, ourPid: ourPid))
    }

    runSuite("本进程窗口在 panelWindowNumber 指向别窗口时仍排除") {
        let r = BackdropPreCapturer.WindowRef(windowID: 702, ownerPid: ourPid)
        assertTrue(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [999], panelWindowNumber: 888, ourPid: ourPid))
    }

    runSuite("其他进程窗口不排除") {
        let r = BackdropPreCapturer.WindowRef(windowID: 8, ownerPid: 1234)
        assertFalse(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [], panelWindowNumber: nil, ourPid: ourPid))
    }

    runSuite("无 ownerPid 的窗口不排除") {
        let r = BackdropPreCapturer.WindowRef(windowID: 9, ownerPid: nil)
        assertFalse(BackdropPreCapturer.shouldExcludeWindow(r, windowIDs: [], panelWindowNumber: nil, ourPid: ourPid))
    }
}

// MARK: - BackdropPreCapturer 预捕会话可用性 Tests
// Fix B2：take() 守卫只校验屏幕尺寸——预捕背景图是「桌面减本进程窗口」，与源/左右邻
// 身份无关。快速连续手势「提交→激活」间隙的预捕源过期、LRU 邻序漂移都不应让 begin
// 放弃已就绪背景；仅源窗口换屏（屏幕尺寸变化）才需重捕。

private func testBackdropSessionUsable() {
    runSuite("同屏幕尺寸 → 会话可用") {
        assertTrue(BackdropPreCapturer.sessionUsable(sessionScreen: CGSize(width: 1728, height: 1117),
                                                     beginScreen: CGSize(width: 1728, height: 1117)))
    }

    runSuite("不同屏幕尺寸（源已换屏）→ 会话不可用") {
        assertFalse(BackdropPreCapturer.sessionUsable(sessionScreen: CGSize(width: 1728, height: 1117),
                                                      beginScreen: CGSize(width: 1440, height: 900)))
    }

    runSuite("高 DPI 整点（Retina 逻辑点）同屏 → 可用") {
        assertTrue(BackdropPreCapturer.sessionUsable(sessionScreen: CGSize(width: 1512, height: 982),
                                                     beginScreen: CGSize(width: 1512, height: 982)))
    }

    runSuite("整数与 CGFloat 精度一致 → 可用") {
        assertTrue(BackdropPreCapturer.sessionUsable(sessionScreen: CGSize(width: 1512.0, height: 982.0),
                                                     beginScreen: CGSize(width: 1512, height: 982)))
    }
}

// MARK: - SettleFallback 兜底决策 Tests
// Fix C：淡出停滞兜底不再硬切（不透明面板瞬间消失=黑闪 + 与下一会话预捕竞争）。
// 面板仍可见 → 先短淡出再拆；面板已透明 → 直接拆；面板已拆 → 无操作。

private func testSettleFallback() {
    runSuite("面板已拆除 → noPanel") {
        let a = SettleFallback.action(panelExists: false, panelAlpha: 1.0)
        assertEqual(a, .noPanel)
    }

    runSuite("面板仍不透明（停滞 1.00，本次实测 token23 场景）→ refade") {
        let a = SettleFallback.action(panelExists: true, panelAlpha: 1.00)
        assertEqual(a, .refadeThenTeardown)
    }

    runSuite("面板淡出中(0.92/0.19) → refade 后拆，而非硬切") {
        assertEqual(SettleFallback.action(panelExists: true, panelAlpha: 0.92), .refadeThenTeardown)
        assertEqual(SettleFallback.action(panelExists: true, panelAlpha: 0.19), .refadeThenTeardown)
    }

    runSuite("面板已透明(≤0.05) → teardownNow") {
        assertEqual(SettleFallback.action(panelExists: true, panelAlpha: 0.00), .teardownNow)
        assertEqual(SettleFallback.action(panelExists: true, panelAlpha: 0.05), .teardownNow)
    }

    runSuite("边界：alpha 0.06 → refade") {
        assertEqual(SettleFallback.action(panelExists: true, panelAlpha: 0.06), .refadeThenTeardown)
    }
}

// MARK: - SlideMomentum Tests（路径A 动量助推）

private func testSlideMomentum() {
    // 默认参数：window=0.15s，maxBoost=735（0.5×1470 屏宽）
    runSuite("快甩同向高速度 → 助推补足") {
        let b = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b, -600)
    }

    runSuite("同向但低于 800px/s 下限（已拦截为 0）→ 无助推") {
        let b = momentumBoost(off: -150, releaseVel: 0, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b, 0)
    }

    runSuite("零速（停顿抬手）→ 无助推") {
        let b = momentumBoost(off: -300, releaseVel: 0, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b, 0)
    }

    runSuite("反向速度（与主方向相反）→ 方向保护归零") {
        let b = momentumBoost(off: -200, releaseVel: 1500, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b, 0)
    }

    runSuite("clamp 正上限") {
        let b = momentumBoost(off: 200, releaseVel: 6000, mainDirSign: 1, window: 0.15, maxBoostPx: 735)
        assertNear(b, 735)
    }

    runSuite("clamp 负上限") {
        let b = momentumBoost(off: -200, releaseVel: -6000, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b, -735)
    }

    runSuite("主方向未知（dir=0）→ 无助推") {
        let b = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: 0, window: 0.15, maxBoostPx: 735)
        assertNear(b, 0)
    }

    runSuite("off 近零时快甩 → 助推仍有效（方向保护不依赖 off）") {
        let b1 = momentumBoost(off: -1, releaseVel: -4000, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        let b2 = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: -1, window: 0.15, maxBoostPx: 735)
        assertNear(b1, b2)
    }

    runSuite("window 放大至 0.30 → clamp 到负上限") {
        let b = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: -1, window: 0.30, maxBoostPx: 735)
        assertNear(b, -735)
    }

    runSuite("window 缩小至 0.05 → 助推 200") {
        let b = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: -1, window: 0.05, maxBoostPx: 735)
        assertNear(b, -200)
    }

    runSuite("maxBoost 足够大（不 clamp）") {
        let b = momentumBoost(off: -200, releaseVel: -4000, mainDirSign: -1, window: 0.15, maxBoostPx: 1470)
        assertNear(b, -600)
    }

    runSuite("左滑方向（dir=+1，vel 正）→ 正向助推") {
        let b = momentumBoost(off: 200, releaseVel: 2500, mainDirSign: 1, window: 0.15, maxBoostPx: 735)
        assertNear(b, 375)
    }
}

private func makeSolidImage(width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

// MARK: - Entry Point

@main
struct TestRunner {
    static func main() {
        print("Running WindowSwitcher unit tests...")
        print("")

        print("[LRUOrderingEngine]")
        testLRUOrderingEngine()

        print("")
        print("[ActivationHistory]")
        testActivationHistory()

        print("")
        print("[ActivationSuppressor]")
        testActivationSuppressor()

        print("")
        print("[GesturePhase]")
        testGesturePhase()

        print("")
        print("[AXWindowMatcher]")
        testAXWindowMatcher()

        print("")
        print("[LRUBoundary]")
        testLRUBoundary()

        print("")
        print("[Integration]")
        testIntegration()

        print("")
        print("[SlideOffset]")
        testSlideOffset()

        print("")
        print("[SlideChain]")
        testSlideChain()

        print("")
        print("[MenuBarImageCache]")
        testMenuBarImageCache()

        print("")
        print("[BackdropExclusion]")
        testBackdropExclusion()

        print("")
        print("[BackdropSessionUsable]")
        testBackdropSessionUsable()

        print("")
        print("[SettleFallback]")
        testSettleFallback()

        print("")
        print("[SlideMomentum]")
        testSlideMomentum()

        print("")
        print("Results: \(passed) passed, \(failed) failed")

        if failed > 0 {
            exit(1)
        }
    }
}
