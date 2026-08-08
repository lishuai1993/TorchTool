import AppKit
import CoreGraphics

final class WindowManager: @unchecked Sendable {
    static let shared = WindowManager()

    let orderingEngine = LRUOrderingEngine()
    let activationHistory = ActivationHistory()
    let activationSuppressor = ActivationSuppressor()
    let axFocusObserver = AXFocusObserver()
    private let axMatcher = AXWindowMatcher.shared
    private let thumbCapturer = ThumbnailCapturer.shared

    /// Current snapshot of visible windows, keyed by CGWindowID.
    var windows: [CGWindowID: WindowInfo] = [:]

    /// Windows in LRU order (convenience for display reconstruction).
    var orderedWindows: [WindowInfo] {
        orderingEngine.orderedIDs.compactMap { windows[$0] }
    }

    /// Current frontmost window ID.
    private(set) var frontmostWindowID: CGWindowID?

    private var scrollMonitor: Any?
    private var interactionMonitor: Any?

    /// Scroll-gesture state machine. A single trackpad scroll gesture
    /// (began → … → ended) promotes the frontmost window to the LRU head
    /// exactly once; the dedup flag is re-armed on the next gesture.
    private var scrollGestureActive = false
    private var scrollDidTriggerReorder = false
    private var lastScrollReorderTime: TimeInterval = 0

    /// Callback invoked when a window receives substantial interaction.
    var onInteraction: ((CGWindowID) -> Void)?

    /// Callback invoked on trackpad scroll/swipe events.
    var onTrackpadActivity: (() -> Void)?

    /// The current gesture/interaction phase, driven by AppDelegate.
    /// Scroll events are treated as gesture artifacts (and do NOT trigger
    /// windowDidInteract) only while quickSwitching or elasticDragging.
    var gesturePhase: GesturePhase = .idle

    /// Per-app z-ordered window list (CGWindowID + frame) from the most recent
    /// refresh, in CGWindowList order (frontmost first). Used to correlate a
    /// target CGWindowID to the matching AX element by z-order rank, since
    /// AX kAXWindows order mirrors the window-server z-order.
    private(set) var appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]

    /// Delegate thumbnail capture to the extracted capturer.
    func captureRawImage(for windowID: CGWindowID, ownerName: String = "?") -> NSImage? {
        thumbCapturer.captureRawImage(for: windowID, ownerName: ownerName)
    }
    func preloadThumbnails(count: Int) { thumbCapturer.preloadThumbnails(count: count) }
    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        thumbCapturer.setThumbnail(image, for: windowID)
    }
    func clearThumbnailCache() { thumbCapturer.clearCache() }

    /// Guard flag to prevent event tap / activation notification from
    /// reordering the list during programmatic window activation.
    private var isActivating = false

    private init() {
        activationHistory.onAppActivated = { [weak self] pid in
            guard let self, !self.isActivating else { return }
            // Suppress the notification caused by our own programmatic
            // app.activate() (delivered asynchronously after isActivating reset).
            if self.activationSuppressor.shouldSuppress(pid: pid) {
                logDebug("ActivationHistory: suppressed programmatic activation pid=\(pid)")
                return
            }
            // Real user activation (Cmd+Tab, Dock click) — record focus
            // but do NOT reorder. Only substantial interaction (click/type)
            // triggers windowDidInteract → reorder.
            if let topWindowID = self.orderingEngine.orderedIDs.first(where: { id in
                self.windows[id]?.ownerPid == pid
            }) {
                self.orderingEngine.windowDidFocus(topWindowID)
            }
            // Refresh the frontmost-window cache so the event tap's
            // windowDidInteract reorders the window the user is ACTUALLY in.
            // Validate against the canonical window list to avoid storing an ID
            // from a stale snapshot that may have been filtered out by parseWindow.
            if let front = self.frontmostWindow(for: pid), windows[front] != nil {
                self.frontmostWindowID = front
            } else if frontmostWindowID == nil || windows[frontmostWindowID!] == nil {
                self.frontmostWindowID = orderingEngine.orderedIDs.first
            }
            // Start observing same-app focused-window changes for the new app.
            self.axFocusObserver.startObserving(pid: pid)
        }

        axFocusObserver.onFocusChanged = { [weak self] pid in
            self?.handleAXFocusChange(pid: pid)
        }
    }

    // MARK: - Window enumeration

    /// Refresh the window list from the system.
    func refreshWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            logDebug("WindowManager: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        var newWindows: [CGWindowID: WindowInfo] = [:]
        var orderedIDs: [CGWindowID] = []

        for dict in list {
            guard let info = parseWindow(dict) else { continue }
            newWindows[info.id] = info
            orderedIDs.append(info.id)
        }

        // Cache the per-app z-order snapshot (frontmost first) for correlating
        // a target CGWindowID to its AX element by rank.
        var zOrderByPid: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]
        for id in orderedIDs {
            guard let info = newWindows[id] else { continue }
            zOrderByPid[info.ownerPid, default: []].append((id, info.frame))
        }
        appZOrder = zOrderByPid

        // Backfill real titles from AX for apps whose CGWindowList title is
        // empty (e.g. Chrome), correlated by frame / z-order rank.
        axMatcher.backfillTitles(&newWindows, appZOrder: appZOrder)

        windows = newWindows
        orderingEngine.sync(windowIDs: orderedIDs)

        // Populate window name lookup for LRU diagnostics
        for (id, info) in newWindows {
            let title = info.windowTitle.isEmpty ? "" : " — \(info.windowTitle)"
            orderingEngine.windowNames[id] = "\(info.ownerName)\(title)"
        }

        // Update frontmost if stale — but don't clobber a fresher value set
        // by handleAXFocusChange or activateWindow between refreshes.
        if let front = orderedIDs.first {
            if frontmostWindowID == nil || windows[frontmostWindowID!] == nil {
                frontmostWindowID = front
            }
            orderingEngine.windowDidFocus(front)
        }

        logDebug("WindowManager: refreshed \(orderedIDs.count) windows")
        return orderedIDs.compactMap { newWindows[$0] }
    }

    func activateWindow(_ windowID: CGWindowID) {
        isActivating = true
        defer { isActivating = false }

        guard let info = windows[windowID] else {
            logDebug("WindowManager: activateWindow - window \(windowID) not found")
            return
        }

        // Step 1: Resolve the application
        let app: NSRunningApplication?
        if let bid = info.ownerBundleID, !bid.isEmpty,
           let a = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app = a
        } else {
            app = NSRunningApplication(processIdentifier: info.ownerPid)
        }
        guard let app = app else {
            logDebug("WindowManager: activateWindow - app not found for \(info.ownerName)")
            return
        }
        let needsActivate = !app.isActive
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        logDebug("ACTIVATE-DIAG: [\(info.ownerName)] pid=\(app.processIdentifier) bid=\(app.bundleIdentifier ?? "nil") isActive=\(app.isActive) needsActivate=\(needsActivate) frontmostBefore=\(frontmostBefore) window=\(windowID)")

        // Step 2: Raise the specific window via Accessibility API.
        // Do this BEFORE activation so the app comes to front already showing
        // the correct window, avoiding a flash of a different window first.
        let snapshots = axMatcher.enumerateAXWindows(forPid: info.ownerPid)
        if !snapshots.isEmpty {
            logDebug("AX: \(info.ownerName) has \(snapshots.count) AX windows, target=[\(info.windowTitle)] frame=\(info.frame)")

            // Build index-keyed info for selectAXWindow
            var axWindowsInfo: [(index: Int, title: String, frame: CGRect)] = []
            for (idx, s) in snapshots.enumerated() {
                logDebug("AX:   [\(idx)][\(s.title)] frame=\(s.frame)")
                axWindowsInfo.append((idx, s.title, s.frame))
            }

            // Select the AX element that corresponds to the EXACT target window:
            // frame group first, then z-order rank within the group.
            let selected = axMatcher.selectAXWindow(
                for: windowID,
                pid: info.ownerPid,
                frame: info.frame,
                title: info.windowTitle,
                axWindows: axWindowsInfo,
                appZOrder: appZOrder
            )

            if let sel = selected, sel.index >= 0 && sel.index < snapshots.count {
                AXUIElementPerformAction(snapshots[sel.index].element, kAXRaiseAction as CFString)
                logDebug("AX: raised [\(info.ownerName)] idx=\(sel.index) title=\"\(sel.title)\"")
                axMatcher.scheduleMappingCheck(pid: info.ownerPid, expectedTitle: sel.title, windowID: windowID)
            } else {
                logDebug("AX: NO MATCH for [\(info.ownerName) — \(info.windowTitle)]")
            }
        } else {
            logDebug("AX: failed to get windows for \(info.ownerName)")
        }

        // Step 3: Activate the application if not already frontmost.
        // Done AFTER raising so the correct window is shown immediately,
        // avoiding a flash of a different window appearing first.
        if needsActivate {
            logDebug("ACTIVATE-DIAG: calling app.activate() for [\(info.ownerName)] pid=\(app.processIdentifier)")
            activationSuppressor.recordActivation(pid: app.processIdentifier)
            let activateResult = app.activate()
            logDebug("ACTIVATE-DIAG: app.activate() returned \(activateResult) for [\(info.ownerName)]")
            // Ground-truth: did the app actually become frontmost?
            let pid = app.processIdentifier
            let name = info.ownerName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let frontmostAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let activeNow = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
                logDebug("ACTIVATE-DIAG: after 300ms frontmost=\(frontmostAfter) [\(name)] isActiveNow=\(activeNow)")
            }
        } else {
            logDebug("ACTIVATE-DIAG: skipping app.activate() (already active or needsActivate=false) for [\(info.ownerName)]")
        }

        frontmostWindowID = windowID
        let idxBefore = orderingEngine.index(of: windowID)
        orderingEngine.userDidSelectWindow(windowID)
        logDebug("ACTIVATE-DONE: window=\(info.ownerName) — \(info.windowTitle) idx=\(idxBefore.map(String.init(describing:)) ?? "nil") cursorAfter=\(orderingEngine.orderedIDs.firstIndex(of: windowID).map(String.init(describing:)) ?? "nil") orderedIDs[0]=\(orderingEngine.windowNames[orderingEngine.orderedIDs.first!] ?? "?") isActivating=\(isActivating)")
    }

    // MARK: - Interaction monitoring

    func startInteractionMonitoring() -> Bool {
        activationHistory.start()

        // Reset scroll-gesture state in case monitoring was stopped mid-gesture.
        scrollGestureActive = false
        scrollDidTriggerReorder = false
        lastScrollReorderTime = 0

        // Scroll monitor: trackpad activity watchdog + MRU-gated reorder.
        // Gate: interaction is only meaningful for a window that is NOT already
        // the LRU head (most-recently-active). For such a window, the first
        // effective vertical scroll event — slow or fast — is treated as a real
        // user interaction and promotes it to the LRU head. Once it is at the
        // head, promotion is idempotent, so further interactions short-circuit.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            self.onTrackpadActivity?()

            // Skip the inertial (momentum) phase: it is a physical continuation
            // of the previous gesture, not a fresh user input.
            guard event.momentumPhase.isEmpty else { return }

            // Track the scroll-gesture lifecycle to deduplicate one gesture.
            switch event.phase {
            case .began:
                self.scrollGestureActive = true
                self.scrollDidTriggerReorder = false
            case .ended, .cancelled:
                self.scrollGestureActive = false
            case .changed:
                if !self.scrollGestureActive {
                    self.scrollGestureActive = true
                    self.scrollDidTriggerReorder = false
                }
            default: break
            }

            // Block: three-finger gesture in progress / programmatic activation /
            // no known front window.
            guard !self.gesturePhase.interceptsScroll, !self.isActivating,
                  let frontID = self.frontmostWindowID else { return }

            // MRU gate: if the frontmost window is already the LRU head, any
            // reorder would be a no-op — short-circuit before processing.
            if frontID == self.orderingEngine.orderedIDs.first { return }

            // Only vertical-dominant scroll counts as real page scrolling.
            // Horizontal-dominant scroll is a three-finger swipe artifact and
            // must not trigger windowDidInteract.
            guard abs(event.deltaY) > abs(event.deltaX) else { return }

            // Deduplicate: one gesture triggers exactly one reorder. The time
            // window also backs up phase-less devices (e.g. external mouse
            // wheels), where .began/.ended never fire, so a fresh scroll after
            // a pause re-arms the trigger.
            let now = ProcessInfo.processInfo.systemUptime
            if self.scrollDidTriggerReorder {
                guard now - self.lastScrollReorderTime > 0.5 else { return }
                self.scrollDidTriggerReorder = false
            }

            self.scrollDidTriggerReorder = true
            self.lastScrollReorderTime = now
            logDebug("SCROLL-MON: → windowDidInteract(\(frontID)) name=\(self.orderingEngine.windowNames[frontID] ?? "?")")
            self.orderingEngine.windowDidInteract(frontID)
            self.onInteraction?(frontID)
        }

        // Interaction monitor: clicks on windows trigger reorder. Gated the same
        // way as scroll — a click on an already-MRU window is a no-op.
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  let frontID = self.frontmostWindowID,
                  !self.isActivating,
                  frontID != self.orderingEngine.orderedIDs.first else { return }
            self.orderingEngine.windowDidInteract(frontID)
            self.onInteraction?(frontID)
        }

        logDebug("WindowManager: NSEvent monitors registered OK")
        return true
    }

    func stopInteractionMonitoring() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = interactionMonitor { NSEvent.removeMonitor(m); interactionMonitor = nil }
        axFocusObserver.stopObserving()
        activationHistory.stop()
        logDebug("WindowManager: interaction monitoring stopped")
    }

    // MARK: - AX delegates (thin wrappers for external callers)

    func enumerateAXWindows(forPid pid: pid_t) -> [AXWindowSnapshot] {
        axMatcher.enumerateAXWindows(forPid: pid)
    }

    static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10) -> Bool {
        AXWindowMatcher.frameMatches(a, b, tolerance: tolerance)
    }

    // MARK: - Private

    /// Called by AXFocusObserver when the focused AX window changes within the
    /// same app. Queries the AX focused window's title & frame, matches it to
    /// a known CGWindowID, and updates frontmostWindowID + LRU ordering.
    private func handleAXFocusChange(pid: pid_t) {
        guard !isActivating else {
            logDebug("AXFocusChange: suppressed (isActivating)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard r == .success, let fw = focusedWindow else {
            logDebug("AXFocusChange: no focused window for pid=\(pid), err=\(r.rawValue)")
            return
        }
        let axWindow = fw as! AXUIElement

        var axTitleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &axTitleVal)
        let axTitle = (axTitleVal as? String) ?? ""

        var axPos: CFTypeRef?, axSize: CFTypeRef?
        var axFrame = CGRect.zero
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
        if let pv = axPos { AXValueGetValue(pv as! AXValue, .cgPoint, &axFrame.origin) }
        if let sv = axSize { AXValueGetValue(sv as! AXValue, .cgSize, &axFrame.size) }

        logDebug("AXFocusChange: pid=\(pid) title=\"\(axTitle)\" frame=\(axFrame)")

        guard let matchedID = axMatcher.matchAXToCGWindowID(pid: pid, title: axTitle, frame: axFrame, windows: windows, appZOrder: appZOrder) else {
            logDebug("AXFocusChange: NO MATCH for pid=\(pid) title=\"\(axTitle)\"")
            return
        }

        guard matchedID != frontmostWindowID else {
            logDebug("AXFocusChange: same window \(matchedID), no-op")
            return
        }

        let oldID = frontmostWindowID
        frontmostWindowID = matchedID
        orderingEngine.windowDidInteract(matchedID)
        onInteraction?(matchedID)
        let oldName = oldID.flatMap { orderingEngine.windowNames[$0] } ?? "?"
        let newName = orderingEngine.windowNames[matchedID] ?? "?"
        logDebug("AXFocusChange: frontmostWindowID \(String(describing: oldID))(\(oldName)) → \(matchedID)(\(newName))")
    }

    /// Returns the topmost on-screen window of an app from a fresh snapshot.
    private func frontmostWindow(for pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for dict in list {
            guard let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = dict[kCGWindowNumber as String] as? Int
            else { continue }
            return CGWindowID(num)
        }
        return nil
    }

    private func parseWindow(_ dict: [String: Any]) -> WindowInfo? {
        guard let windowID = dict[kCGWindowNumber as String] as? Int,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
              let ownerName = dict[kCGWindowOwnerName as String] as? String,
              let bounds = dict[kCGWindowBounds as String] as? [String: Any]
        else { return nil }

        if ownerPID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        let bundleID = NSRunningApplication(
            processIdentifier: ownerPID
        )?.bundleIdentifier

        if let bid = bundleID, Constants.excludedAppBundleIDs.contains(bid) {
            return nil
        }

        guard let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat,
              w >= 100, h >= 100
        else { return nil }

        let frame = CGRect(x: x, y: y, width: w, height: h)

        return WindowInfo(
            id: CGWindowID(windowID),
            ownerPid: ownerPID,
            ownerName: ownerName,
            ownerBundleID: bundleID,
            windowTitle: (dict[kCGWindowName as String] as? String) ?? "",
            frame: frame
        )
    }
}
