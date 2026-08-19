import AppKit

// File-level counters for the C→Swift callback bridge — must be at file scope
// because the C function pointer closure cannot capture context.
private var cCallbackCount: Int = 0
private var cCallbackLastLogTime: Double = 0

enum GestureEvent {
    case threeFingerTap
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case swipeUpdate(progress: Float)  // signed: positive=right, negative=left
    case trackingBegan  // 3 fingers landed; tracking session started
    case gestureEnd
}

final class GestureEngine: @unchecked Sendable {
    static let shared = GestureEngine()

    var onGesture: ((GestureEvent) -> Void)?

    private var monitor: Any?
    private(set) var isRunning = false

    // Tap detection state
    private var touchTimer: Timer?
    private var swipeInProgress = false

    // Watchdog state — detects when the MT contact stream has stalled and
    // re-registers the device (stream is killed by lock / session / wake).
    // MT callbacks fire only while the trackpad is touched, so a frozen count
    // alone is ambiguous (idle vs stall). We only restart when the count has
    // been frozen WHILE the user is actively providing input (event tap).
    private var watchdogTimer: Timer?
    private var lastCallbackCount: Int = 0
    private var freezeInterval: TimeInterval = 0
    private var lastInputDate: Date?
    private var nextRestartAllowedAt: Date?
    private let watchdogPeriod: TimeInterval = 2.0
    private let freezeThreshold: TimeInterval = 10.0
    private let inputActivityWindow: TimeInterval = 8.0
    private let restartCooldown: TimeInterval = 60.0

    private init() {}

    /// Start using MultitouchSupport (C engine, more precise but may crash
    /// if contact data offsets are wrong for this macOS version).
    func startFull() -> Bool {
        if isRunning {
            logDebug("GestureEngine: already running, skipping startFull()")
            return true
        }
        let settings = AppSettings.shared
        let tapMaxD = Float(settings.tapMaxDuration)
        let tapMaxDisp = settings.tapMaxDisplacement
        let swipeMinDisp = settings.swipeMinDisplacement
        logDebug("GestureEngine: sensitivity — tapMaxDur=\(tapMaxD) tapMaxDisp=\(tapMaxDisp) swipeMinDisp=\(swipeMinDisp)")
        gesture_engine_set_sensitivity(tapMaxD, tapMaxDisp, swipeMinDisp, 0.05)
        gesture_engine_set_touchdown_window(settings.touchdownWindow)
        logDebug("GestureEngine: sensitivity — touchdownWindow=\(String(format: "%.0f", settings.touchdownWindow * 1000))ms")
        logDebug("GestureEngine: starting C engine (MultitouchSupport)...")
        let logPath = "/Users/lishuai/lishuai/personal_projects/TorchTool/WindowSwitcher/log.txt"
        gesture_engine_set_log_path(logPath)
        let result = gesture_engine_start(makeCallback())
        if result == 0 {
            isRunning = true
            logDebug("GestureEngine: C engine started OK (result=\(result))")
        } else {
            logDebug("GestureEngine: C engine FAILED (result=\(result))")
        }
        startWatchdog()
        return result == 0
    }

    /// Re-register the MultitouchSupport device callback. Called after the
    /// contact stream is interrupted (lock/unlock, sleep/wake, session change)
    /// and by the watchdog when a stall is detected.
    func restart() {
        logDebug("GestureEngine: restart() — re-registering MT device")
        gesture_engine_stop()
        let result = gesture_engine_start(makeCallback())
        isRunning = result == 0
        // Re-baseline the heartbeat so the watchdog doesn't immediately
        // see a stale freeze from before the restart.
        lastCallbackCount = Int(gesture_engine_callback_count())
        freezeInterval = 0
        logDebug("GestureEngine: restart() done (result=\(result))")
    }

    private func makeCallback() -> GestureCallback {
        // NOTE: This closure must NOT capture self or any local context,
        // as it's passed to C as a function pointer.
        { cType, progress in
            // Rate-limited heartbeat: log every 120 callbacks to prove C→Swift bridge is alive.
            // Uses file-level vars (no capture allowed in C function pointer closures).
            cCallbackCount += 1
            let now = CACurrentMediaTime()
            if cCallbackCount % 120 == 1 || now - cCallbackLastLogTime > 10.0 {
                cCallbackLastLogTime = now
                logDebug("GestureEngine(Swift): callback #\(cCallbackCount), type=\(cType.rawValue), progress=\(progress)")
            }

            let event: GestureEvent
            switch cType {
            case GestureThreeFingerTap:
                event = .threeFingerTap
                logDebug("GestureEngine(C): TAP detected, progress=\(progress)")
            case GestureThreeFingerSwipeLeft:
                event = .threeFingerSwipeLeft
                logDebug("GestureEngine(C): SWIPE LEFT detected")
            case GestureThreeFingerSwipeRight:
                event = .threeFingerSwipeRight
                logDebug("GestureEngine(C): SWIPE RIGHT detected")
            case GestureThreeFingerSwipeUp:
                event = .threeFingerSwipeUp
                logDebug("GestureEngine(C): SWIPE UP detected")
            case GestureThreeFingerSwipeDown:
                event = .threeFingerSwipeDown
                logDebug("GestureEngine(C): SWIPE DOWN detected")
            case GestureSwipeUpdate:
                event = .swipeUpdate(progress: progress)
            case GestureTrackingBegan:
                event = .trackingBegan
            case GestureEnd:
                event = .gestureEnd
            default:
                return
            }
            DispatchQueue.main.async {
                GestureEngine.shared.onGesture?(event)
            }
        }
    }

    // MARK: - Watchdog

    /// Called on trackpad scroll/swipe events (2-finger scroll and 3-finger
    /// swipe both generate scrollWheel). Used by the watchdog to distinguish
    /// "trackpad in use but stream dead" from idle/typing (where a frozen count
    /// is expected and must NOT trigger a restart).
    func noteTrackpadActivity() {
        lastInputDate = Date()
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        lastCallbackCount = Int(gesture_engine_callback_count())
        freezeInterval = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogPeriod, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        let count = Int(gesture_engine_callback_count())
        if count != lastCallbackCount {
            lastCallbackCount = count
            freezeInterval = 0
            return
        }

        freezeInterval += watchdogPeriod
        guard freezeInterval >= freezeThreshold else { return }

        let now = Date()
        let hasRecentInput = lastInputDate.map { now.timeIntervalSince($0) < inputActivityWindow } ?? false
        if hasRecentInput {
            restartIfCooldownAllows()
        } else {
            // Idle, not a stall — a frozen count is expected when the trackpad
            // is untouched. Reset so a long idle doesn't restart the moment
            // input resumes; if the stream is truly dead, the first touch will
            // re-accumulate and restart.
            freezeInterval = 0
        }
    }

    private func restartIfCooldownAllows() {
        let now = Date()
        if let next = nextRestartAllowedAt, now < next {
            return
        }
        nextRestartAllowedAt = now.addingTimeInterval(restartCooldown)
        logDebug("GestureEngine: watchdog — contact stream stalled while active, restarting")
        restart()
    }

    /// Start using NSEvent global monitor (fallback — may not capture
    /// three-finger gestures already consumed by the system).
    func start() -> Bool {
        guard !isRunning else {
            logDebug("GestureEngine: already running")
            return true
        }
        logDebug("GestureEngine: starting NSEvent global monitor...")
        let mask: NSEvent.EventTypeMask = [
            .swipe, .gesture, .magnify, .beginGesture, .endGesture, .pressure,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }
        isRunning = true
        logDebug("GestureEngine: NSEvent monitor started OK")
        return true
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        stopWatchdog()
        gesture_engine_stop()
        isRunning = false
        onGesture = nil
        logDebug("GestureEngine: stopped")
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Event handling

    private func handleEvent(_ event: NSEvent) {
        logDebug("GestureEngine: event type=\(event.type.rawValue) phase=\(event.phase.rawValue) deltaX=\(event.deltaX) deltaY=\(event.deltaY)")

        switch event.type {
        case .swipe:
            handleSwipe(event)
        case .gesture:
            handleGestureEvent(event)
        case .beginGesture:
            swipeInProgress = true
        case .endGesture:
            swipeInProgress = false
        case .pressure:
            // Pressure events may indicate a tap (quick pressure increase then release)
            handlePressure(event)
        default:
            break
        }
    }

    private func handleSwipe(_ event: NSEvent) {
        // deltaX > 0 = swipe right, deltaX < 0 = swipe left
        if event.deltaX > 0.5 {
            logDebug("GestureEngine: SWIPE RIGHT detected")
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(.threeFingerSwipeRight)
            }
        } else if event.deltaX < -0.5 {
            logDebug("GestureEngine: SWIPE LEFT detected")
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(.threeFingerSwipeLeft)
            }
        }
    }

    private func handleGestureEvent(_ event: NSEvent) {
        // Gesture events may carry swipe-like information
        if event.deltaX > 0.5 {
            logDebug("GestureEngine: GESTURE swipe right")
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(.threeFingerSwipeRight)
            }
        } else if event.deltaX < -0.5 {
            logDebug("GestureEngine: GESTURE swipe left")
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(.threeFingerSwipeLeft)
            }
        }
    }

    private func handlePressure(_ event: NSEvent) {
        // Quick pressure tap (simulated three-finger tap via pressure)
        if event.pressure > 0.5 {
            touchTimer?.invalidate()
            touchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                // If pressure has returned to 0 quickly, it was a tap
                logDebug("GestureEngine: pressure tap detected")
                DispatchQueue.main.async {
                    self?.onGesture?(.threeFingerTap)
                }
            }
        }
    }
}
