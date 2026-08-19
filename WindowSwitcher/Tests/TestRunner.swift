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

// MARK: - SlideGeometry（覆盖/露出几何判别）Tests
// 验证 buried/reveal 判别（统一模型 2.3）：全盖→buried、有意义露出→reveal、
// 微小露出→buried、遮挡者并集覆盖→buried、矩形减法面积守恒。

private func testSlideGeometry() {
    let target = CGRect(x: 0, y: 0, width: 800, height: 600)

    runSuite("全屏源盖住目标 → buried") {
        let full = CGRect(x: 0, y: 0, width: 1470, height: 956)
        assertTrue(SlideGeometry.isEffectivelyCovered(target, by: [full]))
    }

    runSuite("目标明显部分露出（≥60px）→ reveal") {
        let cover = CGRect(x: 0, y: 0, width: 800, height: 300)
        assertFalse(SlideGeometry.isEffectivelyCovered(target, by: [cover]))
    }

    runSuite("微小露出（55px < 60 阈值）→ buried") {
        let cover = CGRect(x: 0, y: 0, width: 800, height: 545)
        assertTrue(SlideGeometry.isEffectivelyCovered(target, by: [cover]))
    }

    runSuite("遮挡者并集覆盖目标 → buried（单窗只盖一半，并集盖全）") {
        let a = CGRect(x: 0, y: 0, width: 400, height: 600)
        let b = CGRect(x: 400, y: 0, width: 400, height: 600)
        assertTrue(SlideGeometry.isEffectivelyCovered(target, by: [a, b]))
    }

    runSuite("矩形减法：挖去中心后面积守恒且剩 4 块") {
        let cover = CGRect(x: 200, y: 150, width: 400, height: 300)
        let regions = SlideGeometry.exposedRegions(target, subtracting: [cover])
        let area = regions.reduce(0) { $0 + $1.width * $1.height }
        assertEqual(regions.count, 4)
        assertEqual(area, 800 * 600 - 400 * 300)
    }

    runSuite("完全不覆盖 → 露出区域 = 目标本身") {
        let offscreen = CGRect(x: 2000, y: 2000, width: 100, height: 100)
        let regions = SlideGeometry.exposedRegions(target, subtracting: [offscreen])
        assertEqual(regions.count, 1)
        assertEqual(regions[0], target)
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
        print("[SlideGeometry]")
        testSlideGeometry()

        print("")
        print("[MenuBarImageCache]")
        testMenuBarImageCache()

        print("")
        print("Results: \(passed) passed, \(failed) failed")

        if failed > 0 {
            exit(1)
        }
    }
}
