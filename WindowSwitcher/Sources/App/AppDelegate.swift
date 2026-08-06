import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    static var shared: AppDelegate {
        NSApplication.shared.delegate as! AppDelegate
    }

    private let gestureEngine = GestureEngine.shared
    private let windowManager = WindowManager.shared
    private let overlayController = OverlayWindowController.shared
    private let menuBar = MenuBarController.shared
    private var currentQuickSwitchIndex: Int = 0

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logDebug("=== applicationDidFinishLaunching BEGIN ===")

        // Step 0: Ensure only one instance is running.
        logDebug("Step 0: Ensuring single instance...")
        ensureSingleInstance()

        // Step 1: Set activation policy to accessory FIRST.
        // NSApp launches with .regular policy, which briefly makes it frontmost
        // and disturbs the z-order. Setting .accessory immediately relinquishes
        // frontmost status so the z-order settles back to the user's real state.
        logDebug("Step 1: Setting activation policy to .accessory")
        NSApp.setActivationPolicy(.accessory)
        logDebug("Step 1: OK")

        // Step 2: Setup menu bar
        logDebug("Step 2: Setting up menu bar...")
        menuBar.setup()
        logDebug("Step 2: Menu bar OK")

        // Step 3: Start gesture detection via MultitouchSupport
        logDebug("Step 3: Starting gesture engine (MultitouchSupport)...")
        let gestureOK = gestureEngine.startFull()
        if gestureOK {
            logDebug("Step 3: Gesture engine started OK")
        } else {
            logDebug("Step 3: Gesture engine FAILED, trying NSEvent fallback...")
            _ = gestureEngine.start()
        }
        menuBar.updateIconAppearance()  // refresh icon now that engine is running

        // Step 4: Start interaction monitoring (checks Accessibility permission)
        logDebug("Step 4: Starting interaction monitoring...")
        let monitorOK = windowManager.startInteractionMonitoring()
        if monitorOK {
            logDebug("Step 4: Interaction monitoring started OK")
        } else {
            logDebug("Step 4: Interaction monitoring skipped (no Accessibility permission or other error)")
        }

        // Step 5: Wire callbacks
        logDebug("Step 5: Wiring callbacks...")
        wireCallbacks()
        logDebug("Step 5: Callbacks wired OK")

        // Step 6: Settings observer
        logDebug("Step 6: Setting up settings observer...")
        setupSettingsObserver()
        logDebug("Step 6: OK")

        // Step 6.5: Session observers — re-register the MultitouchSupport
        // device after lock/unlock or sleep/wake interrupts its contact stream.
        logDebug("Step 6.5: Setting up session observers...")
        setupSessionObservers()
        logDebug("Step 6.5: OK")

        // Step 7: Check permissions and alert if needed
        logDebug("Step 7: Checking permissions...")
        checkPermissions()

        // Step 8: Capture window state after all init settles.
        // This is where v1 logAppZOrder got the correct Cmd+Tab order.
        _ = windowManager.refreshWindows()
        logDebug("Initial LRU order:\n\(windowManager.orderingEngine.dumpLRU())")
        logAppZOrder()
        checkOrderConsistency()

        logDebug("=== applicationDidFinishLaunching END (SUCCESS) ===")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logDebug("applicationWillTerminate")
        gestureEngine.stop()
        windowManager.stopInteractionMonitoring()
    }

    // MARK: - Service lifecycle

    /// Whether the gesture service is currently running (drives menu enable/disable).
    var serviceIsRunning: Bool {
        gestureEngine.isRunning
    }

    /// Start the full service: clear the log, start gesture detection, start
    /// interaction monitoring, then (re)wire callbacks. GestureEngine.stop()
    /// nils onGesture, so callbacks must be re-wired on every start.
    func startService() {
        logDebug("startService called")

        // 0. Ensure only one instance is running.
        ensureSingleInstance()

        // 1. Clear the log first so this run starts clean (no historical noise).
        Logger.shared.clearLog()
        gesture_engine_reset_log()
        logDebug("=== 服务启动 ===")

        // 2. Start gesture engine (MT first, fall back to NSEvent).
        let gestureOK = gestureEngine.startFull()
        if gestureOK {
            logDebug("startService: gesture engine started OK")
        } else {
            logDebug("startService: MT engine failed, falling back to NSEvent...")
            _ = gestureEngine.start()
        }

        // 3. Start interaction monitoring (requires Accessibility permission).
        let monitorOK = windowManager.startInteractionMonitoring()
        if monitorOK {
            logDebug("startService: interaction monitoring started OK")
        } else {
            logDebug("startService: interaction monitoring skipped (no Accessibility permission or other error)")
        }

        // 4. Re-wire callbacks (onGesture was cleared by stop()).
        wireCallbacks()
        menuBar.updateIconAppearance()
    }

    /// Stop the gesture engine, interaction monitoring, and any visible overlay.
    func stopService() {
        logDebug("stopService called")
        gestureEngine.stop()
        windowManager.stopInteractionMonitoring()
        overlayController.hide()
    }

    /// Restart the service: stop then start (clears the log again).
    func restartService() {
        logDebug("restartService called")
        stopService()
        startService()
    }

    private func wireCallbacks() {
        windowManager.onInteraction = { windowID in
            logDebug("onInteraction fired for window \(windowID)")
        }
        windowManager.onTrackpadActivity = { [weak self] in
            self?.gestureEngine.noteTrackpadActivity()
        }
        gestureEngine.onGesture = { [weak self] event in
            self?.handleGesture(event)
        }
    }

    // MARK: - Single instance enforcement

    /// Check for other WindowSwitcher instances via pgrep. If found, show an
    /// alert (kill command auto-copied to clipboard), auto-dismiss after 5s or
    /// via ESC/OK, then terminate. Safe to call on the main thread only.
    private func ensureSingleInstance() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "WindowSwitcher"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return // can't check — proceed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return }

        let otherPIDs = output.split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != myPID }
        guard !otherPIDs.isEmpty else { return }

        let cmd = "kill -9 " + otherPIDs.map(String.init).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)

        logDebug("ensureSingleInstance: found other instances pids=\(otherPIDs), alerting user")

        let alert = NSAlert()
        alert.messageText = "已有正在运行的实例"
        alert.informativeText = "可通过 \(cmd) 命令清理该进程\n\n该命令已自动复制到剪贴板中"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        NSApp.activate(ignoringOtherApps: true)
        // Auto-dismiss after 5s. DispatchQueue fires during the modal run loop.
        let dismissWork = DispatchWorkItem { NSApp.stopModal(withCode: .cancel) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: dismissWork)
        alert.runModal()
        dismissWork.cancel()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Gesture dispatch

    private func handleGesture(_ event: GestureEvent) {
        let settings = AppSettings.shared

        switch event {
        case .threeFingerTap:
            logDebug("GESTURE: threeFingerTap, overlayVisible=\(overlayController.isVisible)")
            windowManager.isGestureActive = false
            if elasticDragInProgress {
                logDebug("ElasticDrag: tap intercepted [session=\(elasticDragSessionID)], triggering spring-back")
                finishElasticDrag()
                return
            }
            if overlayController.isVisible {
                overlayController.selectFocused()
                return
            }
            guard settings.immersiveModeEnabled, settings.threeFingerTapEnabled else { return }
            showImmersiveOverlay()

        case .threeFingerSwipeUp:
            logDebug("GESTURE: threeFingerSwipeUp, overlayVisible=\(overlayController.isVisible)")
            windowManager.isGestureActive = false
            if elasticDragInProgress {
                logDebug("ElasticDrag: swipeUp intercepted [session=\(elasticDragSessionID)], triggering spring-back")
                finishElasticDrag()
                return
            }
            if overlayController.isVisible { return }
            guard settings.immersiveModeEnabled, settings.threeFingerSwipeUpEnabled else { return }
            showImmersiveOverlay()

        case .threeFingerSwipeDown:
            logDebug("GESTURE: threeFingerSwipeDown, overlayVisible=\(overlayController.isVisible)")
            windowManager.isGestureActive = false
            if overlayController.isVisible {
                overlayController.hide()
                return
            }

        case .threeFingerSwipeLeft:
            windowManager.isGestureActive = true
            guard !overlayController.isVisible else { return }
            if elasticDragInProgress {
                logDebug("ElasticDrag: BUG swipeLeft while drag in progress [session=\(elasticDragSessionID)] — gestureEnd/tap was NOT received before next swipe action!")
            }
            guard settings.quickSwitchModeEnabled else { return }
            if !settings.cyclicScrollEnabled && isAtBoundary(directionRight: true) {
                logDebug("ElasticDrag: swipeLeft at boundary, skipping quickSwitch")
                return
            }
            quickSwitch(directionRight: true)

        case .threeFingerSwipeRight:
            windowManager.isGestureActive = true
            guard !overlayController.isVisible else { return }
            if elasticDragInProgress {
                logDebug("ElasticDrag: BUG swipeRight while drag in progress [session=\(elasticDragSessionID)] — gestureEnd/tap was NOT received before next swipe action!")
            }
            guard settings.quickSwitchModeEnabled else { return }
            if !settings.cyclicScrollEnabled && isAtBoundary(directionRight: false) {
                logDebug("ElasticDrag: swipeRight at boundary, skipping quickSwitch")
                return
            }
            quickSwitch(directionRight: false)

        case .swipeUpdate(let progress):
            windowManager.isGestureActive = true
            guard !overlayController.isVisible else { return }
            guard settings.quickSwitchModeEnabled, !settings.cyclicScrollEnabled else { return }
            let dirRight = progress < 0
            if !elasticDragInProgress {
                guard isAtBoundary(directionRight: dirRight) else { return }
                if settings.elasticDragEnabled {
                    logDebug("ElasticDrag: begin [session=\(elasticDragSessionID + 1)], progress=\(String(format: "%.3f", progress)), dirRight=\(dirRight)")
                    beginElasticDrag()
                } else {
                    atBoundaryWithoutDrag = true
                }
            }
            if settings.elasticDragEnabled {
                applyElasticDisplacement(progress: progress)
            }

        case .gestureEnd:
            windowManager.isGestureActive = false
            logDebug("ElasticDrag: gestureEnd, inProgress=\(elasticDragInProgress), session=\(elasticDragSessionID)")
            if elasticDragInProgress {
                finishElasticDrag()
            } else if atBoundaryWithoutDrag {
                atBoundaryWithoutDrag = false
                logDebug("ElasticDrag: gestureEnd — showing hint at boundary (drag disabled)")
                if let currentID = windowManager.frontmostWindowID {
                    showQuickSwitchHint(for: currentID)
                }
                if AppSettings.shared.hintShakeEnabled, let hint = hintWindow {
                    let hintOrigin = hint.frame.origin
                    let offsets: [CGFloat] = [-8, 8, -6, 6, 0]
                    var delay: Double = 0
                    for offset in offsets {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            hint.setFrameOrigin(NSPoint(x: hintOrigin.x + offset, y: hintOrigin.y))
                        }
                        delay += 0.06
                    }
                }
            } else {
                logDebug("ElasticDrag: gestureEnd ignored — no drag in progress")
            }
        }
    }

    // MARK: - Immersive mode

    private func showImmersiveOverlay() {
        let t0 = CACurrentMediaTime()
        logDebug("TIMING: [t=0ms] showImmersiveOverlay called")

        let windowList = windowManager.refreshWindows()
        let t1 = CACurrentMediaTime()
        logDebug("TIMING: [t=\(Int((t1 - t0) * 1000))ms] refreshWindows done, \(windowList.count) windows")

        guard !windowList.isEmpty else {
            logDebug("showImmersiveOverlay: no windows found, aborting")
            return
        }

        // Preload only visible windows synchronously, the rest in background
        let visibleCount = min(AppSettings.shared.maxVisibleCount, windowList.count)
        windowManager.preloadThumbnails(count: visibleCount)
        let t2 = CACurrentMediaTime()
        let cachedCount = windowList.prefix(visibleCount).filter { $0.thumbnail != nil }.count
        logDebug("TIMING: [t=\(Int((t2 - t0) * 1000))ms] preload visible done (capture=\(Int((t2 - t1) * 1000))ms, hit=\(cachedCount), miss=\(visibleCount - cachedCount))")

        let orderedIDs = windowManager.orderingEngine.orderedIDs
        let windowsWithThumbnails = orderedIDs.compactMap { windowManager.windows[$0] }
        let names = orderedIDs.compactMap { windowManager.windows[$0]?.ownerName }
        logDebug("IMMERSIVE-SHOW: LRU order = \(names.enumerated().map { "[\($0)]\($1)" }.joined(separator: " → "))")
        overlayController.show(with: windowsWithThumbnails)
        let t3 = CACurrentMediaTime()
        logDebug("TIMING: [t=\(Int((t3 - t0) * 1000))ms] overlay shown (UI=\(Int((t3 - t2) * 1000))ms, total=\(Int((t3 - t0) * 1000))ms)")

        // Background: capture remaining windows
        let remaining = windowList.count - visibleCount
        if remaining > 0 {
            let remainingIDs = Array(orderedIDs.dropFirst(visibleCount))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var captured: [(CGWindowID, NSImage)] = []
                for id in remainingIDs {
                    if let image = self.windowManager.captureRawImage(for: id) {
                        captured.append((id, image))
                    }
                }
                if !captured.isEmpty {
                    DispatchQueue.main.async {
                        for (id, image) in captured {
                            self.windowManager.setThumbnail(image, for: id)
                        }
                        self.overlayController.refreshThumbnails()
                        logDebug("TIMING: background preload complete, captured \(captured.count) thumbnails")
                    }
                }
            }
        }
    }

    // MARK: - Quick switch mode

    private func quickSwitch(directionRight: Bool) {
        if elasticDragInProgress {
            logDebug("ElasticDrag: BUG quickSwitch called while drag in progress [session=\(elasticDragSessionID)]!")
        }
        let dirLabel = directionRight ? "→ 右滑" : "← 左滑"
        let windows = windowManager.refreshWindows()
        guard windows.count > 1 else { return }
        let cyclic = AppSettings.shared.cyclicScrollEnabled
        guard let target = windowManager.orderingEngine.advanceCursor(directionRight: directionRight,
                                                                      cyclic: cyclic) else {
            logDebug("QuickSwitch: \(dirLabel) ⛔ wall-bump, staying put")
            return
        }

        let targetName = windowManager.orderingEngine.windowNames[target] ?? "?"
        logDebug("QuickSwitch: \(dirLabel) → 激活 [\(targetName)]")

        windowManager.activateWindow(target)
        cachedBoundaryOrigin = nil  // left the boundary — clear cached origin
        if AppSettings.shared.quickSwitchHintEnabled {
            showQuickSwitchHint(for: target)
        }
    }

    // MARK: - Elastic drag (wall-bump)

    /// Returns true if the cursor is at the boundary for the given swipe direction.
    private func isAtBoundary(directionRight: Bool) -> Bool {
        let engine = windowManager.orderingEngine
        guard engine.count > 1 else {
            logDebug("ElasticDrag: isAtBoundary → true (count=\(engine.count) ≤ 1)")
            return true
        }
        let result = engine.isAtBoundary(directionRight: directionRight)
        logDebug("ElasticDrag: isAtBoundary(dirRight=\(directionRight)) → \(result), count=\(engine.count)")
        return result
    }

    private func beginElasticDrag() {
        // Cancel any in-flight spring-back animation frames from a previous session.
        springBackGeneration += 1
        let gen = springBackGeneration

        if elasticDragInProgress {
            logDebug("ElasticDrag: begin WARNING — already in progress [session=\(elasticDragSessionID)], overwriting")
            elasticDragStaleTimer?.cancel()
        }

        guard let currentID = windowManager.frontmostWindowID,
              let info = windowManager.windows[currentID] else {
            logDebug("ElasticDrag: begin FAILED [session=\(elasticDragSessionID + 1)] — no window info")
            return
        }
        let app = AXUIElementCreateApplication(info.ownerPid)
        var focusedWindow: CFTypeRef?
        let axWin: AXUIElement?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let fw = focusedWindow {
            axWin = (fw as! AXUIElement)
        } else {
            axWin = axWindowFor(pid: info.ownerPid, frame: info.frame)
        }
        guard let axWin = axWin else {
            logDebug("ElasticDrag: begin FAILED [session=\(elasticDragSessionID + 1)] — no AX window for pid=\(info.ownerPid)")
            return
        }

        // Read the window's current position as the drag reference point.
        // If a previous spring-back animation was mid-flight, the generation bump
        // above already cancelled its remaining frames; we pick up from wherever
        // the window currently sits — this gives natural frame continuation.
        guard let currentPos = axPosition(of: axWin) else {
            logDebug("ElasticDrag: begin FAILED [session=\(elasticDragSessionID + 1)] — no position for pid=\(info.ownerPid)")
            return
        }

        // On the very first boundary hit, capture the true original position.
        // All subsequent spring-backs target this cached value — never drifts.
        if cachedBoundaryOrigin == nil {
            cachedBoundaryOrigin = currentPos
            logDebug("ElasticDrag: cached boundary origin = (\(String(format: "%.1f", currentPos.x)), \(String(format: "%.1f", currentPos.y)))")
        }

        elasticDragSessionID += 1
        elasticDragAxWindow = axWin
        elasticDragOrigin = currentPos
        elasticDragInProgress = true
        logDebug("ElasticDrag: began [session=\(elasticDragSessionID)], gen=\(gen), dragRef=(\(String(format: "%.1f", currentPos.x)), \(String(format: "%.1f", currentPos.y))), cachedOrigin=(\(String(format: "%.1f", cachedBoundaryOrigin!.x)), \(String(format: "%.1f", cachedBoundaryOrigin!.y))), title=\(info.windowTitle)")

        // Stale-state watchdog: if GestureEnd hasn't arrived within 3s, log it.
        let sid = elasticDragSessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.elasticDragInProgress, self.elasticDragSessionID == sid else { return }
            logDebug("ElasticDrag: STALE STATE [session=\(sid)] — elasticDragInProgress still true after 3s!")
        }
        elasticDragStaleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func applyElasticDisplacement(progress: Float) {
        guard let axWin = elasticDragAxWindow,
              let origin = elasticDragOrigin,
              let p0 = cachedBoundaryOrigin else {
            logDebug("ElasticDrag: apply skipped [session=\(elasticDragSessionID)] — axWin=\(elasticDragAxWindow != nil ? "ok" : "nil"), origin=\(elasticDragOrigin != nil ? "ok" : "nil"), cached=\(cachedBoundaryOrigin != nil ? "ok" : "nil")")
            return
        }
        let raw = CGFloat(progress) * 60.0
        let damped = raw / (1.0 + abs(raw) / 40.0)
        let maxDisp = CGFloat(AppSettings.shared.elasticDragMaxDisplacement)
        let clamped = max(-maxDisp, min(maxDisp, damped))
        var newPos = CGPoint(x: origin.x + clamped, y: origin.y)
        // Clamp to ±maxDisp from the true original position
        newPos.x = max(p0.x - maxDisp, min(p0.x + maxDisp, newPos.x))
        let val = AXValueCreate(.cgPoint, &newPos)!
        AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, val)
    }

    private func finishElasticDrag() {
        let sid = elasticDragSessionID
        elasticDragInProgress = false
        elasticDragStaleTimer?.cancel()
        elasticDragStaleTimer = nil

        guard let axWin = elasticDragAxWindow,
              let p0 = cachedBoundaryOrigin else {
            logDebug("ElasticDrag: finish SKIPPED [session=\(sid)] — axWin=\(elasticDragAxWindow != nil ? "ok" : "nil"), cachedOrigin=\(cachedBoundaryOrigin != nil ? "ok" : "nil")")
            elasticDragAxWindow = nil
            elasticDragOrigin = nil
            return
        }

        logDebug("ElasticDrag: finish [session=\(sid)], target=(\(String(format: "%.1f", p0.x)), \(String(format: "%.1f", p0.y)))")

        // Show hint text
        if let currentID = windowManager.frontmostWindowID {
            showQuickSwitchHint(for: currentID)
        }

        // Shake the hint window
        if AppSettings.shared.hintShakeEnabled, let hint = hintWindow {
            let hintOrigin = hint.frame.origin
            let offsets: [CGFloat] = [-8, 8, -6, 6, 0]
            var delay: Double = 0
            for offset in offsets {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    hint.setFrameOrigin(NSPoint(x: hintOrigin.x + offset, y: hintOrigin.y))
                }
                delay += 0.06
            }
        }

        // Spring-back animation: ease-out cubic over 0.3s.
        // Always targets cachedBoundaryOrigin (the true original position).
        // Each frame checks springBackGeneration — if a new drag starts before
        // this animation completes, beginElasticDrag increments the generation
        // and all remaining frames become no-ops.
        let gen = springBackGeneration
        var currentPos = p0
        if let p = axPosition(of: axWin) { currentPos = p }
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

        elasticDragAxWindow = nil
        elasticDragOrigin = nil
    }

    /// Find the AXUIElement for a window matching the given pid and frame.
    private func axWindowFor(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
              let axWindows = list as? [AXUIElement] else { return nil }

        for axWin in axWindows {
            guard let axFrame = axFrame(of: axWin) else { continue }
            if abs(axFrame.origin.x - frame.origin.x) < 2,
               abs(axFrame.origin.y - frame.origin.y) < 2,
               abs(axFrame.size.width - frame.size.width) < 2,
               abs(axFrame.size.height - frame.size.height) < 2 {
                return axWin
            }
        }
        return nil
    }

    private func axFrame(of axWindow: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeVal) == .success else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func axPosition(of axWindow: AXUIElement) -> CGPoint? {
        var posVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posVal) == .success else { return nil }
        var pos = CGPoint.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos) else { return nil }
        return pos
    }

    // MARK: - Quick switch hint

    private var hintWindow: NSWindow?
    private var hintDismissWork: DispatchWorkItem?

    // Elastic drag state for wall-bump effect
    private var elasticDragInProgress = false
    private var elasticDragAxWindow: AXUIElement?
    private var elasticDragOrigin: CGPoint?
    private var elasticDragSessionID = 0
    private var elasticDragStaleTimer: DispatchWorkItem?

    // Animation generation counter. Incremented each beginElasticDrag so stale
    // spring-back animation frames from a previous session bail out.
    private var springBackGeneration = 0

    // The true original window position, captured on the first boundary hit.
    // All spring-back animations target this position (never drifts).
    // Cleared when the user successfully switches away from the boundary.
    private var cachedBoundaryOrigin: CGPoint?

    // True when user swipes at boundary with elasticDragEnabled=false.
    // On gestureEnd, show hint text + shake without window dragging.
    private var atBoundaryWithoutDrag = false

    private func showQuickSwitchHint(for windowID: CGWindowID) {
        guard let info = windowManager.windows[windowID] else { return }
        guard let screen = NSScreen.main else { return }

        let hintWidth: CGFloat = 300
        let hintHeight: CGFloat = 50
        let hintRect = NSRect(
            x: (screen.frame.width - hintWidth) / 2,
            y: screen.frame.height - 120,
            width: hintWidth,
            height: hintHeight
        )

        let label = "\(info.ownerName) — \(info.windowTitle)"

        if let existing = hintWindow {
            if let hosting = existing.contentView as? NSHostingView<QuickSwitchHintView> {
                hosting.rootView = QuickSwitchHintView(text: label)
            }
            existing.setFrameOrigin(NSPoint(x: hintRect.origin.x, y: hintRect.origin.y))
            existing.orderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: hintWidth, height: hintHeight),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .transient]

            let hosting = NSHostingView(rootView: QuickSwitchHintView(text: label))
            hosting.frame = NSRect(x: 0, y: 0, width: hintWidth, height: hintHeight)
            window.setFrameOrigin(NSPoint(x: hintRect.origin.x, y: hintRect.origin.y))
            window.contentView = hosting

            window.orderFront(nil)
            hintWindow = window
        }

        hintDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hintWindow?.orderOut(nil)
        }
        hintDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Settings observer

    private var settingsObserver: NSObjectProtocol?

    private func setupSettingsObserver() {
        // Reserved for future dynamic settings updates.
        // Sensitivity is currently handled within the NSEvent-based GestureEngine.
    }

    // MARK: - Session observers (MT stream recovery)

    private var sessionObservers: [NSObjectProtocol] = []
    private var lastSessionRestartDate: Date?

    /// The MultitouchSupport contact stream is killed by lock/unlock, sleep/wake
    /// and session changes. Re-register the gesture engine device after the
    /// session becomes active again so gestures keep working.
    private func setupSessionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sessionObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            logDebug("Session observers: session became active — scheduling MT restart")
            self?.scheduleGestureRestart()
        })
        sessionObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            logDebug("Session observers: system woke — scheduling MT restart")
            self?.scheduleGestureRestart()
        })
        sessionObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            logDebug("Session observers: screens woke — scheduling MT restart")
            self?.scheduleGestureRestart()
        })
        // Lock/resign is logged only for diagnostics; recovery happens on resume.
        sessionObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            logDebug("Session observers: session resigned (lock/sleep/FUS)")
        })
    }

    private func scheduleGestureRestart() {
        let now = Date()
        if let last = lastSessionRestartDate, now.timeIntervalSince(last) < 3.0 {
            logDebug("Session observers: restart already scheduled recently, skipping")
            return
        }
        lastSessionRestartDate = now
        // Let the session / display settle before re-registering the device.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.gestureEngine.restart()
        }
    }

    // MARK: - Permission check

    private func checkPermissions() {
        let axOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)
        logDebug("Permission check: Accessibility = \(axTrusted)")

        if !axTrusted {
            logDebug("Accessibility NOT granted — showing alert")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPermissionAlert()
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要权限"
        alert.informativeText = """
        WindowSwitcher 需要以下权限才能正常工作：

        1. 辅助功能权限 — 用于监听键盘/鼠标交互和切换窗口
        2. 屏幕录制权限 — 用于采集窗口缩略图

        请在"系统设置 → 隐私与安全性"中授予相应权限。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: - Diagnostics

    /// Log the app-level z-order derived from the SAME CGWindowList snapshot as the LRU.
    private func logAppZOrder() {
        let orderedIDs = windowManager.orderingEngine.orderedIDs
        var seen = Set<String>()
        var order: [String] = []
        for id in orderedIDs {
            guard let info = windowManager.windows[id] else { continue }
            if seen.insert(info.ownerName).inserted {
                order.append(info.ownerName)
            }
        }

        logDebug("App z-order v2 (from same snapshot), \(order.count) apps:")
        for (i, name) in order.enumerated() {
            logDebug("  [\(i)] \(name)")
        }
    }

    /// Validate that the LRU ordering is internally consistent and matches
    /// the system frontmost app.
    private func checkOrderConsistency() {
        let orderedIDs = windowManager.orderingEngine.orderedIDs

        // 1. Derive app-level order from LRU
        var seen = Set<String>()
        var lruAppOrder: [String] = []
        for id in orderedIDs {
            guard let info = windowManager.windows[id] else { continue }
            if seen.insert(info.ownerName).inserted {
                lruAppOrder.append(info.ownerName)
            }
        }

        var issues: [String] = []

        // 2. Check: frontmost app from NSWorkspace matches LRU[0]
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let firstID = orderedIDs.first,
           let firstInfo = windowManager.windows[firstID] {
            let frontmostName = frontmost.localizedName ?? "?"
            if firstInfo.ownerName != frontmostName {
                issues.append("frontmost mismatch: NSWorkspace=[\(frontmostName)], LRU[0]=[\(firstInfo.ownerName)]")
            }
        }

        // 3. Check: same-app windows should be non-interleaved
        var lastSeen: [String: Int] = [:]
        for (idx, id) in orderedIDs.enumerated() {
            guard let info = windowManager.windows[id] else { continue }
            let owner = info.ownerName
            if let prev = lastSeen[owner] {
                for mid in (prev + 1)..<idx {
                    if let midInfo = windowManager.windows[orderedIDs[mid]],
                       midInfo.ownerName != owner {
                        issues.append("interleaved: [\(owner)] at [\(prev)]&[\(idx)], but [\(mid)]=[\(midInfo.ownerName)]")
                        break
                    }
                }
            }
            lastSeen[owner] = idx
        }

        // 4. Report
        logDebug("=== ORDER CONSISTENCY CHECK ===")
        if issues.isEmpty {
            logDebug("PASS")
            logDebug("  app-order: \(lruAppOrder.joined(separator: " → "))")
            logDebug("  frontmost: match")
            logDebug("  interleaving: none")
        } else {
            logDebug("FAIL (\(issues.count) issues):")
            for issue in issues {
                logDebug("  - \(issue)")
            }
        }
        logDebug("=== END ===")
    }
}

// MARK: - Quick Switch Hint View

struct QuickSwitchHintView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}
