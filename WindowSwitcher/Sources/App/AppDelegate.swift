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
    private let elasticDrag = ElasticDragController.shared
    private let immersiveOverlay = ImmersiveOverlayCoordinator.shared
    private let slideTransition = SlideTransitionController.shared

    /// 滑动会话收尾看门狗：触控板 MT 事件流停顿（手指静止/系统暂停回调）时，
    /// C 引擎只能在下一帧到达才检测到 callback-gap，Swift 侧收不到 gestureEnd，
    /// 面板会冻结在已过提交阈值的位移上。会话开始后 2.5s 内无任何 progress 更新
    /// 即自动按当前 offset 收尾（提交或回弹），每次 swipeUpdate 重置。
    private var slideWatchdogTimer: Timer?
    private let slideWatchdogPeriod: TimeInterval = 2.5


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

        // Step 6: Session observers — re-register the MultitouchSupport
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
#if DEBUG
        logAppZOrder()
        checkOrderConsistency()
#endif

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
        slideTransition.cancel()
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
        elasticDrag.onShowHint = { [weak self] windowID in
            self?.showQuickSwitchHint(for: windowID)
        }
        elasticDrag.onShakeHint = { [weak self] in
            guard let hint = self?.hintWindow else { return }
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
            if slideTransition.isActive {
                slideTransition.cancel()
                invalidateSlideWatchdog()
            }
            if elasticDrag.isInProgress {
                logDebug("ElasticDrag: tap intercepted [session=\(elasticDrag.sessionID)], triggering spring-back")
                elasticDrag.finishDrag()
                windowManager.gesturePhase = .idle
                return
            }
            if overlayController.isVisible {
                overlayController.selectFocused()
                windowManager.gesturePhase = overlayController.isVisible ? .overlayVisible : .idle
                return
            }
            guard settings.immersiveModeEnabled, settings.threeFingerTapEnabled else {
                windowManager.gesturePhase = .idle
                return
            }
            immersiveOverlay.show()
            windowManager.gesturePhase = .overlayVisible

        case .threeFingerSwipeUp:
            logDebug("GESTURE: threeFingerSwipeUp, overlayVisible=\(overlayController.isVisible)")
            if slideTransition.isActive {
                slideTransition.cancel()
                invalidateSlideWatchdog()
            }
            if elasticDrag.isInProgress {
                logDebug("ElasticDrag: swipeUp intercepted [session=\(elasticDrag.sessionID)], triggering spring-back")
                elasticDrag.finishDrag()
                windowManager.gesturePhase = .idle
                return
            }
            if overlayController.isVisible {
                windowManager.gesturePhase = .overlayVisible
                return
            }
            guard settings.immersiveModeEnabled, settings.threeFingerSwipeUpEnabled else {
                windowManager.gesturePhase = .idle
                return
            }
            immersiveOverlay.show()
            windowManager.gesturePhase = .overlayVisible

        case .threeFingerSwipeDown:
            logDebug("GESTURE: threeFingerSwipeDown, overlayVisible=\(overlayController.isVisible)")
            if slideTransition.isActive {
                slideTransition.cancel()
                invalidateSlideWatchdog()
            }
            if overlayController.isVisible {
                overlayController.hide()
                windowManager.gesturePhase = .idle
                return
            }
            windowManager.gesturePhase = .idle

        case .threeFingerSwipeLeft:
            windowManager.gesturePhase = .quickSwitching
            guard !overlayController.isVisible else { return }
            if settings.slidingTransitionEnabled {
                guard settings.quickSwitchModeEnabled else { return }
                if slideTransition.isActive {
                    // 会话进行中：离散方向事件不改变画面——offset 严格由 swipeUpdate 跟手，
                    // 避免「闪现半屏」瞬移。抬手提交/回弹完全交给 finishSlideSession 的阈值判定。
                    logDebug("SLIDE: mid-session swipeLeft — ignored（严格跟手，离散事件不改画面）")
                } else {
                    beginSlideSessionIfNeeded(progress: slideInitialProgress(sign: -1))
                }
                return
            }
            if elasticDrag.isInProgress {
                logDebug("ElasticDrag: BUG swipeLeft while drag in progress [session=\(elasticDrag.sessionID)] — gestureEnd/tap was NOT received before next swipe action!")
            }
            guard settings.quickSwitchModeEnabled else { return }
            if !settings.cyclicScrollEnabled && elasticDrag.isAtBoundary(directionRight: true) {
                logDebug("ElasticDrag: swipeLeft at boundary, skipping quickSwitch")
                return
            }
            quickSwitch(directionRight: true)

        case .threeFingerSwipeRight:
            windowManager.gesturePhase = .quickSwitching
            guard !overlayController.isVisible else { return }
            if settings.slidingTransitionEnabled {
                guard settings.quickSwitchModeEnabled else { return }
                if slideTransition.isActive {
                    logDebug("SLIDE: mid-session swipeRight — ignored（严格跟手，离散事件不改画面）")
                } else {
                    beginSlideSessionIfNeeded(progress: slideInitialProgress(sign: 1))
                }
                return
            }
            if elasticDrag.isInProgress {
                logDebug("ElasticDrag: BUG swipeRight while drag in progress [session=\(elasticDrag.sessionID)] — gestureEnd/tap was NOT received before next swipe action!")
            }
            guard settings.quickSwitchModeEnabled else { return }
            if !settings.cyclicScrollEnabled && elasticDrag.isAtBoundary(directionRight: false) {
                logDebug("ElasticDrag: swipeRight at boundary, skipping quickSwitch")
                return
            }
            quickSwitch(directionRight: false)

        case .swipeUpdate(let progress):
            windowManager.gesturePhase = .quickSwitching
            guard !overlayController.isVisible else { return }
            if settings.slidingTransitionEnabled {
                guard settings.quickSwitchModeEnabled else { return }
                let p = CGFloat(progress)
                if slideTransition.isActive {
                    slideTransition.update(progress: p)
                    armSlideWatchdog()
                } else {
                    beginSlideSessionIfNeeded(progress: p)
                }
                return
            }
            guard settings.quickSwitchModeEnabled, !settings.cyclicScrollEnabled else { return }
            let dirRight = progress < 0
            if !elasticDrag.isInProgress {
                guard elasticDrag.isAtBoundary(directionRight: dirRight) else { return }
                if settings.elasticDragEnabled {
                    logDebug("ElasticDrag: begin [session=\(elasticDrag.sessionID + 1)], progress=\(String(format: "%.3f", progress)), dirRight=\(dirRight)")
                    elasticDrag.beginElasticDrag()
                    windowManager.gesturePhase = .elasticDragging
                } else {
                    elasticDrag.setBoundaryWithoutDrag()
                }
            }
            if settings.elasticDragEnabled {
                elasticDrag.applyDisplacement(progress: progress)
                elasticDrag.scheduleWatchdog()
            }

        case .gestureEnd:
            elasticDrag.cancelWatchdog()
            windowManager.lastGestureEndAt = ProcessInfo.processInfo.systemUptime
            invalidateSlideWatchdog()
            if slideTransition.isActive {
                finishSlideSession()
                windowManager.gesturePhase = .idle
                return
            }
            logDebug("ElasticDrag: gestureEnd, inProgress=\(elasticDrag.isInProgress), session=\(elasticDrag.sessionID)")
            if elasticDrag.isInProgress {
                elasticDrag.finishDrag()
            } else if elasticDrag.hasBoundaryWithoutDrag {
                elasticDrag.clearBoundaryWithoutDrag()
                logDebug("ElasticDrag: gestureEnd — showing hint at boundary (drag disabled)")
                elasticDrag.handleBoundaryHint()
            } else {
                logDebug("ElasticDrag: gestureEnd ignored — no drag in progress")
            }
            windowManager.gesturePhase = overlayController.isVisible ? .overlayVisible : .idle
        }
    }

    // MARK: - Slide transition (跟随手指)

    /// 快扫兜底开会话的初始 progress：C 引擎的离散 Left/Right 语义为「完成一次
    /// 有效滑动」（progress=1.0），以其作为首帧位移（≈一次滑动的跟手位置），
    /// 不瞬移到提交阈值；释放提交/回弹完全交给抬手时的阈值判定。
    private func slideInitialProgress(sign: CGFloat) -> CGFloat {
        1.0 * sign
    }

    /// 开启（或继续）滑动过渡会话。首个合格 swipeUpdate 或 Left/Right 快扫兜底
    /// 时调用。会话已在推进时仅把 progress 喂给控制器。
    private func beginSlideSessionIfNeeded(progress: CGFloat) {
        guard AppSettings.shared.quickSwitchModeEnabled else { return }
        guard !slideTransition.isActive else {
            slideTransition.update(progress: progress)
            return
        }

        windowManager.gesturePhase = .slidingTransition
        // 会话开始：取消该滑动自身 scroll 可能已挂起的延迟重排，并记录开始时刻
        //（延迟重排触发时据此识别滑动产物）。此时刷新窗口会同步 LRU。
        windowManager.noteSlideSessionBegan()
        let windows = windowManager.refreshWindows()
        guard windows.count > 1,
              let sourceID = windowManager.frontmostWindowID,
              let idx = windowManager.orderingEngine.index(of: sourceID) else {
            logDebug("SLIDE: abort — need >=2 windows and a valid source (count=\(windows.count))")
            windowManager.gesturePhase = .idle
            invalidateSlideWatchdog()
            return
        }

        let ids = windowManager.orderingEngine.orderedIDs
        let leftID = idx > 0 ? ids[idx - 1] : nil      // moreRecent — p>0 时滑入
        let rightID = idx + 1 < ids.count ? ids[idx + 1] : nil  // lessRecent — p<0 时滑入

        slideTransition.begin(sourceID: sourceID, leftID: leftID, rightID: rightID, initialProgress: progress)
        armSlideWatchdog()
    }

    /// 滑动过渡会话结束：依据最终 offset（相对屏宽比例）判定提交或回弹。
    /// 提交阈值取屏幕像素，与 progress 解耦，消除「clamp 到满屏导致 delta=0 直切」的缺陷。
    private func finishSlideSession() {
        invalidateSlideWatchdog()
        let off = slideTransition.currentOffset
        let settings = AppSettings.shared
        let thresholdPx = CGFloat(settings.slidingCommitThreshold) * slideTransition.screenWidth
        let commit = abs(off) >= thresholdPx
        logDebug("SLIDE: gestureEnd offset=\(Int(off)) threshold=\(Int(thresholdPx)) commit=\(commit)")

        let cyclic = settings.cyclicScrollEnabled
        if commit {
            let dirRight = off < 0
            if let target = windowManager.orderingEngine.advanceCursor(directionRight: dirRight, cyclic: cyclic) {
                let targetName = windowManager.orderingEngine.windowNames[target] ?? "?"
                logDebug("SLIDE: commit dirRight=\(dirRight) → 激活 [\(targetName)]")
                slideTransition.settle(finalOffset: off, commit: true) { [weak self] in
                    self?.windowManager.activateWindow(target)
                    self?.slideTransition.logPostActivationDiagnostics()
                }
                return
            }
            logDebug("SLIDE: boundary wall-bump, rebounding")
        } else {
            logDebug("SLIDE: rebound to source")
        }
        slideTransition.settle(finalOffset: off, commit: false, onComplete: nil)
    }

    /// 启动/重置滑动会话看门狗：2.5s 内无 progress 更新即自动收尾，防止
    /// MT 事件流停顿导致面板冻结（事件三）。
    private func armSlideWatchdog() {
        slideWatchdogTimer?.invalidate()
        slideWatchdogTimer = Timer.scheduledTimer(withTimeInterval: slideWatchdogPeriod, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.slideTransition.isActive {
                logDebug("SLIDE: watchdog fired — auto-settling stalled session")
                self.finishSlideSession()
            }
        }
    }

    private func invalidateSlideWatchdog() {
        slideWatchdogTimer?.invalidate()
        slideWatchdogTimer = nil
    }

    // MARK: - Quick switch mode

    private func quickSwitch(directionRight: Bool) {
        if elasticDrag.isInProgress {
            logDebug("ElasticDrag: BUG quickSwitch called while drag in progress [session=\(elasticDrag.sessionID)]!")
        }
        let dirLabel = directionRight ? "→ 右滑" : "← 左滑"
        let windows = windowManager.refreshWindows()
        guard windows.count > 1 else { return }

        let engine = windowManager.orderingEngine
        let idsBefore = engine.orderedIDs
        let namesBefore = idsBefore.compactMap { engine.windowNames[$0] }.joined(separator: " → ")
        let cursorBefore = engine.currentIndex
        let frontBefore = windowManager.frontmostWindowID
        let frontNameBefore = frontBefore.flatMap { engine.windowNames[$0] } ?? "?"
        logDebug("QuickSwitch: \(dirLabel) BEFORE cursor=\(cursorBefore) front=[\(frontNameBefore)] order=[\(namesBefore)]")

        let cyclic = AppSettings.shared.cyclicScrollEnabled
        guard let target = windowManager.orderingEngine.advanceCursor(directionRight: directionRight,
                                                                      cyclic: cyclic) else {
            logDebug("QuickSwitch: \(dirLabel) ⛔ wall-bump, staying put")
            return
        }

        let targetName = windowManager.orderingEngine.windowNames[target] ?? "?"
        logDebug("QuickSwitch: \(dirLabel) → 激活 [\(targetName)]")

        windowManager.activateWindow(target)
        elasticDrag.clearBoundaryOrigin()  // left the boundary — clear cached origin

        let idsAfter = engine.orderedIDs
        let namesAfter = idsAfter.compactMap { engine.windowNames[$0] }.joined(separator: " → ")
        let cursorAfter = engine.currentIndex
        let frontAfter = windowManager.frontmostWindowID
        let frontNameAfter = frontAfter.flatMap { engine.windowNames[$0] } ?? "?"
        logDebug("QuickSwitch: \(dirLabel) AFTER  cursor=\(cursorAfter) front=[\(frontNameAfter)] order=[\(namesAfter)]")

        if AppSettings.shared.quickSwitchHintEnabled {
            showQuickSwitchHint(for: target)
        }
    }

    // MARK: - Quick switch hint

    private var hintWindow: NSWindow?
    private var hintDismissWork: DispatchWorkItem?

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

#if DEBUG
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
#endif
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
