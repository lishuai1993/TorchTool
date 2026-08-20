import AppKit
import CoreGraphics

/// 会话级 scrollWheel 事件 tap：三指手势跟踪期间（`gesture_engine_is_tracking()`）
/// 以及手势结束后的短免疫窗内丢弃 scrollWheel，阻止前台 App（如 Chrome 网页）
/// 随三指移动左右滚动。滑动跟手由 C 引擎（MultitouchSupport 原始触点）驱动，
/// 不依赖 scrollWheel，因此吞掉 scrollWheel 不影响跟手与手感。
final class ScrollSuppressionTap {
    static let shared = ScrollSuppressionTap()

    fileprivate var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retryCount = 0
    private let maxRetries = 3

    /// 免疫窗：tracking 下降沿起 0.6s 内继续丢弃，覆盖系统延迟 ~200-400ms
    /// 送达的残余 scrollWheel，避免「滑动结束后网页再滚一下」。
    private let immunityDuration: TimeInterval = 0.6

    // 以下状态全部在主 run loop 线程访问（tap 源挂主 run loop），无需加锁。
    private var wasTracking = false
    private var suppressedThisGesture = false
    private var dropCount = 0
    private var suppressionLogged = false
    private var immunityUntil: TimeInterval = 0

    private init() {}

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let locations: [(CGEventTapLocation, String)] = [
            (.cgAnnotatedSessionEventTap, "annotated"),
            (.cgSessionEventTap, "session"),
        ]
        for (location, name) in locations {
            guard let t = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: scrollSuppressionTapCallback,
                userInfo: userInfo
            ) else { continue }
            tap = t
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            tapSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            logDebug("SCROLL-SUPPRESS: tap registered (loc=\(name), retry=\(retryCount)) trusted=\(AXIsProcessTrusted())")
            return
        }
        logDebug("SCROLL-SUPPRESS: tap FAILED (retry=\(retryCount)) trusted=\(AXIsProcessTrusted())")
        retryCount += 1
        guard retryCount <= maxRetries else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }

    func stop() {
        if let src = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            tapSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        resetState()
        logDebug("SCROLL-SUPPRESS: tap stopped")
    }

    private func resetState() {
        wasTracking = false
        suppressedThisGesture = false
        dropCount = 0
        suppressionLogged = false
        immunityUntil = 0
    }

    /// 运行在主 run loop。返回 nil = 丢弃该 scrollWheel（不派发给任何 App）。
    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let tracking = gesture_engine_is_tracking()
        let now = ProcessInfo.processInfo.systemUptime

        if tracking {
            wasTracking = true
            suppressedThisGesture = true
            dropCount += 1
            if !suppressionLogged {
                suppressionLogged = true
                logDebug("SCROLL-SUPPRESS: suppress begin (tracking)")
            }
            return nil
        }

        if wasTracking {
            wasTracking = false
            if suppressedThisGesture {
                immunityUntil = now + immunityDuration
                logDebug("SCROLL-SUPPRESS: gesture end — dropped=\(dropCount), immunity \(Int(immunityDuration * 1000))ms")
            }
            suppressedThisGesture = false
            dropCount = 0
        }

        if now < immunityUntil {
            dropCount += 1
            if !suppressionLogged {
                suppressionLogged = true
                logDebug("SCROLL-SUPPRESS: suppress (immunity) dropped=\(dropCount)")
            }
            return nil
        }

        if suppressionLogged {
            suppressionLogged = false
            logDebug("SCROLL-SUPPRESS: pass-through resumed")
        }
        return Unmanaged.passUnretained(event)
    }
}

/// C 桥接回调。tap 源挂主 run loop，故运行在主线程。
private func scrollSuppressionTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<ScrollSuppressionTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = suppressor.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    return suppressor.handle(event: event)
}
