import AppKit
import CoreGraphics

final class WindowManager: @unchecked Sendable {
    static let shared = WindowManager()

    let orderingEngine = LRUOrderingEngine()
    let activationHistory = ActivationHistory()
    let activationSuppressor = ActivationSuppressor()
    let axFocusObserver = AXFocusObserver()

    /// Current snapshot of visible windows, keyed by CGWindowID.
    private(set) var windows: [CGWindowID: WindowInfo] = [:]

    /// Current frontmost window ID.
    private(set) var frontmostWindowID: CGWindowID?

    private var scrollMonitor: Any?
    private var interactionMonitor: Any?

    /// Callback invoked when a window receives substantial interaction.
    var onInteraction: ((CGWindowID) -> Void)?

    /// Callback invoked on trackpad scroll/swipe events.
    var onTrackpadActivity: (() -> Void)?

    /// Set by AppDelegate when a three-finger gesture is in progress.
    /// When true, scroll events are treated as gesture artifacts and do NOT
    /// trigger windowDidInteract (they would reset the LRU cursor mid-swipe).
    var isGestureActive = false

    /// Per-app z-ordered window list (CGWindowID + frame) from the most recent
    /// refresh, in CGWindowList order (frontmost first). Used to correlate a
    /// target CGWindowID to the matching AX element by z-order rank, since
    /// AX kAXWindows order mirrors the window-server z-order.
    private var appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]

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
            if let front = self.frontmostWindow(for: pid) {
                self.frontmostWindowID = front
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
        backfillTitles(&newWindows)

        windows = newWindows
        orderingEngine.sync(windowIDs: orderedIDs)

        // Populate window name lookup for LRU diagnostics
        for (id, info) in newWindows {
            let title = info.windowTitle.isEmpty ? "" : " — \(info.windowTitle)"
            orderingEngine.windowNames[id] = "\(info.ownerName)\(title)"
        }

        // Update frontmost
        if let front = orderedIDs.first {
            frontmostWindowID = front
            orderingEngine.windowDidFocus(front)
        }

        logDebug("WindowManager: refreshed \(orderedIDs.count) windows")
        return orderedIDs.compactMap { newWindows[$0] }
    }

    /// Thread-safe thumbnail setter — call from background completion on main thread.
    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        windows[windowID]?.thumbnail = image
    }

    /// Stateless raw capture — safe to call from any thread.
    func captureRawImage(for windowID: CGWindowID) -> NSImage? {
        let cgImageUnmanaged = WindowSwitcher_CaptureWindowImage(windowID)
        guard let cgImage = cgImageUnmanaged?.takeRetainedValue() else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Capture a thumbnail for a single window (with cache check).
    func captureThumbnail(for windowID: CGWindowID) -> NSImage? {
        if let cached = windows[windowID]?.thumbnail { return cached }
        guard let image = captureRawImage(for: windowID) else { return nil }
        windows[windowID]?.thumbnail = image
        return image
    }

    /// Preload thumbnails for the top N windows.
    func preloadThumbnails(count: Int) {
        let ids = Array(orderingEngine.orderedIDs.prefix(count))
        var successCount = 0
        for id in ids {
            if captureThumbnail(for: id) != nil {
                successCount += 1
            }
        }
        logDebug("WindowManager: preloadThumbnails count=\(count) ids.count=\(ids.count) success=\(successCount)")
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
        let axApp = AXUIElementCreateApplication(info.ownerPid)
        var windowList: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        if copyResult == .success, let axWindows = windowList as? [AXUIElement] {
            logDebug("AX: \(info.ownerName) has \(axWindows.count) AX windows, target=[\(info.windowTitle)] frame=\(info.frame)")

            // Collect all AX windows with (index, title, frame) in AX order.
            var axWindowsInfo: [(index: Int, title: String, frame: CGRect)] = []
            for (idx, axWindow) in axWindows.enumerated() {
                var axTitle: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &axTitle)
                let title = (axTitle as? String) ?? ""

                var axPos: CFTypeRef?
                var axSize: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
                var axFrame = CGRect.zero
                if let posVal = axPos { AXValueGetValue(posVal as! AXValue, .cgPoint, &axFrame.origin) }
                if let sizeVal = axSize { AXValueGetValue(sizeVal as! AXValue, .cgSize, &axFrame.size) }

                logDebug("AX:   [\(idx)][\(title)] frame=\(axFrame)")
                axWindowsInfo.append((idx, title, axFrame))
            }

            // Select the AX element that corresponds to the EXACT target window:
            // frame group first, then z-order rank within the group.
            let selected = selectAXWindow(
                for: windowID,
                pid: info.ownerPid,
                frame: info.frame,
                title: info.windowTitle,
                axWindows: axWindowsInfo
            )

            if let sel = selected, sel.index >= 0 && sel.index < axWindows.count {
                AXUIElementPerformAction(axWindows[sel.index], kAXRaiseAction as CFString)
                logDebug("AX: raised [\(info.ownerName)] idx=\(sel.index) title=\"\(sel.title)\"")
                scheduleMappingCheck(pid: info.ownerPid, expectedTitle: sel.title, windowID: windowID)
            } else {
                logDebug("AX: NO MATCH for [\(info.ownerName) — \(info.windowTitle)]")
            }
        } else {
            logDebug("AX: failed to get windows for \(info.ownerName), result=\(copyResult.rawValue)")
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

        // Scroll monitor: trackpad activity watchdog + real-scroll reorder.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            self.onTrackpadActivity?()
            let blockedByGesture = self.isGestureActive
            let blockedByActivating = self.isActivating
            let frontID = self.frontmostWindowID
            if blockedByGesture || blockedByActivating || frontID == nil {
                if event.momentumPhase.isEmpty && event.phase == .ended {
                    logDebug("SCROLL-MON: blocked gesture=\(blockedByGesture) activating=\(blockedByActivating) frontID=\(frontID?.description ?? "nil")")
                }
                return
            }
            // Only trigger reorder on vertical-dominant scroll (page content
            // scrolling). Horizontal-dominant scroll is a three-finger swipe
            // artifact and must not trigger windowDidInteract.
            guard event.phase == .began, abs(event.deltaY) > abs(event.deltaX) else { return }
            logDebug("SCROLL-MON: → windowDidInteract(\(frontID!)) name=\(self.orderingEngine.windowNames[frontID!] ?? "?")")
            DispatchQueue.main.async {
                self.orderingEngine.windowDidInteract(frontID!)
                self.onInteraction?(frontID!)
            }
        }

        // Interaction monitor: clicks on windows trigger reorder.
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  let frontID = self.frontmostWindowID,
                  !self.isActivating else { return }
            DispatchQueue.main.async {
                self.orderingEngine.windowDidInteract(frontID)
                self.onInteraction?(frontID)
            }
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

    /// Clear the thumbnail cache.
    func clearThumbnailCache() {
        for key in windows.keys {
            windows[key]?.thumbnail = nil
        }
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

        guard let matchedID = matchAXToCGWindowID(pid: pid, title: axTitle, frame: axFrame) else {
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

    /// Matches an AX focused window (by title + frame) to a known CGWindowID
    /// in the current window snapshot. Uses frame match for simple cases,
    /// then z-order rank correlation when multiple CG windows share the same
    /// frame (e.g. Chrome tabs).
    private func matchAXToCGWindowID(pid: pid_t, title: String, frame: CGRect) -> CGWindowID? {
        // Step 1: frame match (covers most apps)
        let candidates = windows.filter { $0.value.ownerPid == pid && self.frameMatches($0.value.frame, frame) }

        if candidates.isEmpty {
            // No CG window shares this frame — try title match across all
            // windows for this PID.
            if !title.isEmpty, let m = windows.first(where: {
                $0.value.ownerPid == pid && $0.value.windowTitle == title
            }) {
                logDebug("AXFocusChange: match by title only (no frame match)")
                return m.key
            }
            return nil
        }

        if candidates.count == 1 {
            return candidates.first!.key
        }

        // Step 2: multiple same-frame CG windows → z-order rank correlation.
        // AX kAXWindows order mirrors window-server z-order, so the focused
        // window's rank among same-frame AX windows maps to the same rank
        // among same-frame CG windows.
        let zOrder = appZOrder[pid] ?? []
        let sameFrameCG = zOrder.filter { self.frameMatches($0.frame, frame) }

        // Enumerate AX windows to find the focused one's rank among same-frame
        var sameFrameAXTitles: [String] = []
        let app = AXUIElementCreateApplication(pid)
        var axList: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &axList) == .success,
           let axWindows = axList as? [AXUIElement] {
            for axWin in axWindows {
                var axT: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &axT)
                let t = (axT as? String) ?? ""
                var axP: CFTypeRef?, axS: CFTypeRef?
                var axF = CGRect.zero
                AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &axP)
                AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &axS)
                if let pv = axP { AXValueGetValue(pv as! AXValue, .cgPoint, &axF.origin) }
                if let sv = axS { AXValueGetValue(sv as! AXValue, .cgSize, &axF.size) }
                if self.frameMatches(axF, frame) {
                    sameFrameAXTitles.append(t)
                }
            }
        }

        logDebug("AXFocusChange: sameFrameAX=\(sameFrameAXTitles.count) sameFrameCG=\(sameFrameCG.count)")

        // Step 2: match by title among same-frame CG windows.
        // AX kAXWindows order mirrors MRU (most recently used), while CG
        // z-order mirrors stacking order — they differ, so rank correlation
        // is unreliable. Title matching is deterministic.
        if !title.isEmpty, let m = sameFrameCG.first(where: { w in
            let cgTitle = windows[CGWindowID(w.id)]?.windowTitle ?? ""
            return cgTitle == title || title.hasPrefix(cgTitle) || cgTitle.hasPrefix(title)
        }) {
            logDebug("AXFocusChange: title match → CG id=\(m.id)")
            return CGWindowID(m.id)
        }

        // Step 3: fallbacks — candidate title match, then first frame match
        if !title.isEmpty, let m = candidates.first(where: {
            $0.value.windowTitle == title || title.hasPrefix($0.value.windowTitle) || $0.value.windowTitle.hasPrefix(title)
        }) {
            logDebug("AXFocusChange: fallback title match")
            return m.key
        }
        logDebug("AXFocusChange: fallback first frame match")
        return candidates.first!.key
    }

    /// Whether two rects describe the same on-screen window frame (with tolerance).
    private func frameMatches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 10 &&
        abs(a.origin.y - b.origin.y) < 10 &&
        abs(a.size.width - b.size.width) < 10 &&
        abs(a.size.height - b.size.height) < 10
    }

    /// Selects the AX window corresponding to `targetID` among the app's AX
    /// windows. Prefers a unique frame match; when several windows share the
    /// target's frame, disambiguates by z-order rank (AX kAXWindows order
    /// mirrors the window-server z-order), then by title, then by first match.
    private func selectAXWindow(
        for targetID: CGWindowID,
        pid: pid_t,
        frame: CGRect,
        title: String,
        axWindows: [(index: Int, title: String, frame: CGRect)]
    ) -> (index: Int, title: String)? {
        let sameFrame = axWindows
            .filter { frameMatches($0.frame, frame) }
            .map { (index: $0.index, title: $0.title) }
        if !sameFrame.isEmpty {
            if sameFrame.count == 1 {
                return sameFrame[0]
            }
            // Multiple same-frame candidates → z-order rank correlation.
            let zOrder = appZOrder[pid] ?? []
            let sameFrameCG = zOrder.filter { frameMatches($0.frame, frame) }
            if let rank = sameFrameCG.firstIndex(where: { $0.id == targetID }),
               rank < sameFrame.count {
                return sameFrame[rank]
            }
            // Rank correlation unavailable → title match, then first.
            if !title.isEmpty, let t = sameFrame.first(where: { $0.title == title }) {
                return t
            }
            return sameFrame[0]
        }
        // No frame match at all → title match, then first AX window.
        if !title.isEmpty, let t = axWindows.first(where: { $0.title == title }) {
            return (index: t.index, title: t.title)
        }
        return axWindows.first.map { (index: $0.index, title: $0.title) }
    }

    /// Fills real window titles from the Accessibility API into apps whose
    /// CGWindowList title is empty (e.g. Chrome). Correlates AX windows to CG
    /// windows by frame, and by z-order rank when frames collide.
    private func backfillTitles(_ dict: inout [CGWindowID: WindowInfo]) {
        let emptyPids = Set(dict.values.filter { $0.windowTitle.isEmpty }.map { $0.ownerPid })
        guard !emptyPids.isEmpty else { return }

        for pid in emptyPids {
            let app = AXUIElementCreateApplication(pid)
            var list: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list)
            guard r == .success, let axWindows = list as? [AXUIElement] else { continue }

            var axInfo: [(index: Int, title: String, frame: CGRect)] = []
            for (idx, w) in axWindows.enumerated() {
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
                let title = (t as? String) ?? ""
                var pos: CFTypeRef?, size: CFTypeRef?
                var frame = CGRect.zero
                AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos)
                AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size)
                if let pv = pos { AXValueGetValue(pv as! AXValue, .cgPoint, &frame.origin) }
                if let sv = size { AXValueGetValue(sv as! AXValue, .cgSize, &frame.size) }
                axInfo.append((idx, title, frame))
            }
            guard !axInfo.isEmpty else { continue }

            let zOrder = appZOrder[pid] ?? []
            for key in dict.keys where dict[key]?.ownerPid == pid && (dict[key]?.windowTitle.isEmpty ?? true) {
                guard let info = dict[key] else { continue }
                let sameFrameAX = axInfo.filter { frameMatches($0.frame, info.frame) }
                var newTitle = ""
                if sameFrameAX.count == 1 {
                    newTitle = sameFrameAX[0].title
                } else if sameFrameAX.count > 1 {
                    let sameFrameCG = zOrder.filter { frameMatches($0.frame, info.frame) }
                    if let rank = sameFrameCG.firstIndex(where: { $0.id == info.id }),
                       rank < sameFrameAX.count {
                        newTitle = sameFrameAX[rank].title
                    } else {
                        newTitle = sameFrameAX[0].title
                    }
                }
                if !newTitle.isEmpty {
                    dict[key] = info.withTitle(newTitle)
                }
            }
        }
    }

    /// Post-activation diagnostic: verify the app's focused AX window matches
    /// the AX element we raised, to surface apps whose AX order breaks the
    /// z-order-rank correlation.
    private func scheduleMappingCheck(pid: pid_t, expectedTitle: String, windowID: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let app = AXUIElementCreateApplication(pid)
            var f: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &f)
            guard r == .success, let fw = f else { return }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(fw as! AXUIElement, kAXTitleAttribute as CFString, &t)
            let focused = (t as? String) ?? ""
            if focused != expectedTitle {
                logDebug("MAPPING-MISMATCH: window=\(windowID) expected=\"\(expectedTitle)\" focused=\"\(focused)\"")
            } else {
                logDebug("MAPPING-OK: window=\(windowID) focused=\"\(focused)\"")
            }
        }
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
              let bounds = dict[kCGWindowBounds as String] as? [String: Any],
              let layer = dict[kCGWindowLayer as String] as? Int
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
            windowNumber: windowID,
            ownerPid: ownerPID,
            ownerName: ownerName,
            ownerBundleID: bundleID,
            windowTitle: (dict[kCGWindowName as String] as? String) ?? "",
            frame: frame,
            isOnScreen: true,
            windowLayer: layer
        )
    }
}
