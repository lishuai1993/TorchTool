import AppKit

/// Observes AX focused-window changes for the current frontmost application.
/// When the user switches between windows of the same app (e.g. two Chrome
/// windows), the event tap cannot detect the switch, but the AX system fires
/// kAXFocusedWindowChangedNotification. This class captures that notification
/// and forwards the PID so WindowManager can update frontmostWindowID.
final class AXFocusObserver {
    /// Called on the main thread when the focused AX window changes within
    /// the observed app. The receiver should re-resolve frontmostWindowID.
    var onFocusChanged: ((pid_t) -> Void)?

    private var currentPID: pid_t?
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?

    deinit {
        stopObserving()
    }

    /// Start observing focused-window changes for the given PID. No-op if
    /// already observing the same PID. If a different PID was being observed,
    /// the old observer is torn down before the new one is created.
    func startObserving(pid: pid_t) {
        if currentPID == pid {
            logDebug("AXFocusObserver: already observing pid=\(pid)")
            return
        }

        stopObserving()

        var obsRef: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let createResult = AXObserverCreate(pid, axFocusCallback, &obsRef)
        guard createResult == .success, let obs = obsRef else {
            logDebug("AXFocusObserver: AXObserverCreate FAILED pid=\(pid) result=\(createResult.rawValue)")
            return
        }

        let appEl = AXUIElementCreateApplication(pid)
        let addResult = AXObserverAddNotification(
            obs, appEl,
            kAXFocusedWindowChangedNotification as CFString,
            selfPtr
        )
        guard addResult == .success else {
            logDebug("AXFocusObserver: AXObserverAddNotification FAILED pid=\(pid) result=\(addResult.rawValue)")
            observer = nil  // release obs
            return
        }

        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        observer = obs
        runLoopSource = src
        currentPID = pid
        logDebug("AXFocusObserver: started pid=\(pid)")
    }

    func stopObserving() {
        guard let obs = observer else { return }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        // Remove the notification to balance the add — prevents stale callbacks.
        AXObserverRemoveNotification(
            obs,
            AXUIElementCreateApplication(currentPID ?? 0),
            kAXFocusedWindowChangedNotification as CFString
        )
        observer = nil  // release obs
        observer = nil
        currentPID = nil
        logDebug("AXFocusObserver: stopped")
    }
}

// MARK: - C callback

private func axFocusCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = context else { return }
    let self_ = Unmanaged<AXFocusObserver>.fromOpaque(context).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    logDebug("AXFocusObserver: callback - focus changed pid=\(pid)")
    // AXObserver callbacks already run on the runloop thread (main), but
    // re-dispatch to be safe against potential future threading changes.
    DispatchQueue.main.async {
        self_.onFocusChanged?(pid)
    }
}
