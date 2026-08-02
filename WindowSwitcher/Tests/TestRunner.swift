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
        print("[Integration]")
        testIntegration()

        print("")
        print("Results: \(passed) passed, \(failed) failed")

        if failed > 0 {
            exit(1)
        }
    }
}
