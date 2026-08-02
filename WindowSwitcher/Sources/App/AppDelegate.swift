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
        windowManager.onInteraction = { windowID in
            logDebug("onInteraction fired for window \(windowID)")
        }
        windowManager.onTrackpadActivity = { [weak self] in
            self?.gestureEngine.noteTrackpadActivity()
        }
        gestureEngine.onGesture = { [weak self] event in
            self?.handleGesture(event)
        }
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

        // Step 9: Diagnostic self-test — activate a background app without a
        // gesture to reproduce activate() behavior in the real process context.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            logDebug("SELF-TEST: trigger start")
            self.windowManager.selfTestActivation()
        }

        logDebug("=== applicationDidFinishLaunching END (SUCCESS) ===")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logDebug("applicationWillTerminate")
        gestureEngine.stop()
        windowManager.stopInteractionMonitoring()
    }

    // MARK: - Service start/stop

    func startAllServices() {
        logDebug("startAllServices called")
        _ = windowManager.startInteractionMonitoring()
    }

    func stopAllServices() {
        logDebug("stopAllServices called")
        windowManager.stopInteractionMonitoring()
        overlayController.hide()
    }

    // MARK: - Gesture dispatch

    private func handleGesture(_ event: GestureEvent) {
        let settings = AppSettings.shared
        logDebug("handleGesture: \(event)")

        switch event {
        case .threeFingerTap:
            guard settings.immersiveModeEnabled else { return }
            showImmersiveOverlay()

        case .threeFingerSwipeLeft:
            guard settings.quickSwitchModeEnabled else { return }
            quickSwitch(directionRight: true)

        case .threeFingerSwipeRight:
            guard settings.quickSwitchModeEnabled else { return }
            quickSwitch(directionRight: false)

        case .swipeUpdate(let progress):
            if overlayController.isVisible {
                overlayController.updateProgress(progress)
            }
        }
    }

    // MARK: - Immersive mode

    private func showImmersiveOverlay() {
        logDebug("showImmersiveOverlay called")
        let windowList = windowManager.refreshWindows()
        guard !windowList.isEmpty else {
            logDebug("showImmersiveOverlay: no windows found, aborting")
            return
        }
        windowManager.preloadThumbnails(
            count: min(windowList.count, AppSettings.shared.maxVisibleCount)
        )
        let updatedList = windowManager.refreshWindows()
        overlayController.show(with: updatedList)
        logDebug("showImmersiveOverlay: overlay shown with \(updatedList.count) windows")
    }

    // MARK: - Quick switch mode

    private func quickSwitch(directionRight: Bool) {
        let dirLabel = directionRight ? "→ 右滑" : "← 左滑"
        let windows = windowManager.refreshWindows()
        guard windows.count > 1 else { return }
        guard let target = windowManager.orderingEngine.advanceCursor(directionRight: directionRight) else { return }

        let targetName = windowManager.orderingEngine.windowNames[target] ?? "?"
        logDebug("QuickSwitch: \(dirLabel) → 激活 [\(targetName)]")

        windowManager.activateWindow(target)
        if AppSettings.shared.quickSwitchHintEnabled {
            showQuickSwitchHint(for: target)
        }
    }

    // MARK: - Quick switch hint

    private var hintWindow: NSWindow?

    private func showQuickSwitchHint(for windowID: CGWindowID) {
        hintWindow?.close()
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

        let label = "\(info.ownerName) — \(info.windowTitle)"
        let hosting = NSHostingView(rootView: QuickSwitchHintView(text: label))
        hosting.frame = NSRect(x: 0, y: 0, width: hintWidth, height: hintHeight)
        window.setFrameOrigin(NSPoint(x: hintRect.origin.x, y: hintRect.origin.y))
        window.contentView = hosting

        window.orderFront(nil)
        hintWindow = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
            window?.orderOut(nil)
        }
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
        let axOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false]
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
