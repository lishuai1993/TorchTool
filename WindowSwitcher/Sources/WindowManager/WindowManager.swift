import AppKit
import CoreGraphics

final class WindowManager: @unchecked Sendable {
    static let shared = WindowManager()

    let orderingEngine = LRUOrderingEngine()

    /// Current snapshot of visible windows, keyed by CGWindowID.
    private(set) var windows: [CGWindowID: WindowInfo] = [:]

    /// Current frontmost window ID.
    private(set) var frontmostWindowID: CGWindowID?

    /// Event tap for detecting substantial interaction.
    private var eventTap: CFMachPort?

    /// Callback invoked when a window receives substantial interaction.
    var onInteraction: ((CGWindowID) -> Void)?

    /// Tracks the last raised AX window per PID for round-robin cycling
    /// across multiple windows of the same app.
    private var lastRaisedAXTitle: [pid_t: String] = [:]
    private var lastRaisedAXIndex: [pid_t: Int] = [:]

    private init() {}

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

    /// Capture a thumbnail for a single window.
    func captureThumbnail(for windowID: CGWindowID) -> NSImage? {
        if let cached = windows[windowID]?.thumbnail { return cached }

        let cgImageUnmanaged = WindowSwitcher_CaptureWindowImage(windowID)
        guard let cgImage = cgImageUnmanaged?.takeRetainedValue() else {
            return nil
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
        windows[windowID]?.thumbnail = nsImage
        return nsImage
    }

    /// Preload thumbnails for the top N windows.
    func preloadThumbnails(count: Int) {
        let ids = orderingEngine.orderedIDs.prefix(count)
        for id in ids {
            _ = captureThumbnail(for: id)
        }
    }

    /// Activate (bring to front) a window.
    func activateWindow(_ windowID: CGWindowID) {
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

        // Step 2: Raise the specific window via Accessibility API.
        // Do this BEFORE activation so the app comes to front already showing
        // the correct window, avoiding a flash of a different window first.
        let axApp = AXUIElementCreateApplication(info.ownerPid)
        var windowList: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        if copyResult == .success, let axWindows = windowList as? [AXUIElement] {
            logDebug("AX: \(info.ownerName) has \(axWindows.count) AX windows, target=[\(info.windowTitle)] frame=\(info.frame)")

            // Collect all matching AX windows first.
            var matchingIndices: [(index: Int, title: String)] = []
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

                let titleMatch = title == info.windowTitle && !info.windowTitle.isEmpty
                let frameMatch = abs(axFrame.origin.x - info.frame.origin.x) < 10 &&
                                 abs(axFrame.origin.y - info.frame.origin.y) < 10 &&
                                 abs(axFrame.size.width - info.frame.size.width) < 10 &&
                                 abs(axFrame.size.height - info.frame.size.height) < 10

                logDebug("AX:   [\(idx)][\(title)] frame=\(axFrame) titleMatch=\(titleMatch) frameMatch=\(frameMatch)")

                if titleMatch || frameMatch {
                    matchingIndices.append((idx, title))
                }
            }

            if !matchingIndices.isEmpty {
                let lastTitle = lastRaisedAXTitle[info.ownerPid]
                let lastIdx = lastRaisedAXIndex[info.ownerPid]
                logDebug("AX: \(matchingIndices.count) matches, lastRaised(title=\"\(lastTitle ?? "nil")\", idx=\(lastIdx.map(String.init) ?? "nil"))")

                var selected = matchingIndices[0]
                if matchingIndices.count > 1 {
                    if let lt = lastTitle, let alt = matchingIndices.first(where: { $0.title != lt }) {
                        selected = alt
                        logDebug("AX: title-based pick → idx=\(selected.index)")
                    } else if let li = lastIdx, let alt = matchingIndices.first(where: { $0.index != li }) {
                        selected = alt
                        logDebug("AX: index-based fallback → idx=\(selected.index)")
                    } else {
                        logDebug("AX: first match → idx=\(selected.index)")
                    }
                }

                AXUIElementPerformAction(axWindows[selected.index], kAXRaiseAction as CFString)
                lastRaisedAXTitle[info.ownerPid] = selected.title
                lastRaisedAXIndex[info.ownerPid] = selected.index
                logDebug("AX: raised [\(info.ownerName)] idx=\(selected.index) title=\"\(selected.title)\"")
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
            app.activate()
        }

        orderingEngine.userDidSelectWindow(windowID)
    }

    // MARK: - Interaction event tap

    func startInteractionMonitoring() -> Bool {
        // Check Accessibility permission first
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false]
        let trusted = AXIsProcessTrustedWithOptions(options)
        logDebug("WindowManager: AXIsProcessTrusted = \(trusted)")

        if !trusted {
            logDebug("WindowManager: Accessibility NOT granted, skipping event tap. Event tap requires Accessibility permission.")
            return false
        }

        let eventMask: CGEventMask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )

        logDebug("WindowManager: creating CGEvent tap...")
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, _) -> Unmanaged<CGEvent>? in
                if let frontID = WindowManager.shared.frontmostWindowID {
                    DispatchQueue.main.async {
                        WindowManager.shared.orderingEngine.windowDidInteract(frontID)
                        WindowManager.shared.onInteraction?(frontID)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap = tap else {
            logDebug("WindowManager: CGEvent.tapCreate returned nil (likely permission denied)")
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap, 0
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(), runLoopSource, .commonModes
        )
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        logDebug("WindowManager: event tap created and enabled OK")
        return true
    }

    func stopInteractionMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
            logDebug("WindowManager: event tap stopped")
        }
    }

    /// Clear the thumbnail cache.
    func clearThumbnailCache() {
        for key in windows.keys {
            windows[key]?.thumbnail = nil
        }
    }

    // MARK: - Private

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
