import AppKit
import CoreGraphics

/// Manages the wall-bump elastic drag effect when the user swipes past the
/// boundary of the window list in non-cyclic mode. Owns all elastic-drag state;
/// AppDelegate calls into it from handleGesture and provides callbacks for
/// hint-window display (which AppDelegate owns).
final class ElasticDragController {
    static let shared = ElasticDragController()

    // MARK: - Callbacks (owned by AppDelegate)

    /// Called to show the quick-switch hint for the given window.
    var onShowHint: ((CGWindowID) -> Void)?
    /// Called to shake the hint window (after spring-back).
    var onShakeHint: (() -> Void)?

    // MARK: - State

    private(set) var isInProgress = false
    private(set) var sessionID = 0

    private var axWindow: AXUIElement?
    private var origin: CGPoint?
    private var watchdog: DispatchWorkItem?
    private var springBackGeneration = 0
    private var cachedBoundaryOrigin: CGPoint?
    private var atBoundaryWithoutDrag = false

    // MARK: - Accessors

    var hasBoundaryWithoutDrag: Bool { atBoundaryWithoutDrag }

    // MARK: - Boundary detection

    func isAtBoundary(directionRight: Bool) -> Bool {
        let engine = WindowManager.shared.orderingEngine
        guard engine.count > 1 else {
            logDebug("ElasticDrag: isAtBoundary → true (count=\(engine.count) ≤ 1)")
            return true
        }
        let result = engine.isAtBoundary(directionRight: directionRight)
        logDebug("ElasticDrag: isAtBoundary(dirRight=\(directionRight)) → \(result), count=\(engine.count)")
        return result
    }

    // MARK: - Drag lifecycle

    func beginElasticDrag() {
        springBackGeneration += 1
        let gen = springBackGeneration

        if isInProgress {
            logDebug("ElasticDrag: begin WARNING — already in progress [session=\(sessionID)], overwriting")
        }

        let wm = WindowManager.shared
        guard let currentID = wm.frontmostWindowID,
              let info = wm.windows[currentID] else {
            logDebug("ElasticDrag: begin FAILED [session=\(sessionID + 1)] — no window info")
            return
        }
        let app = AXUIElementCreateApplication(info.ownerPid)
        var focusedWindow: CFTypeRef?
        let axWin: AXUIElement?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let fw = focusedWindow {
            axWin = (fw as! AXUIElement)
        } else {
            let snapshots = wm.enumerateAXWindows(forPid: info.ownerPid)
            let match = snapshots.first { WindowManager.frameMatches($0.frame, info.frame, tolerance: 2) }
            axWin = match?.element
        }
        guard let axWin = axWin else {
            logDebug("ElasticDrag: begin FAILED [session=\(sessionID + 1)] — no AX window for pid=\(info.ownerPid)")
            return
        }

        var posVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posVal) == .success,
              let pv = posVal else {
            logDebug("ElasticDrag: begin FAILED [session=\(sessionID + 1)] — no position for pid=\(info.ownerPid)")
            return
        }
        var currentPos = CGPoint.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &currentPos)

        if cachedBoundaryOrigin == nil {
            cachedBoundaryOrigin = currentPos
            logDebug("ElasticDrag: cached boundary origin = (\(String(format: "%.1f", currentPos.x)), \(String(format: "%.1f", currentPos.y)))")
        }

        sessionID += 1
        self.axWindow = axWin
        origin = currentPos
        isInProgress = true
        logDebug("ElasticDrag: began [session=\(sessionID)], gen=\(gen), dragRef=(\(String(format: "%.1f", currentPos.x)), \(String(format: "%.1f", currentPos.y))), cachedOrigin=(\(String(format: "%.1f", cachedBoundaryOrigin!.x)), \(String(format: "%.1f", cachedBoundaryOrigin!.y))), title=\(info.windowTitle)")

        scheduleWatchdog()
    }

    func applyDisplacement(progress: Float) {
        guard let axWin = axWindow,
              let p0 = cachedBoundaryOrigin else {
            logDebug("ElasticDrag: apply skipped [session=\(sessionID)] — axWin=\(axWindow != nil ? "ok" : "nil"), cached=\(cachedBoundaryOrigin != nil ? "ok" : "nil")")
            return
        }
        let raw = CGFloat(progress) * 60.0
        let damped = raw / (1.0 + abs(raw) / 40.0)
        let maxDisp = CGFloat(AppSettings.shared.elasticDragMaxDisplacement)
        let clamped = max(-maxDisp, min(maxDisp, damped))
        var newPos = CGPoint(x: p0.x + clamped, y: p0.y)
        newPos.x = max(p0.x - maxDisp, min(p0.x + maxDisp, newPos.x))
        let val = AXValueCreate(.cgPoint, &newPos)!
        AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, val)
    }

    // MARK: - Watchdog

    func scheduleWatchdog() {
        let sid = sessionID
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isInProgress,
                  self.sessionID == sid else { return }
            logDebug("ElasticDrag: callback stream interrupted [session=\(sid)], triggering spring-back")
            self.finishDrag()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - Spring-back

    func finishDrag() {
        let sid = sessionID
        isInProgress = false
        watchdog?.cancel()
        watchdog = nil

        guard let axWin = axWindow,
              let p0 = cachedBoundaryOrigin else {
            logDebug("ElasticDrag: finish SKIPPED [session=\(sid)] — axWin=\(axWindow != nil ? "ok" : "nil"), cachedOrigin=\(cachedBoundaryOrigin != nil ? "ok" : "nil")")
            axWindow = nil
            origin = nil
            return
        }

        logDebug("ElasticDrag: finish [session=\(sid)], target=(\(String(format: "%.1f", p0.x)), \(String(format: "%.1f", p0.y)))")

        if let currentID = WindowManager.shared.frontmostWindowID {
            onShowHint?(currentID)
        }
        if AppSettings.shared.hintShakeEnabled {
            onShakeHint?()
        }

        // Spring-back animation: ease-out cubic over 0.3s.
        let gen = springBackGeneration
        var currentPos = p0
        var readPosVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &readPosVal) == .success,
           let rpv = readPosVal {
            AXValueGetValue(rpv as! AXValue, .cgPoint, &currentPos)
        }
        let startX = currentPos.x
        let targetX = p0.x
        logDebug("ElasticDrag: spring-back [session=\(sid), gen=\(gen)] from x=\(String(format: "%.1f", startX)) to x=\(String(format: "%.1f", targetX))")
        let steps = 12
        let duration: Double = 0.3
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1.0 - pow(1.0 - t, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * t) { [self] in
                guard springBackGeneration == gen else { return }
                var pos = CGPoint(x: startX + (targetX - startX) * CGFloat(eased),
                                  y: p0.y)
                let val = AXValueCreate(.cgPoint, &pos)!
                _ = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, val)
                if i == steps {
                    var finalPos = CGPoint.zero
                    var finalVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &finalVal) == .success {
                        AXValueGetValue(finalVal as! AXValue, .cgPoint, &finalPos)
                    }
                    let delta = abs(finalPos.x - targetX)
                    logDebug("ElasticDrag: spring-back DONE [session=\(sid), gen=\(gen)], step=\(i), finalX=\(String(format: "%.1f", finalPos.x)), targetX=\(String(format: "%.1f", targetX)), delta=\(String(format: "%.1f", delta))")
                }
            }
        }

        axWindow = nil
        origin = nil
    }

    // MARK: - Boundary without drag

    /// Called when the user swipes at a boundary with elasticDragEnabled=false.
    /// Shows the hint text with optional shake.
    func handleBoundaryHint() {
        guard let currentID = WindowManager.shared.frontmostWindowID else { return }
        onShowHint?(currentID)
        if AppSettings.shared.hintShakeEnabled {
            onShakeHint?()
        }
    }

    /// Set by handleGesture when at boundary without elastic drag enabled.
    func setBoundaryWithoutDrag() {
        atBoundaryWithoutDrag = true
    }

    func clearBoundaryWithoutDrag() {
        atBoundaryWithoutDrag = false
    }

    // MARK: - Reset

    /// Clear all state — called on service stop or when quickSwitch leaves the boundary.
    func clearBoundaryOrigin() {
        cachedBoundaryOrigin = nil
    }

    func reset() {
        isInProgress = false
        axWindow = nil
        origin = nil
        sessionID = 0
        watchdog?.cancel()
        watchdog = nil
        springBackGeneration = 0
        cachedBoundaryOrigin = nil
        atBoundaryWithoutDrag = false
    }
}
