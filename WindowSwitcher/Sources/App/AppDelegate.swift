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
    /// C 引擎只能在下一帧到达才检测到 callback-gap，Swift 侧收不到 gestureEnd。
    /// C 引擎侧帧饥饿定时器（200ms）先兜底收尾并保留甩动动量；此 Swift 看门狗作为
    /// 二次兜底，0.8s 内无任何 progress 更新即自动按当前 offset 收尾（提交或回弹），
    /// 每次 swipeUpdate 重置。
    private var slideWatchdogTimer: Timer?
    private let slideWatchdogPeriod: TimeInterval = 0.8


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

        // Step 3.5: Start scroll suppression tap（三指跟踪期丢弃 scrollWheel，
        // 阻止前台 App 网页随三指移动滚动；依赖 C 引擎 trackingActive）。
        ScrollSuppressionTap.shared.start()

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
        ScrollSuppressionTap.shared.stop()
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

        // 2.5 Start scroll suppression tap（依赖 C 引擎 trackingActive 判定三指手势，
        // 跟踪期丢弃 scrollWheel，阻止前台 App 网页随三指移动滚动）。
        ScrollSuppressionTap.shared.start()

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
        ScrollSuppressionTap.shared.stop()
        windowManager.stopInteractionMonitoring()
        overlayController.hide()
        slideTransition.cancel(flushPending: false)   // 服务停止：丢弃 pending，不补激活
        BackdropPreCapturer.shared.cancel()
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
        // 会话非链式结束时（tap/纵向手势/边界丢弃）补激活已 commit 但未落定的目标，
        // 消除「滑了没切」（BUG #2：settle 被打断导致最后一甩丢失）。
        slideTransition.onFlushPending = { [weak self] windowID in
            guard let self else { return }
            let name = self.windowManager.orderingEngine.windowNames[windowID] ?? "?"
            logDebug("SLIDE: FLUSH activate pending target=[\(name)]")
            self.windowManager.activateWindow(windowID)
            self.slideTransition.logPostActivationDiagnostics()
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
                // 轻点不构成新的滑动意图：cancel 会补激活已提交目标（BUG #2 最后一甩不丢）。
                slideTransition.cancel()
                invalidateSlideWatchdog()
            }
            // tap 手势不产生滑动：清掉 trackingBegan 时启动的预捕会话（若未消费）
            BackdropPreCapturer.shared.cancel()
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
                // 纵向手势打断滑动会话：cancel 补激活已提交目标，再进入纵向操作。
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
                // 纵向手势打断滑动会话：cancel 补激活已提交目标，再进入纵向操作。
                slideTransition.cancel()
                invalidateSlideWatchdog()
            }
            if overlayController.isVisible {
                overlayController.hide()
                windowManager.gesturePhase = .idle
                return
            }
            windowManager.gesturePhase = .idle

        case .trackingBegan:
            logDebug("GESTURE: trackingBegan — 三指落地")
            // 三指刚落地、滑动方向未知：若滑动过渡开启，按左右两方向预捕 SCK 背景，
            // 使会话 begin 时背景图已就绪（面板弹出即带完整桌面，根治非全屏源黑闪）。
            // 该手势若最终不是横滑（tap/纵向 swipe），由 gestureEnd/tap 清理预捕会话。
            if settings.slidingTransitionEnabled && settings.quickSwitchModeEnabled
                && settings.backdropCaptureEnabled && !overlayController.isVisible {
                windowManager.beginBackdropPreCapture()
            }

        case .threeFingerSwipeLeft:
            windowManager.gesturePhase = .quickSwitching
            guard !overlayController.isVisible else { return }
            if settings.slidingTransitionEnabled {
                guard settings.quickSwitchModeEnabled else { return }
                if slideTransition.isActive && !slideTransition.isSettling {
                    // 会话跟手中：离散方向事件不改变画面——offset 严格由 swipeUpdate 跟手，
                    // 避免「闪现半屏」瞬移。抬手提交/回弹完全交给 finishSlideSession 的阈值判定。
                    logDebug("SLIDE: mid-session swipeLeft — ignored（严格跟手，离散事件不改画面）")
                } else {
                    // 会话收尾中（settle/fade）：快扫兜底进入三态派发（同向链式/反向重开）。
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
                if slideTransition.isActive && !slideTransition.isSettling {
                    // 会话跟手中：离散方向事件不改变画面——offset 严格由 swipeUpdate 跟手，
                    // 避免「闪现半屏」瞬移。抬手提交/回弹完全交给 finishSlideSession 的阈值判定。
                    logDebug("SLIDE: mid-session swipeRight — ignored（严格跟手，离散事件不改画面）")
                } else {
                    // 会话收尾中（settle/fade）：快扫兜底进入三态派发（同向链式/反向重开）。
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
                // 三态派发：跟手 update / 收尾同向链式 / 未激活或反向全新 begin。
                beginSlideSessionIfNeeded(progress: CGFloat(progress))
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

        case .swipePeakVelocity(let velocity):
            // 方案A：C 引擎按 MT 帧时间戳算出的会话峰值横向速度（progress/sec，
            // 带符号）。路径A 起仅作会话主方向判定与日志诊断，不参与助推。
            logDebug("GESTURE: swipePeakVelocity v=\(String(format: "%.3f", velocity)) progress/s")
            slideTransition.recordPeakVelocity(CGFloat(velocity))

        case .releaseVelocity(let velocity):
            // 路径A：C 引擎按 MT 帧时间戳算出的抬手前即时速度（progress/sec，
            // 带符号，最近3帧均值）。动量助推的唯一速度源——慢速拖拽抬手前停顿/
            // 反向时趋零或反号，方向保护据此让助推归零，回归纯位移判定。
            logDebug("GESTURE: releaseVelocity v=\(String(format: "%.3f", velocity)) progress/s")
            slideTransition.recordReleaseVelocity(CGFloat(velocity))

        case .gestureEnd:
            elasticDrag.cancelWatchdog()
            windowManager.lastGestureEndAt = ProcessInfo.processInfo.systemUptime
            invalidateSlideWatchdog()
            // 连续快甩诊断：手势收尾时的会话状态快照。
            let snapGE = "active=\(slideTransition.isActive) settling=\(slideTransition.isSettling) settleDone=\(slideTransition.settleComplete) lastSettleSign=\(Int(slideTransition.lastSettleSign)) off=\(Int(slideTransition.currentOffset)) carry=\(Int(slideTransition.carryOffset)) peak=\(Int(slideTransition.lastPeakVelocity))"
            logDebug("GESTURE-TRACE t=\(String(format: "%.4f", CACurrentMediaTime())) event=gestureEnd [\(snapGE)]")
            // 手势结束：未消费的预捕会话随手势清理（已消费的会话早已被 begin 的 take 清空）
            BackdropPreCapturer.shared.cancel()
            if slideTransition.isActive {
                // 收尾中（isSettling）：settle/fade 动画自行完成，不重复结算（防双重 settle）。
                if !slideTransition.isSettling {
                    finishSlideSession()
                } else {
                    logDebug("SLIDE: gestureEnd during settle — skipping（settle 动画进行中）")
                }
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

    /// 开启/继续/链式接续滑动过渡会话。首个合格 swipeUpdate 或 Left/Right 快扫兜底
    /// 时调用。三态派发（SlideChain.decision）：
    ///   - 会话未激活 → 全新 begin；
    ///   - 会话跟手中 → 仅喂 progress（update）；
    ///   - 会话收尾中（settle/fade）同向 → 链式接续（复用面板，从打断位置继续）；
    ///   - 会话收尾中反向 → 取消旧会话、全新 begin。
    private func beginSlideSessionIfNeeded(progress: CGFloat) {
        guard AppSettings.shared.quickSwitchModeEnabled else { return }
        let decision = SlideChain.decision(
            isActive: slideTransition.isActive,
            isSettling: slideTransition.isSettling,
            settleComplete: slideTransition.settleComplete,
            newSign: SlideChain.sign(ofProgress: progress),
            lastSettleSign: slideTransition.lastSettleSign)
        // 连续快甩诊断：每个 swipeUpdate/快扫兜底 的派发轨迹。
        let snapshot = "active=\(slideTransition.isActive) settling=\(slideTransition.isSettling) settleDone=\(slideTransition.settleComplete) lastSettleSign=\(Int(slideTransition.lastSettleSign)) off=\(Int(slideTransition.currentOffset)) carry=\(Int(slideTransition.carryOffset)) peak=\(Int(slideTransition.lastPeakVelocity))"
        logDebug("GESTURE-TRACE t=\(String(format: "%.4f", CACurrentMediaTime())) p=\(String(format: "%+.3f", progress)) [\(snapshot)] → decision=\(decision)")
        switch decision {
        case .update:
            slideTransition.update(progress: progress)
            armSlideWatchdog()
        case .chain:
            chainToNextSession(progress: progress)
            armSlideWatchdog()
        case .freshBegin:
            beginFreshSlideSession(progress: progress)
        case .cancelAndFresh:
            if slideTransition.isActive {
                // 反向/重置：用户反悔改向，丢弃已提交目标（不补激活），从新前置重开。
                slideTransition.cancel(flushPending: false)
                invalidateSlideWatchdog()
            }
            beginFreshSlideSession(progress: progress)
        }
    }

    /// 链式接续（连甩连贯）：同向新快甩打断正在收尾的会话，从被打断位置继续滑向
    /// 下一目标。源 = 游标所在窗口（最近一次 commit 已把游标推进到目标位），目标 =
    /// 其 LRU 左右邻。不重捕背景（链式期间未激活、窗口未移动，原背景始终正确）。
    private func chainToNextSession(progress: CGFloat) {
        guard slideTransition.isActive else { return }
        guard let sourceID = windowManager.orderingEngine.id(at: windowManager.orderingEngine.currentIndex) else {
            logDebug("SLIDE-CHAIN: abort — no cursor window")
            slideTransition.cancel()
            invalidateSlideWatchdog()
            return
        }
        let (leftID, rightID) = windowManager.orderingEngine.neighbors(
            of: sourceID, cyclic: AppSettings.shared.cyclicScrollEnabled)
        slideTransition.chainBegin(sourceID: sourceID, leftID: leftID, rightID: rightID,
                                   initialProgress: progress)
    }

    /// 全新滑动过渡会话：刷新窗口取源与 LRU 左右邻，begin 建面板。
    private func beginFreshSlideSession(progress: CGFloat) {
        windowManager.gesturePhase = .slidingTransition
        // 会话开始：取消该滑动自身 scroll 可能已挂起的延迟重排，并记录开始时刻
        //（延迟重排触发时据此识别滑动产物）。此时刷新窗口会同步 LRU。
        windowManager.noteSlideSessionBegan()
        let windows = windowManager.refreshWindows()
        guard windows.count > 1,
              let sourceID = windowManager.frontmostWindowID,
              windowManager.orderingEngine.index(of: sourceID) != nil else {
            logDebug("SLIDE: abort — need >=2 windows and a valid source (count=\(windows.count))")
            windowManager.gesturePhase = .idle
            invalidateSlideWatchdog()
            return
        }

        // 循环滚动开启时边界绕回对侧窗口，与 commit 的 advanceCursor(cyclic:) wrap 一致
        //（画面滑入目标 == 提交激活目标）。
        let (leftID, rightID) = windowManager.orderingEngine.neighbors(
            of: sourceID, cyclic: AppSettings.shared.cyclicScrollEnabled)

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

        // 甩动动量（路径A）：有效位移 = 当前位移 + 抬手前即时速度外推助推。速度取 C
        // 引擎帧级时间基的抬手前即时速度（最近3帧均值），反映抬手瞬间真实意图：
        // 快甩 → 速度高 → 助推补足；慢速拖拽到位后停顿 → 速度≈0 → 助推归零（纯位移
        // 判定）；反向回退 → 速度与主方向相反 → 方向保护归零助推 → 回归纯位移判定。
        // 会话峰值仅用于主方向符号（方向保护）与日志诊断，不参与助推。
        let releaseVel = slideTransition.releaseOffsetVelocity()   // 抬手前即时速度（px/s，带符号，800px/s 下限已拦截）
        let peakVel = slideTransition.peakOffsetVelocity()         // 会话峰值（px/s，仅诊断）
        let mainDirSign = slideTransition.lastPeakVelocity > 0 ? 1
                        : (slideTransition.lastPeakVelocity < 0 ? -1 : 0)
        let boost: CGFloat
        if settings.momentumCommitEnabled {
            let maxBoostPx = CGFloat(settings.momentumMaxBoostRatio) * slideTransition.screenWidth
            boost = momentumBoost(off: off,
                                  releaseVel: releaseVel,
                                  mainDirSign: mainDirSign,
                                  window: CGFloat(settings.momentumBoostWindow),
                                  maxBoostPx: maxBoostPx)
        } else {
            boost = 0
        }
        let effective = off + boost
        let commit = abs(effective) >= thresholdPx
        logDebug("SLIDE: gestureEnd offset=\(Int(off)) releaseVel=\(Int(releaseVel))px/s peakVel=\(Int(peakVel))px/s mainDir=\(mainDirSign) boost=\(Int(boost)) effective=\(Int(effective)) threshold=\(Int(thresholdPx)) commit=\(commit)")

        let cyclic = settings.cyclicScrollEnabled
        if commit {
            let dirRight = effective < 0
            if let target = windowManager.orderingEngine.advanceCursor(directionRight: dirRight, cyclic: cyclic) {
                let targetName = windowManager.orderingEngine.windowNames[target] ?? "?"
                logDebug("SLIDE: commit dirRight=\(dirRight) → 激活 [\(targetName)]")
                // 方案B1：提交即把目标标记为前置。activateWindow（AX 抬升 + app.activate）
                // 仍等 settle 淡出完成后执行；提前更新 frontmostWindowID 消除「提交→激活」
                // 之间的陈旧窗口——快速连续手势的预捕（trackingBegan）落进该窗口会读到旧源、
                // 与 begin 失配，回退全新捕获暴露黑占位闪屏。
                windowManager.markCommitFrontmost(target)
                // 登记待激活目标：settle 落定前若被非链式方式结束（tap/边界丢弃），
                // cancel 会补激活它，避免「滑了没切」（BUG #2）。
                slideTransition.markCommitPending(target)
                slideTransition.settle(finalOffset: effective, commit: true) { [weak self] in
                    self?.windowManager.activateWindow(target)
                    self?.slideTransition.logPostActivationDiagnostics()
                }
                return
            }
            logDebug("SLIDE: boundary wall-bump, rebounding")
        } else {
            logDebug("SLIDE: rebound to source")
        }
        slideTransition.settle(finalOffset: effective, commit: false, onComplete: nil)
    }

    /// 启动/重置滑动会话看门狗：2.5s 内无 progress 更新即自动收尾，防止
    /// MT 事件流停顿导致面板冻结（事件三）。
    private func armSlideWatchdog() {
        slideWatchdogTimer?.invalidate()
        slideWatchdogTimer = Timer.scheduledTimer(withTimeInterval: slideWatchdogPeriod, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.slideTransition.isActive && !self.slideTransition.isSettling {
                // 停顿实锤标记：watchdog 触发意味着 2.5s 内无 swipeUpdate 且无 gestureEnd
                //（正常 gestureEnd 会先 invalidateWatchdog 再 finishSlideSession）。
                // 由此可反推 MT 回调中断 → 引擎停在 SWIPING/3 指 → 面板冻结的机制。
                logDebug("SLIDE-WATCHDOG-STALL: fired offset=\(Int(self.slideTransition.currentOffset)) — no swipeUpdate & no gestureEnd for \(Int(self.slideWatchdogPeriod))s, engine stalled → finishSlideSession()")
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
        // 菜单栏真实像素缓存采集：App 变为前台且尚无缓存时，采集其菜单横条
        //（刘海左侧）。每 App 会话内只采一次（contains 判定），供滑动过渡目标侧用。
        sessionObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let cached = MenuBarImageCache.shared.contains(pid: app.processIdentifier)
            logDebug("MENU-CACHE: activate pid=\(app.processIdentifier) name=\(app.localizedName ?? "?") cached=\(cached)")
            self?.scheduleMenuBarCacheCapture(for: app.processIdentifier)
        })
    }

    // MARK: - 菜单栏真实像素缓存采集

    /// App 变为前台时采集其菜单横条（刘海左侧真实像素）缓存。每 App 会话内只采
    /// 一次（已有缓存跳过）；延迟 ~0.3s 执行以等菜单渲染完成/滑动淡出结束；采集前
    /// 校验 frontmost 仍为该 pid（防延迟窗口内用户切走而采错 App）。源 App 滑动时
    /// 菜单就在整屏背景图里、无需此采集——本缓存专供「目标侧」滑动过渡使用。
    private func scheduleMenuBarCacheCapture(for pid: pid_t, delay: TimeInterval = 0.3) {
        guard AppSettings.shared.menuBarGradientEnabled else {
            logDebug("MENU-CACHE: gradient disabled — skip capture pid=\(pid)")
            return
        }
        let ourPid = ProcessInfo.processInfo.processIdentifier
        guard pid != ourPid else { return }
        guard !MenuBarImageCache.shared.contains(pid: pid) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard pid != ProcessInfo.processInfo.processIdentifier else { return }
            guard !MenuBarImageCache.shared.contains(pid: pid) else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                logDebug("MENU-CACHE: skip pid=\(pid) frontmost changed")
                return
            }
            guard let screen = NSScreen.main else { return }
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            var ownNumbers = Set<CGWindowID>()
            for w in list {
                guard let wpid = w[kCGWindowOwnerPID as String] as? Int, wpid == ourPid else { continue }
                if let num = w[kCGWindowNumber as String] as? Int {
                    ownNumbers.insert(CGWindowID(num))
                }
            }
            do {
                let result = try await BackdropPreCapturer.captureDesktop(
                    size: screen.frame.size,
                    excluding: ownNumbers,
                    panelWindowNumber: nil)
                let scale = CGFloat(result.image.height) / max(screen.frame.height, 1)
                let menuBarPx = max(Int(WindowManager.menuBarHeightPoints * scale), 1)
                let coverW = MenuBarImageCache.leftmostStatusItemX(fallbackScreenWidth: screen.frame.width)
                let coverPx = max(Int(coverW * scale), 1)
                guard let strip = MenuBarImageCache.cropTopStrip(from: result.image,
                                                                 coverWidthPx: coverPx,
                                                                 menuBarPx: menuBarPx) else {
                    logDebug("MENU-CACHE: crop failed pid=\(pid)")
                    return
                }
                MenuBarImageCache.shared.record(pid: pid, strip: strip)
                logDebug("MENU-CACHE: record pid=\(pid) \(strip.width)x\(strip.height)px coverW=\(Int(coverW))")
            } catch {
                logDebug("MENU-CACHE: capture failed pid=\(pid) — \(error.localizedDescription)")
            }
        }
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
