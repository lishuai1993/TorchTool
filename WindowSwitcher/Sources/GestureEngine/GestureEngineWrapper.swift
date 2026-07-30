import AppKit

enum GestureEvent {
    case threeFingerTap
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case swipeUpdate(progress: Float)
}

final class GestureEngine: @unchecked Sendable {
    static let shared = GestureEngine()

    var onGesture: ((GestureEvent) -> Void)?

    private var monitor: Any?
    private var isRunning = false

    // Tap detection state
    private var touchTimer: Timer?
    private var swipeInProgress = false

    private init() {}

    /// Start using MultitouchSupport (C engine, more precise but may crash
    /// if contact data offsets are wrong for this macOS version).
    func startFull() -> Bool {
        if isRunning {
            logDebug("GestureEngine: already running, skipping startFull()")
            return true
        }
        let settings = AppSettings.shared
        gesture_engine_set_sensitivity(
            Float(settings.tapMaxDuration),
            settings.tapMaxDisplacement,
            settings.swipeMinDisplacement,
            0.05
        )
        logDebug("GestureEngine: starting C engine (MultitouchSupport)...")
        let logPath = "/Users/lishuai/lishuai/personal_projects/TorchTool/WindowSwitcher/log.txt"
        gesture_engine_set_log_path(logPath)
        let result = gesture_engine_start { cType, progress in
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
            case GestureSwipeUpdate:
                event = .swipeUpdate(progress: progress)
            default:
                return
            }
            DispatchQueue.main.async {
                GestureEngine.shared.onGesture?(event)
            }
        }
        if result == 0 {
            isRunning = true
            logDebug("GestureEngine: C engine started OK (result=\(result))")
        } else {
            logDebug("GestureEngine: C engine FAILED (result=\(result))")
        }
        return result == 0
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
        isRunning = false
        onGesture = nil
        logDebug("GestureEngine: stopped")
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
